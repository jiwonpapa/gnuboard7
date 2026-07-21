#!/usr/bin/env bash

# shellcheck disable=SC2016

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

K6_SCRIPT="${G7_OP_K6_SCRIPT:-${REPO_ROOT}/modules/_bundled/sirsoft-benchmark/tests/k6/g7-operational-load.js}"
K6_BIN="${G7_OP_K6_BIN:-k6}"
SSH_BIN="${G7_OP_SSH_BIN:-ssh}"
CURL_BIN="${G7_OP_CURL_BIN:-curl}"
JQ_BIN="${G7_OP_JQ_BIN:-jq}"

PROFILE="${G7_OP_PROFILE:-warmup}"
TARGET_RPS="${G7_OP_RATE:-}"
DURATION="${G7_OP_DURATION:-}"
REMOTE_HOST="${G7_OP_HOST:-}"
REMOTE_ROOT="${G7_OP_ROOT:-/var/www/gnuboard7}"
BASE_URL="${G7_OP_BASE_URL:-}"
HOST_HEADER="${G7_OP_HOST_HEADER:-}"
BOARD_SLUG="${G7_OP_BOARD_SLUG:-freebd}"
POST_ID="${G7_OP_POST_ID:-}"
PRODUCT_ID="${G7_OP_PRODUCT_ID:-}"
STATE_LABEL="${G7_OP_STATE_LABEL:-current}"
PREALLOCATED_VUS="${G7_OP_PREALLOCATED_VUS:-}"
MAX_VUS="${G7_OP_MAX_VUS:-}"
REQUEST_TIMEOUT_SECONDS="${G7_OP_REQUEST_TIMEOUT_SECONDS:-20}"
SAMPLE_INTERVAL_SECONDS="${G7_OP_SAMPLE_INTERVAL_SECONDS:-1}"
MEM_AVAILABLE_LIMIT_MIB="${G7_OP_MEM_AVAILABLE_LIMIT_MIB:-400}"
MEM_LOW_CONSECUTIVE="${G7_OP_MEM_LOW_CONSECUTIVE:-3}"
MEM_AVAILABLE_PASS_PCT="${G7_OP_MEM_AVAILABLE_PASS_PCT:-25}"
SWAP_GROWTH_LIMIT_MIB="${G7_OP_SWAP_GROWTH_LIMIT_MIB:-64}"
SSH_CONNECT_TIMEOUT_SECONDS="${G7_OP_SSH_CONNECT_TIMEOUT_SECONDS:-10}"
OUTPUT_DIR="${G7_OP_OUTPUT_DIR:-}"
TLS_INSECURE=0
PLAN_ONLY=0
DIRECT_RATE_SET=0
DIRECT_DURATION_SET=0
[[ -z "${TARGET_RPS}" ]] || DIRECT_RATE_SET=1
[[ -z "${DURATION}" ]] || DIRECT_DURATION_SET=1

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/g7-operational-load.sh [options]

Runs one read-only operational workload against the server's current state.
It never enables, disables, deploys, or rolls back tuning.

Workload profiles (one HTTP GET per k6 iteration):
  warmup   5 RPS / 5m
  steady  15 RPS / 30m
  peak    30 RPS / 15m
  spike   33 RPS / 5m   (highest integer RPS below board 600/min)
  soak    15 RPS / 2h
  smoke    2 RPS / 3m

Traffic mix is deterministic: shop 50%, board 30%, home 10%, and read-safe
write-like preparation 10%. No POST, PUT, PATCH, or DELETE request exists.

Options:
  --profile NAME          warmup|steady|peak|spike|soak|smoke. Default: warmup.
  --rate RPS              Direct exact arrival rate; requires --duration.
  --duration DURATION     Direct duration such as 10m or 2h; requires --rate.
  --host SSH_HOST         Remote sampler SSH target. Required.
  --root PATH             Remote app root used only to read the Git commit.
  --base-url URL          HTTP origin under test. Required.
  --host-header HOST      Optional Host header for an IP-based local test.
  --insecure              Accept the local test certificate in curl and k6.
  --board-slug SLUG       Public board slug. Default: freebd.
  --post-id ID            Fixed public post ID; otherwise discovered once.
  --product-id ID         Fixed public product ID; otherwise discovered once.
  --state-label LABEL     Report label, e.g. tuned-off or tuned-on.
  --preallocated-vus N    k6 initial VUs. Default: rate x 2.
  --max-vus N             k6 hard VU cap. Default: rate x 4.
  --request-timeout SEC   Per-request timeout. Default: 20.
  --sample-interval SEC   Remote resource sample interval. Default: 1.
  --output-dir PATH       New report directory.
  --plan                  Print the resolved, throttle-checked plan only.
  -h, --help              Show this help.

Safety gates:
  - board traffic must remain <= 600 requests/minute (30% of total traffic)
  - abort when MemAvailable is below 400 MiB for 3 consecutive samples
  - abort when swap grows by 64 MiB from the pre-load sample
  - fail when minimum MemAvailable is below 25% of total memory
  - fail when any request is dropped or HTTP/semantic validation fails
EOF
}

