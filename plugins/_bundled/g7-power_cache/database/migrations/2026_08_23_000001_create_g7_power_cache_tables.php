<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

return new class extends Migration
{
    /**
     * G7PowerCache 런타임 상태와 내구성 있는 무효화 아웃박스를 생성합니다.
     */
    public function up(): void
    {
        Schema::create('g7_power_cache_state', function (Blueprint $table) {
            $table->string('state_key', 64)->primary()->comment('상태 식별자');
            $table->text('state_value')->comment('상태 값');
            $table->timestamps();
        });

        Schema::create('g7_power_cache_invalidation_outbox', function (Blueprint $table) {
            $table->bigIncrements('id')->comment('단조 증가 무효화 이벤트 ID');
            $table->json('scopes')->comment('회전할 세대 스코프 배열');
            $table->string('reason', 191)->comment('무효화 사유');
            $table->json('payload')->nullable()->comment('감사·진단용 최소 부가정보');
            $table->unsignedInteger('attempts')->default(0)->comment('적용 시도 횟수');
            $table->text('last_error')->nullable()->comment('마지막 적용 오류');
            $table->timestamp('applied_at')->nullable()->comment('캐시 저장소 적용 완료 시각');
            $table->timestamps();

            $table->index(['applied_at', 'id'], 'idx_g7pc_outbox_pending');
        });

        $now = now();
        DB::table('g7_power_cache_state')->insert([
            [
                'state_key' => 'site_id',
                'state_value' => (string) Str::uuid(),
                'created_at' => $now,
                'updated_at' => $now,
            ],
            [
                'state_key' => 'runtime_epoch',
                'state_value' => (string) Str::uuid(),
                'created_at' => $now,
                'updated_at' => $now,
            ],
            [
                'state_key' => 'dirty_event_id',
                'state_value' => '0',
                'created_at' => $now,
                'updated_at' => $now,
            ],
        ]);

        if (DB::getDriverName() === 'mysql') {
            Schema::table('g7_power_cache_state', function (Blueprint $table) {
                $table->comment('G7PowerCache 설치 ID·런타임 epoch·복구 장벽 상태');
            });
            Schema::table('g7_power_cache_invalidation_outbox', function (Blueprint $table) {
                $table->comment('커밋 후 재생 가능한 G7PowerCache 무효화 아웃박스');
            });
        }
    }

    /**
     * 플러그인 전용 테이블을 역순으로 제거합니다.
     */
    public function down(): void
    {
        Schema::dropIfExists('g7_power_cache_invalidation_outbox');
        Schema::dropIfExists('g7_power_cache_state');
    }
};
