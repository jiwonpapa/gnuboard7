import { afterEach, expect, it, vi } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { ComponentRegistry } from '../../../ComponentRegistry';
import { useExtensionHost } from '../../extensions/useExtensionHost';
import { useRevisionedDocument } from '../../hooks/useRevisionedDocument';
import { useEditorHistory } from '../../hooks/useEditorHistory';
import type { UseLayoutDocumentResult, LoadedLayoutDocument } from '../../hooks/useLayoutDocument';
import type { LayoutEditorState } from '../../LayoutEditorContext';
import type { EditorNode } from '../../utils/layoutTreeUtils';
import type { EditorExtensionContext } from '../../extensions/contract';
import type { EditorSpec } from '../../spec/specTypes';
import { extensionCompositions, type CompositionState } from '../../extensions/compositions';
import { canonical, dependencyScope, insertComposition, readComposition, type CompositionRules } from '../../extensions/compositionDocument';
import { listLayoutAttachments } from '../../utils/layoutAttachments';
vi.mock('../../utils/layoutAttachments', () => ({ listLayoutAttachments: vi.fn(), uploadLayoutAttachment: vi.fn() }));
const context: EditorExtensionContext = { templateIdentifier: 'theme', layoutName: 'source', sessionId: 's', revision: 1,
  lockVersion: 1, readonly: false, nodeId: 'group', path: [0], editMode: 'route' };
const source = { kind: 'route' as const, layout: 'source' };
const node: EditorNode = { name: 'Div', type: 'basic', id: 'group', __source: source, props: { future: {} }, children: [
  { name: 'P', type: 'basic', id: 'target', text: 'Original', __source: source },
  { name: 'A', type: 'basic', id: 'link', text: 'Jump', props: { href: '#target' }, __source: source },
] };
const spec: EditorSpec = { componentCapabilities: { Div: {}, P: {}, A: {} }, nesting: { draggable: ['Div', 'P', 'A'],
  containers: { Div: { accepts: ['Div', 'P', 'A'] } } }, componentPalette: { entries: { P: { defaultNode: { type: 'basic', name: 'P', text: 'new' } } } } };
