<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * 상품 설명에 남은 이전 벤치마크 상품 코드를 현재 코드로 동기화합니다.
     */
    public function up(): void
    {
        if (! Schema::hasTable('ecommerce_products')) {
            return;
        }

        DB::table('ecommerce_products')
            ->whereRaw("product_code REGEXP '^BMJ[0-9A-Z]{13}$'")
            ->update([
                'description' => DB::raw(
                    'REPLACE(description, '
                    ."CONCAT('BMJ', CONV(SUBSTRING(product_code, 4, 4), 36, 10), '-', "
                    ."LPAD(CONV(SUBSTRING(product_code, 8, 9), 36, 10), 9, '0')), "
                    .'product_code)'
                ),
            ]);
    }

    /**
     * 상품 설명의 벤치마크 상품 코드를 이전 형식으로 되돌립니다.
     */
    public function down(): void
    {
        if (! Schema::hasTable('ecommerce_products')) {
            return;
        }

        DB::table('ecommerce_products')
            ->whereRaw("product_code REGEXP '^BMJ[0-9A-Z]{13}$'")
            ->update([
                'description' => DB::raw(
                    'REPLACE(description, product_code, '
                    ."CONCAT('BMJ', CONV(SUBSTRING(product_code, 4, 4), 36, 10), '-', "
                    ."LPAD(CONV(SUBSTRING(product_code, 8, 9), 36, 10), 9, '0')))"
                ),
            ]);
    }
};
