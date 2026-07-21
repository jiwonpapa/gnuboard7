import { defineConfig } from 'vitest/config';
import path from 'path';
import fs from 'fs';

function findProjectRoot(startDir: string): string {
    let dir = startDir;
    while (dir !== path.dirname(dir)) {
        if (fs.existsSync(path.join(dir, 'artisan'))) {
            return dir;
        }
        dir = path.dirname(dir);
    }

    return path.resolve(startDir, '../../');
}

const projectRoot = findProjectRoot(__dirname);
export default defineConfig({
    root: __dirname,
    test: {
        globals: true,
        environment: 'jsdom',
        include: ['resources/js/**/*.{test,spec}.{ts,tsx}'],
        exclude: ['node_modules/', 'dist/'],
        setupFiles: ['./resources/js/__tests__/setup.ts'],
    },
    resolve: {
        alias: {
            '@': path.resolve(__dirname, 'resources/js'),
            '@core': path.resolve(projectRoot, 'resources/js/core'),
        },
    },
});