log() { printf '[g7-operational] %s\n' "$*" >&2; }
fail() { printf '[g7-operational] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) shift; PROFILE="${1:-}" ;;
        --rate) shift; TARGET_RPS="${1:-}"; DIRECT_RATE_SET=1 ;;
        --duration) shift; DURATION="${1:-}"; DIRECT_DURATION_SET=1 ;;
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        --host-header) shift; HOST_HEADER="${1:-}" ;;
        --insecure) TLS_INSECURE=1 ;;
        --board-slug) shift; BOARD_SLUG="${1:-}" ;;
        --post-id) shift; POST_ID="${1:-}" ;;
        --product-id) shift; PRODUCT_ID="${1:-}" ;;
        --state-label) shift; STATE_LABEL="${1:-}" ;;
        --preallocated-vus) shift; PREALLOCATED_VUS="${1:-}" ;;
        --max-vus) shift; MAX_VUS="${1:-}" ;;
        --request-timeout) shift; REQUEST_TIMEOUT_SECONDS="${1:-}" ;;
        --sample-interval) shift; SAMPLE_INTERVAL_SECONDS="${1:-}" ;;
        --output-dir) shift; OUTPUT_DIR="${1:-}" ;;
        --plan) PLAN_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

if [[ "${DIRECT_RATE_SET}" != "${DIRECT_DURATION_SET}" ]]; then
    fail '--rate and --duration must be supplied together'
fi
if [[ "${DIRECT_RATE_SET}" == 0 ]]; then
    case "${PROFILE}" in
        smoke) TARGET_RPS=2; DURATION=3m ;;
        warmup) TARGET_RPS=5; DURATION=5m ;;
        steady) TARGET_RPS=15; DURATION=30m ;;
        peak) TARGET_RPS=30; DURATION=15m ;;
        spike) TARGET_RPS=33; DURATION=5m ;;
        soak) TARGET_RPS=15; DURATION=2h ;;
        *) fail '--profile must be smoke, warmup, steady, peak, spike, or soak' ;;
    esac
else
    PROFILE=direct
fi

duration_seconds() {
    local raw="$1" value unit multiplier
    [[ "${raw}" =~ ^[0-9]+[smh]$ ]] || return 1
    value="${raw%?}"
    unit="${raw: -1}"
    case "${unit}" in
        s) multiplier=1 ;;
        m) multiplier=60 ;;
        h) multiplier=3600 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$((value * multiplier))"
}

[[ "${TARGET_RPS}" =~ ^[0-9]+$ && "${TARGET_RPS}" -ge 1 ]] \
    || fail 'rate must be a positive integer'
DURATION_SECONDS="$(duration_seconds "${DURATION}")" \
    || fail 'duration must use an integer s, m, or h suffix'
[[ "${DURATION_SECONDS}" -ge 30 && "${DURATION_SECONDS}" -le 28800 ]] \
    || fail 'duration must be between 30 seconds and 8 hours'
[[ "${REQUEST_TIMEOUT_SECONDS}" =~ ^[0-9]+$ \
    && "${REQUEST_TIMEOUT_SECONDS}" -ge 1 \
    && "${REQUEST_TIMEOUT_SECONDS}" -le 120 ]] \
    || fail 'request timeout must be between 1 and 120 seconds'
[[ "${SAMPLE_INTERVAL_SECONDS}" =~ ^[0-9]+$ \
    && "${SAMPLE_INTERVAL_SECONDS}" -ge 1 \
    && "${SAMPLE_INTERVAL_SECONDS}" -le 10 ]] \
    || fail 'sample interval must be between 1 and 10 seconds'
[[ "${MEM_AVAILABLE_LIMIT_MIB}" =~ ^[0-9]+$ && "${MEM_AVAILABLE_LIMIT_MIB}" -ge 128 ]] \
    || fail 'memory safety limit must be at least 128 MiB'
[[ "${MEM_LOW_CONSECUTIVE}" =~ ^[0-9]+$ && "${MEM_LOW_CONSECUTIVE}" -ge 1 ]] \
    || fail 'memory consecutive count must be positive'
[[ "${MEM_AVAILABLE_PASS_PCT}" =~ ^[0-9]+$ \
    && "${MEM_AVAILABLE_PASS_PCT}" -ge 1 \
    && "${MEM_AVAILABLE_PASS_PCT}" -le 90 ]] \
    || fail 'memory pass percentage must be between 1 and 90'
[[ "${SWAP_GROWTH_LIMIT_MIB}" =~ ^[0-9]+$ && "${SWAP_GROWTH_LIMIT_MIB}" -ge 1 ]] \
    || fail 'swap growth safety limit must be positive'
[[ -n "${BOARD_SLUG}" && -n "${STATE_LABEL}" ]] \
    || fail 'board slug and state label must not be empty'

if [[ -z "${PREALLOCATED_VUS}" ]]; then PREALLOCATED_VUS=$((TARGET_RPS * 2)); fi
if [[ -z "${MAX_VUS}" ]]; then MAX_VUS=$((TARGET_RPS * 4)); fi
[[ "${PREALLOCATED_VUS}" =~ ^[0-9]+$ && "${PREALLOCATED_VUS}" -ge 1 ]] \
    || fail 'preallocated VUs must be positive'
[[ "${MAX_VUS}" =~ ^[0-9]+$ \
    && "${MAX_VUS}" -ge "${PREALLOCATED_VUS}" \
    && "${MAX_VUS}" -le 1000 ]] \
    || fail 'max VUs must be >= preallocated VUs and <= 1000'

# 10회 주기 중 게시판 3회. 올림 계산으로 경계에서도 600회/분을 넘기지 않는다.
BOARD_REQUESTS_PER_MINUTE=$(((TARGET_RPS * 3 * 60 + 9) / 10))
[[ "${BOARD_REQUESTS_PER_MINUTE}" -le 600 ]] \
    || fail "${TARGET_RPS} RPS sends ${BOARD_REQUESTS_PER_MINUTE} board requests/minute; shared limit is 600"
