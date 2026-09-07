/** Cloning is not JSON text replacement: only declared identity/reference positions change. */
export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
export function plain(value: unknown): boolean {
  return value == null || typeof value === 'number' && Number.isFinite(value) || typeof value === 'boolean'
    || typeof value === 'string' && !/\{\{|\}\}|\$[\w-]+:|\{p\d+\}|<[^>]*>/.test(value);
}
export function freshId(used: Set<string>): string {
  let id: string;
  do { id = 'node_' + crypto.randomUUID(); } while (used.has(id));
  used.add(id);
  return id;
}
export function allIds(value: unknown, result = new Set<string>()): Set<string> {
  if (value && typeof value === 'object') {
    if (record(value) && typeof value.id === 'string' && value.id) result.add(value.id);
    Object.values(value).forEach(child => allIds(child, result));
  }
  return result;
}
const singleRefs = new Set(['htmlFor', 'targetId', 'componentId', 'activeTabId']);
const listRefs = new Set(['aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns']);
const contentKeys = new Set(['text', 'alt', 'label', 'title']);
export function remapReferences(value: unknown, ids: Map<string, string>, identityOwners: Set<object>): boolean {
  if (!value || typeof value !== 'object') return true;
  for (const [key, child] of Object.entries(value)) {
    if (identityOwners.has(value) && key === 'id') continue;
    if (key === '__source') continue;
    if (typeof child === 'string') {
      if (contentKeys.has(key) && plain(child)) continue;
      const target = key === 'href' && child.startsWith('#') ? child.slice(1) : child;
      if (singleRefs.has(key) || key === 'href' && child.startsWith('#')) {
        if (ids.has(target)) Reflect.set(value, key, (key === 'href' ? '#' : '') + ids.get(target));
      } else if (listRefs.has(key)) {
        Reflect.set(value, key, child.split(/\s+/).map(id => ids.get(id) ?? id).join(' '));
      } else if ([...ids.keys()].some(id => child === id || child === '#' + id
        || child.includes('{{') && child.includes(id))) return false;
    } else if (!remapReferences(child, ids, identityOwners)) return false;
  }
  return true;
}
/** Refuse deleting a target that is still referenced outside the removed value. */
export function hasOutsideReference(document: unknown, removed: unknown, ids: Set<string>): boolean {
  if (document === removed || !document || typeof document !== 'object') return false;
  return Object.entries(document).some(([key, value]) => {
    if (key === '__source' || key === 'id') return false;
    if (contentKeys.has(key) && plain(value)) return false;
    if (typeof value === 'string') return [...ids].some(id => value === id || value === '#' + id
      || listRefs.has(key) && value.split(/\s+/).includes(id) || value.includes('{{') && value.includes(id));
    return hasOutsideReference(value, removed, ids);
  });
}
