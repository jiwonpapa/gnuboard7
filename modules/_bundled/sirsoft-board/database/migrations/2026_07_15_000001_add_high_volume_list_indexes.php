<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * 대용량 게시판의 ID·조회수 정렬 페이지네이션용 인덱스를 추가합니다.
     */
    public function up(): void
    {
        Schema::table('board_posts', function (Blueprint $table) {
            if (! $this->hasIndex('board_posts', 'idx_board_posts_list_id')) {
                // 게시판별 기본 ID 정렬과 깊은 OFFSET의 ID 선조회에 사용합니다.
                $table->index(
                    ['board_id', 'is_notice', 'parent_id', 'deleted_at', 'id'],
                    'idx_board_posts_list_id'
                );
            }

            if (! $this->hasIndex('board_posts', 'idx_board_posts_list_views')) {
                // 조회수 정렬에서도 filesort 없이 ID 선조회가 가능하도록 합니다.
                $table->index(
                    ['board_id', 'is_notice', 'parent_id', 'deleted_at', 'view_count', 'id'],
                    'idx_board_posts_list_views'
                );
            }
        });
    }

    /**
     * 이번 변경에서 추가한 인덱스만 제거합니다.
     */
    public function down(): void
    {
        Schema::table('board_posts', function (Blueprint $table) {
            if ($this->hasIndex('board_posts', 'idx_board_posts_list_views')) {
                $table->dropIndex('idx_board_posts_list_views');
            }

            if ($this->hasIndex('board_posts', 'idx_board_posts_list_id')) {
                $table->dropIndex('idx_board_posts_list_id');
            }
        });
    }

    /**
     * 인덱스 존재 여부를 확인합니다.
     */
    private function hasIndex(string $table, string $indexName): bool
    {
        return collect(Schema::getIndexes($table))
            ->contains(fn (array $index) => $index['name'] === $indexName);
    }
};
