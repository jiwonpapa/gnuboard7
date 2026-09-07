import { expect, it } from 'vitest';
import { readPreviewLocalDefaults, mergePreviewLocal } from '../../utils/previewLocalDefaults';
import { limitIterationSourceToOne } from '../../utils/iterationSampleLimit';
it('copies only object defaults without mutating the saved layout', () => {
  const input = { items: [{ title: 'One' }, { title: 'Two' }], preserved: true };
  const defaults = readPreviewLocalDefaults(input);
  expect(defaults).toEqual(input); expect(defaults.items).not.toBe(input.items);
  for (const invalid of [null, undefined, [], 'binding']) expect(readPreviewLocalDefaults(invalid)).toEqual({});
});
it('keeps existing local values, fills missing defaults and retains deliberate empty arrays', () => {
  expect(mergePreviewLocal({ items: [1], page: 1 }, { items: [], edited: true })).toEqual({ items: [], page: 1, edited: true });
});
it('limits the local iteration preview only and leaves its saved source and siblings intact', () => {
  const local = { items: [{ title: 'One' }, { title: 'Two' }], other: [1, 2] };
  const context = { staticItems: [3, 4], _local: mergePreviewLocal(local, {}) };
  const preview = limitIterationSourceToOne(context, '{{_local.items}}');
  expect(preview._local.items).toEqual([local.items[0]]); expect(preview._local.other).toEqual([1, 2]);
  expect(preview.staticItems).toEqual([3, 4]); expect(local.items).toHaveLength(2); expect(context._local.items).toHaveLength(2);
});
