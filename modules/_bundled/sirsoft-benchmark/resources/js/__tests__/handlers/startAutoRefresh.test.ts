// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { startAutoRefreshHandler } from '../../handlers/startAutoRefresh';

const AUTO_REFRESH_KEY = '__sirsoftBenchmarkAutoRefresh';

describe('startAutoRefreshHandler', () => {
    let refetch: ReturnType<typeof vi.fn>;
    let status: string;

    beforeEach(() => {
        vi.useFakeTimers();
        status = 'running';
        refetch = vi.fn().mockResolvedValue(undefined);
        window.history.replaceState({}, '', '/admin/benchmark/dummy-data/4');
        (window as any).G7Core = {
            dataSource: {
                refetch,
                get: () => ({ data: { status } }),
            },
        };
        delete (window as any)[AUTO_REFRESH_KEY];
    });

    afterEach(() => {
        const state = (window as any)[AUTO_REFRESH_KEY];
        if (state?.intervalId) {
            window.clearInterval(state.intervalId);
        }
        delete (window as any)[AUTO_REFRESH_KEY];
        vi.useRealTimers();
    });

    it('상세를 우선 갱신하고 로그와 목록은 낮은 주기로 순차 갱신한다', async () => {
        await startAutoRefreshHandler({
            params: { enabled: true, routeId: '4', interval: 5000 },
        });

        expect(refetch.mock.calls).toEqual([['selectedJob']]);

        await vi.advanceTimersByTimeAsync(5000);

        expect(refetch.mock.calls).toEqual([
            ['selectedJob'],
            ['selectedJob'],
            ['selectedLogs'],
        ]);

        await vi.advanceTimersByTimeAsync(5000);

        expect(refetch.mock.calls.slice(-2)).toEqual([
            ['selectedJob'],
            ['jobs'],
        ]);
        expect(refetch.mock.calls.every((call) => call.length === 1)).toBe(true);
    });

    it('stopping 상태에서도 완료 상태를 확인할 때까지 갱신을 유지한다', async () => {
        status = 'stopping';

        await startAutoRefreshHandler({
            params: { enabled: true, routeId: '4', interval: 5000 },
        });

        expect((window as any)[AUTO_REFRESH_KEY]).toBeTruthy();
        expect(vi.getTimerCount()).toBe(1);
    });

    it('완료 상태에서는 마지막 상세·로그·목록 갱신 후 타이머를 해제한다', async () => {
        status = 'completed';

        await startAutoRefreshHandler({
            params: { enabled: true, routeId: '4', interval: 5000 },
        });

        expect(refetch.mock.calls).toEqual([
            ['selectedJob'],
            ['selectedLogs'],
            ['jobs'],
        ]);
        expect((window as any)[AUTO_REFRESH_KEY]).toBeUndefined();
        expect(vi.getTimerCount()).toBe(0);
    });

    it('refetch 실패를 처리하고 다음 polling을 계속할 수 있게 잠금을 해제한다', async () => {
        const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
        refetch.mockRejectedValueOnce(new Error('temporary network error'));

        await expect(startAutoRefreshHandler({
            params: { enabled: true, routeId: '4', interval: 5000 },
        })).resolves.toBeUndefined();

        expect((window as any)[AUTO_REFRESH_KEY]?.refreshing).toBe(false);
        expect(vi.getTimerCount()).toBe(1);
        expect(errorSpy).toHaveBeenCalled();
        errorSpy.mockRestore();
    });
});
