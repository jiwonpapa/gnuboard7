import { useEffect, useMemo, useRef } from 'react';
import type { LayoutEditorState } from '../LayoutEditorContext';
import type { UseLayoutDocumentResult } from '../hooks/useLayoutDocument';
import type { UseEditorHistoryReturn } from '../hooks/useEditorHistory';
import { parseEditorPath } from '../hooks/useElementSelection';
import { findNodeByPath, type EditorNode } from '../utils/layoutTreeUtils';
import type { NestingSpec } from '../spec/specTypes';
import { editableRouteNode, frozenCopy, prepareExtensionCommand } from './command';
import type { EditorExtensionContext, EditorExtensionHost, EditorExtensionSnapshot } from './contract';

type Inputs = {
  state: LayoutEditorState;
  document: UseLayoutDocumentResult | null;
  selectedPath: string | null;
  locked: boolean;
  history: UseEditorHistoryReturn<EditorNode[]>;
  nesting: NestingSpec | null | undefined;
};

export function useExtensionHost(inputs: Inputs): EditorExtensionHost {
  const live = useRef(inputs);
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  live.current = inputs;
  const read = (): EditorExtensionSnapshot | null => {
    if (!active.current) return null;
    const { state, document, selectedPath, locked } = live.current;
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
      readonly: locked || state.editMode !== 'route' || !editableRouteNode(root, path),
      nodeId: node.id, path,
    };
    return frozenCopy({ context, node });
  };
  const stamp = inputs.document?.readExtensionDocument?.();
  const snapshot = useMemo(() => {
    try { return read(); } catch { return null; }
  }, [stamp?.sessionId, stamp?.revision, inputs.selectedPath, inputs.locked,
    inputs.document?.isLoading, inputs.document?.error, inputs.state.templateIdentifier,
    inputs.state.editMode, inputs.state.selectedRoute?.layoutName]);
  return {
    protocol: 'g7.layout-editor/1', snapshot,
    execute(command) {
      try {
        command = frozenCopy(command);
        const latest = read();
        const { document, nesting, history } = live.current;
        const cell = document?.readExtensionDocument?.();
        if (!cell?.value || !document) return { kind: 'refused', reason: 'unavailable' };
        const result = prepareExtensionCommand(
          (cell.value.raw.components ?? []) as EditorNode[], latest?.context ?? null, command, nesting,
        );
        if (result.result.kind === 'applied') {
          // Same synchronous document cell used by every host patch and Undo/Redo.
          document.patchLayout(() => result.components);
          history.push({ actionKind: command.kind === 'insertChild' ? 'insert' : 'inline_text_edit',
            label: 'extension:' + command.kind, snapshot: result.components });
        }
        return result.result;
      } catch { return { kind: 'refused', reason: 'invalid' }; }
    },
  };
}