PLANNED_REQUESTS=$((TARGET_RPS * DURATION_SECONDS))
SAMPLER_MAX_SECONDS=$((DURATION_SECONDS + 60))

print_plan() {
    printf '{"profile":"%s","target_rps":%s,"duration":"%s","duration_seconds":%s,"planned_requests":%s,"mix":{"shop_pct":50,"board_pct":30,"home_pct":10,"write_like_read_safe_pct":10},"board_requests_per_minute":%s,"board_throttle_limit_per_minute":600,"board_throttle_compliant":true,"preallocated_vus":%s,"max_vus":%s,"mutation_requests":0}\n' \
        "${PROFILE}" "${TARGET_RPS}" "${DURATION}" "${DURATION_SECONDS}" \
        "${PLANNED_REQUESTS}" "${BOARD_REQUESTS_PER_MINUTE}" \
        "${PREALLOCATED_VUS}" "${MAX_VUS}"
}

if [[ "${PLAN_ONLY}" == 1 ]]; then
    print_plan
    exit 0
fi

[[ -n "${REMOTE_HOST}" ]] || fail '--host is required'
[[ -n "${BASE_URL}" ]] || fail '--base-url is required'
BASE_URL="${BASE_URL%/}"
[[ "${BASE_URL}" =~ ^https?:// ]] || fail 'base URL must start with http:// or https://'
[[ -f "${K6_SCRIPT}" ]] || fail "k6 script not found: ${K6_SCRIPT}"
for command in "${K6_BIN}" "${SSH_BIN}" "${CURL_BIN}" "${JQ_BIN}" awk; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command not found: ${command}"
done

SSH_OPTIONS=(-o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT_SECONDS}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
CURL_OPTIONS=(--fail --silent --show-error --max-time "${REQUEST_TIMEOUT_SECONDS}" -H 'Accept: application/json' -H 'Cache-Control: no-cache')
if [[ "${TLS_INSECURE}" == 1 ]]; then CURL_OPTIONS+=(--insecure); fi
if [[ -n "${HOST_HEADER}" ]]; then CURL_OPTIONS+=(-H "Host: ${HOST_HEADER}"); fi

api_get() {
    "${CURL_BIN}" "${CURL_OPTIONS[@]}" "${BASE_URL}$1"
}

discover_targets() {
    local encoded_board payload detail
    encoded_board="$("${JQ_BIN}" -rn --arg value "${BOARD_SLUG}" '$value|@uri')"
    if [[ -z "${POST_ID}" ]]; then
        payload="$(api_get "/api/modules/sirsoft-board/boards/${encoded_board}/posts?page=1&per_page=20")"
        POST_ID="$("${JQ_BIN}" -r '[.data.data[]? | select(.is_secret != true and (.status // "published") == "published") | .id][0] // empty' <<<"${payload}")"
    fi
    [[ "${POST_ID}" =~ ^[0-9A-Za-z_-]+$ ]] || fail 'could not discover a public post; pass --post-id'
    detail="$(api_get "/api/modules/sirsoft-board/boards/${encoded_board}/posts/${POST_ID}")"
    "${JQ_BIN}" -e --arg id "${POST_ID}" '.success == true and ((.data.id|tostring) == $id)' \
        <<<"${detail}" >/dev/null || fail 'post target failed semantic preflight'

    if [[ -z "${PRODUCT_ID}" ]]; then
        payload="$(api_get '/api/modules/sirsoft-ecommerce/products?page=1&per_page=12')"
        PRODUCT_ID="$("${JQ_BIN}" -r '.data.data[0].id // empty' <<<"${payload}")"
    fi
    [[ "${PRODUCT_ID}" =~ ^[0-9A-Za-z_-]+$ ]] || fail 'could not discover a public product; pass --product-id'
    detail="$(api_get "/api/modules/sirsoft-ecommerce/products/${PRODUCT_ID}")"
    "${JQ_BIN}" -e --arg id "${PRODUCT_ID}" '.success == true and ((.data.id|tostring) == $id)' \
        <<<"${detail}" >/dev/null || fail 'product target failed semantic preflight'
}

REMOTE_COMMIT="$("${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" bash -s -- "${REMOTE_ROOT}" <<'REMOTE'
set -euo pipefail
root="$1"
if [[ -d "${root}/.git" ]]; then
    git -C "${root}" rev-parse HEAD
else
    printf 'not-a-git-checkout\n'
fi
REMOTE
)" || fail 'remote sampler SSH preflight failed'

discover_targets

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/storage/app/benchmark/reports/g7-operational-$(date '+%Y%m%d-%H%M%S')-${STATE_LABEL}"
fi
[[ ! -e "${OUTPUT_DIR}" ]] || fail "output directory already exists: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

K6_SUMMARY="${OUTPUT_DIR}/k6-summary.json"
K6_LOG="${OUTPUT_DIR}/k6.log"
SAMPLES_CSV="${OUTPUT_DIR}/resources.csv"
SAMPLER_LOG="${OUTPUT_DIR}/resources.log"
RESOURCE_JSON="${OUTPUT_DIR}/resources-summary.json"
REPORT_JSON="${OUTPUT_DIR}/summary.json"
REPORT_CSV="${OUTPUT_DIR}/summary.csv"
REPORT_MD="${OUTPUT_DIR}/report.md"
TOKEN="g7-operational-$(date +%s)-$$"
REMOTE_STOP_FILE="/tmp/${TOKEN}.stop"
SAMPLER_PID=''
K6_PID=''
CLEANUP_RUNNING=0

stop_k6() {
    local attempt
    [[ -n "${K6_PID}" ]] || return 0
    if kill -0 "${K6_PID}" >/dev/null 2>&1; then
        kill -INT "${K6_PID}" >/dev/null 2>&1 || true
        for ((attempt = 0; attempt < 30; attempt++)); do
            kill -0 "${K6_PID}" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    kill -0 "${K6_PID}" >/dev/null 2>&1 && kill -TERM "${K6_PID}" >/dev/null 2>&1 || true
    wait "${K6_PID}" >/dev/null 2>&1 || true
    K6_PID=''
}

request_sampler_stop() {
    [[ -n "${SAMPLER_PID}" ]] || return 0
    "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" bash -s -- stop "${REMOTE_STOP_FILE}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
[[ "$1" == stop && "$2" =~ ^/tmp/g7-operational-[A-Za-z0-9_-]+[.]stop$ ]]
touch -- "$2"
REMOTE
}

cleanup() {
    local status=$?
    [[ "${CLEANUP_RUNNING}" == 0 ]] || exit "${status}"
    CLEANUP_RUNNING=1
    stop_k6
    if [[ -n "${SAMPLER_PID}" ]]; then
        request_sampler_stop
        kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
        wait "${SAMPLER_PID}" >/dev/null 2>&1 || true
        SAMPLER_PID=''
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM

start_sampler() {
    "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" bash -s -- sample \
        "${REMOTE_STOP_FILE}" "${SAMPLE_INTERVAL_SECONDS}" "${SAMPLER_MAX_SECONDS}" \
        "${MEM_AVAILABLE_LIMIT_MIB}" "${MEM_LOW_CONSECUTIVE}" "${SWAP_GROWTH_LIMIT_MIB}" \
        >"${SAMPLES_CSV}" 2>"${SAMPLER_LOG}" <<'REMOTE' &
set -euo pipefail
action="$1"; stop_file="$2"; interval="$3"; max_seconds="$4"
mem_limit_mib="$5"; mem_count_limit="$6"; swap_growth_limit_mib="$7"
[[ "${action}" == sample ]]
[[ "${stop_file}" =~ ^/tmp/g7-operational-[A-Za-z0-9_-]+[.]stop$ ]]
[[ "${interval}" =~ ^[0-9]+$ && "${max_seconds}" =~ ^[0-9]+$ ]]
[[ "${mem_limit_mib}" =~ ^[0-9]+$ && "${mem_count_limit}" =~ ^[0-9]+$ ]]
[[ "${swap_growth_limit_mib}" =~ ^[0-9]+$ ]]
rm -f -- "${stop_file}"
trap 'rm -f -- "${stop_file}"' EXIT

declare -A last_ticks=()
PHP_TICKS=0; MYSQL_TICKS=0; SEARCHD_TICKS=0
PHP_RSS_KIB=0; MYSQL_RSS_KIB=0; SEARCHD_RSS_KIB=0

read_host() {
    local label user nice system idle iowait irq softirq steal guest guest_nice
    read -r label user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    HOST_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
    HOST_IDLE=$((idle + iowait))
}

read_memory() {
    local ignored total_kib available_kib swap_total_kib swap_free_kib
    read -r LOAD1 ignored < /proc/loadavg
    total_kib="$(awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo)"
    available_kib="$(awk '$1 == "MemAvailable:" {print $2; exit}' /proc/meminfo)"
    swap_total_kib="$(awk '$1 == "SwapTotal:" {print $2; exit}' /proc/meminfo)"
    swap_free_kib="$(awk '$1 == "SwapFree:" {print $2; exit}' /proc/meminfo)"
    MEM_TOTAL_MIB=$((total_kib / 1024))
    MEM_AVAILABLE_MIB=$((available_kib / 1024))
    SWAP_USED_MIB=$(((swap_total_kib - swap_free_kib) / 1024))
}

read_processes() {
    local proc_dir pid comm stat_line stat_tail start_time key ticks previous delta rss_kib
    local -a fields
    PHP_TICKS=0; MYSQL_TICKS=0; SEARCHD_TICKS=0
    PHP_RSS_KIB=0; MYSQL_RSS_KIB=0; SEARCHD_RSS_KIB=0
    for proc_dir in /proc/[0-9]*; do
        [[ -r "${proc_dir}/comm" && -r "${proc_dir}/stat" ]] || continue
        pid="${proc_dir##*/}"
        read -r comm < "${proc_dir}/comm" || continue
        case "${comm}" in php-fpm*|mysqld|mariadbd|searchd) ;; *) continue ;; esac
        stat_line="$(<"${proc_dir}/stat")" || continue
        stat_tail="${stat_line#*) }"
        read -r -a fields <<<"${stat_tail}"
        [[ ${#fields[@]} -gt 19 ]] || continue
        ticks=$((fields[11] + fields[12]))
        start_time="${fields[19]}"
        key="${pid}:${start_time}"
        previous="${last_ticks[${key}]:-${ticks}}"
        delta=$((ticks - previous)); (( delta >= 0 )) || delta=0
        last_ticks["${key}"]="${ticks}"
        rss_kib="$(awk '$1 == "VmRSS:" {print $2; exit}' "${proc_dir}/status" 2>/dev/null || true)"
        [[ "${rss_kib}" =~ ^[0-9]+$ ]] || rss_kib=0
        case "${comm}" in
            php-fpm*) PHP_TICKS=$((PHP_TICKS + delta)); PHP_RSS_KIB=$((PHP_RSS_KIB + rss_kib)) ;;
            mysqld|mariadbd) MYSQL_TICKS=$((MYSQL_TICKS + delta)); MYSQL_RSS_KIB=$((MYSQL_RSS_KIB + rss_kib)) ;;
            searchd) SEARCHD_TICKS=$((SEARCHD_TICKS + delta)); SEARCHD_RSS_KIB=$((SEARCHD_RSS_KIB + rss_kib)) ;;
        esac
    done
}

CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
[[ "${CPU_COUNT}" =~ ^[0-9]+$ && "${CPU_COUNT}" -gt 0 ]] || CPU_COUNT=1
read_host
read_memory
read_processes
previous_total="${HOST_TOTAL}"
previous_idle="${HOST_IDLE}"
swap_baseline_mib="${SWAP_USED_MIB}"
started="${SECONDS}"
sample=0
mem_low_count=0
printf 'sample,elapsed_seconds,timestamp,cpu_count,host_busy_pct,php_fpm_cpu_pct,php_fpm_rss_mib,mysql_cpu_pct,mysql_rss_mib,searchd_cpu_pct,searchd_rss_mib,load1,mem_available_mib,mem_total_mib,swap_used_mib,abort_reason\n'
while [[ ! -e "${stop_file}" ]] && (( SECONDS - started < max_seconds )); do
    sleep "${interval}"
    read_host
    read_memory
    read_processes
    total_delta=$((HOST_TOTAL - previous_total))
    idle_delta=$((HOST_IDLE - previous_idle))
    (( total_delta > 0 )) || continue
    host_busy="$(awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN {printf "%.3f", (total-idle)*100/total}')"
    php_cpu="$(awk -v ticks="${PHP_TICKS}" -v total="${total_delta}" 'BEGIN {printf "%.3f", ticks*100/total}')"
    mysql_cpu="$(awk -v ticks="${MYSQL_TICKS}" -v total="${total_delta}" 'BEGIN {printf "%.3f", ticks*100/total}')"
    searchd_cpu="$(awk -v ticks="${SEARCHD_TICKS}" -v total="${total_delta}" 'BEGIN {printf "%.3f", ticks*100/total}')"
    php_rss="$(awk -v kib="${PHP_RSS_KIB}" 'BEGIN {printf "%.3f", kib/1024}')"
    mysql_rss="$(awk -v kib="${MYSQL_RSS_KIB}" 'BEGIN {printf "%.3f", kib/1024}')"
    searchd_rss="$(awk -v kib="${SEARCHD_RSS_KIB}" 'BEGIN {printf "%.3f", kib/1024}')"
    if (( MEM_AVAILABLE_MIB < mem_limit_mib )); then
        mem_low_count=$((mem_low_count + 1))
    else
        mem_low_count=0
    fi
    swap_growth=$((SWAP_USED_MIB - swap_baseline_mib)); (( swap_growth >= 0 )) || swap_growth=0
    abort_reason=''
    if (( mem_low_count >= mem_count_limit )); then
        abort_reason='mem_available_below_limit_consecutive'
    elif (( swap_growth >= swap_growth_limit_mib )); then
        abort_reason='swap_growth'
    fi
    sample=$((sample + 1))
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${sample}" "$((SECONDS - started))" "$(date --iso-8601=seconds)" "${CPU_COUNT}" \
        "${host_busy}" "${php_cpu}" "${php_rss}" "${mysql_cpu}" "${mysql_rss}" \
        "${searchd_cpu}" "${searchd_rss}" "${LOAD1}" "${MEM_AVAILABLE_MIB}" \
        "${MEM_TOTAL_MIB}" "${SWAP_USED_MIB}" "${abort_reason}"
    if [[ -n "${abort_reason}" ]]; then
        printf 'G7_OPERATIONAL_ABORT reason=%s mem=%sMiB swap_growth=%sMiB\n' \
            "${abort_reason}" "${MEM_AVAILABLE_MIB}" "${swap_growth}" >&2
        exit 86
    fi
    previous_total="${HOST_TOTAL}"
    previous_idle="${HOST_IDLE}"
done
REMOTE
    SAMPLER_PID=$!

    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s "${SAMPLES_CSV}" ]] && return 0
        kill -0 "${SAMPLER_PID}" >/dev/null 2>&1 || break
        sleep 0.1
    done
    return 1
}

