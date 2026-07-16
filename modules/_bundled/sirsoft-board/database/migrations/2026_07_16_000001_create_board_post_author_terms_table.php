<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * 게시판별 고유 작성자명만 보관하는 작은 검색 사전을 생성합니다.
     */
    public function up(): void
    {
        if (! Schema::hasTable('board_post_author_terms')) {
            $textColumn = $this->postAuthorTextColumn();

            Schema::create('board_post_author_terms', function (Blueprint $table) use ($textColumn) {
                if ($textColumn !== null) {
                    $table->charset = $textColumn->character_set_name;
                    $table->collation = $textColumn->collation_name;
                }

                $table->unsignedBigInteger('board_id')->comment('게시판 ID');
                $table->string('author_name', 50)->comment('작성자명 검색 사전');
                $table->primary(['board_id', 'author_name']);
            });
        }

        $this->assertCompatibleAuthorTermsTable();

        DB::table('board_post_author_terms')->insertOrIgnoreUsing(
            ['board_id', 'author_name'],
            DB::table('board_posts')
                ->select(['board_id', 'author_name'])
                ->whereNotNull('author_name')
                ->where('author_name', '<>', '')
                ->distinct()
        );
    }

    /**
     * 작성자 검색 사전만 제거합니다.
     */
    public function down(): void
    {
        Schema::dropIfExists('board_post_author_terms');
    }

    /**
     * MySQL 계열에서는 원본 작성자 컬럼의 문자셋과 정렬 규칙을 그대로 사용합니다.
     */
    private function postAuthorTextColumn(): ?object
    {
        if (! in_array(DB::connection()->getDriverName(), ['mysql', 'mariadb'], true)) {
            return null;
        }

        // Query Builder는 table prefix를 information_schema에도 붙이므로 raw 조회합니다.
        return DB::selectOne(
            'SELECT CHARACTER_SET_NAME AS character_set_name,
                    COLLATION_NAME AS collation_name
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?',
            [
                DB::connection()->getDatabaseName(),
                DB::getTablePrefix().'board_posts',
                'author_name',
            ]
        );
    }

    /**
     * 같은 이름의 불완전한 테이블을 정상 스키마로 오인하지 않습니다.
     */
    private function assertCompatibleAuthorTermsTable(): void
    {
        $columnNames = collect(Schema::getColumns('board_post_author_terms'))
            ->pluck('name')
            ->sort()
            ->values()
            ->all();
        $primary = collect(Schema::getIndexes('board_post_author_terms'))
            ->first(fn (array $index): bool => $index['primary']);

        if (
            $columnNames !== ['author_name', 'board_id']
            || $primary === null
            || $primary['columns'] !== ['board_id', 'author_name']
        ) {
            throw new RuntimeException(
                'board_post_author_terms table exists with an incompatible schema.'
            );
        }

        if (! in_array(DB::connection()->getDriverName(), ['mysql', 'mariadb'], true)) {
            return;
        }

        $database = DB::connection()->getDatabaseName();
        $prefix = DB::getTablePrefix();
        $shape = DB::selectOne(
            'SELECT COUNT(*) AS total_columns,
                    SUM(CASE
                        WHEN COLUMN_NAME = ? AND DATA_TYPE = ?
                            AND COLUMN_TYPE LIKE ? AND IS_NULLABLE = ? THEN 1
                        WHEN COLUMN_NAME = ? AND DATA_TYPE = ?
                            AND CHARACTER_MAXIMUM_LENGTH = ? AND IS_NULLABLE = ? THEN 1
                        ELSE 0
                    END) AS matching_columns
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?',
            [
                'board_id',
                'bigint',
                '%unsigned%',
                'NO',
                'author_name',
                'varchar',
                50,
                'NO',
                $database,
                $prefix.'board_post_author_terms',
            ]
        );
        $table = DB::selectOne(
            'SELECT ENGINE AS engine
             FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?',
            [$database, $prefix.'board_post_author_terms']
        );
        $sourceColumn = $this->postAuthorTextColumn();
        $termsColumn = DB::selectOne(
            'SELECT CHARACTER_SET_NAME AS character_set_name,
                    COLLATION_NAME AS collation_name
             FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?',
            [$database, $prefix.'board_post_author_terms', 'author_name']
        );

        if (
            (int) ($shape->total_columns ?? 0) !== 2
            || (int) ($shape->matching_columns ?? 0) !== 2
            || ($table->engine ?? null) !== 'InnoDB'
            || $sourceColumn === null
            || $termsColumn === null
            || $termsColumn->character_set_name !== $sourceColumn->character_set_name
            || $termsColumn->collation_name !== $sourceColumn->collation_name
        ) {
            throw new RuntimeException(
                'board_post_author_terms table exists with an incompatible MySQL schema.'
            );
        }
    }
};
