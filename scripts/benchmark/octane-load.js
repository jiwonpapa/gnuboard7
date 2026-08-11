import http from 'k6/http';
import { check } from 'k6';

const baseUrl = (__ENV.BASE_URL || 'http://127.0.0.1:18080').replace(/\/$/, '');
const path = __ENV.PERF_PATH || '/';
const expectedStatus = Number(__ENV.EXPECTED_STATUS || '200');
const summaryPath = __ENV.SUMMARY_PATH || 'octane-k6-summary.json';
const requestHost = __ENV.REQUEST_HOST || '';

export const options = {
    vus: Number(__ENV.VUS || '5'),
    duration: __ENV.DURATION || '15s',
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    thresholds: {
        checks: ['rate>0.99'],
        http_req_failed: ['rate==0'],
        http_reqs: ['count>0'],
    },
};

export default function () {
    const headers = requestHost ? { Host: requestHost } : {};
    const response = http.get(`${baseUrl}${path}`, {
        headers,
        tags: { scenario: 'g7-octane-ab' },
    });

    check(response, {
        'expected status': (result) => result.status === expectedStatus,
        'response body is not empty': (result) => result.body !== null && result.body.length > 0,
    });
}

export function handleSummary(data) {
    return {
        [summaryPath]: JSON.stringify(data, null, 2),
        stdout: `requests=${data.metrics.http_reqs?.values?.count ?? 0} `
            + `rps=${(data.metrics.http_reqs?.values?.rate ?? 0).toFixed(2)} `
            + `avg_ms=${(data.metrics.http_req_duration?.values?.avg ?? 0).toFixed(2)} `
            + `p95_ms=${(data.metrics.http_req_duration?.values?.['p(95)'] ?? 0).toFixed(2)}\n`,
    };
}
