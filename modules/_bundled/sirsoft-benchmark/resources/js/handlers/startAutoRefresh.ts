const logger = ((window as any).G7Core?.createLogger?.('Handler:BenchmarkAutoRefresh')) ?? {
    log: (...args: unknown[]) => console.log('[Handler:BenchmarkAutoRefresh]', ...args),
    warn: (...args: unknown[]) => console.warn('[Handler:BenchmarkAutoRefresh]', ...args),
    error: (...args: unknown[]) => console.error('[Handler:BenchmarkAutoRefresh]', ...args),
};

const AUTO_REFRESH_KEY = '__sirsoftBenchmarkAutoRefresh';
const TERMINAL_STATUSES = new Set(['completed', 'failed', 'stopped', 'stopping']);

type AutoRefreshState = {
    intervalId: number;
    intervalMs: number;
    routeId: string;
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

    await core.dataSource.refetch(dataSourceId, { sync: true });
}

async function refreshBenchmarkState(): Promise<void> {
    if (!isBenchmarkPage()) {
        clearAutoRefresh('left benchmark page');
        return;
    }

    if (document.visibilityState === 'hidden') {
        return;
    }

    await Promise.allSettled([
        refetchDataSource('jobs'),
        refetchDataSource('selectedJob'),
        refetchDataSource('selectedLogs'),
    ]);

    const status = getSelectedJobStatus();
    if (status && TERMINAL_STATUSES.has(status)) {
        clearAutoRefresh(`terminal status: ${status}`);
    }
}

export async function startAutoRefreshHandler(action: any, _context?: any): Promise<void> {
    const enabled = normalizeBoolean(action?.params?.enabled ?? true);
    const routeId = String(action?.params?.routeId ?? '').trim();
    const intervalValue = Number(action?.params?.interval ?? 5000);
    const intervalMs = Number.isFinite(intervalValue) && intervalValue >= 1000 ? intervalValue : 5000;

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
    } satisfies AutoRefreshState;

    logger.log('[startAutoRefresh] started', { routeId, intervalMs });

    await refreshBenchmarkState();
}
