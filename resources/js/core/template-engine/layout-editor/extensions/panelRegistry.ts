import type React from 'react';
import type { EditorExtensionHost } from './contract';

export interface EditorExtensionPanel {
  label: string;
  render: React.ComponentType<{ host: EditorExtensionHost }>;
}
const panels = new Map<string, EditorExtensionPanel>();
const listeners = new Set<() => void>();
let snapshot: ReadonlyArray<readonly [string, EditorExtensionPanel]> = [];
const changed = () => { snapshot = [...panels]; listeners.forEach(listener => listener()); };

/** Namespaced IDs; duplicate registration replaces, null unregisters. */
export function registerPanel(id: string, panel: EditorExtensionPanel | null): void {
  if (!/^[a-z][a-z0-9-]*\/[a-z][a-z0-9-]*$/.test(id)) throw new Error('Invalid editor panel ID');
  if (panel === null) panels.delete(id);
  else {
    if (!panel || typeof panel.label !== 'string' || typeof panel.render !== 'function') throw new Error('Invalid editor panel');
    panels.set(id, Object.freeze({ ...panel }));
  }
  changed();
}
export const readPanels = () => snapshot;
export function subscribePanels(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
