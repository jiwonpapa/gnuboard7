import { findNodeByPath, insertNode, patchNode, type ComponentPath, type EditorNode } from '../utils/layoutTreeUtils';
import { classifyLockKind } from '../hooks/useElementSelection';
import { changeExtensionField } from './fields';
import type { EditorSpec } from '../spec/specTypes';
import { canDrop } from '../dnd/nestingRules';
import type { NestingSpec } from '../spec/specTypes';
import type { EditorExtensionCommand, EditorExtensionContext, EditorExtensionResult } from './contract';
import { changeStructure } from './structureCommand';
import { record } from './structureIdentity';

export function frozenCopy<T>(value: T): T {
  const copy = structuredClone(value);
  const freeze = (v: unknown): void => {
    if (!v || typeof v !== 'object') return;
    Object.values(v).forEach(freeze);
    Object.freeze(v);
  };
  freeze(copy);
  return copy;
}

export function editableRouteNode(root: EditorNode, path: ComponentPath): EditorNode | null {
  const node = findNodeByPath(root, path);
  if (!node || !path.length || node.__source?.kind !== 'route') return null;
  const ancestors = path.slice(0, -1).map((_, index) => findNodeByPath(root, path.slice(0, index + 1)))
    .filter((ancestor): ancestor is EditorNode => ancestor !== null);
  if (classifyLockKind(node, 'route', undefined, ancestors) !== 'none') return null;
  return node;
}

export function editableExtensionNode(root: EditorNode, current: Pick<EditorExtensionContext, 'path' | 'editMode' | 'iterationRoot'>): EditorNode | null {
  const node = findNodeByPath(root, current.path);
  if (!node || !current.path.length || node.__source?.kind !== 'route') return null;
  const ancestors = current.path.slice(0, -1).map((_, i) => findNodeByPath(root, current.path.slice(0, i + 1)))
    .filter((parent): parent is EditorNode => parent !== null);
  const lock = classifyLockKind(node, 'route', undefined, ancestors);
  if (!['none', 'data_bound'].includes(lock)) return null;
  if (current.editMode === 'route') return node.iteration != null || ancestors.some(parent => parent.iteration != null) ? null : node;
  if (current.editMode !== 'iteration_item' || !current.iterationRoot?.length
    || !current.iterationRoot.every((segment, i) => JSON.stringify(segment) === JSON.stringify(current.path[i]))) return null;
  const iteration = findNodeByPath(root, current.iterationRoot);
  if (iteration?.__source?.kind !== 'route' || !record(iteration.iteration) || iteration.iteration.source === undefined) return null;
  if (ancestors.some(parent => parent !== iteration && parent.iteration != null)) return null;
  return node !== iteration && node.iteration != null ? null : node;
}

/** Host-side validation; it never trusts an extension's readonly flag or proposed source. */
export function prepareExtensionCommand(
  components: EditorNode[], current: EditorExtensionContext | null,
  command: EditorExtensionCommand, nesting: NestingSpec | null | undefined, spec?: EditorSpec | null,
): { result: EditorExtensionResult; components: EditorNode[] } {
  const refuse = (reason: Extract<EditorExtensionResult, { kind: 'refused' }>['reason']) =>
    ({ result: { kind: 'refused' as const, reason }, components });
  if (!current) return refuse('unavailable');
  if (!command.expected || Object.keys(current).some(key => JSON.stringify(command.expected[key as keyof EditorExtensionContext]) !== JSON.stringify(current[key as keyof EditorExtensionContext]))) return refuse('stale');
  if (current.readonly) return refuse('readonly');
  const root = { children: components };
  const node = command.kind === 'structure' || current.editMode === 'iteration_item'
    ? editableExtensionNode(root, current) : editableRouteNode(root, current.path);
  if (!node || typeof node.id !== 'string' || node.id !== current.nodeId) return refuse('target');
  const iterationTemplate = current.editMode === 'iteration_item' && JSON.stringify(current.path) === JSON.stringify(current.iterationRoot);
  if (command.kind === 'structure') {
    const changed = changeStructure(node, command.change, root, spec, nesting, iterationTemplate);
    if (!changed) return refuse('structure');
    if (JSON.stringify(changed) === JSON.stringify(node)) return { result: { kind: 'noop' }, components };
    const next = patchNode(root, current.path, () => changed);
    return { result: { kind: 'applied' }, components: next.children as EditorNode[] };
  }
  if (iterationTemplate || current.editMode !== 'route' && current.editMode !== 'iteration_item') return refuse('readonly');
  if (command.kind === 'setText') {
    const plain = (value: unknown): value is string => typeof value === 'string'
      && !/\$[\w-]+:|\{\{|\}\}|\{p\d+\}|<[^>]*>/.test(value);
    if (!plain(node.text) || !plain(command.text)) return refuse('binding');
    if (node.text === command.text) return { result: { kind: 'noop' }, components };
    const next = patchNode(root, current.path, existing => ({ ...existing, text: command.text }));
    return { result: { kind: 'applied' }, components: next.children as EditorNode[] };
  }
  if (command.kind === 'setControl') {
    const changed = changeExtensionField(node, spec, command.control, command.value, command.reset === true);
    if (!changed) return refuse('invalid');
    if (JSON.stringify(changed) === JSON.stringify(node)) return { result: { kind: 'noop' }, components };
    const next = patchNode(root, current.path, () => changed);
    return { result: { kind: 'applied' }, components: next.children as EditorNode[] };
  }
  if (command.kind !== 'insertChild') return refuse('invalid');
  const count = Array.isArray(node.children) ? node.children.length : 0;
  if (!Number.isInteger(command.index) || command.index < 0 || command.index > count) return refuse('structure');
  const ids = new Set<string>();
  const collect = (value: unknown): void => {
    if (!value || typeof value !== 'object') return;
    if ('id' in value && typeof value.id === 'string') ids.add(value.id);
    Object.values(value).forEach(collect);
  };
  collect(root);
  const validChild = (child: EditorNode, parentName: string): boolean => {
    if (typeof child.name !== 'string' || child.type !== 'basic'
      || child.__source !== undefined || child.iteration != null || child.responsive !== undefined
      || !canDrop({ draggedComponentName: child.name, targetContainerName: parentName, nesting })) return false;
    if (child.id !== undefined) {
      if (typeof child.id !== 'string' || !child.id || ids.has(child.id)) return false;
      ids.add(child.id);
    }
    if (child.children !== undefined && !Array.isArray(child.children)) return false;
    return !Array.isArray(child.children) || child.children.every((nested: EditorNode) => validChild(nested, child.name!));
  };
  if (typeof node.name !== 'string' || !validChild(command.node, node.name)) return refuse('structure');
  const inserted = frozenCopy(command.node);
  const withSource = (child: EditorNode): EditorNode => ({ ...child, __source: { ...node.__source! },
    ...(Array.isArray(child.children) ? { children: child.children.map(withSource) } : {}) });
  const next = insertNode(root, current.path, command.index, withSource(inserted));
  return { result: { kind: 'applied' }, components: next.children as EditorNode[] };
}
