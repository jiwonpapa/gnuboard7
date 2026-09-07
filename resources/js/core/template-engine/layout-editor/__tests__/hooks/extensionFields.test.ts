import { readFileSync } from 'node:fs';
import { expect, it, vi, afterEach } from 'vitest';
import type { EditorSpec } from '../../spec/specTypes';
import { readExtensionFields, changeExtensionField } from '../../extensions/fields';
import { prepareExtensionCommand } from '../../extensions/command';
import { extensionMedia } from '../../extensions/media';
import type { EditorExtensionContext } from '../../extensions/contract';
const dir = 'templates/_bundled/sirsoft-basic/editor-spec/';
const spec: EditorSpec = { componentCapabilities: JSON.parse(readFileSync(dir + 'componentCapabilities.json', 'utf8')),
  controls: JSON.parse(readFileSync(dir + 'controls.json', 'utf8')) };
const context: EditorExtensionContext = { templateIdentifier: 'sirsoft-basic', layoutName: 'test', editMode: 'route',
  sessionId: 'session', revision: 1, lockVersion: 4, readonly: false, nodeId: 'node', path: [0] };
const image = { id: 'node', type: 'basic', name: 'Img', __source: { kind: 'route' as const },
  props: { src: '/before.png', alt: 'Before', className: 'custom dark:w-1/2', style: { border: '1px solid red' },
    title: '$t:keep', onClick: [{ action: 'keep' }] }, future: { keep: 1 }, responsive: { mobile: { props: { alt: '$t:mobile' } } } };
