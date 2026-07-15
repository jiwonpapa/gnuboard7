import { handlerMap } from './handlers';

const MODULE_IDENTIFIER = 'sirsoft-benchmark';

const logger = ((window as any).G7Core?.createLogger?.(`Module:${MODULE_IDENTIFIER}`)) ?? {
    log: (...args: unknown[]) => console.log(`[Module:${MODULE_IDENTIFIER}]`, ...args),
    warn: (...args: unknown[]) => console.warn(`[Module:${MODULE_IDENTIFIER}]`, ...args),
    error: (...args: unknown[]) => console.error(`[Module:${MODULE_IDENTIFIER}]`, ...args),
};

function registerHandlers(retry: boolean = false): void {
    const actionDispatcher = (window as any).G7Core?.getActionDispatcher?.();

    if (actionDispatcher) {
        Object.entries(handlerMap).forEach(([name, handler]) => {
            const fullName = `${MODULE_IDENTIFIER}.${name}`;
            actionDispatcher.registerHandler(fullName, handler, {
                category: 'module',
                source: MODULE_IDENTIFIER,
            });
        });

        logger.log(
            `${Object.keys(handlerMap).length} handler(s) registered:`,
            Object.keys(handlerMap).map(name => `${MODULE_IDENTIFIER}.${name}`)
        );

        return;
    }

    if (!retry) {
        logger.warn('ActionDispatcher not found, handlers not registered');
        return;
    }

    let retryCount = 0;
    const maxRetries = 50;

    const retryRegister = () => {
        const dispatcher = (window as any).G7Core?.getActionDispatcher?.();

        if (dispatcher) {
            Object.entries(handlerMap).forEach(([name, handler]) => {
                const fullName = `${MODULE_IDENTIFIER}.${name}`;
                dispatcher.registerHandler(fullName, handler, {
                    category: 'module',
                    source: MODULE_IDENTIFIER,
                });
            });

            logger.log(
                `${Object.keys(handlerMap).length} handler(s) registered:`,
                Object.keys(handlerMap).map(name => `${MODULE_IDENTIFIER}.${name}`)
            );

            return;
        }

        retryCount++;
        if (retryCount <= maxRetries) {
            logger.warn(`ActionDispatcher not found, retrying... (${retryCount}/${maxRetries})`);
            setTimeout(retryRegister, 100);
        } else {
            logger.error('Failed to register handlers: ActionDispatcher not available after maximum retries');
        }
    };

    retryRegister();
}

export function initModule(): void {
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => registerHandlers(true));
    } else {
        const hasDispatcher = !!(window as any).G7Core?.getActionDispatcher?.();
        registerHandlers(!hasDispatcher);
    }
}

initModule();

if (typeof window !== 'undefined') {
    (window as any).__SirsoftBenchmark = {
        identifier: MODULE_IDENTIFIER,
        handlers: Object.keys(handlerMap),
        initModule,
    };
}
