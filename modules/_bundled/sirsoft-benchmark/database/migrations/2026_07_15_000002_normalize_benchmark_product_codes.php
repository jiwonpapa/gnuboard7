<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * 기존 하이픈 포함 벤치마크 상품 코드를 공개 상품 라우트와 호환되는 영숫자 코드로 변환합니다.
     */
    public function up(): void
    {
        if (! Schema::hasTable('ecommerce_products')) {
            return;
        }

        DB::table('ecommerce_products')
            ->whereRaw("product_code REGEXP '^BMJ[0-9]+-[0-9]{9}$'")
            ->whereRaw("CAST(SUBSTRING_INDEX(SUBSTRING(product_code, 4), '-', 1) AS UNSIGNED) BETWEEN 1 AND 1679615")
            ->update([
                'product_code' => DB::raw(
                    "CONCAT('BMJ', "
                    ."LPAD(UPPER(CONV(SUBSTRING_INDEX(SUBSTRING(product_code, 4), '-', 1), 10, 36)), 4, '0'), "
                    ."LPAD(UPPER(CONV(SUBSTRING_INDEX(product_code, '-', -1), 10, 36)), 9, '0'))"
                ),
            ]);
    }

    /**
     * 벤치마크 상품 코드를 이전 형식으로 되돌립니다.
     */
    public function down(): void
    {
        if (! Schema::hasTable('ecommerce_products')) {
            return;
        }

        DB::table('ecommerce_products')
            ->whereRaw("product_code REGEXP '^BMJ[0-9A-Z]{13}$'")
            ->update([
                'product_code' => DB::raw(
                    "CONCAT('BMJ', "
                    ."CONV(SUBSTRING(product_code, 4, 4), 36, 10), '-', "
                    ."LPAD(CONV(SUBSTRING(product_code, 8, 9), 36, 10), 9, '0'))"
                ),
            ]);
    }
};
