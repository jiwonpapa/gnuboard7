import { expect, it } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { useExtensionHost } from '../../extensions/useExtensionHost';
import { useRevisionedDocument } from '../../hooks/useRevisionedDocument';
import { useEditorHistory } from '../../hooks/useEditorHistory';
import type { LoadedLayoutDocument, UseLayoutDocumentResult } from '../../hooks/useLayoutDocument';
import type { LayoutEditorState } from '../../LayoutEditorContext';
import { prepareExtensionCommand, frozenCopy } from '../../extensions/command';
import { structureSlots } from '../../extensions/structureSlots';
import type { EditorExtensionContext } from '../../extensions/contract';
import type { ExtensionStructureChange } from '../../extensions/structureTypes';
import type { EditorNode } from '../../utils/layoutTreeUtils';
import type { EditorSpec } from '../../spec/specTypes';
const source = { kind: 'route' as const, layout: 'test' };
const context: EditorExtensionContext = { templateIdentifier: 'theme', layoutName: 'test', editMode: 'route', sessionId: 's', revision: 1, lockVersion: 1, readonly: false, nodeId: 'root', path: [0] };
const node = (id: string, name = 'P'): EditorNode => ({ id, type: 'basic', name, __source: source, text: id, future: { kept: true } });
const spec: EditorSpec = {
  nesting: { draggable: ['P', 'Div', 'A'], containers: { Div: { accepts: ['P', 'Div', 'A'] } } },
  componentPalette: { entries: { P: { defaultNode: { type: 'basic', name: 'P', text: 'New' } }, Div: { defaultNode: { type: 'basic', name: 'Div', children: [] } } } },
  componentCapabilities: {
    Gallery: { nodeEditor: { kind: 'array', params: { arrayProp: 'items', newItem: { id: '', src: '', alt: '' }, fields: [
      { key: 'src', widget: 'image', label: '이미지' }, { key: 'alt', widget: 'text', label: '설명' }] } } },
    Cards: { nodeEditor: { kind: 'array-cell-tree', params: { arrayProp: 'cards', newItem: { id: '', cellChildren: [] }, cellChildComponent: 'Div' } } },
  },
};
const root: EditorNode = { ...node('root', 'Div'), text: undefined, children: [node('one'), { ...node('box', 'Div'), children: [node('two')] }], props: { future: '$t:preserve' } };
const slot = (...path: Array<string | number>): string => JSON.stringify(path);
const children = slot('children');
function run(input: EditorNode, change: ExtensionStructureChange, expected = context, definition = spec) {
  return prepareExtensionCommand([input], expected, { kind: 'structure', expected, change }, definition.nesting, definition);
}
// @scenario operation=structure, source=route
// @effects declared_slots_atomic_changes, preserve_identity_references, scoped_iteration_template
it('inserts an owned seed, moves into a nested parent, duplicates and deletes without touching other fields', () => {
  const before = frozenCopy(root);
  const added = run(before, { operation: 'insert', collection: children, index: 1, choice: 'P' });
  expect(added.result.kind).toBe('applied');
  const items = added.components[0].children as EditorNode[];
  expect(items[1]).toMatchObject({ type: 'basic', name: 'P', text: 'New', __source: source });
  expect(items[1].id).toMatch(/^node_/);
  expect(before).toEqual(root);
  const moved = run(root, { operation: 'move', collection: children, index: 0, destination: slot('children', 1, 'children'), toIndex: 1 });
  expect(moved.result.kind).toBe('applied');
  expect(moved.components[0].children).toEqual([{ ...(root.children as EditorNode[])[1], children: [node('two'), node('one')] }]);
  const duplicated = run(root, { operation: 'duplicate', collection: children, index: 0 });
  expect(duplicated.result.kind).toBe('applied');
  const copy = (duplicated.components[0].children as EditorNode[])[1];
  expect(copy.id).not.toBe('one'); expect(copy.future).toEqual({ kept: true });
  const removed = run(duplicated.components[0], { operation: 'delete', collection: children, index: 1 });
  expect(removed.components).toEqual([root]);
});
it('keeps unrelated responsive branches and supports their explicit child slots', () => {
  const input = { ...root, responsive: { mobile: { props: { style: { color: 'red' } }, children: [node('mobile')] } } };
  const result = run(input, { operation: 'insert', collection: slot('responsive', 'mobile', 'children'), index: 1, choice: 'P' });
  expect(result.result.kind).toBe('applied');
  expect(result.components[0].children).toEqual(root.children);
  expect(result.components[0].responsive?.mobile.props).toEqual(input.responsive.mobile.props);
  expect(result.components[0].responsive?.mobile.children).toHaveLength(2);
});
it.each([
  { operation: 'move', collection: children, index: 1, destination: slot('children', 1, 'children'), toIndex: 0 },
  { operation: 'insert', collection: children, index: -1, choice: 'P' },
  { operation: 'insert', collection: children, index: 0, choice: 'Script' },
  { operation: 'delete', collection: children, index: 99 },
  { operation: 'delete', collection: '["props","constructor"]', index: 0 },
] satisfies ExtensionStructureChange[])('refuses illegal operation $operation / $collection', change => {
  const result = run(root, change); expect(result.result.kind).toBe('refused'); expect(result.components).toEqual([root]);
});
it.each(['base', 'partial', 'extension'] as const)('refuses protected descendant %s', kind => {
  const input = { ...root, children: [{ ...node('locked'), __source: { kind } }] };
  expect(run(input, { operation: 'delete', collection: children, index: 0 }).result.kind).toBe('refused');
});
it('remaps local DOM references while preserving external links and refuses unresolved reference expressions', () => {
  const target = { ...node('target'), __source: { ...source, extraProvenance: 'retain' } };
  const group = { ...node('group', 'Div'), children: [target, { ...node('link', 'A'), props: { href: '#target', 'aria-controls': 'target external' } }] };
  const input = { ...root, children: [group] };
  const result = run(input, { operation: 'duplicate', collection: children, index: 0 });
  expect(result.result.kind).toBe('applied');
  const copy = (result.components[0].children as EditorNode[])[1].children as EditorNode[];
  expect(copy[0].__source).toEqual(target.__source);
  expect(copy[1].props).toEqual({ href: '#' + copy[0].id, 'aria-controls': copy[0].id + ' external' });
  const linked = { ...root, props: { targetId: 'one' } };
  expect(run(linked, { operation: 'delete', collection: children, index: 0 }).result.kind).toBe('refused');
  const opaque = { ...root, children: [{ ...group, future: { reference: '{{lookup.target}}' } }] };
  expect(run(opaque, { operation: 'duplicate', collection: children, index: 0 }).result.kind).toBe('refused');
});
it('edits image fields in a declared array, materializes defaults once and preserves unknown item data', () => {
  const gallery = { ...node('root', 'Gallery'), props: { items: [{ id: 'slide', src: '/before.png', alt: 'Before', future: [1, 2] }] } };
  const collection = slot('props', 'items');
  const edited = run(gallery, { operation: 'field', collection, index: 0, field: 'src', value: '/after.png' });
  expect(edited.result.kind).toBe('applied');
  expect(edited.components[0].props?.items).toEqual([{ ...gallery.props.items[0], src: '/after.png' }]);
  for (const value of ['javascript:alert(1)', '{{file}}', '//foreign/x']) expect(run(gallery, { operation: 'field', collection, index: 0, field: 'src', value }).result.kind).toBe('refused');
  expect(run({ ...gallery, props: { items: '{{slides}}' } }, { operation: 'insert', collection, index: 0, choice: 'item' }).result.kind).toBe('refused');
  const defaults = structuredClone(spec);
  defaults.componentCapabilities!.Gallery.nodeEditor!.params = { ...defaults.componentCapabilities!.Gallery.nodeEditor!.params, defaultItems: gallery.props.items };
  const result = run({ ...gallery, props: {} }, { operation: 'insert', collection, index: 1, choice: 'item' }, context, defaults);
  expect(result.components[0].props?.items).toHaveLength(2);
});
it('uses distinct prop-cell addresses and remaps identities inside duplicated cards', () => {
  const input = { ...node('root', 'Cards'), props: { cards: [{ id: 'card', cellChildren: [{ ...node('cell', 'Div'), children: [node('inner')] }] }], future: 'keep' } };
  const collection = slot('props', 'cards', 0, 'cellChildren', 0, 'children');
  const inserted = run(input, { operation: 'insert', collection, index: 1, choice: 'P' });
  expect(inserted.result.kind).toBe('applied');
  expect(inserted.components[0].props?.future).toBe('keep');
  const duplicated = run(input, { operation: 'duplicate', collection: slot('props', 'cards'), index: 0 });
  expect(duplicated.result.kind).toBe('applied');
  const cards = duplicated.components[0].props?.cards as typeof input.props.cards;
  expect(cards[1].id).not.toBe('card'); expect(cards[1].cellChildren[0].id).not.toBe('cell');
  expect((cards[1].cellChildren[0].children as EditorNode[])[0].id).not.toBe('inner');
});
it('allows only the explicit iteration template mode, preserving source and bound values', () => {
  const input = { ...root, iteration: { source: '{{products}}', itemVar: 'product' } };
  const change: ExtensionStructureChange = { operation: 'insert', collection: children, index: 0, choice: 'P' };
  expect(run(input, change).result.kind).toBe('refused');
  const expected = { ...context, editMode: 'iteration_item', iterationRoot: [0] };
  const result = run(input, change, expected);
  expect(result.result.kind).toBe('applied'); expect(result.components[0].iteration).toEqual(input.iteration);
  expect(run(input, change, { ...expected, iterationRoot: [1] }).result.kind).toBe('refused');
  const bound = { ...root, children: [{ ...node('bound'), text: '{{product.name}}' }] };
  expect(structureSlots(bound, spec, spec.nesting)[0].view.items[0].fields[0].editable).toBe(false);
  expect(run(bound, { operation: 'field', collection: children, index: 0, field: 'node:text', value: 'overwrite' }).result.kind).toBe('refused');
});
it('materializes default cell trees on deep edits and isolates grouped array props', () => {
  const definition = structuredClone(spec);
  definition.componentCapabilities!.Cards.nodeEditor!.params = { arrayProp: 'cards', cellChildComponent: 'Div', defaultItems: [
    { id: 'card', cellChildren: [{ ...node('cell', 'Div'), children: [node('inside')] }] }], newItem: { id: '', cellChildren: [] } };
  const input = { ...node('root', 'Cards'), props: { untouched: true } };
  const result = run(input, { operation: 'insert', collection: slot('props', 'cards', 0, 'cellChildren', 0, 'children'), index: 1, choice: 'P' }, context, definition);
  expect(result.result.kind).toBe('applied');
  expect(result.components[0].props?.cards).toHaveLength(1); expect(input.props).toEqual({ untouched: true });
  definition.componentCapabilities!.Groups = { nodeEditor: { kind: 'array-group', params: { groups: [
    { arrayProp: 'left', newItem: 'new', fields: [{ key: 'label', primary: true, widget: 'text' }] },
    { arrayProp: 'right', newItem: 'new', fields: [{ key: 'label', primary: true, widget: 'text' }] }] } } };
  const grouped = { ...node('root', 'Groups'), props: { left: ['one'], right: ['two'] } };
  const edited = run(grouped, { operation: 'field', collection: slot('props', 'left'), index: 0, field: 'label', value: 'after' }, context, definition);
  expect(edited.components[0].props).toEqual({ left: ['after'], right: ['two'] });
});
it('rejects stale structure commands and pushes exactly one existing history entry', () => {
  const { result } = renderHook(() => {
    const cell = useRevisionedDocument<LoadedLayoutDocument>('test');
    const history = useEditorHistory<EditorNode[]>();
    const document = { document: cell.value, readExtensionDocument: cell.read, isLoading: false, error: null,
      patchLayout: (patch: (nodes: EditorNode[]) => EditorNode[]) => cell.set(prev => prev ? { ...prev, raw: { ...prev.raw, components: patch(prev.raw.components as EditorNode[]) } } : prev),
    } as UseLayoutDocumentResult;
    const state = { templateIdentifier: 'theme', editMode: 'route', selectedRoute: { path: '/test', layoutName: 'test' } } as LayoutEditorState;
    const host = useExtensionHost({ state, document, selectedPath: '0', locked: false, history, spec, nesting: spec.nesting });
    return { cell, history, host };
  });
  act(() => { result.current.cell.set({ layoutName: 'test', raw: { components: [root] }, lockVersion: 1 }); result.current.history.push({ snapshot: [root] }); });
  const host = result.current.host;
  const command = { kind: 'structure' as const, expected: host.snapshot!.context, change: { operation: 'duplicate' as const, collection: children, index: 0 } };
  act(() => { expect(host.execute(command).kind).toBe('applied'); expect(host.execute(command).kind).toBe('refused'); });
  expect(result.current.host.snapshot?.node.children).toHaveLength(3);
  act(() => { const snapshot = result.current.history.undo()!.snapshot; result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot?.node).toEqual(root); expect(result.current.history.canUndo).toBe(false);
  act(() => { const snapshot = result.current.history.redo()!.snapshot; result.current.cell.set(prev => ({ ...prev!, raw: { components: snapshot } })); });
  expect(result.current.host.snapshot?.node.children).toHaveLength(3);
});

it('does not infer identity semantics for a custom array idField', () => {
  const definition = structuredClone(spec);
  definition.componentCapabilities!.Cards.nodeEditor!.params = { arrayProp: 'cards', idField: 'key', newItem: { key: 'reused', cellChildren: [] } };
  const input = { ...node('root', 'Cards'), props: { cards: [{ key: 'one', cellChildren: [] }] } };
  expect(structureSlots(input, definition, definition.nesting)).toEqual([]);
  const changed = run(input, { operation: 'duplicate', collection: slot('props', 'cards'), index: 0 }, context, definition);
  expect(changed.result.kind).toBe('refused'); expect(changed.components).toEqual([input]);
});
