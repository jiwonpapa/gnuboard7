// @vitest-environment jsdom
/**
 * @file admin-benchmark-dashboard.test.tsx
 * @description 벤치마크 더미데이터 관리자 레이아웃 기본 렌더링 회귀 테스트
 */

import React from 'react';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createLayoutTest, screen } from '@core/template-engine/__tests__/utils/layoutTestUtils';
import { ComponentRegistry } from '@core/template-engine/ComponentRegistry';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const layoutPath = path.resolve(__dirname, '../../../layouts/admin/admin_benchmark_dashboard.json');
const benchmarkLayout = JSON.parse(fs.readFileSync(layoutPath, 'utf-8'));

const TestDiv: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <div className={className}>{children || text}</div>
);

const TestButton: React.FC<{
    type?: string;
    className?: string;
    disabled?: boolean;
    children?: React.ReactNode;
    onClick?: () => void;
}> = ({ type, className, disabled, children, onClick }) => (
    <button type={type as any} className={className} disabled={disabled} onClick={onClick}>
        {children}
    </button>
);

const TestSpan: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <span className={className}>{children || text}</span>
);

const TestP: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <p className={className}>{children || text}</p>
);

const TestH1: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <h1 className={className}>{children || text}</h1>
);

const TestH3: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <h3 className={className}>{children || text}</h3>
);

const TestLabel: React.FC<{
    className?: string;
    children?: React.ReactNode;
    text?: string;
}> = ({ className, children, text }) => (
    <label className={className}>{children || text}</label>
);

const TestInput: React.FC<{
    type?: string;
    step?: string;
    value?: string;
    className?: string;
    disabled?: boolean;
    onChange?: (e: React.ChangeEvent<HTMLInputElement>) => void;
}> = ({ type, step, value, className, disabled, onChange }) => (
    <input
        type={type}
        step={step}
        value={value}
        className={className}
        disabled={disabled}
        onChange={onChange}
        readOnly={!onChange}
    />
);

const TestCheckbox: React.FC<{
    checked?: boolean;
    className?: string;
    onChange?: (e: React.ChangeEvent<HTMLInputElement>) => void;
}> = ({ checked, className, onChange }) => (
    <input type="checkbox" checked={checked} className={className} onChange={onChange} readOnly={!onChange} />
);

const TestSelect: React.FC<{
    value?: string | number;
    className?: string;
    options?: Array<{ value: string | number; label: string }>;
    onChange?: (e: React.ChangeEvent<HTMLSelectElement>) => void;
}> = ({ value, className, options, onChange }) => (
    <select value={value} className={className} onChange={onChange}>
        {options?.map((option) => (
            <option key={String(option.value)} value={option.value}>
                {option.label}
            </option>
        ))}
    </select>
);

const TestIcon: React.FC<{
    name?: string;
    className?: string;
}> = ({ name, className }) => (
    <i className={className} data-icon={name} />
);

const TestPageHeader: React.FC<{
    title?: string;
    description?: string;
    children?: React.ReactNode;
}> = ({ title, description, children }) => (
    <div>
        <div>
            <h1>{title}</h1>
            {description ? <p>{description}</p> : null}
        </div>
        {children ? <div>{children}</div> : null}
    </div>
);

const TestModal: React.FC<{
    title?: string;
    children?: React.ReactNode;
}> = ({ title, children }) => (
    <div role="dialog" aria-label={title}>
        {children}
    </div>
);

const TestFragment: React.FC<{
    children?: React.ReactNode;
}> = ({ children }) => <>{children}</>;

function setupTestRegistry(): ComponentRegistry {
    const registry = ComponentRegistry.getInstance();

    (registry as any).registry = {
        Fragment: { component: TestFragment, metadata: { name: 'Fragment', type: 'layout' } },
        Div: { component: TestDiv, metadata: { name: 'Div', type: 'basic' } },
        Button: { component: TestButton, metadata: { name: 'Button', type: 'basic' } },
        Span: { component: TestSpan, metadata: { name: 'Span', type: 'basic' } },
        P: { component: TestP, metadata: { name: 'P', type: 'basic' } },
        H1: { component: TestH1, metadata: { name: 'H1', type: 'basic' } },
        H3: { component: TestH3, metadata: { name: 'H3', type: 'basic' } },
        Label: { component: TestLabel, metadata: { name: 'Label', type: 'basic' } },
        Input: { component: TestInput, metadata: { name: 'Input', type: 'basic' } },
        Checkbox: { component: TestCheckbox, metadata: { name: 'Checkbox', type: 'basic' } },
        Select: { component: TestSelect, metadata: { name: 'Select', type: 'composite' } },
        Icon: { component: TestIcon, metadata: { name: 'Icon', type: 'basic' } },
        PageHeader: { component: TestPageHeader, metadata: { name: 'PageHeader', type: 'composite' } },
        Modal: { component: TestModal, metadata: { name: 'Modal', type: 'composite' } },
    };

    return registry;
}

