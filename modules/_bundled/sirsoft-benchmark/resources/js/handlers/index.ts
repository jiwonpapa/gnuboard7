import { toggleBoardTargetHandler, updateBoardTargetPostsHandler } from './boardTargets';
import { startAutoRefreshHandler } from './startAutoRefresh';

export const handlerMap = {
    toggleBoardTarget: toggleBoardTargetHandler,
    updateBoardTargetPosts: updateBoardTargetPostsHandler,
    startAutoRefresh: startAutoRefreshHandler,
};
