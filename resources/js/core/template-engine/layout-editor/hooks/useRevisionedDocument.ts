import { useCallback, useRef, useState } from 'react';

/** A synchronous cell keeps queued edits and history in the same event consistent. */
export function useRevisionedDocument<T>(identity: string) {
  const [, render] = useState(0);
  const cell = useRef({ identity, sessionId: crypto.randomUUID(), revision: 0, value: null as T | null });
  if (cell.current.identity !== identity) {
    cell.current = { identity, sessionId: crypto.randomUUID(), revision: 0, value: null };
  }
  const read = useCallback(() => cell.current, []);
  const set = useCallback((update: T | null | ((previous: T | null) => T | null)) => {
    const previous = cell.current;
    const value = typeof update === 'function'
      ? (update as (previous: T | null) => T | null)(previous.value) : update;
    if (value === previous.value) return;
    cell.current = { ...previous, value, revision: previous.revision + 1 };
    render(n => n + 1);
  }, []);
  const renew = useCallback(() => {
    cell.current = { ...cell.current, sessionId: crypto.randomUUID(), revision: 0, value: null };
    render(n => n + 1);
    return cell.current.sessionId;
  }, []);
  return { value: cell.current.value, set, read, renew };
}