describe('admin_benchmark_dashboard 레이아웃', () => {
    let testUtils: ReturnType<typeof createLayoutTest> | undefined;
    let registry: ComponentRegistry;

    beforeEach(() => {
        registry = setupTestRegistry();
    });

    afterEach(() => {
        testUtils?.cleanup();
        ComponentRegistry.resetInstance();
    });

    it('기본 진입 화면에서 생성 폼과 작업 목록 헤더가 렌더링된다', async () => {
        testUtils = createLayoutTest(benchmarkLayout, {
            componentRegistry: registry,
            auth: {
                isAuthenticated: true,
                authType: 'admin',
                user: {
                    id: 1,
                    name: 'Admin',
                    role: 'admin',
                },
            },
        });

        await testUtils.render();

        testUtils.assertNoValidationErrors();

        expect(screen.getByText('대용량 더미데이터 생성')).toBeInTheDocument();
        expect(screen.getByText('작업 생성')).toBeInTheDocument();
        expect(screen.getByText('데이터셋 이름')).toBeInTheDocument();
        expect(screen.getByDisplayValue('benchmark-dataset')).toBeInTheDocument();
        expect(screen.getByText('대상 게시판 선택')).toBeInTheDocument();
        expect(screen.getByText('생성 시작')).toBeInTheDocument();
        expect(screen.getByText('최근 작업')).toBeInTheDocument();
        expect(
            benchmarkLayout.init_actions.some(
                (action: { handler?: string }) => action.handler === 'sirsoft-benchmark.startAutoRefresh'
            )
        ).toBe(true);

        expect(screen.getByRole('button', { name: '예상 생성량 계산' })).toHaveAttribute('type', 'button');
        expect(screen.getByRole('button', { name: '생성 시작' })).toHaveAttribute('type', 'button');
    });

    it('작업 상세에서 대상 게시판과 초기화 삭제 결과를 명확하게 표시한다', async () => {
        testUtils = createLayoutTest(benchmarkLayout, {
            componentRegistry: registry,
            routeParams: { id: '4' },
            auth: {
                isAuthenticated: true,
                authType: 'admin',
                user: { id: 1, name: 'Admin', role: 'admin' },
            },
        });
        testUtils.mockApi('selectedJob', {
            response: {
                data: {
                    id: 4,
                    dataset_name: 'benchmark-dataset2',
                    target_summary: '자유게시판 (freebd, ID 1) · 게시글 1,000,000건',
                    workload_type: 'board',
                    status: 'completed',
                    current_stage: 'completed',
                    progress_percent: 100,
                    current_step: '데이터셋 초기화가 완료되었습니다.',
                    reset: {
                        is_reset: true,
                        is_completed: true,
                        phase: 'completed',
                        cleanup: {
                            deleted_posts: 1000000,
                            deleted_comments: 1254010,
                            deleted_users: 10000,
                        },
                        expected: {
                            posts: 1000000,
                            comments: 1254010,
                            users: 10000,
                        },
                    },
                    verification: null,
                },
            },
        });
        testUtils.mockApi('jobs', { response: { data: [], meta: {} } });
        testUtils.mockApi('selectedLogs', { response: { data: [] } });
        testUtils.mockApi('availableBoards', { response: { data: [] } });

        await testUtils.render();

        testUtils.assertNoValidationErrors();
        expect(screen.getByText('생성·초기화 대상')).toBeInTheDocument();
        expect(screen.getByText('자유게시판 (freebd, ID 1) · 게시글 1,000,000건')).toBeInTheDocument();
        expect(screen.getByText('초기화 완료 · completed')).toBeInTheDocument();
        expect(screen.getByText('게시글 삭제 1000000 / 1000000')).toBeInTheDocument();
        expect(screen.getByText('댓글 삭제 1254010 / 1254010')).toBeInTheDocument();
        expect(screen.getByText('더미회원 삭제 10000 / 10000')).toBeInTheDocument();
    });

    it('초기화 버튼은 즉시 삭제하지 않고 대상 확인 모달을 연다', () => {
        const serialized = JSON.stringify(benchmarkLayout);
        const resetModal = benchmarkLayout.modals.find((modal: { id?: string }) => modal.id === 'reset_confirm_modal');

        expect(resetModal).toBeTruthy();
        expect(serialized).toContain('생성·초기화 대상');
        expect(serialized).toContain('대상: {{job.target_summary}}');
        expect(serialized).toContain('"handler":"openModal","target":"reset_confirm_modal"');
        expect(serialized).toContain('확인 후 초기화');
    });
});
