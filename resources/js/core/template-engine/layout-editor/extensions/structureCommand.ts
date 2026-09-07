import type { EditorNode } from '../utils/layoutTreeUtils';
import type { EditorSpec, NestingSpec } from '../spec/specTypes';
import type { ExtensionStructureChange } from './structureTypes';
import { structureSlots, owned, type StructureSlot } from './structureSlots';
import { allIds, freshId, hasOutsideReference, plain, record, remapReferences } from './structureIdentity';
import { changeExtensionField } from './fields';
import type { ExtensionValue } from './contract';

function containsProtected(value: unknown, source: EditorNode['__source']): boolean {
  if (!value || typeof value !== 'object') return false;
  if (record(value) && !owned(value, source)) return true;
  return Object.entries(value).some(([key, child]) => key !== '__source' && containsProtected(child, source));
}

function identityOwners(value: unknown, nodeItems: boolean, spec: EditorSpec | null | undefined,
  nesting: NestingSpec | null | undefined, cellProp?: string): Set<Record<string, unknown>> {
  const owners = new Set<Record<string, unknown>>();
  if (!record(value)) return owners;
  if ('id' in value || nodeItems) owners.add(value);
  if (cellProp && Array.isArray(value[cellProp])) for (const child of value[cellProp]) {
    identityOwners(child, true, spec, nesting).forEach(owner => owners.add(owner));
  }
  if (nodeItems) for (const slot of structureSlots(value, spec, nesting)) {
    for (const child of slot.values) if (record(child) && (slot.nodeItems || 'id' in child)) owners.add(child);
  }
  return owners;
}
function cloneItem(value: unknown, slot: StructureSlot, document: unknown, source: EditorNode['__source'],
  spec: EditorSpec | null | undefined, nesting: NestingSpec | null | undefined): unknown {
  const clone: unknown = structuredClone(value);
  const ids = allIds(document);
  const mapping = new Map<string, string>();
  const owners = identityOwners(clone, slot.nodeItems, spec, nesting, slot.cellProp);
  const undeclaredIdentity = (value: unknown): boolean => {
    if (!value || typeof value !== 'object') return false;
    if (record(value) && typeof value.name === 'string' && ['basic', 'composite', 'layout'].includes(String(value.type)) && !owners.has(value)) return true;
    return Object.entries(value).some(([key, child]) => key !== '__source' && undeclaredIdentity(child));
  };
  if (containsProtected(clone, source) || undeclaredIdentity(clone)) throw new Error('unsupported subtree');
  for (const owner of owners) {
    if (!owned(owner, source)) throw new Error('protected source');
    const old = owner.id;
    if (old !== undefined && typeof old !== 'string') throw new Error('unsupported identity');
    if (typeof old === 'string' && old && mapping.has(old)) throw new Error('duplicate identity');
    const id = freshId(ids);
    if (typeof old === 'string' && old) mapping.set(old, id);
    owner.id = id;
    if (typeof owner.name === 'string' && owner.__source === undefined) owner.__source = { ...source };
  }
  if (!remapReferences(clone, mapping, owners)) throw new Error('unresolved reference');
  return clone;
}
function fieldChange(slot: StructureSlot, index: number, fieldId: string, value: ExtensionValue, spec?: EditorSpec | null): boolean {
  const field = slot.view.items[index]?.fields.find(field => field.id === fieldId);
  if (!field?.editable || !plain(value) || value === undefined) return false;
  if (field.options.length && !field.options.some(option => option.value === value)) return false;
  if (field.kind !== 'choice' && typeof value !== 'string') return false;
  if ((field.kind === 'image' || field.kind === 'link') && typeof value === 'string'
    && (/[\u0000-\u0020\u007f\\]/.test(value) || !(/^(https?:\/\/|\/(?!\/))/.test(value) || value === ''
      || field.kind === 'link' && /^(#|mailto:|tel:)/.test(value)))) return false;
  const item = slot.values[index];
  if (slot.nodeItems && record(item)) {
    const next = fieldId === 'node:text' ? { ...item, text: value }
      : changeExtensionField(item, spec, fieldId, value, false);
    if (!next) return false;
    slot.values[index] = next;
  } else if (record(item)) slot.values[index] = { ...item, [fieldId]: value };
  else if (slot.fieldKeys.includes(fieldId)) slot.values[index] = value;
  else return false;
  slot.write(slot.values);
  return true;
}
/** One selected anchor, one patch and one host history entry, including cross-slot moves. */
export function changeStructure(anchor: EditorNode, command: ExtensionStructureChange, document: unknown,
  spec: EditorSpec | null | undefined, nesting: NestingSpec | null | undefined, iterationTemplate = false): EditorNode | null {
  const next = structuredClone(anchor);
  const slots = structureSlots(next, spec, nesting, undefined, iterationTemplate);
  const slot = slots.find(item => item.view.id === command.collection);
  if (!slot?.view.editable || !Number.isSafeInteger(command.index) || command.index < 0) return null;
  const index = command.index;
  try {
    if (command.operation === 'insert') {
      if (index > slot.values.length || !slot.seeds.has(command.choice)) return null;
      const value = cloneItem(slot.seeds.get(command.choice), slot, document, anchor.__source, spec, nesting);
      if (!slot.accepts(value)) return null;
      slot.values.splice(index, 0, value);
    } else {
      if (index >= slot.values.length || !slot.view.items[index]?.editable) return null;
      const value = slot.values[index];
      // Source locks below a subtree are not bypassed by operating on its parent.
      const nested = record(value) && slot.nodeItems ? structureSlots(value, spec, nesting) : [];
      if (nested.some(childSlot => childSlot.view.items.some(item => !item.editable))) return null;
      if (command.operation === 'field') return fieldChange(slot, index, command.field, command.value, spec) ? next : null;
      if (containsProtected(value, anchor.__source)) return null;
      if (command.operation === 'delete') {
        // Document and removed value must share identity for exclusion; use the original slot value.
        const original = structureSlots(anchor, spec, nesting, undefined, iterationTemplate).find(item => item.view.id === slot.view.id)?.values[index];
        if (hasOutsideReference(document, original, allIds(value))) return null;
        slot.values.splice(index, 1);
      } else if (command.operation === 'duplicate') {
        const cloned = cloneItem(value, slot, document, anchor.__source, spec, nesting);
        slot.values.splice(index + 1, 0, cloned);
      } else if (command.operation === 'move') {
        const destination = slots.find(item => item.view.id === command.destination);
        if (!destination?.view.editable || destination.nodeItems !== slot.nodeItems
          || !Number.isSafeInteger(command.toIndex) || command.toIndex < 0 || command.toIndex > destination.values.length
          || !destination.accepts(value)) return null;
        // Arrays have component-specific record contracts. Cross-array transfer is not implied.
        if (!slot.nodeItems && destination !== slot) return null;
        const childPath = [...slot.path, index];
        if (childPath.every((segment, i) => destination.path[i] === segment)) return null;
        slot.values.splice(index, 1);
        const at = command.toIndex - (slot === destination && command.toIndex > index ? 1 : 0);
        destination.values.splice(at, 0, value);
        destination.write(destination.values);
      } else return null;
    }
    slot.write(slot.values);
    return next;
  } catch { return null; }
}
