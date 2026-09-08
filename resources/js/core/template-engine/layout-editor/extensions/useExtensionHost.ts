import { useEffect, useMemo, useRef } from 'react';
import type { LayoutEditorState } from '../LayoutEditorContext';
import type { UseLayoutDocumentResult } from '../hooks/useLayoutDocument';
import type { UseEditorHistoryReturn } from '../hooks/useEditorHistory';
import { parseEditorPath } from '../hooks/useElementSelection';
import { findNodeByPath, patchNode, type EditorNode } from '../utils/layoutTreeUtils';
import type { EditorSpec, NestingSpec } from '../spec/specTypes';
import { readExtensionFields } from './fields';
import { extensionMedia } from './media';
import { editableExtensionNode, frozenCopy, prepareExtensionCommand } from './command';
import { structureSlots } from './structureSlots';
import { extensionCompositions } from './compositions';
import { insertComposition } from './compositionDocument';
import { ComponentRegistry } from '../../ComponentRegistry';
import type { EditorExtensionContext, EditorExtensionHost, EditorExtensionSnapshot } from './contract';

type Inputs = {
  state: LayoutEditorState;
  document: UseLayoutDocumentResult | null;
  selectedPath: string | null;
  locked: boolean;
  history: UseEditorHistoryReturn<EditorNode[]>;
  nesting: NestingSpec | null | undefined;
  spec?: EditorSpec | null;
  t?: (key: string) => string;
};

export function useExtensionHost(inputs: Inputs): EditorExtensionHost {
  const live = useRef(inputs);
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  live.current = inputs;
  const read = (): EditorExtensionSnapshot | null => {
    if (!active.current) return null;
    const { state, document, selectedPath, locked, spec, t } = live.current;
    const cell = document?.readExtensionDocument?.();
    if (!cell?.value || document?.isLoading || document?.error || !selectedPath
      || cell.value.layoutName !== state.selectedRoute?.layoutName) return null;
    const path = parseEditorPath(selectedPath);
    const root = { children: (cell.value.raw.components ?? []) as EditorNode[] };
    const node = findNodeByPath(root, path);
    if (!node || typeof node.id !== 'string') return null;
    const context: EditorExtensionContext = {
      templateIdentifier: state.templateIdentifier, layoutName: cell.value.layoutName,
      editMode: state.editMode, sessionId: cell.sessionId, revision: cell.revision,
      lockVersion: cell.value.lockVersion,
      readonly: locked,
      nodeId: node.id, path,
      ...(state.editMode === 'iteration_item' && cell.value.iterationContext
        ? { iterationRoot: cell.value.iterationContext.sourceIndexPath } : {}),
    };
    context.readonly ||= !editableExtensionNode(root, context);
    const iterationTemplate = state.editMode === 'iteration_item' && JSON.stringify(path) === JSON.stringify(context.iterationRoot);
    return frozenCopy({ context, node, fields: iterationTemplate ? [] : readExtensionFields(node, spec, t),
      collections: structureSlots(node, spec, live.current.nesting, t, iterationTemplate).map(slot => slot.view) });
  };
  const stamp = inputs.document?.readExtensionDocument?.();
  const snapshot = useMemo(() => {
    try { return read(); } catch { return null; }
  }, [stamp?.sessionId, stamp?.revision, inputs.selectedPath, inputs.locked,
    inputs.document?.isLoading, inputs.document?.error, inputs.state.templateIdentifier,
    inputs.state.editMode, inputs.state.selectedRoute?.layoutName, inputs.spec, inputs.t]);
  return {
    protocol: 'g7.layout-editor/1', snapshot,
    media: extensionMedia(() => read()?.context ?? null),
    compositions: extensionCompositions(() => {
      const snapshot = read();
      const registry = ComponentRegistry.getInstance();
      if (!snapshot || registry.getTemplateId() !== snapshot.context.templateIdentifier || registry.getLoadingState() !== 'loaded') return null;
      return { snapshot, rules: { spec: live.current.spec, nesting: live.current.nesting,
        manifest: registry.getManifest(), hasComponent: name => registry.hasComponent(name) } };
    }, (expected, payload, collection, index) => {
      const latest = read();
      const { document, history, spec, nesting } = live.current;
      const cell = document?.readExtensionDocument?.();
      if (!latest || latest.context.readonly || latest.context.editMode !== 'route' || !document || !cell?.value
        || JSON.stringify(latest.context) !== JSON.stringify(expected)) return { kind: 'refused', reason: 'stale' };
      const root = { children: (cell.value.raw.components ?? []) as EditorNode[] };
      const anchor = editableExtensionNode(root, expected);
      if (!anchor) return { kind: 'refused', reason: 'target' };
      const registry = ComponentRegistry.getInstance();
      const changed = insertComposition(anchor, payload, collection, index, root, {
        spec, nesting, manifest: registry.getManifest(), hasComponent: name => registry.hasComponent(name),
      });
      if (!changed) return { kind: 'refused', reason: 'structure' };
      const next = patchNode(root, expected.path, () => changed).children as EditorNode[];
      document.patchLayout(() => next);
      history.push({ actionKind: 'insert', label: 'extension:composition', snapshot: next });
      return { kind: 'applied' };
    }),
    execute(command) {
      try {
        command = frozenCopy(command);
        const latest = read();
        const { document, nesting, history, spec } = live.current;
        const cell = document?.readExtensionDocument?.();
        if (!cell?.value || !document) return { kind: 'refused', reason: 'unavailable' };
        const result = prepareExtensionCommand(
          (cell.value.raw.components ?? []) as EditorNode[], latest?.context ?? null, command, nesting, spec,
        );
        if (result.result.kind === 'applied') {
          // Same synchronous document cell used by every host patch and Undo/Redo.
          document.patchLayout(() => result.components);
          history.push({ actionKind: command.kind === 'insertChild' ? 'insert' : command.kind === 'structure' ? 'property_change' : 'inline_text_edit',
            label: 'extension:' + command.kind, snapshot: result.components });
        }
        return result.result;
      } catch { return { kind: 'refused', reason: 'invalid' }; }
    },
  };
}