log "profile=${PROFILE}, target=${TARGET_RPS} RPS, duration=${DURATION}, board=${BOARD_REQUESTS_PER_MINUTE}/600 per minute"
log "state=${STATE_LABEL}, remote_commit=${REMOTE_COMMIT}, post=${POST_ID}, product=${PRODUCT_ID}"
start_sampler || fail 'remote resource sampler did not become ready'

(
    export BASE_URL BOARD_SLUG POST_ID PRODUCT_ID TARGET_RPS DURATION PREALLOCATED_VUS MAX_VUS HOST_HEADER
    export REQUEST_TIMEOUT="${REQUEST_TIMEOUT_SECONDS}s"
    export TLS_INSECURE
    exec "${K6_BIN}" run --quiet --summary-export "${K6_SUMMARY}" "${K6_SCRIPT}"
) >"${K6_LOG}" 2>&1 &
K6_PID=$!

K6_EXIT=0
SAMPLER_EXIT=0
SAMPLER_ENDED_DURING_LOAD=0
while kill -0 "${K6_PID}" >/dev/null 2>&1; do
    if ! kill -0 "${SAMPLER_PID}" >/dev/null 2>&1; then
        wait "${SAMPLER_PID}" || SAMPLER_EXIT=$?
        SAMPLER_PID=''
        SAMPLER_ENDED_DURING_LOAD=1
        stop_k6
        break
    fi
    sleep 0.2
