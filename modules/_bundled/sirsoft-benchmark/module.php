<?php

namespace Modules\Sirsoft\Benchmark;

use App\Extension\AbstractModule;

class Module extends AbstractModule
{
    public function getPermissions(): array
    {
        return [
            'name' => [
                'ko' => '벤치마크 더미데이터',
                'en' => 'Benchmark Dummy Data',
            ],
            'description' => [
                'ko' => '대용량 더미데이터 생성 및 정리 권한',
                'en' => 'Permissions for benchmark dataset generation and cleanup',
            ],
            'categories' => [
                [
                    'identifier' => 'jobs',
                    'name' => [
                        'ko' => '생성 작업 관리',
                        'en' => 'Generation Job Management',
                    ],
                    'description' => [
                        'ko' => '대용량 더미데이터 생성 작업 조회 및 제어',
                        'en' => 'View and control benchmark generation jobs',
                    ],
                    'permissions' => [
                        [
                            'action' => 'read',
                            'name' => [
                                'ko' => '작업 조회',
                                'en' => 'View Jobs',
                            ],
                            'description' => [
                                'ko' => '생성 작업 상태와 로그를 조회합니다.',
                                'en' => 'View generation job status and logs.',
                            ],
                            'type' => 'admin',
                            'roles' => ['admin', 'manager'],
                        ],
                        [
                            'action' => 'create',
                            'name' => [
                                'ko' => '작업 생성',
                                'en' => 'Create Jobs',
                            ],
                            'description' => [
                                'ko' => '새 더미데이터 생성 작업을 시작합니다.',
                                'en' => 'Start new benchmark generation jobs.',
                            ],
                            'type' => 'admin',
                            'roles' => ['admin'],
                        ],
                        [
                            'action' => 'update',
                            'name' => [
                                'ko' => '작업 제어',
                                'en' => 'Control Jobs',
                            ],
                            'description' => [
                                'ko' => '작업 중단 및 재개를 수행합니다.',
                                'en' => 'Stop and resume generation jobs.',
                            ],
                            'type' => 'admin',
                            'roles' => ['admin'],
                        ],
                        [
                            'action' => 'delete',
                            'name' => [
                                'ko' => '데이터셋 초기화',
                                'en' => 'Reset Dataset',
                            ],
                            'description' => [
                                'ko' => '생성된 벤치마크 데이터를 빠르게 정리합니다.',
                                'en' => 'Reset generated benchmark datasets.',
                            ],
                            'type' => 'admin',
                            'roles' => ['admin'],
                        ],
                    ],
                ],
            ],
        ];
    }

    public function getAdminMenus(): array
    {
        return [
            [
                'name' => [
                    'ko' => '더미데이터 생성',
                    'en' => 'Dummy Data Generator',
                ],
                'slug' => 'sirsoft-benchmark',
                'url' => '/admin/benchmark/dummy-data',
                'icon' => 'fas fa-database',
                'order' => 60,
                'permission' => 'sirsoft-benchmark.jobs.read',
            ],
        ];
    }

    /**
     * 그누보드7 7.0.6 성능 계측 프로파일을 반환합니다.
     *
     * @return array<string, array<string, mixed>>
     */
    public function getBenchmarkProfiles(): array
    {
        return [
            'generation_jobs_screen' => [
                'type' => 'screen',
                'label' => '더미데이터 최근 작업 화면',
                'route' => 'api.modules.sirsoft-benchmark.admin.generation-jobs.index',
                'query' => ['per_page' => 20],
                'permissions' => ['sirsoft-benchmark.jobs.read'],
            ],
        ];
    }
}
