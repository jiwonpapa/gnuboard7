import React, { useSyncExternalStore } from 'react';
import { readPanels, subscribePanels } from './panelRegistry';
import type { EditorExtensionHost } from './contract';

class PanelBoundary extends React.Component<React.PropsWithChildren, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() { return this.state.failed ? null : this.props.children; }
}
/** Actual consumer, in the existing editor React tree and history session. */
export function ExtensionPanels({ host }: { host: EditorExtensionHost }): React.ReactElement | null {
  const panels = useSyncExternalStore(subscribePanels, readPanels, readPanels);
  if (!panels.length) return null;
  return <aside aria-label="Editor extensions" data-testid="g7le-extension-panels"
    style={{ position: 'absolute', top: 8, right: 8, width: 300, maxHeight: '80%', overflow: 'auto',
      pointerEvents: 'auto', zIndex: 140, color: '#172033', background: '#fff', border: '1px solid #cbd5e1', borderRadius: 8 }}>
    {panels.map(([id, panel]) => <details key={id} open>
      <summary style={{ padding: 12 }}>{panel.label}</summary>
      <PanelBoundary key={id + ':' + host.snapshot?.context.sessionId}>
        <panel.render host={host} />
      </PanelBoundary>
    </details>)}
  </aside>;
}