const rules: CompositionRules = { spec, nesting: spec.nesting, manifest: { version: '1' }, hasComponent: name => ['Div', 'P', 'A'].includes(name) };
function fixture() {
  let value: CompositionState = { snapshot: { context: structuredClone(context), node: structuredClone(node) }, rules: { ...rules } };
  const apply = vi.fn(() => ({ kind: 'applied' as const }));
  return { host: extensionCompositions(() => value, apply), apply, value,
    update(next: CompositionState) { value = next; } };
}
afterEach(() => vi.restoreAllMocks());
it('exports an immutable snapshot and clones declared IDs and internal refs into another allowed parent', async () => {
  const f = fixture(); const result = await f.host.export({ expected: context }); expect(result.ok).toBe(true);
  if (!result.ok) throw new Error(result.reason);
  const payload = readComposition(result.data)!; expect(payload.node).toEqual(node); expect(payload.scope).toBe('template');
  const destination = { ...node, id: 'destination', children: [], __source: { kind: 'route' as const, layout: 'destination' } };
  const inserted = insertComposition(destination, payload, '["children"]', 0, [node, destination], rules)!;
  const copy = (inserted.children as EditorNode[])[0]; const items = copy.children as EditorNode[];
  expect(copy.id).not.toBe(node.id); expect(items[0].id).not.toBe('target');
  expect(items[1].props?.href).toBe('#' + items[0].id); expect(items[0].__source?.layout).toBe('destination');
  expect(copy.props).toEqual({ future: {} }); expect(node.children).toHaveLength(2);
  expect(insertComposition(destination, payload, '["missing"]', 0, [], rules)).toBeNull();
});
it.each(['schema', 'template', 'signature', 'renderer', 'nesting', 'source'] as const)('refuses incompatible %s without applying any history command', async kind => {
  const f = fixture(); const result = await f.host.export({ expected: context }); if (!result.ok) throw new Error(result.reason);
  const payload = JSON.parse(result.data);
  if (kind === 'schema') payload.schema_version = 'future';
  if (kind === 'template') payload.templateIdentifier = 'other';
  if (kind === 'signature') payload.signature = '0'.repeat(64);
  if (kind === 'renderer') f.value.rules = { ...rules, hasComponent: () => false };
  if (kind === 'nesting') f.value.rules = { ...rules, nesting: { containers: { Div: { accepts: [] } } } };
  if (kind === 'source') payload.node.children[0].__source.kind = 'base';
  const applied = await f.host.insert({ expected: context, snapshot: JSON.stringify(payload), collection: '["children"]', index: 0 });
  expect(applied.kind).toBe('refused'); expect(f.apply).not.toHaveBeenCalled();
});
it('keeps bound and external-reference combinations in their original layout', async () => {
  expect(dependencyScope({ ...node, text: '{{user.name}}' })).toBe('layout');
  expect(dependencyScope({ ...node, props: { href: '#outside' } })).toBe('layout');
  const f = fixture(); f.value.snapshot.node.text = '{{user.name}}';
  const exported = await f.host.export({ expected: context }); if (!exported.ok) throw new Error(exported.reason);
  f.value.snapshot.context = { ...context, layoutName: 'other' };
  expect((await f.host.insert({ expected: f.value.snapshot.context, snapshot: exported.data, collection: '["children"]', index: 0 })).kind).toBe('refused');
  expect(f.apply).not.toHaveBeenCalled();
});
it('checks real attachment inventory and refuses a deleted asset or a late response', async () => {
  const f = fixture(); f.value.snapshot.node.props = { src: '/api/templates/theme/layout-attachments/7/file' };
  vi.mocked(listLayoutAttachments).mockResolvedValue({ ok: true, data: [{ id: 7, layout_name: 'source', original_name: 'x.png', mime_type: 'image/png', size: 1, url: '/api/templates/theme/layout-attachments/7/file' }] });
  const exported = await f.host.export({ expected: context }); if (!exported.ok) throw new Error(exported.reason);
  vi.mocked(listLayoutAttachments).mockResolvedValue({ ok: true, data: [] });
  expect((await f.host.insert({ expected: context, snapshot: exported.data, collection: '["children"]', index: 0 })).kind).toBe('refused');
  vi.mocked(listLayoutAttachments).mockImplementation(async () => { f.value.snapshot.context = { ...context, revision: 2 }; return { ok: true, data: [] }; });
  expect((await f.host.export({ expected: context })).ok).toBe(false); expect(f.apply).not.toHaveBeenCalled();
});
it.each(['readonly', 'stale', 'cancelled', 'iteration'] as const)('refuses %s export', async kind => {
  const f = fixture(); const abort = new AbortController();
  if (kind === 'readonly') f.value.snapshot.context.readonly = true;
  if (kind === 'stale') f.value.snapshot.context.revision = 2;
  if (kind === 'cancelled') abort.abort();
  if (kind === 'iteration') f.value.snapshot.context.editMode = 'iteration_item';
  expect((await f.host.export({ expected: context, signal: abort.signal })).ok).toBe(false);
});
it('rejects malformed data and preserves canonical key ordering', () => {
  expect(readComposition('bad')).toBeNull(); expect(readComposition(' '.repeat(262145))).toBeNull();
  expect(canonical({ b: 1, a: {} })).toBe(canonical({ a: {}, b: 1 }));
});
it('uses one real host history entry with Undo/Redo and refuses stale asynchronous reuse', async () => {
  const registry = ComponentRegistry.createIsolatedInstance();
  const adminRegistry = ComponentRegistry.getInstance();
  vi.spyOn(adminRegistry, 'getTemplateId').mockReturnValue('admin-theme');
  const renderer = { templateIdentifier: 'theme', manifest: null, hasComponent: (name: string) => registry.hasComponent(name) };
  vi.spyOn(registry, 'getTemplateId').mockReturnValue('theme'); vi.spyOn(registry, 'getLoadingState').mockReturnValue('loaded');
  vi.spyOn(registry, 'getManifest').mockReturnValue(null); vi.spyOn(registry, 'hasComponent').mockReturnValue(true);
  const { result } = renderHook(() => {
    const cell = useRevisionedDocument<LoadedLayoutDocument>('source'); const history = useEditorHistory<EditorNode[]>();
    const document = { document: cell.value, readExtensionDocument: cell.read, isLoading: false, error: null,
      patchLayout: (patch: (nodes: EditorNode[]) => EditorNode[]) => cell.set(prev => prev ? { ...prev, raw: { ...prev.raw, components: patch(prev.raw.components as EditorNode[]) } } : prev),
    } as UseLayoutDocumentResult;
    const state = { templateIdentifier: 'theme', editMode: 'route', selectedRoute: { path: '/source', layoutName: 'source' } } as LayoutEditorState;
    return { cell, history, host: useExtensionHost({ state, document, selectedPath: '0', locked: false, history, spec, nesting: spec.nesting, renderer }) };
  });
  act(() => { result.current.cell.set({ layoutName: 'source', raw: { components: [node] }, lockVersion: 1 }); result.current.history.push({ snapshot: [node] }); });
  const host = result.current.host; const expected = host.snapshot!.context;
  const exported = await host.compositions!.export({ expected }); if (!exported.ok) throw new Error(exported.reason);
  await act(async () => { expect((await host.compositions!.insert({ expected, snapshot: exported.data, collection: '["children"]', index: 2 })).kind).toBe('applied'); });
  expect(result.current.host.snapshot!.node.children).toHaveLength(3);
  await act(async () => { expect((await host.compositions!.insert({ expected, snapshot: exported.data, collection: '["children"]', index: 2 })).kind).toBe('refused'); });
  act(() => { const snapshot = result.current.history.undo()!.snapshot; result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot!.node).toEqual(node); expect(result.current.history.canUndo).toBe(false);
  act(() => { const snapshot = result.current.history.redo()!.snapshot; result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot!.node.children).toHaveLength(3);
});