done
if [[ -n "${K6_PID}" ]]; then
    wait "${K6_PID}" || K6_EXIT=$?
    K6_PID=''
fi
if [[ -n "${SAMPLER_PID}" ]]; then
    request_sampler_stop
    wait "${SAMPLER_PID}" || SAMPLER_EXIT=$?
    SAMPLER_PID=''
fi

if [[ "${SAMPLER_EXIT}" != 0 || "${SAMPLER_ENDED_DURING_LOAD}" == 1 ]]; then
    reason="$(awk -F, 'NR > 1 && $16 != "" {reason=$16} END {print reason}' "${SAMPLES_CSV}" 2>/dev/null || true)"
    [[ -n "${reason}" ]] || reason="sampler-exit-${SAMPLER_EXIT}"
    fail "resource safety sampler aborted the load (${reason})"
fi
[[ -s "${K6_SUMMARY}" ]] || fail "k6 produced no summary (exit=${K6_EXIT})"

summarize_resources() {
    awk -F, '
        NR == 1 {next}
        NF >= 16 {
            n++
            host_sum += $5; php_cpu_sum += $6; mysql_cpu_sum += $8; searchd_cpu_sum += $10
            if (n == 1 || $5 > host_max) host_max=$5
            if (n == 1 || $7 > php_rss_max) php_rss_max=$7
            if (n == 1 || $9 > mysql_rss_max) mysql_rss_max=$9
            if (n == 1 || $11 > searchd_rss_max) searchd_rss_max=$11
            if (n == 1 || $13 < mem_min) mem_min=$13
            if (n == 1) mem_total=$14
            if (n == 1) swap_start=$15
            if (n == 1 || $15 > swap_max) swap_max=$15
            elapsed=$2; cpu_count=$4
        }
        END {
            if (n == 0) exit 2
            printf "{\"samples\":%d,\"elapsed_seconds\":%d,\"cpu_count\":%d,\"host_busy_avg_pct\":%.3f,\"host_busy_max_pct\":%.3f,\"php_fpm_cpu_avg_pct\":%.3f,\"php_fpm_rss_max_mib\":%.3f,\"mysql_cpu_avg_pct\":%.3f,\"mysql_rss_max_mib\":%.3f,\"searchd_cpu_avg_pct\":%.3f,\"searchd_rss_max_mib\":%.3f,\"mem_available_min_mib\":%.3f,\"mem_total_mib\":%.3f,\"mem_available_min_pct\":%.3f,\"swap_used_start_mib\":%.3f,\"swap_used_max_mib\":%.3f,\"swap_growth_max_mib\":%.3f}\n", n, elapsed, cpu_count, host_sum/n, host_max, php_cpu_sum/n, php_rss_max, mysql_cpu_sum/n, mysql_rss_max, searchd_cpu_sum/n, searchd_rss_max, mem_min, mem_total, mem_min*100/mem_total, swap_start, swap_max, swap_max-swap_start
        }
    ' "${SAMPLES_CSV}" > "${RESOURCE_JSON}"
    "${JQ_BIN}" -e . "${RESOURCE_JSON}" >/dev/null
}
summarize_resources || fail 'resource sampler produced no usable rows'

