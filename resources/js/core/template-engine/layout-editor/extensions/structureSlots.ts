import type { EditorNode } from '../utils/layoutTreeUtils';
import type { EditorSpec, NestingSpec } from '../spec/specTypes';
import type { EditorExtensionField, ExtensionValue } from './contract';
import type { ExtensionCollection } from './structureTypes';
import { canDrop } from '../dnd/nestingRules';
import { plain, record } from './structureIdentity';
import { readExtensionFields } from './fields';

export interface StructureSlot {
  view: ExtensionCollection;
  path: Array<string | number>;
  values: unknown[];
  write: (values: unknown[]) => void;
  seeds: Map<string, unknown>;
  nodeItems: boolean;
  accepts: (value: unknown) => boolean;
  fieldKeys: string[];
  cellProp?: string;
}
const safeKey = (key: unknown): key is string => typeof key === 'string'
  && /^[A-Za-z][A-Za-z0-9_]*$/.test(key) && !['constructor', 'prototype', '__proto__'].includes(key);
const scalar = (value: unknown): value is ExtensionValue => value === null || typeof value === 'string'
  || typeof value === 'boolean' || typeof value === 'number' && Number.isFinite(value);
function label(value: unknown, fallback: string, t: (key: string) => string): string {
  return typeof value === 'string' ? value.startsWith('$t:') ? t(value.slice(3)) : value : fallback;
}
export function owned(value: unknown, source: EditorNode['__source']): boolean {
  if (!record(value)) return true; // scalar array items have their containing node's owner
  if (value.type === 'extension_point' || value.type === 'slot' || typeof value.slot === 'string'
    || typeof value.__editorSlotName === 'string' || value.iteration != null
    || Array.isArray(value.__injectedProps) && value.__injectedProps.length > 0) return false;
  const own = value.__source;
  return own === undefined || record(own) && own.kind === 'route' && own.layout === source?.layout;
}
function itemFields(value: unknown, fields: unknown, t: (key: string) => string): EditorExtensionField[] {
  if (!Array.isArray(fields)) return [];
  return fields.flatMap((field): EditorExtensionField[] => {
    if (!record(field) || !safeKey(field.key) || field.key === 'id') return [];
    const kind = field.widget === 'image' ? 'image' : field.widget === 'link' ? 'link'
      : field.widget === 'boolean' || field.widget === 'select' ? 'choice'
        : ['text', 'i18n-text'].includes(String(field.widget)) ? 'text' : null;
    if (!kind) return [];
    const raw = record(value) ? value[field.key] : field.primary === true ? value : undefined;
    const options = field.widget === 'boolean' ? [{ value: false, label: '아니요' }, { value: true, label: '예' }]
      : Array.isArray(field.options) ? field.options.flatMap(option => record(option) && scalar(option.value)
        ? [{ value: option.value, label: label(option.label, String(option.value), t) }] : []) : [];
    return [{ id: field.key, label: label(field.label, field.key, t), kind, group: 'content',
      value: scalar(raw) ? raw : null, options, editable: plain(raw), custom: false, source: 'template-spec' }];
  });
}

