<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('generation_jobs', function (Blueprint $table) {
            $table->string('workload_type', 20)->default('board')->index()->after('dataset_slug')->comment('board 또는 commerce');
            $table->unsignedInteger('total_categories')->default(0)->after('estimated_comments')->comment('생성 대상 상품 분류 수');
            $table->unsignedInteger('total_brands')->default(0)->after('total_categories')->comment('생성 대상 브랜드 수');
            $table->unsignedBigInteger('total_products')->default(0)->after('total_brands')->comment('생성 대상 상품 수');
            $table->unsignedBigInteger('estimated_product_images')->default(0)->after('total_products')->comment('예상 상품 이미지 연결 수');
            $table->unsignedInteger('generated_categories')->default(0)->after('generated_comments')->comment('생성된 상품 분류 수');
            $table->unsignedInteger('generated_brands')->default(0)->after('generated_categories')->comment('생성된 브랜드 수');
            $table->unsignedBigInteger('generated_products')->default(0)->after('generated_brands')->comment('생성된 상품 수');
            $table->unsignedBigInteger('generated_product_options')->default(0)->after('generated_products')->comment('생성된 기본 상품 옵션 수');
            $table->unsignedBigInteger('generated_product_images')->default(0)->after('generated_product_options')->comment('생성된 상품 이미지 연결 수');
        });
    }

    public function down(): void
    {
        Schema::table('generation_jobs', function (Blueprint $table) {
            $table->dropIndex(['workload_type']);
            $table->dropColumn([
                'workload_type',
                'total_categories',
                'total_brands',
                'total_products',
                'estimated_product_images',
                'generated_categories',
                'generated_brands',
                'generated_products',
                'generated_product_options',
                'generated_product_images',
            ]);
        });
    }
};
