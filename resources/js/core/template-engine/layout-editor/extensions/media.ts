import { listLayoutAttachments, uploadLayoutAttachment } from '../utils/layoutAttachments';
import type { EditorExtensionContext, EditorExtensionMedia, ExtensionMediaResult } from './contract';

/** Uses the existing authenticated attachment client; never edits or deletes a node/file. */
export function extensionMedia(current: () => EditorExtensionContext | null): EditorExtensionMedia {
  function valid(expected: EditorExtensionContext, signal?: AbortSignal): boolean {
    const live = current();
    return !signal?.aborted && !!live && !live.readonly && live.editMode === 'route'
      && Object.keys(live).every(key => JSON.stringify(live[key as keyof EditorExtensionContext]) === JSON.stringify(expected?.[key as keyof EditorExtensionContext]));
  }
  async function run<T>(expected: EditorExtensionContext, signal: AbortSignal | undefined, action: () => Promise<{ ok: true; data: T } | { ok: false; message: string }>): Promise<ExtensionMediaResult<T>> {
    if (!valid(expected, signal)) return { ok: false, reason: 'stale-or-cancelled' };
    try {
      const result = await action();
      if (!valid(expected, signal)) return { ok: false, reason: 'stale-or-cancelled' };
      return result.ok ? result : { ok: false, reason: result.message };
    } catch { return { ok: false, reason: 'media-request-failed' }; }
  }
  return {
    list({ expected, scope, signal }) {
      if (scope !== 'page' && scope !== 'template') return Promise.resolve({ ok: false, reason: 'invalid-scope' });
      return run(expected, signal, () => listLayoutAttachments(expected.templateIdentifier, scope === 'page' ? expected.layoutName : null, signal));
    },
    upload({ expected, file, signal }) {
      if (!(file instanceof File)) return Promise.resolve({ ok: false, reason: 'invalid-file' });
      return run(expected, signal, () => uploadLayoutAttachment(expected.templateIdentifier, expected.layoutName, file, signal));
    },
  };
}