/** Enumerate only declared slots. Prop cell trees never pass through ComponentPath indexes. */
export function structureSlots(anchor: EditorNode, spec: EditorSpec | null | undefined,
  nesting: NestingSpec | null | undefined, t: (key: string) => string = key => key, iterationTemplate = false): StructureSlot[] {
  const slots: StructureSlot[] = [];
  const source = anchor.__source;
  const add = (path: Array<string | number>, name: string, kind: ExtensionCollection['kind'], raw: unknown,
    write: StructureSlot['write'], seeds: Map<string, unknown>, accepts: StructureSlot['accepts'],
    nodeItems: boolean, fields?: unknown, defaults?: unknown[]): StructureSlot | null => {
    // Opaque/bound collections are shown, but no command may materialize over them.
    const editable = raw === undefined || Array.isArray(raw);
    const values = Array.isArray(raw) ? raw : raw === undefined && defaults ? structuredClone(defaults) : [];
    const view: ExtensionCollection = { id: JSON.stringify(path), label: name, kind, editable,
      choices: [...seeds.keys()].map(id => ({ id, label: label(spec?.componentPalette?.entries?.[id]?.label, id === 'item' ? name : id, t) })),
      items: values.map((value, index) => ({
        id: record(value) && typeof value.id === 'string' ? value.id : String(index),
        label: record(value) ? String(value.name ?? value.label ?? value.title ?? value.id ?? name + ' ' + (index + 1)) : String(value),
        editable: owned(value, source), fields: nodeItems && record(value)
          ? [...(typeof value.text === 'string' ? [{ id: 'node:text', label: '문구', kind: 'text' as const,
            group: 'content' as const, value: value.text, options: [], editable: plain(value.text), custom: false, source: 'template-spec' as const }] : []),
            ...readExtensionFields(value, spec, t)] : itemFields(value, fields, t),
      })) };
    const slot: StructureSlot = { view, path, values, write, seeds, accepts, nodeItems,
      fieldKeys: Array.isArray(fields) ? fields.flatMap(field => record(field) && field.primary === true && safeKey(field.key) ? [field.key] : []) : [] };
    slots.push(slot);
    return editable ? slot : null;
  };
  const walk = (node: EditorNode, path: Array<string | number>, prefix: string, depth: number, branchOnly = false, changed: () => void = () => {}): void => {
    if (depth > 24 || slots.length > 256 || !record(node) || !(iterationTemplate && depth === 0 || owned(node, source))) return;
    const name = typeof node.name === 'string' ? node.name : '';
    const capability = spec?.componentCapabilities?.[name];
    const editor = capability?.nodeEditor;
    const params = record(editor?.params) ? editor.params : {};
    const declaredChild = editor?.kind === 'children' && typeof params.childComponent === 'string' ? params.childComponent : null;
    const accepted = declaredChild ? [declaredChild] : nesting?.containers?.[name]?.accepts ?? [];
    const accepts = (value: unknown): boolean => record(value) && typeof value.name === 'string'
      && (declaredChild ? value.name === declaredChild : canDrop({ draggedComponentName: value.name, targetContainerName: name, nesting }));
    if (accepted.length) {
      const seeds = new Map<string, unknown>();
      for (const child of accepted) {
        const seed = declaredChild === child && record(params.childTemplate) ? params.childTemplate : spec?.componentPalette?.entries?.[child]?.defaultNode;
        if (record(seed) && seed.name === child && accepts(seed)) seeds.set(child, seed);
      }
      const slot = add([...path, 'children'], prefix + ' · 자식', 'children', node.children,
        values => { node.children = values; changed(); }, seeds, accepts, true);
      slot?.values.forEach((child, index) => {
        if (record(child)) walk(child, [...path, 'children', index], prefix + ' / ' + String(child.name ?? index + 1), depth + 1, false, changed);
      });
    }
    // Existing responsive branches are distinct slots; never create/flatten a branch implicitly.
    if (!(iterationTemplate && depth === 0) && record(node.responsive)) for (const [key, branch] of Object.entries(node.responsive)) {
      if (record(branch) && Array.isArray(branch.children)) {
        const synthetic: EditorNode = { name: node.name, type: node.type, __source: node.__source, children: branch.children };
        const before = slots.length;
        walk(synthetic, [...path, 'responsive', key], prefix + ' [' + key + ']', depth + 1, true, changed);
        const first = slots[before];
        if (first && first.path.join('.') === [...path, 'responsive', key, 'children'].join('.')) first.write = values => { branch.children = values; changed(); };
      }
    }
    if (branchOnly || iterationTemplate && depth === 0 || node.props !== undefined && !record(node.props)) return;
    const definitions = editor?.kind === 'array-group' && Array.isArray(params.groups)
      ? params.groups.filter(record).map(params => ({ kind: 'array', params })) : [{ kind: editor?.kind, params }];
    for (const definition of definitions) {
    const params = definition.params;
    if (!['array', 'array-cell-tree'].includes(definition.kind ?? '') || !safeKey(params.arrayProp)) continue;
    // The native command remaps standard id references only. Never clone an unknown identity contract.
    if (params.idField !== undefined && params.idField !== 'id') continue;
    const prop = params.arrayProp;
    const props = record(node.props) ? node.props : {};
    const itemLabel = label(params.itemLabel, prop, t);
    const seeds = new Map<string, unknown>();
    if (params.newItem !== undefined) seeds.set('item', params.newItem);
    const array = add([...path, 'props', prop], prefix + ' · ' + itemLabel, 'array', props[prop],
      values => { node.props = { ...node.props, [prop]: values }; changed(); }, seeds, value => record(value) || typeof value === 'string' || typeof value === 'number', false,
      params.fields, Array.isArray(params.defaultItems) ? params.defaultItems : undefined);
    if (!array || definition.kind !== 'array-cell-tree') continue;
    const cellProp = safeKey(params.cellChildrenProp) ? params.cellChildrenProp : 'cellChildren';
    array.cellProp = cellProp;
    const cellName = typeof params.cellChildComponent === 'string' ? params.cellChildComponent : 'Div';
    array.values.forEach((item, index) => {
      if (!record(item) || !owned(item, source)) return;
      const seed = spec?.componentPalette?.entries?.[cellName]?.defaultNode;
      const cellSeeds = new Map<string, unknown>();
      if (record(seed) && seed.name === cellName) cellSeeds.set(cellName, seed);
      const cell = add([...path, 'props', prop, index, cellProp], prefix + ' / ' + itemLabel + ' ' + (index + 1), 'cell', item[cellProp],
        values => { item[cellProp] = values; array.write(array.values); }, cellSeeds,
        value => record(value) && value.name === cellName, true);
      cell?.values.forEach((child, childIndex) => {
        if (record(child)) walk(child, [...path, 'props', prop, index, cellProp, childIndex], prefix + ' / ' + (index + 1) + ' / ' + String(child.name), depth + 1, false, () => array.write(array.values));
      });
    });
    }
  };
  walk(anchor, [], String(anchor.name ?? ''), 0);
  return slots;
}
