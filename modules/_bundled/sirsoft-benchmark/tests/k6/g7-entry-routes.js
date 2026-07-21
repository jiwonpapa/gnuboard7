import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const baseUrl = (__ENV.BASE_URL || 'https://g7-benchmark.test').replace(/\/$/, '');
const boardSlug = __ENV.BOARD_SLUG || 'freebd';
const postId = __ENV.POST_ID || '1';
const productId = __ENV.PRODUCT_ID || '1';
const boardSearch = __ENV.BOARD_SEARCH || '887161';
const globalSearch = __ENV.GLOBAL_SEARCH || boardSearch;
const shopSearch = __ENV.SHOP_SEARCH || '러닝화';
const deepPage = Number.parseInt(__ENV.DEEP_PAGE || '59999', 10);
const hotVus = Number.parseInt(__ENV.HOT_VUS || '1', 10);
const hotArrivalRate = Number.parseInt(__ENV.HOT_ARRIVAL_RATE || '1', 10);
const hotTimeUnit = __ENV.HOT_TIME_UNIT || '5s';
const hotDuration = __ENV.HOT_DURATION || '30s';
const riskyStart = __ENV.RISKY_START || '41s';
const includeRisky = __ENV.INCLUDE_RISKY === '1';
const riskyRouteKey = __ENV.RISKY_ROUTE || 'board_search';

const requestParams = {
  headers: {
    Accept: 'application/json, text/html;q=0.9',
    'Cache-Control': 'no-cache',
    'User-Agent': 'g7-ab-benchmark-k6/1.0',
  },
  timeout: __ENV.REQUEST_TIMEOUT || '20s',
};
const riskyRequestParams = {
  ...requestParams,
  timeout: __ENV.RISKY_REQUEST_TIMEOUT || '3s',
};

function routeMetric(key) {
  return {
    duration: new Trend(`g7_route_${key}_duration`, true),
    valid: new Rate(`g7_route_${key}_valid`),
  };
}

const encodedBoard = encodeURIComponent(boardSlug);
const encodedPost = encodeURIComponent(postId);
const encodedProduct = encodeURIComponent(productId);
const encodedBoardSearch = encodeURIComponent(boardSearch);
const encodedGlobalSearch = encodeURIComponent(globalSearch);
const encodedShopSearch = encodeURIComponent(shopSearch);
const boardModuleBase = '/api/modules/sirsoft-board/boards';
const boardBase = `${boardModuleBase}/${encodedBoard}/posts`;
const shopBase = '/api/modules/sirsoft-ecommerce';

const hotRoutes = [
  { key: 'home', path: '/', kind: 'page' },
  { key: 'home_stats', path: `${boardModuleBase}/stats`, kind: 'api' },
  { key: 'home_recent', path: `${boardModuleBase}/posts/recent?limit=5`, kind: 'api' },
  { key: 'home_popular_boards', path: `${boardModuleBase}/popular-boards?limit=4`, kind: 'api' },
  { key: 'home_boards', path: `${boardModuleBase}?limit=3`, kind: 'api' },
  { key: 'board_list_p1', path: `${boardBase}?page=1&per_page=20`, kind: 'api' },
  { key: 'board_list_p2', path: `${boardBase}?page=2&per_page=20`, kind: 'api' },
  { key: 'board_detail', path: `${boardBase}/${encodedPost}`, kind: 'api' },
  { key: 'board_navigation', path: `${boardBase}/${encodedPost}/navigation`, kind: 'api' },
  { key: 'shop_home_categories', path: `${shopBase}/categories`, kind: 'api' },
  { key: 'shop_list_p1', path: `${shopBase}/products?page=1&per_page=12`, kind: 'api' },
  { key: 'shop_list_p2', path: `${shopBase}/products?page=2&per_page=12`, kind: 'api' },
  { key: 'shop_home_recent', path: `${shopBase}/products/recent?ids=`, kind: 'api' },
  { key: 'shop_home_popular', path: `${shopBase}/products/popular?limit=8`, kind: 'api' },
  { key: 'shop_home_new', path: `${shopBase}/products/new?limit=8`, kind: 'api' },
  { key: 'shop_detail', path: `${shopBase}/products/${encodedProduct}`, kind: 'api' },
  { key: 'shop_detail_reviews', path: `${shopBase}/products/${encodedProduct}/reviews?page=1&per_page=10`, kind: 'api' },
  { key: 'shop_detail_inquiries', path: `${shopBase}/products/${encodedProduct}/inquiries?page=1&per_page=10`, kind: 'api' },
  { key: 'shop_detail_coupons', path: `${shopBase}/products/${encodedProduct}/downloadable-coupons`, kind: 'api' },
  { key: 'shop_search_p1', path: `${shopBase}/products?search=${encodedShopSearch}&page=1&per_page=12`, kind: 'api' },
  { key: 'shop_search_p2', path: `${shopBase}/products?search=${encodedShopSearch}&page=2&per_page=12`, kind: 'api' },
];

const riskyRoutes = [
  { key: 'board_deep', path: `${boardBase}?page=${deepPage}&per_page=20`, kind: 'api' },
  { key: 'board_search', path: `${boardBase}?search=${encodedBoardSearch}&search_field=all&page=1&per_page=20`, kind: 'api' },
  { key: 'global_search', path: `/api/search?q=${encodedGlobalSearch}&page=1&per_page=10`, kind: 'api' },
];
const activeRiskyRoutes = includeRisky
  ? riskyRoutes.filter(({ key }) => key === riskyRouteKey)
  : [];
