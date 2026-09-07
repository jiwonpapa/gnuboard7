import type { ComponentPath, EditorNode } from '../utils/layoutTreeUtils';

/** Public v1 protocol. All values are detached, deeply frozen snapshots. */
export interface EditorExtensionContext {
  templateIdentifier: string;
  layoutName: string;
  editMode: string;
  sessionId: string;
  revision: number;
  lockVersion: number;
  readonly: boolean;
  nodeId: string;
  path: ComponentPath;
}
export interface EditorExtensionSnapshot {
  context: EditorExtensionContext;
  node: EditorNode;
}
export type EditorExtensionCommand = {
  expected: EditorExtensionContext;
} & ({ kind: 'setText'; text: string } | { kind: 'insertChild'; node: EditorNode; index: number });
export type EditorExtensionResult =
  | { kind: 'applied' | 'noop' }
  | { kind: 'refused'; reason: 'unavailable' | 'stale' | 'readonly' | 'target' | 'binding' | 'structure' | 'invalid' };
export interface EditorExtensionHost {
  protocol: 'g7.layout-editor/1';
  snapshot: EditorExtensionSnapshot | null;
  execute: (command: EditorExtensionCommand) => EditorExtensionResult;
}
