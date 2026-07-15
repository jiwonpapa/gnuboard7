<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('generation_jobs', function (Blueprint $table) {
            $table->id();
            $table->string('uuid', 36)->unique()->comment('작업 UUID');
            $table->string('dataset_name', 100)->comment('사용자 지정 데이터셋 이름');
            $table->string('dataset_slug', 120)->unique()->comment('데이터셋 슬러그/마커');
            $table->unsignedBigInteger('seed')->nullable()->comment('재현 가능한 시드');
            $table->string('status', 20)->default('pending')->index()->comment('pending, running, stopping, stopped, completed, failed');
            $table->string('current_stage', 30)->default('planning')->index()->comment('현재 처리 단계');
            $table->boolean('dry_run')->default(false)->comment('실제 INSERT 없이 계획만 계산');

            $table->unsignedBigInteger('total_users')->default(0);
            $table->unsignedInteger('total_boards')->default(0);
            $table->unsignedBigInteger('total_posts')->default(0);
            $table->unsignedBigInteger('estimated_comments')->default(0);
            $table->unsignedBigInteger('processed_comment_candidates')->default(0)->comment('댓글 단계에서 스캔한 게시글 수');

            $table->unsignedBigInteger('generated_users')->default(0);
            $table->unsignedInteger('generated_boards')->default(0);
            $table->unsignedBigInteger('generated_posts')->default(0);
            $table->unsignedBigInteger('generated_comments')->default(0);

            $table->decimal('progress_percent', 5, 2)->default(0);
            $table->string('current_step', 255)->nullable();
            $table->json('options')->nullable();
            $table->json('plan')->nullable();
            $table->json('runtime_state')->nullable();
            $table->text('last_error')->nullable();

            $table->timestamp('started_at')->nullable();
            $table->timestamp('finished_at')->nullable();
            $table->timestamp('stop_requested_at')->nullable();
            $table->timestamp('last_heartbeat_at')->nullable();

            $table->foreignId('requested_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamps();
        });

        if (DB::getDriverName() === 'mysql') {
            Schema::table('generation_jobs', function (Blueprint $table) {
                $table->comment('벤치마크 더미데이터 생성 작업');
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('generation_jobs');
    }
};
