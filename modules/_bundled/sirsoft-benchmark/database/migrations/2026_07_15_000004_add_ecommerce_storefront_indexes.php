<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * 공개 상품 목록과 최근 판매량 집계용 벤치마크 인덱스를 추가합니다.
     */
    public function up(): void
    {
        if (DB::getDriverName() !== 'mysql' || ! Schema::hasTable('ecommerce_products')) {
            return;
        }

        $productIndexes = array_column(Schema::getIndexes('ecommerce_products'), 'name');
        $clauses = [];

        if (! in_array('idx_products_display_created_id', $productIndexes, true)
            && ! in_array('idx_ecommerce_products_public_latest', $productIndexes, true)) {
            $clauses[] = 'ADD INDEX idx_ecommerce_products_public_latest (display_status, deleted_at, created_at, id)';
        }
        if (! in_array('idx_products_display_price_id', $productIndexes, true)
            && ! in_array('idx_ecommerce_products_public_price', $productIndexes, true)) {
            $clauses[] = 'ADD INDEX idx_ecommerce_products_public_price (display_status, deleted_at, selling_price, id)';
        }

        if ($clauses !== []) {
            DB::statement('ALTER TABLE '.DB::getTablePrefix().'ecommerce_products '.implode(', ', $clauses));
        }

        if (! Schema::hasTable('ecommerce_order_options')) {
            return;
        }

        $orderIndexes = array_column(Schema::getIndexes('ecommerce_order_options'), 'name');
        if (! in_array('idx_order_options_product_created_qty', $orderIndexes, true)
            && ! in_array('idx_ecommerce_order_options_recent_sales', $orderIndexes, true)) {
            DB::statement(
                'ALTER TABLE '.DB::getTablePrefix().'ecommerce_order_options '
                .'ADD INDEX idx_ecommerce_order_options_recent_sales (created_at, product_id, quantity)'
            );
        }
    }

    /**
     * 벤치마크 인덱스를 제거해 원본 스키마로 복구합니다.
     */
    public function down(): void
    {
        if (DB::getDriverName() !== 'mysql') {
            return;
        }

        $this->dropIndexIfExists('ecommerce_order_options', 'idx_ecommerce_order_options_recent_sales');
        $this->dropIndexIfExists('ecommerce_products', 'idx_ecommerce_products_public_price');
        $this->dropIndexIfExists('ecommerce_products', 'idx_ecommerce_products_public_latest');
    }

    private function dropIndexIfExists(string $table, string $index): void
    {
        if (! Schema::hasTable($table)) {
            return;
        }

        $indexes = array_column(Schema::getIndexes($table), 'name');
        if (in_array($index, $indexes, true)) {
            DB::statement('ALTER TABLE '.DB::getTablePrefix().$table.' DROP INDEX '.$index);
        }
    }
};
