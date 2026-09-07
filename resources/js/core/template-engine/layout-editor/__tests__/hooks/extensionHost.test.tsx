import { normalizeExtensionPath } from '../../extensions/path';
import { insertNode } from '../../utils/layoutTreeUtils';
import { exposeLayoutEditorGlobals } from '../../spec/exposeLayoutEditorGlobals';
import { act, renderHook } from '@testing-library/react';
import { expect, it } from 'vitest';
import { useRevisionedDocument } from '../../hooks/useRevisionedDocument';
import { useExtensionHost } from '../../extensions/useExtensionHost';
import { useEditorHistory } from '../../hooks/useEditorHistory';
import { prepareExtensionCommand, frozenCopy } from '../../extensions/command';
import { registerPanel, readPanels } from '../../extensions/panelRegistry';
import type { EditorExtensionContext } from '../../extensions/contract';
import type { LayoutEditorState } from '../../LayoutEditorContext';
import type { LoadedLayoutDocument, UseLayoutDocumentResult } from '../../hooks/useLayoutDocument';
import type { EditorNode } from '../../utils/layoutTreeUtils';
const original: EditorNode = { id: 'heading', name: 'H2', type: 'basic', text: 'Before',
  __source: { kind: 'route', layout: 'test' }, props: { title: '$t:hello', onClick: [{ action: 'navigate', url: '/a' }] },
  responsive: { mobile: { text: '{{item.name}}' } }, future: { kept: ['x', 42] } };
const context: EditorExtensionContext = { templateIdentifier: 'theme', layoutName: 'test', editMode: 'route',
  sessionId: 'session', revision: 1, lockVersion: 4, readonly: false, nodeId: 'heading', path: [0] };