if (includeRisky && activeRiskyRoutes.length !== 1) {
  throw new Error(`unsupported RISKY_ROUTE: ${riskyRouteKey}`);
}

const activeRoutes = [...hotRoutes, ...activeRiskyRoutes];
const metrics = {};
activeRoutes.forEach(({ key }) => {
  metrics[key] = routeMetric(key);
});

const thresholds = {
  http_req_failed: ['rate<0.01'],
  dropped_iterations: ['count==0'],
};
activeRoutes.forEach(({ key }) => {
  thresholds[`g7_route_${key}_valid`] = ['rate>0.99'];
});

const scenarios = {
  hot_routes: {
      executor: 'constant-arrival-rate',
      exec: 'runHotRoutes',
      rate: hotArrivalRate,
      timeUnit: hotTimeUnit,
      duration: hotDuration,
      preAllocatedVUs: hotVus,
      maxVUs: hotVus,
      gracefulStop: '10s',
      tags: { workload: 'hot' },
  },
};
if (includeRisky) {
  scenarios.risky_routes = {
      executor: 'shared-iterations',
      exec: 'runRiskyRoutes',
      vus: 1,
      iterations: 1,
      startTime: riskyStart,
      maxDuration: '55s',
      gracefulStop: '5s',
      tags: { workload: 'risky-single-vu' },
  };
}

export const options = {
  scenarios,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds,
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

function currentPage(payload) {
  return Number(payload?.data?.pagination?.current_page);
}

function totalItems(payload) {
  const total = payload?.data?.pagination?.total ?? payload?.data?.total;
  return Number(total);
}

function sameIdentifier(actual, expected) {
  return String(actual ?? '') === String(expected);
}

function boundedSearchMetaIsValid(payload) {
  const meta = payload?.data?.pagination ?? payload?.data?.posts ?? payload?.data;
  const capIsValid = meta?.result_cap == null
    ? meta?.total_is_exact === true
    : Number.isInteger(Number(meta.result_cap)) && Number(meta.result_cap) > 0;
  return typeof meta?.total_is_exact === 'boolean'
    && ['eq', 'gte', 'unknown'].includes(meta?.total_relation)
    && typeof meta?.has_more_pages === 'boolean'
    && capIsValid
    && (meta.total_is_exact ? meta.total_relation === 'eq' : meta.total_relation !== 'eq');
}

function semanticResponseIsValid(route, response, payload) {
  if (route.kind === 'page') {
    return response.status >= 200 && response.status < 400 && String(response.body || '').length > 0;
  }
  if (response.status !== 200 || payload?.success !== true) {
    return false;
  }

  switch (route.key) {
    case 'home_stats':
      return payload.data !== null && typeof payload.data === 'object' && !Array.isArray(payload.data);
    case 'home_recent':
    case 'home_popular_boards':
    case 'home_boards':
    case 'shop_home_categories':
    case 'shop_home_recent':
    case 'shop_home_popular':
    case 'shop_home_new':
    case 'shop_detail_coupons':
      return listData(payload) !== null;
    case 'shop_detail_reviews':
      return Array.isArray(payload?.data?.reviews?.data);
    case 'shop_detail_inquiries':
      return Array.isArray(payload?.data?.items);
    case 'board_list_p1':
    case 'shop_list_p1':
      return currentPage(payload) === 1 && (listData(payload)?.length || 0) > 0;
    case 'board_list_p2':
    case 'shop_list_p2':
      return currentPage(payload) === 2 && listData(payload) !== null;
    case 'board_deep':
      return currentPage(payload) === deepPage && listData(payload) !== null;
    case 'board_detail':
      return sameIdentifier(payload?.data?.id, postId);
    case 'board_navigation':
      return Object.prototype.hasOwnProperty.call(payload, 'data');
    case 'board_search':
      return currentPage(payload) === 1
        && (listData(payload)?.length || 0) > 0
        && boundedSearchMetaIsValid(payload);
    case 'global_search':
      return payload?.data?.q === globalSearch
        && Number(payload?.data?.total) > 0
        && boundedSearchMetaIsValid(payload);
    case 'shop_detail':
      return sameIdentifier(payload?.data?.id, productId);
    case 'shop_search_p1':
      return currentPage(payload) === 1
        && totalItems(payload) > 0
        && (listData(payload)?.length || 0) > 0;
    case 'shop_search_p2':
      return currentPage(payload) === 2
        && totalItems(payload) > 0
        && listData(payload) !== null;
    default:
      return false;
  }
}

function requestRoute(route, params = requestParams) {
  const response = http.get(`${baseUrl}${route.path}`, {
    ...params,
    tags: { route: route.key },
  });
  const payload = route.kind === 'api' ? parseJson(response) : null;
  const semanticValid = semanticResponseIsValid(route, response, payload);
  const valid = check(response, {
    [`${route.key} returned the expected resource`]: () => semanticValid,
  });

  metrics[route.key].valid.add(valid, { route: route.key });
  if (valid) {
    metrics[route.key].duration.add(response.timings.duration, { route: route.key });
  }
}

export function runHotRoutes() {
  hotRoutes.forEach(requestRoute);
}

export function runRiskyRoutes() {
  activeRiskyRoutes.forEach((route) => requestRoute(route, riskyRequestParams));
}
