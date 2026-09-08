import type { EditorNode } from '../utils/layoutTreeUtils';
import type { EditorExtensionContext, EditorExtensionResult, EditorExtensionSnapshot, ExtensionMediaResult } from './contract';
import { extensionMedia } from './media';
import { attachmentIds, COMPOSITION_SCHEMA, dependencyScope, readComposition, rulesIdentity, rulesSignature,
  validateCompositionNode, type CompositionRules, type ExtensionComposition } from './compositionDocument';

export interface EditorExtensionCompositions {
  export: (request: { expected: EditorExtensionContext; signal?: AbortSignal }) => Promise<ExtensionMediaResult<string>>;
  insert: (request: { expected: EditorExtensionContext; snapshot: string; collection: string; index: number; signal?: AbortSignal }) => Promise<EditorExtensionResult>;
}
export interface CompositionState { snapshot: EditorExtensionSnapshot; rules: CompositionRules }
export function extensionCompositions(read: () => CompositionState | null,
  apply: (expected: EditorExtensionContext, payload: ExtensionComposition, collection: string, index: number) => EditorExtensionResult): EditorExtensionCompositions {
  function current(expected: EditorExtensionContext, signal?: AbortSignal): CompositionState | null {
    const value = read();
    if (signal?.aborted || !value || value.snapshot.context.readonly || value.snapshot.context.editMode !== 'route'
      || JSON.stringify(value.snapshot.context) !== JSON.stringify(expected)) return null;
    return value;
  }
  const media = extensionMedia(() => read()?.snapshot.context ?? null);
  async function assets(node: EditorNode, expected: EditorExtensionContext, signal?: AbortSignal): Promise<boolean> {
    const ids = attachmentIds(node, expected.templateIdentifier);
    if (!ids) return false;
    if (!ids.size) return true;
    const response = await media.list({ expected, scope: 'template', signal });
    return response.ok && [...ids].every(id => response.data.some(asset => String(asset.id) === id));
  }
  return {
    async export({ expected, signal }) {
      const value = current(expected, signal);
      if (!value || !validateCompositionNode(value.snapshot.node, expected.layoutName, value.rules)) return { ok: false, reason: 'unsupported-source' };
      const identity = rulesIdentity(value.rules);
      const signature = await rulesSignature(identity);
      if (!await assets(value.snapshot.node, expected, signal)) return { ok: false, reason: 'asset-unavailable' };
      const latest = current(expected, signal);
      if (!latest || rulesIdentity(latest.rules) !== identity) return { ok: false, reason: 'stale' };
      const payload: ExtensionComposition = { schema_version: COMPOSITION_SCHEMA, templateIdentifier: expected.templateIdentifier,
        layoutName: expected.layoutName, signature, scope: dependencyScope(value.snapshot.node), node: value.snapshot.node };
      const snapshot = JSON.stringify(payload);
      return readComposition(snapshot) ? { ok: true, data: snapshot } : { ok: false, reason: 'size' };
    },
    async insert({ expected, snapshot, collection, index, signal }) {
      const value = current(expected, signal);
      const payload = typeof snapshot === 'string' ? readComposition(snapshot) : null;
      if (!value) return { kind: 'refused', reason: 'stale' };
      if (!payload || payload.templateIdentifier !== expected.templateIdentifier
        || (payload.scope === 'layout' || dependencyScope(payload.node) === 'layout') && payload.layoutName !== expected.layoutName
        || !validateCompositionNode(payload.node, payload.layoutName, value.rules)) return { kind: 'refused', reason: 'invalid' };
      const identity = rulesIdentity(value.rules);
      if (await rulesSignature(identity) !== payload.signature || !await assets(payload.node, expected, signal)) return { kind: 'refused', reason: 'invalid' };
      const latest = current(expected, signal);
      if (!latest || rulesIdentity(latest.rules) !== identity) return { kind: 'refused', reason: 'stale' };
      return apply(expected, payload, collection, index);
    },
  };
}

