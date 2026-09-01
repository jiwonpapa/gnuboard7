import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
    define: {
        'process.env.NODE_ENV': JSON.stringify('production'),
    },

    build: {
        lib: {
            entry: path.resolve(__dirname, 'resources/js/index.ts'),
            name: 'SirsoftBenchmark',
            fileName: 'module',
            formats: ['iife'],
        },
        outDir: 'dist',
        emptyOutDir: true,
        // 배포용 빌드(--production)는 G7_BUILD_SOURCEMAP=0 을 주입해 소스맵을 생성하지 않는다.
        // 로컬 기본 빌드는 디버깅을 위해 기존처럼 소스맵을 유지한다.
        sourcemap: !['0', 'false'].includes(process.env.G7_BUILD_SOURCEMAP ?? ''),
        rollupOptions: {
            output: {
                entryFileNames: 'js/module.iife.js',
                chunkFileNames: 'js/[name]-[hash].js',
                assetFileNames: 'assets/[name][extname]',
            },
        },
        minify: 'esbuild',
        target: 'es2020',
        chunkSizeWarningLimit: 500,
    },

    resolve: {
        alias: {
            '@': path.resolve(__dirname, 'resources/js'),
        },
    },
});
