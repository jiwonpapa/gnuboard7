import type { EditorNode } from '../utils/layoutTreeUtils';
import type { EditorSpec, NestingSpec } from '../spec/specTypes';
import { cloneStructureItem } from './structureCommand';
import { record, allIds } from './structureIdentity';
import { structureSlots } from './structureSlots';

export const COMPOSITION_SCHEMA = 'g7.editor-composition/v1';
export interface ExtensionComposition {
  schema_version: typeof COMPOSITION_SCHEMA;
  templateIdentifier: string;
  layoutName: string;
  signature: string;
  scope: 'template' | 'layout';
  node: EditorNode;
}
export interface CompositionRules {
  spec: EditorSpec | null | undefined;
  nesting: NestingSpec | null | undefined;
  manifest: unknown;
  hasComponent: (name: string) => boolean;
}
export type CompositionRenderer = Pick<CompositionRules, 'manifest' | 'hasComponent'> & { templateIdentifier: string | null };
/** Canonical JSON makes object key order irrelevant, without normalizing source values. */
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (record(value)) return '{' + Object.keys(value).sort().filter(key => value[key] !== undefined)
    .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value) ?? 'null';
}
export function rulesIdentity(rules: CompositionRules): string {
  return canonical({ spec: rules.spec, nesting: rules.nesting, manifest: rules.manifest });
}
export async function rulesSignature(identity: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(identity));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}
export function readComposition(snapshot: string): ExtensionComposition | null {
  if (new TextEncoder().encode(snapshot).length > 262144) return null;
  try {
    const value: unknown = JSON.parse(snapshot);
    if (!record(value) || value.schema_version !== COMPOSITION_SCHEMA || !record(value.node)
      || typeof value.templateIdentifier !== 'string' || typeof value.layoutName !== 'string'
      || typeof value.signature !== 'string' || !/^[a-f0-9]{64}$/.test(value.signature)
      || !['template', 'layout'].includes(String(value.scope))) return null;
    return { schema_version: COMPOSITION_SCHEMA, node: value.node, templateIdentifier: value.templateIdentifier,
      layoutName: value.layoutName, signature: value.signature, scope: value.scope === 'layout' ? 'layout' : 'template' };
  } catch { return null; }
}
export function dependencyScope(node: EditorNode): 'template' | 'layout' {
  const ids = allIds(node);
  const references = new Set(['htmlFor', 'targetId', 'componentId', 'activeTabId', 'aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns']);
  const outside = (value: unknown): boolean => !!value && typeof value === 'object' && Object.entries(value).some(([key, child]) => {
    if (key === '__source') return false;
    if (typeof child === 'string' && key === 'href' && child.startsWith('#')) return !ids.has(child.slice(1));
    if (typeof child === 'string' && references.has(key)) return child.split(/\s+/).some(id => !ids.has(id));
    return outside(child);
  });
  return outside(node) || /\{\{|\$[\w-]+:|"actions"\s*:|"iteration"\s*:|"condition"\s*:/.test(JSON.stringify(node)) ? 'layout' : 'template';
}
export function validateCompositionNode(node: EditorNode, origin: string, rules: CompositionRules): boolean {
  if (!record(node.__source) || node.__source.kind !== 'route' || node.__source.layout !== origin) return false;
  let count = 0;
  const scan = (value: unknown, depth: number): boolean => {
    if (depth > 48 || ++count > 10000) return false;
    if (!value || typeof value !== 'object') return true;
    if (record(value)) {
      if (Object.keys(value).some(key => ['__proto__', 'constructor', 'prototype'].includes(key))) return false;
      if (typeof value.name === 'string' && ['basic', 'composite', 'layout'].includes(String(value.type))) {
        if (!rules.hasComponent(value.name) || !rules.spec?.componentCapabilities?.[value.name]) return false;
      }
    }
    return Object.entries(value).every(([key, child]) => key === '__source' || scan(child, depth + 1));
  };
  if (!scan(node, 0)) return false;
  if (structureSlots(node, rules.spec, rules.nesting).some(slot => slot.nodeItems && slot.values.some(value => !slot.accepts(value)))) return false;
  try {
    // Reuse the host's declared structure/identity/source validator; never sanitize an unsupported subtree.
    cloneStructureItem(node, { nodeItems: true }, node, node.__source, rules.spec, rules.nesting);
    return true;
  } catch { return false; }
}
export function attachmentIds(node: EditorNode, template: string): Set<string> | null {
  const ids = new Set<string>();
  let valid = true;
  const scan = (value: unknown): void => {
    if (typeof value === 'string' && value.includes('/layout-attachments/')) {
      const match = value.match(/^\/api\/templates\/([^/]+)\/layout-attachments\/([0-9]+)\/file$/);
      if (!match || decodeURIComponent(match[1]) !== template) valid = false;
      else ids.add(match[2]);
    } else if (value && typeof value === 'object') Object.values(value).forEach(scan);
  };
  try { scan(node); } catch { return null; }
  return valid ? ids : null;
}
export function insertComposition(anchor: EditorNode, payload: ExtensionComposition, collection: string, index: number,
  document: unknown, rules: CompositionRules): EditorNode | null {
  const next = structuredClone(anchor);
  const slot = structureSlots(next, rules.spec, rules.nesting).find(item => item.view.id === collection);
  if (!slot?.nodeItems || !slot.view.editable || !slot.accepts(payload.node) || !Number.isSafeInteger(index) || index < 0 || index > slot.values.length) return null;
  try {
    const copy = cloneStructureItem(payload.node, { nodeItems: true }, document, payload.node.__source, rules.spec, rules.nesting);
    if (!record(copy)) return null;
    const rebase = (value: unknown): void => {
      if (!value || typeof value !== 'object') return;
      if (record(value) && record(value.__source)) {
        if (value.__source.kind !== 'route' || value.__source.layout !== payload.layoutName) throw new Error('source');
        value.__source = { ...value.__source, layout: anchor.__source?.layout };
      }
      Object.entries(value).forEach(([key, child]) => { if (key !== '__source') rebase(child); });
    };
    rebase(copy); slot.values.splice(index, 0, copy); slot.write(slot.values);
    return next;
  } catch { return null; }
}

