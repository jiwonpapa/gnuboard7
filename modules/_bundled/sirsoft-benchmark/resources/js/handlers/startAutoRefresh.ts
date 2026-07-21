const logger = ((window as any).G7Core?.createLogger?.('Handler:BenchmarkAutoRefresh')) ?? {
    log: (...args: unknown[]) => console.log('[Handler:BenchmarkAutoRefresh]', ...args),
    warn: (...args: unknown[]) => console.warn('[Handler:BenchmarkAutoRefresh]', ...args),
    error: (...args: unknown[]) => console.error('[Handler:BenchmarkAutoRefresh]', ...args),
};

const AUTO_REFRESH_KEY = '__sirsoftBenchmarkAutoRefresh';
const TERMINAL_STATUSES = new Set(['completed', 'failed', 'stopped']);

type AutoRefreshState = {
    intervalId: number;
    intervalMs: number;
    routeId: string;
    tick: number;
    refreshing: boolean;
};

function getCore(): any {
    return (window as any).G7Core;
}

function normalizeBoolean(value: unknown): boolean {
    if (typeof value === 'boolean') {
        return value;
    }

    if (typeof value === 'string') {
        const normalized = value.trim().toLowerCase();
        return !['', '0', 'false', 'null', 'undefined'].includes(normalized);
    }

    if (typeof value === 'number') {
        return value !== 0;
    }

    return Boolean(value);
}

function getAutoRefreshState(): AutoRefreshState | null {
    return ((window as any)[AUTO_REFRESH_KEY] as AutoRefreshState | undefined) ?? null;
}

function clearAutoRefresh(reason?: string): void {
    const state = getAutoRefreshState();
    if (!state) {
        return;
    }

    window.clearInterval(state.intervalId);
    delete (window as any)[AUTO_REFRESH_KEY];
    logger.log('[startAutoRefresh] cleared', reason ?? 'no reason');
}

function isBenchmarkPage(): boolean {
    return window.location.pathname.startsWith('/admin/benchmark/dummy-data');
}

function getSelectedJobStatus(): string | null {
    const core = getCore();
    const source =
        core?.dataSource?.get?.('selectedJob')
        ?? core?.state?.getDataSource?.('selectedJob')
        ?? null;

    const status = source?.data?.status
        ?? source?.data?.data?.status
        ?? source?.status
        ?? null;

    return typeof status === 'string' ? status : null;
}

async function refetchDataSource(dataSourceId: string): Promise<void> {
    const core = getCore();
    if (!core?.dataSource?.refetch) {
        logger.warn('[startAutoRefresh] G7Core.dataSource.refetch is not available');
        return;
    }

    await core.dataSource.refetch(dataSourceId);
}

async function refreshBenchmarkState(): Promise<void> {
    const refreshState = getAutoRefreshState();

    if (!refreshState || refreshState.refreshing) {
        return;
    }

    if (!isBenchmarkPage()) {
        clearAutoRefresh('left benchmark page');
        return;
    }

    if (document.visibilityState === 'hidden') {
        return;
    }

    refreshState.refreshing = true;

    try {
        refreshState.tick++;

        // 상세 상태를 우선 갱신하고, 로그와 최근 목록은 낮은 주기로 순차 갱신합니다.
        // 동시 sync refetch가 전역 transition을 반복 토글해 화면이 깜빡이던 문제를 방지합니다.
        await refetchDataSource('selectedJob');

        const status = getSelectedJobStatus();
        if (status && TERMINAL_STATUSES.has(status)) {
            await refetchDataSource('selectedLogs');
            await refetchDataSource('jobs');
            clearAutoRefresh(`terminal status: ${status}`);

            return;
        }

        if (refreshState.tick % 2 === 0) {
            await refetchDataSource('selectedLogs');
        }

        if (refreshState.tick % 3 === 0) {
            await refetchDataSource('jobs');
        }
    } catch (error) {
        logger.error('[startAutoRefresh] refresh failed', error);
    } finally {
        refreshState.refreshing = false;
    }
}

export async function startAutoRefreshHandler(action: any, _context?: any): Promise<void> {
    const enabled = normalizeBoolean(action?.params?.enabled ?? true);
    const routeId = String(action?.params?.routeId ?? '').trim();
    const intervalValue = Number(action?.params?.interval ?? 5000);
    const intervalMs = Number.isFinite(intervalValue) && intervalValue >= 3000 ? intervalValue : 5000;

    if (!enabled || routeId === '' || !isBenchmarkPage()) {
        clearAutoRefresh('disabled');
        return;
    }

    const current = getAutoRefreshState();
    if (current && current.routeId === routeId && current.intervalMs === intervalMs) {
        await refreshBenchmarkState();
        return;
    }

    clearAutoRefresh('restarting');

    const intervalId = window.setInterval(() => {
        void refreshBenchmarkState();
    }, intervalMs);

    (window as any)[AUTO_REFRESH_KEY] = {
        intervalId,
        intervalMs,
        routeId,
        tick: 0,
        refreshing: false,
    } satisfies AutoRefreshState;

    logger.log('[startAutoRefresh] started', { routeId, intervalMs });

    await refreshBenchmarkState();
}