it('exposes only supported current-spec fields plus standard image presentation', () => {
  expect(readExtensionFields(image, null)).toEqual([]);
  const fields = readExtensionFields(image, spec);
  expect(fields.map(f => f.id)).toEqual(['imgSrc', 'imgAlt', 'width', 'height', 'selfAlign', 'core:image-ratio', 'core:image-fit']);
  expect(fields.find(f => f.id === 'width')?.options.map(o => o.value)).toEqual(['100%', '75%', '50%', '25%']);
  expect(fields.find(f => f.id === 'core:image-ratio')?.value).toBeNull();
});
it.each([['imgSrc', '/after.png'], ['imgAlt', 'After'], ['imgAlt', ''], ['core:image-ratio', '16 / 9'], ['core:image-fit', 'cover'], ['width', '50%']] as const)
('applies %s through the same guarded node command without losing other fields', (control, value) => {
  const input = structuredClone(image);
  const result = prepareExtensionCommand([input], context, { kind: 'setControl', expected: context, control, value }, null, spec);
  expect(result.result.kind).toBe('applied');
  const next = result.components[0];
  expect(next.future).toEqual(image.future); expect(next.responsive).toEqual(image.responsive); expect(next.__source).toEqual(image.__source);
  expect(next.props?.title).toBe('$t:keep'); expect(next.props?.onClick).toEqual(image.props.onClick);
  expect(next.props?.style.border).toBe(image.props.style.border); expect(input).toEqual(image);
  if (control === 'imgAlt') expect(next.props?.alt).toBe(value);
});
it.each(['$t:bound', '{{item.image}}', '$local:asset'])('refuses bound image %s including reset', src => {
  const node = { ...image, props: { ...image.props, src } };
  expect(readExtensionFields(node, spec).find(f => f.id === 'imgSrc')?.editable).toBe(false);
  expect(changeExtensionField(node, spec, 'imgSrc', '/after.png', false)).toBeNull();
  expect(changeExtensionField(node, spec, 'imgSrc', null, true)).toBeNull();
  expect(changeExtensionField(node, spec, 'imgAlt', 'Allowed', false)?.props?.src).toBe(src);
});
it.each(['javascript:alert(1)', '//outside.test/a', 'data:image/svg+xml,x', '/bad\\url', 'https://a\n.test', '{{url}}'])('rejects unsafe image/link input %s', value => {
  expect(changeExtensionField(image, spec, 'imgSrc', value, false)).toBeNull();
  expect(changeExtensionField({ ...image, name: 'A', props: { href: '/before' } }, spec, 'linkHref', value, false)).toBeNull();
});
it('resets only the selected spec group and preserves unrelated/dark tokens and style', () => {
  const heading = { ...image, name: 'H2', props: { ...image.props, className: 'custom text-left dark:text-right', style: { ...image.props.style } } };
  const applied = changeExtensionField(heading, spec, 'textAlign', 'center', false)!;
  expect(applied.props?.className).toBe('custom dark:text-right text-center');
  expect(changeExtensionField(applied, spec, 'textAlign', null, true)?.props?.className).toBe('custom dark:text-right');
  const ratio = changeExtensionField(image, spec, 'core:image-ratio', '1 / 1', false)!;
  expect(changeExtensionField(ratio, spec, 'core:image-ratio', null, true)?.props?.style).toEqual(image.props.style);
  expect(changeExtensionField(image, spec, 'width', '999px', false)).toBeNull();
  expect(changeExtensionField(image, spec, '__source', 'route', false)).toBeNull();
});
it('retains custom values as custom and locks expression-backed styles', () => {
  const custom = { ...image, props: { ...image.props, style: { width: '37%' } } };
  expect(readExtensionFields(custom, spec).find(f => f.id === 'width')?.custom).toBe(true);
  const bound = { ...image, name: 'H2', props: { className: '{{item.className}}' } };
  expect(readExtensionFields(bound, spec).find(f => f.id === 'textAlign')?.editable).toBe(false);
});
it.each(['sessionId', 'revision', 'lockVersion', 'nodeId', 'layoutName', 'templateIdentifier', 'path'] as const)('rejects stale %s on field changes', key => {
  const command = { kind: 'setControl' as const, expected: { ...context, [key]: key === 'path' ? [1] : 'other' }, control: 'imgAlt', value: 'After' };
  expect(prepareExtensionCommand([image], context, command, null, spec).result.kind).toBe('refused');
});
it.each(['base', 'partial', 'extension'] as const)('protects %s source on field changes', kind => {
  const node = { ...image, __source: { kind } };
  expect(prepareExtensionCommand([node], context, { kind: 'setControl', expected: context, control: 'imgAlt', value: 'After' }, null, spec).result.kind).toBe('refused');
});
vi.mock('../../utils/authToken', () => ({ buildAuthHeaders: () => ({ Authorization: 'Bearer test-only' }) }));
afterEach(() => vi.unstubAllGlobals());
const asset = { id: 1, layout_name: 'test', original_name: 'photo.png', mime_type: 'image/png', size: 1, url: '/image.png' };
it('uses page or template attachment scopes and uploads into the captured layout', async () => {
  const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ success: true, data: [asset] }) });
  vi.stubGlobal('fetch', fetcher);
  const media = extensionMedia(() => context);
  await media.list({ expected: context, scope: 'page' });
  expect(fetcher.mock.calls[0][0]).toContain('?layout_name=test');
  await media.list({ expected: context, scope: 'template' });
  expect(fetcher.mock.calls[1][0]).not.toContain('?');
  fetcher.mockResolvedValue({ ok: true, json: async () => ({ success: true, data: asset }) });
  expect((await media.upload({ expected: context, file: new File(['test'], 'photo.png', { type: 'image/png' }) })).ok).toBe(true);
  const args = fetcher.mock.calls[2][1];
  expect(args.headers.Authorization).toBe('Bearer test-only');
  expect(args.body.get('layout_name')).toBe('test');
});
it.each(['cancel', 'revision', 'layout', 'readonly', 'unmount'])('drops late media responses after %s', async mode => {
  let finish!: (value: unknown) => void;
  vi.stubGlobal('fetch', vi.fn(() => new Promise(resolve => { finish = resolve; })));
  let live: EditorExtensionContext | null = context;
  const media = extensionMedia(() => live);
  const controller = new AbortController();
  const pending = media.upload({ expected: context, file: new File(['x'], 'photo.png'), signal: controller.signal });
  if (mode === 'cancel') controller.abort();
  else if (mode === 'unmount') live = null;
  else live = { ...context, ...(mode === 'readonly' ? { readonly: true } : mode === 'layout' ? { layoutName: 'other' } : { revision: 2 }) };
  finish({ ok: true, json: async () => ({ success: true, data: asset }) });
  expect(await pending).toEqual({ ok: false, reason: 'stale-or-cancelled' });
});
it('rejects missing permission, aborted requests and API failure without mutation', async () => {
  const fetcher = vi.fn().mockResolvedValue({ ok: false, status: 403, json: async () => ({ message: 'Forbidden' }) });
  vi.stubGlobal('fetch', fetcher);
  const media = extensionMedia(() => context);
  expect((await media.list({ expected: context, scope: 'page' })).ok).toBe(false);
  const abort = new AbortController(); abort.abort();
  await media.list({ expected: context, scope: 'page', signal: abort.signal });
  expect(fetcher).toHaveBeenCalledTimes(1);
  expect((await extensionMedia(() => ({ ...context, readonly: true })).list({ expected: context, scope: 'page' })).ok).toBe(false);
});
it('does not normalize opaque props/style containers while editing a different field', () => {
  const opaque = { ...image, props: { ...image.props, style: '{{theme.style}}' } };
  expect(changeExtensionField(opaque, spec, 'imgAlt', 'After', false)).toBeNull();
  expect(changeExtensionField(opaque, spec, 'width', '50%', false)).toBeNull();
});
it('shows inherited defaults when unrelated classes exist but the edited style group is absent', () => {
  const node = { ...image, name: 'H2', props: { className: 'custom text-left dark:text-right' } };
  expect(readExtensionFields(node, spec).find(f => f.id === 'fontWeight')?.custom).toBe(false);
});
