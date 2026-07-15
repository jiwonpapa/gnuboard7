import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const baseUrl = (__ENV.BASE_URL || 'https://www.g7devops.com').replace(/\/$/, '');
const boardSlug = __ENV.BOARD_SLUG || 'gallery';
const vus = Number.parseInt(__ENV.VUS || '5', 10);
const duration = __ENV.DURATION || '30s';
const thinkTimeSeconds = Number.parseFloat(__ENV.THINK_TIME_SECONDS || '1');

const firstPageDuration = new Trend('board_first_page_duration', true);
const validResponse = new Rate('board_first_page_valid');

export const options = {
  scenarios: {
    first_page: {
      executor: 'constant-vus',
      vus,
      duration,
      gracefulStop: '5s',
      tags: { board: boardSlug },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    board_first_page_valid: ['rate>0.99'],
  },
};

export default function () {
  const response = http.get(
    `${baseUrl}/api/modules/sirsoft-board/boards/${encodeURIComponent(boardSlug)}/posts?page=1&per_page=20`,
    {
      headers: {
        Accept: 'application/json',
        'Cache-Control': 'no-cache',
        'User-Agent': 'g7-benchmark-k6/1.0',
      },
      tags: { board: boardSlug, page: '1' },
    },
  );

  firstPageDuration.add(response.timings.duration, { board: boardSlug });

  let payload = null;
  try {
    payload = response.json();
  } catch (_) {
    // The checks below report malformed responses without aborting the run.
  }

  const valid = check(response, {
    'status is 200': (res) => res.status === 200,
    'page is first page': () => payload?.data?.pagination?.current_page === 1,
    'posts are returned': () => Array.isArray(payload?.data?.data) && payload.data.data.length > 0,
  });

  validResponse.add(valid, { board: boardSlug });

  if (thinkTimeSeconds > 0) {
    sleep(thinkTimeSeconds);
  }
}
