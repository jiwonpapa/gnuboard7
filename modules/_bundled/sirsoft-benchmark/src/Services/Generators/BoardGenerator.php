<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Board\Models\Board;

class BoardGenerator
{
    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state): array
    {
        $boardStates = $state['board_states'] ?? [];
        $boardPlans = $job->plan['board_plans'] ?? [];
        $processed = 0;
        $limit = 5;

        foreach ($boardStates as $index => $boardState) {
            if ($processed >= $limit) {
                break;
            }

            if (! empty($boardState['board_id'])) {
                continue;
            }

            $plan = $boardPlans[$index] ?? null;
            if (! $plan) {
                continue;
            }

            $targetBoardId = (int) ($boardState['target_board_id'] ?? $plan['board_id'] ?? 0);
            $existing = Board::query()->find($targetBoardId);

            if (! $existing || $existing->slug !== $plan['slug']) {
                throw new \RuntimeException("선택한 게시판 {$plan['slug']} 을(를) 찾을 수 없습니다.");
            }

            $boardStates[$index]['board_id'] = $existing->id;
            $processed++;
        }

        $state['board_states'] = $boardStates;

        return $state;
    }
}