metric_value() {
    local metric="$1" field="$2" default_value="$3"
    "${JQ_BIN}" -r --arg metric "${metric}" --arg field "${field}" --argjson default "${default_value}" \
        '.metrics[$metric] as $item
         | (($item.values // $item)[$field]
            // (if $field == "rate" then $item.value else null end)
            // $default)' "${K6_SUMMARY}"
}

HTTP_REQUESTS="$(metric_value http_reqs count 0)"
ITERATIONS="$(metric_value iterations count 0)"
DROPPED="$(metric_value dropped_iterations count 0)"
HTTP_FAILURE_RATE="$(metric_value http_req_failed rate 1)"
SEMANTIC_VALID_RATE="$(metric_value g7_operational_valid rate 0)"
HTTP_VALID_RATE="$(metric_value g7_operational_http_valid rate 0)"
HTTP_REQUESTS="${HTTP_REQUESTS%.*}"
ITERATIONS="${ITERATIONS%.*}"
DROPPED="${DROPPED%.*}"

# remainder는 0..9이므로 write_like 슬롯(9)은 remainder가 10일 때만 포함된다.
# 완전한 10회 주기마다 정확히 1회이며, 부분 주기는 슬롯 9에 도달하지 않는다.
expected_mix_count() {
    local workload="$1" total="$2" cycles remainder extra=0
    cycles=$((total / 10)); remainder=$((total % 10))
    case "${workload}" in
        shop) extra=$((remainder < 5 ? remainder : 5)); printf '%s\n' "$((cycles * 5 + extra))" ;;
        board) extra=$((remainder > 5 ? remainder - 5 : 0)); (( extra <= 3 )) || extra=3; printf '%s\n' "$((cycles * 3 + extra))" ;;
        home) (( remainder >= 9 )) && extra=1 || extra=0; printf '%s\n' "$((cycles + extra))" ;;
        write_like) printf '%s\n' "${cycles}" ;;
    esac
}

VALIDATION_ERRORS=()
[[ "${K6_EXIT}" == 0 ]] || VALIDATION_ERRORS+=("k6_exit_${K6_EXIT}")
[[ "${DROPPED}" == 0 ]] || VALIDATION_ERRORS+=("dropped_iterations")
[[ "${HTTP_REQUESTS}" == "${ITERATIONS}" ]] || VALIDATION_ERRORS+=("iteration_is_not_one_http_request")
if (( ITERATIONS < PLANNED_REQUESTS || ITERATIONS > PLANNED_REQUESTS + 1 )); then
    VALIDATION_ERRORS+=("arrival_schedule_incomplete")
