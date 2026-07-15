import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const baseUrl = (__ENV.BASE_URL || 'https://www.g7devops.com').replace(/\/$/, '');
const target = __ENV.TARGET || 'list';
const page = Number.parseInt(__ENV.PAGE || '1', 10);
const perPage = Number.parseInt(__ENV.PER_PAGE || '12', 10);
const productCode = __ENV.PRODUCT_CODE || 'BMJ00090000007AV';
const vus = Number.parseInt(__ENV.VUS || '10', 10);
const duration = __ENV.DURATION || '30s';
const thinkTimeSeconds = Number.parseFloat(__ENV.THINK_TIME_SECONDS || '1');

const targetDuration = new Trend('ecommerce_target_duration', true);
const listDuration = new Trend('ecommerce_list_duration', true);
const categoryDuration = new Trend('ecommerce_category_duration', true);
const recentDuration = new Trend('ecommerce_recent_duration', true);
const popularDuration = new Trend('ecommerce_popular_duration', true);
const newDuration = new Trend('ecommerce_new_duration', true);
const detailDuration = new Trend('ecommerce_detail_duration', true);
const reviewDuration = new Trend('ecommerce_review_duration', true);
const inquiryDuration = new Trend('ecommerce_inquiry_duration', true);
const couponDuration = new Trend('ecommerce_coupon_duration', true);
const storefrontDuration = new Trend('ecommerce_storefront_duration', true);
const validResponse = new Rate('ecommerce_valid_response');

const requestParams = {
  headers: {
    Accept: 'application/json',
    'Cache-Control': 'no-cache',
    'User-Agent': 'g7-benchmark-k6/1.0',
  },
};

