import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const baseUrl = (__ENV.BASE_URL || 'http://127.0.0.1').replace(/\/$/, '');
const boardSlug = __ENV.BOARD_SLUG || 'freebd';
const postId = __ENV.POST_ID || '1';
const productId = __ENV.PRODUCT_ID || '1';
const targetRps = Number.parseInt(__ENV.TARGET_RPS || '5', 10);
const duration = __ENV.DURATION || '5m';
const preAllocatedVUs = Number.parseInt(__ENV.PREALLOCATED_VUS || String(targetRps * 2), 10);
const maxVUs = Number.parseInt(__ENV.MAX_VUS || String(targetRps * 4), 10);
const requestTimeout = __ENV.REQUEST_TIMEOUT || '20s';
const hostHeader = __ENV.HOST_HEADER || '';

if (!Number.isInteger(targetRps) || targetRps < 1) {
  throw new Error('TARGET_RPS must be a positive integer');
}
if (!/^\d+[smh]$/.test(duration)) {
  throw new Error('DURATION must use an integer s, m, or h suffix');
}
if (!Number.isInteger(preAllocatedVUs) || !Number.isInteger(maxVUs)
  || preAllocatedVUs < 1 || maxVUs < preAllocatedVUs) {
  throw new Error('PREALLOCATED_VUS/MAX_VUS are invalid');
}

const workloadDuration = new Trend('g7_operational_duration', true);
const workloadValid = new Rate('g7_operational_valid');
const httpValid = new Rate('g7_operational_http_valid');

function workloadMetrics(name) {
  return {
    duration: new Trend(`g7_workload_${name}_duration`, true),
    valid: new Rate(`g7_workload_${name}_valid`),
    requests: new Counter(`g7_workload_${name}_requests`),
  };
}

const metrics = {
  shop: workloadMetrics('shop'),
  board: workloadMetrics('board'),
  home: workloadMetrics('home'),
  write_like: workloadMetrics('write_like'),
};

export const options = {
  discardResponseBodies: false,
  insecureSkipTLSVerify: __ENV.TLS_INSECURE === '1',
  scenarios: {
    operational: {
      executor: 'constant-arrival-rate',
      rate: targetRps,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '30s',
      exec: 'runOperationalRequest',
      tags: { harness: 'g7-operational-load' },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    dropped_iterations: ['count==0'],
    http_req_failed: ['rate==0'],
    g7_operational_http_valid: ['rate==1'],
    g7_operational_valid: ['rate==1'],
    g7_workload_shop_valid: ['rate==1'],
    g7_workload_board_valid: ['rate==1'],
    g7_workload_home_valid: ['rate==1'],
    g7_workload_write_like_valid: ['rate==1'],
  },
};

const encodedBoard = encodeURIComponent(boardSlug);
const encodedPost = encodeURIComponent(postId);
const encodedProduct = encodeURIComponent(productId);
const boardBase = `/api/modules/sirsoft-board/boards/${encodedBoard}/posts`;
const shopBase = '/api/modules/sirsoft-ecommerce';

const routes = {
  shop: [
    { key: 'shop_list_p1', path: `${shopBase}/products?page=1&per_page=12`, type: 'list', page: 1 },
    { key: 'shop_list_p2', path: `${shopBase}/products?page=2&per_page=12`, type: 'list', page: 2 },
    { key: 'shop_categories', path: `${shopBase}/categories`, type: 'collection' },
    { key: 'shop_detail', path: `${shopBase}/products/${encodedProduct}`, type: 'product' },
    { key: 'shop_popular', path: `${shopBase}/products/popular?limit=8`, type: 'collection' },
  ],
  board: [
    { key: 'board_list_p1', path: `${boardBase}?page=1&per_page=20`, type: 'list', page: 1 },
    { key: 'board_list_p2', path: `${boardBase}?page=2&per_page=20`, type: 'list', page: 2 },
    { key: 'board_detail', path: `${boardBase}/${encodedPost}`, type: 'post' },
  ],
  home: [
    { key: 'home', path: '/', type: 'page' },
  ],
  // 작성·문의 화면이 먼저 읽는 공개 데이터만 조회한다. POST/PUT/PATCH/DELETE는 없다.
  write_like: [
    { key: 'write_like_reviews_read', path: `${shopBase}/products/${encodedProduct}/reviews?page=1&per_page=10`, type: 'reviews' },
    { key: 'write_like_inquiries_read', path: `${shopBase}/products/${encodedProduct}/inquiries?page=1&per_page=10`, type: 'inquiries' },
  ],
};

const requestParams = {
  headers: {
    Accept: 'application/json, text/html;q=0.9',
    'Cache-Control': 'no-cache',
    'User-Agent': 'g7-operational-load-k6/1.0',
    ...(hostHeader ? { Host: hostHeader } : {}),
  },
  redirects: 5,
  timeout: requestTimeout,
};

function parseJson(response) {
  try {
    return response.json();
  } catch (_) {
    return null;
  }
}

function listData(payload) {
  if (Array.isArray(payload?.data?.data)) {
    return payload.data.data;
  }
  if (Array.isArray(payload?.data)) {
    return payload.data;
  }
  return null;
}

function semanticResponseIsValid(route, response, payload) {
  if (route.type === 'page') {
    return response.status >= 200
      && response.status < 400
      && String(response.body || '').length > 0;
  }
  if (response.status !== 200 || payload?.success !== true) {
    return false;
  }

  switch (route.type) {
    case 'list':
      return Number(payload?.data?.pagination?.current_page) === route.page
        && listData(payload) !== null;
    case 'collection':
      return listData(payload) !== null;
    case 'product':
      return String(payload?.data?.id ?? '') === String(productId);
    case 'post':
      return String(payload?.data?.id ?? '') === String(postId);
    case 'reviews':
      return Array.isArray(payload?.data?.reviews?.data);
    case 'inquiries':
      return Array.isArray(payload?.data?.items);
    default:
      return false;
  }
}

function workloadForSequence(sequence) {
  const slot = sequence % 10;
  if (slot < 5) return 'shop';
  if (slot < 8) return 'board';
  if (slot === 8) return 'home';
  return 'write_like';
}

export function runOperationalRequest() {
  const sequence = exec.scenario.iterationInTest;
  const workload = workloadForSequence(sequence);
  const routeSet = routes[workload];
  const cycle = Math.floor(sequence / 10);
  const route = routeSet[cycle % routeSet.length];
  const response = http.get(`${baseUrl}${route.path}`, {
    ...requestParams,
    tags: { workload, route: route.key, method_safety: 'read-only' },
  });
  const payload = route.type === 'page' ? null : parseJson(response);
  const statusValid = response.status >= 200 && response.status < 400;
  const semanticValid = semanticResponseIsValid(route, response, payload);

  const valid = check(response, {
    [`${route.key}: HTTP status is valid`]: () => statusValid,
    [`${route.key}: response semantics are valid`]: () => semanticValid,
    [`${route.key}: request method remains GET`]: () => response.request.method === 'GET',
  }, { workload, route: route.key });

  httpValid.add(statusValid, { workload, route: route.key });
  workloadValid.add(valid, { workload, route: route.key });
  workloadDuration.add(response.timings.duration, { workload, route: route.key });
  metrics[workload].valid.add(valid, { route: route.key });
  metrics[workload].duration.add(response.timings.duration, { route: route.key });
  metrics[workload].requests.add(1, { route: route.key });
}