fi
awk -v value="${HTTP_FAILURE_RATE}" 'BEGIN {exit !(value == 0)}' || VALIDATION_ERRORS+=("http_failure")
awk -v value="${HTTP_VALID_RATE}" 'BEGIN {exit !(value == 1)}' || VALIDATION_ERRORS+=("http_status_validation")
awk -v value="${SEMANTIC_VALID_RATE}" 'BEGIN {exit !(value == 1)}' || VALIDATION_ERRORS+=("semantic_validation")
MEM_AVAILABLE_MIN_PCT="$("${JQ_BIN}" -r '.mem_available_min_pct' "${RESOURCE_JSON}")"
awk -v value="${MEM_AVAILABLE_MIN_PCT}" -v minimum="${MEM_AVAILABLE_PASS_PCT}" \
    'BEGIN {exit !(value >= minimum)}' \
    || VALIDATION_ERRORS+=("memory_available_below_${MEM_AVAILABLE_PASS_PCT}pct")

for workload in shop board home write_like; do
    actual="$(metric_value "g7_workload_${workload}_requests" count 0)"; actual="${actual%.*}"
    expected="$(expected_mix_count "${workload}" "${ITERATIONS}")"
    [[ "${actual}" == "${expected}" ]] || VALIDATION_ERRORS+=("${workload}_mix_mismatch")
done

VALIDATION_JSON='[]'
if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
    VALIDATION_JSON="$(printf '%s\n' "${VALIDATION_ERRORS[@]}" | "${JQ_BIN}" -R . | "${JQ_BIN}" -s .)"
