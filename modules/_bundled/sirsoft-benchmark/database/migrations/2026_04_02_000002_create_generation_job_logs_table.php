<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('generation_job_logs', function (Blueprint $table) {
            $table->id();
            $table->foreignId('generation_job_id')
                ->constrained('generation_jobs')
                ->cascadeOnDelete();
            $table->string('level', 20)->default('info')->index();
            $table->string('stage', 30)->nullable()->index();
            $table->string('message', 255);
            $table->json('context')->nullable();
            $table->timestamp('created_at')->useCurrent()->index();
        });

        if (DB::getDriverName() === 'mysql') {
            Schema::table('generation_job_logs', function (Blueprint $table) {
                $table->comment('벤치마크 더미데이터 생성 작업 로그');
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('generation_job_logs');
    }
};
