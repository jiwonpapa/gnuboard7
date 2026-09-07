import { parseEditorPath } from '../hooks/useElementSelection';
import { serializeEditorPath, type ComponentPath } from '../utils/layoutTreeUtils';

/** Explicit legacy string compatibility; malformed/virtual paths never become root. */
export function normalizeExtensionPath(input: string | ComponentPath): ComponentPath | null {
  if (typeof input === 'string') {
    const canonical = input.replace(/^children\./, '');
    const parsed = parseEditorPath(canonical);
    return serializeEditorPath(parsed) === canonical ? normalizeExtensionPath(parsed) : null;
  }
  if (!Array.isArray(input)) return null;
  const result: ComponentPath = [];
  for (let index = 0; index < input.length; index++) {
    const segment = input[index];
    if (typeof segment === 'number' && Number.isSafeInteger(segment) && segment >= 0) result.push(segment);
    else if (segment && typeof segment === 'object' && typeof segment.responsive === 'string'
      && segment.responsive && index > 0 && typeof input[index - 1] === 'number'
      && typeof input[index + 1] === 'number') result.push({ responsive: segment.responsive });
    else return null;
  }
  return result;
}