fi
PASSED=true
[[ ${#VALIDATION_ERRORS[@]} == 0 ]] || PASSED=false

COMPLETED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
"${JQ_BIN}" -n \
    --slurpfile k6 "${K6_SUMMARY}" --slurpfile resources "${RESOURCE_JSON}" \
    --arg completed_at "${COMPLETED_AT}" --arg profile "${PROFILE}" --arg state "${STATE_LABEL}" \
    --arg base_url "${BASE_URL}" --arg remote_host "${REMOTE_HOST}" --arg remote_commit "${REMOTE_COMMIT}" \
    --arg board_slug "${BOARD_SLUG}" --arg post_id "${POST_ID}" --arg product_id "${PRODUCT_ID}" \
    --arg duration "${DURATION}" --argjson duration_seconds "${DURATION_SECONDS}" \
    --argjson target_rps "${TARGET_RPS}" --argjson planned_requests "${PLANNED_REQUESTS}" \
    --argjson actual_requests "${HTTP_REQUESTS}" --argjson iterations "${ITERATIONS}" \
    --argjson dropped "${DROPPED}" --argjson board_rpm "${BOARD_REQUESTS_PER_MINUTE}" \
    --argjson preallocated_vus "${PREALLOCATED_VUS}" --argjson max_vus "${MAX_VUS}" \
    --argjson mem_available_pass_pct "${MEM_AVAILABLE_PASS_PCT}" \
    --argjson passed "${PASSED}" --argjson validation_errors "${VALIDATION_JSON}" '
    def metric($name; $field):
      $k6[0].metrics[$name] as $item
      | (($item.values // $item)[$field]
         // (if $field == "rate" then $item.value else null end)
         // null);
    def workload($name; $weight): {
      name: $name,
      target_weight_pct: $weight,
      requests: metric("g7_workload_" + $name + "_requests"; "count"),
      semantic_valid_rate: metric("g7_workload_" + $name + "_valid"; "rate"),
      latency_ms: {
        avg: metric("g7_workload_" + $name + "_duration"; "avg"),
        p95: metric("g7_workload_" + $name + "_duration"; "p(95)"),
        p99: metric("g7_workload_" + $name + "_duration"; "p(99)"),
        max: metric("g7_workload_" + $name + "_duration"; "max")
      }
    };
    {
      metadata: {
        completed_at: $completed_at,
        profile: $profile,
        state_label: $state,
        base_url: $base_url,
        remote_host: $remote_host,
        remote_commit: $remote_commit,
        read_only: true,
        tuning_transition_performed: false
      },
      target: {board_slug: $board_slug, post_id: $post_id, product_id: $product_id},
      schedule: {
        executor: "constant-arrival-rate",
        target_rps: $target_rps,
        duration: $duration,
        duration_seconds: $duration_seconds,
        planned_requests: $planned_requests,
        actual_requests: $actual_requests,
        iterations: $iterations,
        achieved_rps: ($actual_requests / $duration_seconds),
        dropped_iterations: $dropped,
        preallocated_vus: $preallocated_vus,
        max_vus: $max_vus
      },
      throttle: {
        board_requests_per_minute: $board_rpm,
        shared_limit_per_minute: 600,
        compliant: ($board_rpm <= 600)
      },
      validation: {
        passed: $passed,
        errors: $validation_errors,
        mem_available_pass_pct: $mem_available_pass_pct,
        http_failure_rate: metric("http_req_failed"; "rate"),
        http_valid_rate: metric("g7_operational_http_valid"; "rate"),
        semantic_valid_rate: metric("g7_operational_valid"; "rate")
      },
      latency_ms: {
        avg: metric("g7_operational_duration"; "avg"),
        p95: metric("g7_operational_duration"; "p(95)"),
        p99: metric("g7_operational_duration"; "p(99)"),
        max: metric("g7_operational_duration"; "max")
      },
      workloads: [workload("shop"; 50), workload("board"; 30), workload("home"; 10), workload("write_like"; 10)],
      resources: $resources[0]
    }
    ' > "${REPORT_JSON}"

"${JQ_BIN}" -r '
  ["scope","target_weight_pct","requests","target_rps","achieved_rps","dropped","semantic_valid_rate","avg_ms","p95_ms","p99_ms","host_busy_avg_pct","php_fpm_cpu_avg_pct","php_fpm_rss_max_mib","mysql_cpu_avg_pct","mysql_rss_max_mib","searchd_cpu_avg_pct","searchd_rss_max_mib","mem_available_min_mib","mem_available_min_pct","swap_growth_max_mib"],
  (["all",100,.schedule.actual_requests,.schedule.target_rps,.schedule.achieved_rps,.schedule.dropped_iterations,.validation.semantic_valid_rate,.latency_ms.avg,.latency_ms.p95,.latency_ms.p99,.resources.host_busy_avg_pct,.resources.php_fpm_cpu_avg_pct,.resources.php_fpm_rss_max_mib,.resources.mysql_cpu_avg_pct,.resources.mysql_rss_max_mib,.resources.searchd_cpu_avg_pct,.resources.searchd_rss_max_mib,.resources.mem_available_min_mib,.resources.mem_available_min_pct,.resources.swap_growth_max_mib]),
  (.workloads[] | [.name,.target_weight_pct,.requests,"","",0,.semantic_valid_rate,.latency_ms.avg,.latency_ms.p95,.latency_ms.p99,"","","","","","","","","",""])
  | @csv
' "${REPORT_JSON}" > "${REPORT_CSV}"

{
    printf '# 그누보드7 운영 부하 결과\n\n'
    printf -- '- 판정: **%s**\n' "$("${JQ_BIN}" -r 'if .validation.passed then "PASS" else "FAIL" end' "${REPORT_JSON}")"
    printf -- '- 상태: `%s` (하네스가 튜닝 상태를 변경하지 않음)\n' "${STATE_LABEL}"
    printf -- '- 부하: %s RPS / %s, 요청 %s회, drop %s회\n' "${TARGET_RPS}" "${DURATION}" "${HTTP_REQUESTS}" "${DROPPED}"
    printf -- '- 게시판 제한: %s/600회·분 (준수)\n' "${BOARD_REQUESTS_PER_MINUTE}"
    printf -- '- 대상 커밋: `%s`\n\n' "${REMOTE_COMMIT}"
    printf '## HTTP·의미 검증\n\n'
    printf '| HTTP 실패율 | HTTP 유효율 | 의미 유효율 | 오류 |\n'
    printf '|---:|---:|---:|---|\n'
    "${JQ_BIN}" -r '[.validation.http_failure_rate,.validation.http_valid_rate,.validation.semantic_valid_rate,((.validation.errors // [])|join(", "))] | @tsv' "${REPORT_JSON}" \
        | while IFS=$'\t' read -r failed http_valid semantic_valid errors; do
            printf '| %s | %s | %s | %s |\n' "${failed}" "${http_valid}" "${semantic_valid}" "${errors:-없음}"
        done
    printf '\n## 워크로드\n\n'
    printf '| 구분 | 목표 비중 | 요청 | 평균(ms) | p95(ms) | p99(ms) | 의미 유효율 |\n'
    printf '|---|---:|---:|---:|---:|---:|---:|\n'
    "${JQ_BIN}" -r '.workloads[] | [.name,.target_weight_pct,.requests,.latency_ms.avg,.latency_ms.p95,.latency_ms.p99,.semantic_valid_rate] | @tsv' "${REPORT_JSON}" \
        | while IFS=$'\t' read -r name weight requests avg p95 p99 valid; do
            printf '| %s | %s%% | %s | %s | %s | %s | %s |\n' "${name}" "${weight}" "${requests}" "${avg}" "${p95}" "${p99}" "${valid}"
        done
    printf '\n## 서버 자원\n\n'
    printf '| 호스트 CPU 평균/최대 | PHP CPU/RSS | MySQL CPU/RSS | searchd CPU/RSS | 최소 가용 메모리 | swap 증가 |\n'
    printf '|---:|---:|---:|---:|---:|---:|\n'
    "${JQ_BIN}" -r '[((.resources.host_busy_avg_pct|tostring)+"% / "+(.resources.host_busy_max_pct|tostring)+"%"),((.resources.php_fpm_cpu_avg_pct|tostring)+"% / "+(.resources.php_fpm_rss_max_mib|tostring)+" MiB"),((.resources.mysql_cpu_avg_pct|tostring)+"% / "+(.resources.mysql_rss_max_mib|tostring)+" MiB"),((.resources.searchd_cpu_avg_pct|tostring)+"% / "+(.resources.searchd_rss_max_mib|tostring)+" MiB"),((.resources.mem_available_min_mib|tostring)+" MiB ("+(.resources.mem_available_min_pct|tostring)+"%)"),((.resources.swap_growth_max_mib|tostring)+" MiB")] | @tsv' "${REPORT_JSON}" \
        | while IFS=$'\t' read -r host php mysql searchd mem swap; do
            printf '| %s | %s | %s | %s | %s | %s |\n' "${host}" "${php}" "${mysql}" "${searchd}" "${mem}" "${swap}"
        done
} > "${REPORT_MD}"

trap - EXIT INT TERM
log "JSON: ${REPORT_JSON}"
log "CSV: ${REPORT_CSV}"
log "Markdown: ${REPORT_MD}"
log "resource samples: ${SAMPLES_CSV}"
[[ "${PASSED}" == true ]] || fail "load validation failed: ${VALIDATION_ERRORS[*]}"
