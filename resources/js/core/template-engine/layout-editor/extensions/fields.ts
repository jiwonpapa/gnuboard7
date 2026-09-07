import type { EditorSpec, EditorControlSpec } from '../spec/specTypes';
import { applyRecipe, reverseResolve, type RecipeApply } from '../spec/recipeEngine';
import type { EditorNode } from '../utils/layoutTreeUtils';
import type { EditorExtensionField, ExtensionValue } from './contract';

type Definition = { id: string; control: EditorControlSpec; group: 'content' | 'style'; source: 'template-spec' | 'core-image' };
const plain = (v: unknown): boolean => v == null || typeof v === 'string' && !/\$[\w-]+:|\{\{|\}\}|\{p\d+\}|<[^>]*>/.test(v);
const scalar = (v: unknown): v is ExtensionValue => v === null || typeof v === 'string' || typeof v === 'boolean' || typeof v === 'number' && Number.isFinite(v);
function record(v: unknown): v is Record<string, unknown> { return !!v && typeof v === 'object' && !Array.isArray(v); }
function applyOf(control: EditorControlSpec): RecipeApply | undefined { return typeof control.apply === 'object' ? control.apply : undefined; }
const contentKinds = { href: 'link', src: 'image', alt: 'alt', target: 'choice', title: 'text' } as const;
function kindOf(control: EditorControlSpec): EditorExtensionField['kind'] | null {
  const apply = applyOf(control);
  if (apply?.type === 'propValue') {
    const key = apply.propKey;
    return key && key in contentKinds ? contentKinds[key as keyof typeof contentKinds] : null;
  }
  return Array.isArray(control.options) && control.options.length > 0 ? 'choice' : null;
}
/** Standard image presentation only; no CSS framework or arbitrary style input. */
const imageControls: Record<string, EditorControlSpec> = {
  'core:image-ratio': { label: '$t:layout_editor.extension.image_ratio', widget: 'segmented', apply: { type: 'styleProp', prop: 'aspectRatio' },
    options: ['auto', '1 / 1', '4 / 3', '16 / 9'].map(value => ({ value, label: value === 'auto' ? '$t:layout_editor.extension.original_ratio' : value.replace(' / ', ':') })) },
  'core:image-fit': { label: '$t:layout_editor.extension.image_fit', widget: 'segmented', apply: { type: 'styleProp', prop: 'objectFit' },
    options: [{ value: 'cover', label: '$t:layout_editor.extension.cover' }, { value: 'contain', label: '$t:layout_editor.extension.contain' }] },
};
function definitions(node: EditorNode, spec: EditorSpec | null | undefined): Definition[] {
  const cap = typeof node.name === 'string' ? spec?.componentCapabilities?.[node.name] : null;
  if (!cap) return [];
  const result: Definition[] = [];
  for (const [group, keys] of [['content', cap.propControls], ['style', cap.styleControls]] as const) {
    if (!Array.isArray(keys)) continue;
    for (const id of keys) {
      const control = typeof id === 'string' ? spec?.controls?.[id] : null;
      if (control && kindOf(control) && !result.some(field => field.id === id)) result.push({ id, control, group, source: 'template-spec' });
    }
  }
  if (node.type === 'basic' && node.name === 'Img' && result.some(d => kindOf(d.control) === 'image')) {
    for (const [id, control] of Object.entries(imageControls)) result.push({ id, control, group: 'style', source: 'core-image' });
  }
  return result;
}
function affectedValues(node: EditorNode, control: EditorControlSpec): unknown[] {
  const props = record(node.props) ? node.props : {};
  const style = record(props.style) ? props.style : {};
  const applies = [applyOf(control), ...(control.options ?? []).map(o => record(o) && record(o.apply) ? o.apply : undefined)];
  return applies.flatMap(a => {
    if (!a) return [];
    if (a.type === 'propValue') return [props[String(a.propKey)]];
    if (a.type === 'classToken') return [props.className];
    if (a.type === 'cssVar') return [style[String(a.varName)]];
    if (a.type === 'styleProp') return (Array.isArray(a.props) ? a.props : [a.prop]).map(p => style[String(p)]);
    return [];
  });
}
function translated(label: unknown, fallback: string, t: (key: string) => string): string {
  return typeof label === 'string' ? label.startsWith('$t:') ? t(label.slice(3)) : label : fallback;
}
export function readExtensionFields(node: EditorNode, spec: EditorSpec | null | undefined, t: (key: string) => string = key => key): EditorExtensionField[] {
  return definitions(node, spec).map(({ id, control, group, source }) => {
    const resolved = reverseResolve(node, control);
    const options = (control.options ?? []).flatMap(o => record(o) && (o.value === undefined || scalar(o.value))
      ? [{ value: o.value === undefined ? null : o.value, label: translated(o.label, String(o.value ?? '기본'), t) }] : []);
    const value = scalar(resolved.value) ? resolved.value : null;
    return { id, label: translated(control.label, id, t), kind: kindOf(control)!, group, value, options,
      editable: (node.props == null || record(node.props))
        && (node.props?.style == null || record(node.props.style))
        && affectedValues(node, control).every(v => plain(v) || typeof v === 'number' && Number.isFinite(v)),
      custom: resolved.conflict === true || value !== null && options.length > 0 && !options.some(o => o.value === value)
        || resolved.matched === false && JSON.stringify(applyRecipe(node, control, undefined).props) !== JSON.stringify(node.props), source };
  });
}
function safeUrl(value: string, image: boolean): boolean {
  if (/[\u0000-\u0020\u007f\\]/.test(value)) return false;
  return /^https?:\/\//i.test(value) || value.startsWith('/') && !value.startsWith('//')
    || !image && (/^(?:mailto:|tel:)/i.test(value) || value.startsWith('#')) || value === '';
}
export function changeExtensionField(node: EditorNode, spec: EditorSpec | null | undefined, id: string, value: ExtensionValue, reset: boolean): EditorNode | null {
  const definition = definitions(node, spec).find(d => d.id === id);
  const field = readExtensionFields(node, spec).find(d => d.id === id);
  if (!definition || !field?.editable || !scalar(value)) return null;
  if (!reset) {
    if (field.kind === 'choice' && !field.options.some(o => o.value === value)) return null;
    if (field.kind !== 'choice' && (typeof value !== 'string' || !plain(value))) return null;
    if ((field.kind === 'image' || field.kind === 'link') && (typeof value !== 'string' || !safeUrl(value, field.kind === 'image'))) return null;
    // Empty alt remains an explicit decorative-image alt; reset removes the override instead.
    const apply = applyOf(definition.control);
    if (value === '' && apply?.type === 'propValue' && apply.propKey) return { ...node, props: { ...node.props, [apply.propKey]: '' } };
  }
  return applyRecipe(node, definition.control, reset ? undefined : value);
}
