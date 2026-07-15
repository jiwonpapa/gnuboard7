const logger = ((window as any).G7Core?.createLogger?.('Handler:BenchmarkBoardTargets')) ?? {
    log: (...args: unknown[]) => console.log('[Handler:BenchmarkBoardTargets]', ...args),
    warn: (...args: unknown[]) => console.warn('[Handler:BenchmarkBoardTargets]', ...args),
    error: (...args: unknown[]) => console.error('[Handler:BenchmarkBoardTargets]', ...args),
};

type BoardTarget = {
    board_id: number;
    slug: string;
    name: string;
    target_posts: number;
    type?: string;
    is_active?: boolean;
    use_comment?: boolean;
    use_reply?: boolean;
};

function getLocalState(): Record<string, any> {
    return (window as any).G7Core?.state?.getLocal?.() ?? {};
}

function setLocalState(updates: Record<string, any>): void {
    const G7Core = (window as any).G7Core;

    if (!G7Core?.state?.setLocal) {
        logger.warn('G7Core.state.setLocal not available');
        return;
    }

    G7Core.state.setLocal(updates);
}

function normalizeTargetPosts(value: unknown, fallback = 0): number {
    const parsed = Number(value);

    if (!Number.isFinite(parsed)) {
        return fallback;
    }

    return Math.max(0, Math.floor(parsed));
}

function syncBoardTargets(selectedBoards: BoardTarget[]): void {
    const localState = getLocalState();
    const form = localState.form ?? {};
    const normalizedBoards = selectedBoards.map((boardTarget) => ({
        ...boardTarget,
        target_posts: normalizeTargetPosts(boardTarget.target_posts, 0),
    }));
    const selectedBoardIndex = Object.fromEntries(
        normalizedBoards.map((boardTarget) => [String(boardTarget.board_id), boardTarget])
    );

    setLocalState({
        form: {
            ...form,
            selected_boards: normalizedBoards,
            total_boards: normalizedBoards.length,
            total_posts: normalizedBoards.reduce((sum, boardTarget) => sum + boardTarget.target_posts, 0),
        },
        selectedBoardIndex,
    });
}

export function toggleBoardTargetHandler(action?: any, _context?: any): void {
    const board = action?.params?.board ?? null;
    const checked = Boolean(action?.params?.checked);
    const defaultTargetPosts = normalizeTargetPosts(action?.params?.defaultTargetPosts, 10000);
    const localState = getLocalState();
    const currentTargets = Array.isArray(localState.form?.selected_boards)
        ? [...localState.form.selected_boards]
        : [];

    if (!board || typeof board !== 'object') {
        logger.warn('toggleBoardTarget: invalid board payload', board);
        return;
    }

    const boardId = normalizeTargetPosts(board.id, 0);
    if (boardId <= 0) {
        logger.warn('toggleBoardTarget: invalid board id', board);
        return;
    }

    const nextTargets = currentTargets.filter((target: BoardTarget) => target.board_id !== boardId);

    if (checked) {
        nextTargets.push({
            board_id: boardId,
            slug: String(board.slug ?? ''),
            name: String(board.name ?? board.slug ?? `board-${boardId}`),
            target_posts: defaultTargetPosts,
            type: board.type ? String(board.type) : undefined,
            is_active: typeof board.is_active === 'boolean' ? board.is_active : undefined,
            use_comment: typeof board.use_comment === 'boolean' ? board.use_comment : undefined,
            use_reply: typeof board.use_reply === 'boolean' ? board.use_reply : undefined,
        });
    }

    syncBoardTargets(nextTargets);
}

export function updateBoardTargetPostsHandler(action?: any, _context?: any): void {
    const boardId = normalizeTargetPosts(action?.params?.boardId, 0);
    const targetPosts = normalizeTargetPosts(action?.params?.targetPosts, 0);
    const localState = getLocalState();
    const currentTargets = Array.isArray(localState.form?.selected_boards)
        ? [...localState.form.selected_boards]
        : [];

    if (boardId <= 0) {
        logger.warn('updateBoardTargetPosts: invalid board id', action?.params);
        return;
    }

    const nextTargets = currentTargets.map((target: BoardTarget) => {
        if (target.board_id !== boardId) {
            return target;
        }

        return {
            ...target,
            target_posts: targetPosts,
        };
    });

    syncBoardTargets(nextTargets);
}