const command = { kind: 'setText' as const, expected: context, text: 'After' };
// @scenario operation=text, source=route
// @effects route_changes_text_only, immutable_snapshot
it('changes only text, detaches snapshots, and treats no-op distinctly', () => {
  const input = frozenCopy([original]);
  const result = prepareExtensionCommand(input, context, command, null);
  expect(result.result.kind).toBe('applied');
  expect(result.components).toEqual([{ ...original, text: 'After' }]);
  expect(input).toEqual([original]);
  expect(Object.isFrozen(input[0].future)).toBe(true);
  expect(prepareExtensionCommand(input, context, { ...command, text: 'Before' }, null).result.kind).toBe('noop');
});
it.each(['sessionId', 'revision', 'lockVersion', 'templateIdentifier', 'layoutName', 'nodeId', 'path'] as const)
('rejects changed %s without modifying input', key => {
  const current = { ...context, [key]: key === 'path' ? [1] : 'changed' } as EditorExtensionContext;
  const result = prepareExtensionCommand([original], current, command, null);
  expect(result.result).toEqual({ kind: 'refused', reason: 'stale' });
  expect(result.components).toEqual([original]);
});
// @scenario operation=text, source=base
// @scenario operation=text, source=partial
// @scenario operation=text, source=extension
// @effects protected_sources_have_no_mutation
it.each(['base', 'partial', 'extension'] as const)('rejects protected %s source', kind => {
  expect(prepareExtensionCommand([{ ...original, __source: { kind } }], context, command, null).result.kind).toBe('refused');
});
it.each(['{{item.title}}', '$t:hello', '$local:text', '<b>text</b>'])('preserves binding/markup %s', text => {
  const result = prepareExtensionCommand([{ ...original, text }], context, command, null);
  expect(result.result.kind).toBe('refused');
  expect(result.components[0].text).toBe(text);
});
it('rejects readonly and an iteration ancestor', () => {
  const locked = { ...context, readonly: true };
  expect(prepareExtensionCommand([original], locked, { ...command, expected: locked }, null).result.kind).toBe('refused');
  const nested = { ...context, path: [0, 0] };
  expect(prepareExtensionCommand([{ iteration: { source: '{{items}}' }, children: [original] }], nested,
    { ...command, expected: nested }, null).result.kind).toBe('refused');
});
// @effects responsive_path_preserved
it('edits a responsive child without mutating its base sibling', () => {
  const expected = { ...context, path: [0, { responsive: 'portable' }, 0] };
  const root = [{ ...original, id: 'parent', responsive: { portable: { children: [original] } } }];
  const result = prepareExtensionCommand(root, expected, { ...command, expected }, null);
  expect(result.result.kind).toBe('applied');
  expect(result.components[0].text).toBe('Before');
  expect(result.components[0].responsive?.portable.children).toEqual([{ ...original, text: 'After' }]);
});
it('validates insertion nesting and duplicate IDs before adding source metadata', () => {
  const parent = { ...original, name: 'Div', children: [] };
  const nesting = { draggable: ['H2'], containers: { Div: { accepts: ['H2'] } } };
  const add = { expected: context, kind: 'insertChild' as const, index: 0,
    node: { id: 'new-heading', type: 'basic', name: 'H2', text: 'Added' } };
  expect(prepareExtensionCommand([parent], context, add, null).result.kind).toBe('refused');
  const result = prepareExtensionCommand([parent], context, add, nesting);
  expect(result.result.kind).toBe('applied');
  expect(result.components[0].children).toEqual([{ ...add.node, __source: original.__source }]);
  expect(prepareExtensionCommand([parent], context, { ...add, node: { ...add.node, id: 'heading' } }, nesting).result.kind).toBe('refused');
});
function useHarness(identity: string, locked: boolean) {
  const cell = useRevisionedDocument<LoadedLayoutDocument>(identity);
  const history = useEditorHistory<EditorNode[]>();
  const document = { document: cell.value, readExtensionDocument: cell.read, isLoading: false, error: null,
    patchLayout: (patch: (nodes: EditorNode[]) => EditorNode[]) => cell.set(prev => prev
      ? { ...prev, raw: { ...prev.raw, components: patch(prev.raw.components as EditorNode[]) } } : prev),
  } as UseLayoutDocumentResult;
  const state = { templateIdentifier: 'theme', editMode: 'route', selectedRoute: { path: '/' + identity, layoutName: identity } } as LayoutEditorState;
  const host = useExtensionHost({ state, document, selectedPath: 'children.0', locked, history, nesting: null });
  return { cell, host, history };
}
// @effects stale_session_revision_path_rejected, existing_history_undo_redo
it('uses existing history for Undo/Redo and rejects a second stale call before render', () => {
  const { result } = renderHook(() => useHarness('test', false));
  act(() => { result.current.cell.set({ layoutName: 'test', raw: { components: [original] }, lockVersion: 4 });
    result.current.history.push({ snapshot: [original] }); });
  const host = result.current.host;
  const change = { kind: 'setText' as const, expected: host.snapshot!.context, text: 'After' };
  act(() => {
    expect(host.execute(change).kind).toBe('applied');
    expect(host.execute(change)).toEqual({ kind: 'refused', reason: 'stale' });
  });
  expect(result.current.history.canUndo).toBe(true);
  act(() => { const snapshot = result.current.history.undo()!.snapshot;
    result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot?.node.text).toBe('Before');
  act(() => { const snapshot = result.current.history.redo()!.snapshot;
    result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot?.node.text).toBe('After');
});
it('invalidates delayed requests on route, readonly, and same-route reload', () => {
  const { result, rerender } = renderHook(({ identity, locked }) => useHarness(identity, locked),
    { initialProps: { identity: 'test', locked: false } });
  act(() => result.current.cell.set({ layoutName: 'test', raw: { components: [original] }, lockVersion: 4 }));
  const stale = result.current.host;
  const change = { kind: 'setText' as const, expected: stale.snapshot!.context, text: 'Late' };
  rerender({ identity: 'test', locked: true });
  expect(stale.execute(change).kind).toBe('refused');
  rerender({ identity: 'other', locked: false });
  expect(stale.execute(change).kind).toBe('refused');
  rerender({ identity: 'test', locked: false });
  act(() => result.current.cell.set({ layoutName: 'test', raw: { components: [original] }, lockVersion: 4 }));
  expect(stale.execute(change).kind).toBe('refused');
  const session = result.current.host.snapshot!.context.sessionId;
  act(() => result.current.cell.renew());
  expect(result.current.cell.read().sessionId).not.toBe(session);
  expect(result.current.host.snapshot).toBeNull();
});
it('registers, replaces and unregisters a namespaced panel', () => {
  const render = () => null;
  registerPanel('test/contract', { label: 'First', render });
  registerPanel('test/contract', { label: 'Second', render });
  expect(readPanels().filter(([id]) => id === 'test/contract')).toHaveLength(1);
  expect(readPanels().find(([id]) => id === 'test/contract')?.[1].label).toBe('Second');
  registerPanel('test/contract', null);
  expect(readPanels().some(([id]) => id === 'test/contract')).toBe(false);
});

it.each(['0.responsive.portable.children.0', [0, { responsive: 'portable' }, 0]])('normalizes actual responsive insertion %j', input => {
  const path = normalizeExtensionPath(input);
  expect(path).toEqual([0, { responsive: 'portable' }, 0]);
  const root = { children: [{ responsive: { portable: { children: [{ children: [] }] } } }] };
  expect(insertNode(root, path!, 0, { name: 'H2' }).children?.[0].responsive?.portable.children)
    .toEqual([{ children: [{ name: 'H2' }] }]);
});
it.each(['garbage', '0.iteration.4.children.0', '0.responsive.mobile', [-1]])('rejects invalid public path %j', input => {
  expect(normalizeExtensionPath(input)).toBeNull();
});
// @effects panel_ready_replace_unregister, old_host_compatibility
it('flushes queued panels before ready and isolates failed registrations', () => {
  const render = () => null;
  Object.assign(window, { G7Core: { layoutEditor: { __isStub: true,
    __queue: [['panel', 'bad', { label: 'invalid', render }], ['panel', 'test/ready', { label: 'Ready', render }]],
    __readyCallbacks: [() => expect(readPanels().some(([id]) => id === 'test/ready')).toBe(true)],
  } } });
  exposeLayoutEditorGlobals();
  expect(readPanels().some(([id]) => id === 'test/ready')).toBe(true);
  registerPanel('test/ready', null);
});

it('revokes a host retained after its editor is unmounted', () => {
  const { result, unmount } = renderHook(() => useHarness('test', false));
  act(() => result.current.cell.set({ layoutName: 'test', raw: { components: [original] }, lockVersion: 4 }));
  const host = result.current.host;
  const cell = result.current.cell;
  unmount();
  expect(host.execute({ kind: 'setText', expected: host.snapshot!.context, text: 'Late' }).kind).toBe('refused');
  expect(cell.read().value?.raw.components).toEqual([original]);
});
