<?php

use Illuminate\Support\Facades\Route;
use Modules\Sirsoft\Benchmark\Http\Controllers\Admin\GenerationJobController;

Route::prefix('admin/generation-jobs')
    ->middleware(['auth:sanctum', 'throttle:120,1'])
    ->name('admin.generation-jobs.')
    ->group(function () {
        Route::get('/boards', [GenerationJobController::class, 'boards'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.read')
            ->name('boards');

        Route::get('/', [GenerationJobController::class, 'index'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.read')
            ->name('index');

        Route::post('/estimate', [GenerationJobController::class, 'estimate'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.create')
            ->name('estimate');

        Route::post('/', [GenerationJobController::class, 'store'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.create')
            ->name('store');

        Route::get('/{generationJob}', [GenerationJobController::class, 'show'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.read')
            ->name('show');

        Route::get('/{generationJob}/logs', [GenerationJobController::class, 'logs'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.read')
            ->name('logs');

        Route::post('/{generationJob}/stop', [GenerationJobController::class, 'stop'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.update')
            ->name('stop');

        Route::post('/{generationJob}/resume', [GenerationJobController::class, 'resume'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.update')
            ->name('resume');

        Route::post('/{generationJob}/rerun', [GenerationJobController::class, 'rerun'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.create')
            ->name('rerun');

        Route::post('/{generationJob}/reset', [GenerationJobController::class, 'reset'])
            ->middleware('permission:admin,sirsoft-benchmark.jobs.delete')
            ->name('reset');
    });
