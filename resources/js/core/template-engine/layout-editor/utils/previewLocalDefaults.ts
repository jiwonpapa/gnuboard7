/** Layout initLocal/state defaults have the same missing-key precedence as TemplateApp. */
function object(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
export function readPreviewLocalDefaults(value: unknown): Record<string, unknown> {
  return structuredClone(object(value));
}
export function mergePreviewLocal(defaults: unknown, current: unknown): Record<string, unknown> {
  return { ...object(defaults), ...object(current) };
}