export const options = {
  scenarios: {
    ecommerce: {
      executor: 'constant-vus',
      vus,
      duration,
      gracefulStop: '5s',
      tags: { target },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    ecommerce_valid_response: ['rate>0.99'],
  },
};

function parseJson(response) {
  try {
    return response.json();
  } catch (_) {
    return null;
  }
}

function runList() {
  const response = http.get(
    `${baseUrl}/api/modules/sirsoft-ecommerce/products?page=${page}&per_page=${perPage}`,
    { ...requestParams, tags: { endpoint: 'list', page: String(page) } },
  );
  const payload = parseJson(response);
  targetDuration.add(response.timings.duration, { endpoint: 'list', page: String(page) });
  listDuration.add(response.timings.duration, { page: String(page) });

  return check(response, {
    'list status is 200': (res) => res.status === 200,
    'list page matches': () => payload?.data?.pagination?.current_page === page,
    'list products returned': () => Array.isArray(payload?.data?.data) && payload.data.data.length > 0,
  });
}

function runStandalone(endpoint, metric, label) {
  const response = http.get(`${baseUrl}${endpoint}`, {
    ...requestParams,
    tags: { endpoint: label },
  });
  const payload = parseJson(response);
  targetDuration.add(response.timings.duration, { endpoint: label });
  metric.add(response.timings.duration);

  return check(response, {
    [`${label} status is 200`]: (res) => res.status === 200,
    [`${label} payload is valid`]: () => payload?.success === true,
  });
}

function runListBundle() {
  const responses = http.batch([
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/categories`, null, { ...requestParams, tags: { endpoint: 'categories' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products?page=${page}&per_page=${perPage}`, null, { ...requestParams, tags: { endpoint: 'list', page: String(page) } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/recent?ids=`, null, { ...requestParams, tags: { endpoint: 'recent' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/popular?limit=8`, null, { ...requestParams, tags: { endpoint: 'popular' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/new?limit=8`, null, { ...requestParams, tags: { endpoint: 'new' } }],
  ]);

  categoryDuration.add(responses[0].timings.duration);
  listDuration.add(responses[1].timings.duration, { page: String(page) });
  recentDuration.add(responses[2].timings.duration);
  popularDuration.add(responses[3].timings.duration);
  newDuration.add(responses[4].timings.duration);
  responses.forEach((response) => targetDuration.add(response.timings.duration));

  return check(responses, {
    'list bundle statuses are 200': (items) => items.every((response) => response.status === 200),
    'list bundle payloads are valid': (items) => items.every((response) => parseJson(response)?.success === true),
    'list bundle page matches': (items) => parseJson(items[1])?.data?.pagination?.current_page === page,
  });
}

function runListPage() {
  const responses = http.batch([
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/storefront`, null, { ...requestParams, tags: { endpoint: 'storefront' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products?page=${page}&per_page=${perPage}`, null, { ...requestParams, tags: { endpoint: 'list', page: String(page) } }],
  ]);

  storefrontDuration.add(responses[0].timings.duration);
  listDuration.add(responses[1].timings.duration, { page: String(page) });
  responses.forEach((response) => targetDuration.add(response.timings.duration));

  return check(responses, {
    'list page statuses are 200': (items) => items.every((response) => response.status === 200),
    'list page payloads are valid': (items) => items.every((response) => parseJson(response)?.success === true),
    'list page matches': (items) => parseJson(items[1])?.data?.pagination?.current_page === page,
  });
}

function runDetail() {
  const response = http.get(
    `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodeURIComponent(productCode)}`,
    { ...requestParams, tags: { endpoint: 'detail' } },
  );
  const payload = parseJson(response);
  targetDuration.add(response.timings.duration, { endpoint: 'detail' });
  detailDuration.add(response.timings.duration);

  return check(response, {
    'detail status is 200': (res) => res.status === 200,
    'detail code matches': () => payload?.data?.product_code === productCode,
  });
}

function runDetailBundle() {
  const encodedCode = encodeURIComponent(productCode);
  const responses = http.batch([
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}`, null, { ...requestParams, tags: { endpoint: 'detail' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}/reviews`, null, { ...requestParams, tags: { endpoint: 'reviews' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}/inquiries`, null, { ...requestParams, tags: { endpoint: 'inquiries' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}/downloadable-coupons`, null, { ...requestParams, tags: { endpoint: 'coupons' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/popular?limit=8`, null, { ...requestParams, tags: { endpoint: 'popular' } }],
  ]);

  detailDuration.add(responses[0].timings.duration);
  reviewDuration.add(responses[1].timings.duration);
  inquiryDuration.add(responses[2].timings.duration);
  couponDuration.add(responses[3].timings.duration);
  popularDuration.add(responses[4].timings.duration);
  responses.forEach((response) => targetDuration.add(response.timings.duration));

  return check(responses, {
    'detail bundle statuses are 200': (items) => items.every((response) => response.status === 200),
    'detail bundle payloads are valid': (items) => items.every((response) => parseJson(response)?.success === true),
  });
}

function runDetailPage() {
  const encodedCode = encodeURIComponent(productCode);
  const responses = http.batch([
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}`, null, { ...requestParams, tags: { endpoint: 'detail' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/${encodedCode}/downloadable-coupons`, null, { ...requestParams, tags: { endpoint: 'coupons' } }],
    ['GET', `${baseUrl}/api/modules/sirsoft-ecommerce/products/popular?limit=8`, null, { ...requestParams, tags: { endpoint: 'popular' } }],
  ]);

  detailDuration.add(responses[0].timings.duration);
  couponDuration.add(responses[1].timings.duration);
  popularDuration.add(responses[2].timings.duration);
  responses.forEach((response) => targetDuration.add(response.timings.duration));

  return check(responses, {
    'detail page statuses are 200': (items) => items.every((response) => response.status === 200),
    'detail page payloads are valid': (items) => items.every((response) => parseJson(response)?.success === true),
  });
}

export default function () {
  let valid;

  if (target === 'list') {
    valid = runList();
  } else if (target === 'list_bundle') {
    valid = runListBundle();
  } else if (target === 'list_page') {
    valid = runListPage();
  } else if (target === 'detail') {
    valid = runDetail();
  } else if (target === 'detail_bundle') {
    valid = runDetailBundle();
  } else if (target === 'detail_page') {
    valid = runDetailPage();
  } else if (target === 'categories') {
    valid = runStandalone('/api/modules/sirsoft-ecommerce/categories', categoryDuration, 'categories');
  } else if (target === 'recent') {
    valid = runStandalone('/api/modules/sirsoft-ecommerce/products/recent?ids=', recentDuration, 'recent');
  } else if (target === 'popular') {
    valid = runStandalone('/api/modules/sirsoft-ecommerce/products/popular?limit=8', popularDuration, 'popular');
  } else if (target === 'new') {
    valid = runStandalone('/api/modules/sirsoft-ecommerce/products/new?limit=8', newDuration, 'new');
  } else {
    throw new Error(`Unsupported TARGET: ${target}`);
  }

  validResponse.add(valid, { target });

  if (thinkTimeSeconds > 0) {
    sleep(thinkTimeSeconds);
  }
}
