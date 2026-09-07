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
  fields?: EditorExtensionField[];
}
export type EditorExtensionCommand = {
  expected: EditorExtensionContext;
} & ({ kind: 'setText'; text: string } | { kind: 'insertChild'; node: EditorNode; index: number } | { kind: 'setControl'; control: string; value: ExtensionValue; reset?: boolean });
export type EditorExtensionResult =
  | { kind: 'applied' | 'noop' }
  | { kind: 'refused'; reason: 'unavailable' | 'stale' | 'readonly' | 'target' | 'binding' | 'structure' | 'invalid' };
export interface EditorExtensionHost {
  protocol: 'g7.layout-editor/1';
  snapshot: EditorExtensionSnapshot | null;
  execute: (command: EditorExtensionCommand) => EditorExtensionResult;
  media?: EditorExtensionMedia;
}

export type ExtensionValue = string | number | boolean | null;
export interface EditorExtensionField {
  id: string;
  label: string;
  kind: 'text' | 'link' | 'image' | 'alt' | 'choice';
  group: 'content' | 'style';
  value: ExtensionValue;
  options: Array<{ value: ExtensionValue; label: string }>;
  editable: boolean;
  custom: boolean;
  source: 'template-spec' | 'core-image';
}
export type ExtensionMediaResult<T> = { ok: true; data: T } | { ok: false; reason: string };
export interface ExtensionAsset {
  id: string | number;
  layout_name: string | null;
  original_name: string;
  mime_type: string;
  size: number;
  url: string;
}
export interface EditorExtensionMedia {
  list: (request: { expected: EditorExtensionContext; scope: 'page' | 'template'; signal?: AbortSignal }) => Promise<ExtensionMediaResult<ExtensionAsset[]>>;
  upload: (request: { expected: EditorExtensionContext; file: File; signal?: AbortSignal }) => Promise<ExtensionMediaResult<ExtensionAsset>>;
}
