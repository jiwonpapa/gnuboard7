<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * 그누보드7 7.0.6 이커머스가 공식 제공하는 인덱스와 겹치는 이전 실험용 인덱스를 정리합니다.
 *
 * 0.4.0 이하를 설치한 데이터베이스에는 7.0.5용 인덱스가 이미 적용되어 있을 수 있습니다.
 * 공식 대응 인덱스가 실제로 존재하는 경우에만 이전 인덱스를 제거해, 독립 설치나 부분
 * 업그레이드 상태에서 조회 인덱스가 사라지지 않도록 합니다.
 */
return new class extends Migration
{
    /**
     * 대상 [테이블, 이전 실험용 인덱스, 7.0.6 공식 인덱스, 되돌릴 컬럼]
     *
     * @var array<int, array{0: string, 1: string, 2: string, 3: array<int, string>}>
     */
    private const TARGETS = [
        [
            'ecommerce_products',
            'idx_ecommerce_products_public_latest',
            'idx_products_display_created_id',
            ['display_status', 'deleted_at', 'created_at', 'id'],
        ],
        [
            'ecommerce_products',
            'idx_ecommerce_products_public_price',
            'idx_products_display_price_id',
            ['display_status', 'deleted_at', 'selling_price', 'id'],
        ],
        [
            'ecommerce_order_options',
            'idx_ecommerce_order_options_recent_sales',
            'idx_order_options_product_created_qty',
            ['created_at', 'product_id', 'quantity'],
        ],
    ];

    /**
     * 7.0.6 공식 인덱스가 있는 테이블에서 이전 중복 인덱스를 제거합니다.
     */
    public function up(): void
    {
        if (DB::getDriverName() !== 'mysql') {
            return;
        }

        foreach (self::TARGETS as [$table, $legacyIndex, $officialIndex]) {
            if (! Schema::hasTable($table)) {
                continue;
            }

            $indexes = array_column(Schema::getIndexes($table), 'name');
            if (! in_array($officialIndex, $indexes, true)
                || ! in_array($legacyIndex, $indexes, true)) {
                continue;
            }

            Schema::table($table, function (Blueprint $blueprint) use ($legacyIndex) {
                $blueprint->dropIndex($legacyIndex);
            });
        }
    }

    /**
     * 모듈 롤백 시 제거했던 이전 실험용 인덱스를 복구합니다.
     */
    public function down(): void
    {
        if (DB::getDriverName() !== 'mysql') {
            return;
        }

        foreach (self::TARGETS as [$table, $legacyIndex, $officialIndex, $columns]) {
            if (! Schema::hasTable($table)) {
                continue;
            }

            $indexes = array_column(Schema::getIndexes($table), 'name');
            if (! in_array($officialIndex, $indexes, true)
                || in_array($legacyIndex, $indexes, true)) {
                continue;
            }

            Schema::table($table, function (Blueprint $blueprint) use ($legacyIndex, $columns) {
                $blueprint->index($columns, $legacyIndex);
            });
        }
    }
};
