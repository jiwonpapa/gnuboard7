import type { EditorExtensionField, ExtensionValue } from './contract';

/** Slot ids are opaque addresses, valid only in the accompanying snapshot revision. */
export interface ExtensionCollection {
  id: string;
  label: string;
  kind: 'children' | 'array' | 'cell';
  editable: boolean;
  choices: Array<{ id: string; label: string }>;
  items: Array<{ id: string; label: string; editable: boolean; fields: EditorExtensionField[] }>;
}
export type ExtensionStructureChange =
  | { operation: 'insert'; collection: string; choice: string; index: number }
  | { operation: 'delete' | 'duplicate'; collection: string; index: number }
  | { operation: 'move'; collection: string; index: number; destination: string; toIndex: number }
  | { operation: 'field'; collection: string; index: number; field: string; value: ExtensionValue };
