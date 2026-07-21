#!/usr/bin/env bash

# shellcheck disable=SC2016

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

PERFORMANCE_TOGGLE="${G7_SEARCH_AB_PERFORMANCE_TOGGLE:-${SCRIPT_DIR}/g7-performance-toggle.sh}"
SEARCH_TOGGLE="${G7_SEARCH_AB_SEARCH_TOGGLE:-${SCRIPT_DIR}/g7-search-backend-toggle.sh}"
SSH_BIN="${G7_SEARCH_AB_SSH_BIN:-ssh}"
CURL_BIN="${G7_SEARCH_AB_CURL_BIN:-curl}"
JQ_BIN="${G7_SEARCH_AB_JQ_BIN:-jq}"

REMOTE_HOST="${G7_SEARCH_AB_HOST:-g7-benchmark}"
REMOTE_ROOT="${G7_SEARCH_AB_ROOT:-/var/www/gnuboard7}"
REMOTE_APP_USER="${G7_SEARCH_AB_APP_USER:-www-data}"
REMOTE_DB_NAME="${G7_SEARCH_AB_DB_NAME:-gnuboard7}"
REMOTE_DB_PREFIX="${G7_SEARCH_AB_DB_PREFIX:-g7_}"
BASE_URL="${G7_SEARCH_AB_BASE_URL:-https://g7-benchmark.test}"
BASELINE_REF="${G7_SEARCH_AB_BASELINE_REF:-7.0.5}"
OPTIMIZED_REF="${G7_SEARCH_AB_OPTIMIZED_REF:-HEAD}"
BOARD_SLUG="${G7_SEARCH_AB_BOARD_SLUG:-freebd}"
REPEATS="${G7_SEARCH_AB_REPEATS:-3}"
REQUEST_TIMEOUT_SECONDS="${G7_SEARCH_AB_REQUEST_TIMEOUT_SECONDS:-30}"
SAMPLE_INTERVAL_SECONDS="${G7_SEARCH_AB_SAMPLE_INTERVAL_SECONDS:-1}"
GLOBAL_SEARCH="${G7_SEARCH_AB_GLOBAL_SEARCH:-운영}"
BOARD_SEARCH="${G7_SEARCH_AB_BOARD_SEARCH:-운영}"
SHOP_SEARCH="${G7_SEARCH_AB_SHOP_SEARCH:-노트북 파우치}"
OUTPUT_DIR="${G7_SEARCH_AB_OUTPUT_DIR:-}"

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/g7-search-ab-benchmark.sh [options]

Measures the same integrated, board, and shop searches in three phases:
  official 7.0.5 + MySQL
  tuned 7.0.5 + MySQL
  tuned 7.0.5 + Manticore

The finalizer always restores tuning ON and the Manticore connection. It does
not uninstall Manticore or delete its indexes.

Options:
  --repeats N             Requests per route and phase. Default: 3.
  --request-timeout SEC   Per-request timeout. Default: 30.
  --sample-interval SEC   Remote resource interval. Default: 1.
  --global-search TERM    Integrated-search term. Default: 운영.
  --board-search TERM     Board-search term. Default: 운영.
  --shop-search TERM      Shop-search term. Default: 노트북 파우치.
  --board-slug SLUG       Public board. Default: freebd.
  --host HOST             SSH host/IP. Default: g7-benchmark.
  --root PATH             Remote G7 root.
  --app-user USER         Remote application user.
  --db NAME               Remote database name.
  --db-prefix PREFIX      Remote database prefix.
  --base-url URL          HTTP origin.
  --baseline REF          Official baseline ref. Default: 7.0.5.
  --optimized-ref REF     Reviewed optimized ref. Default: HEAD.
  --output-dir PATH       Report directory.
  -h, --help              Show this help.
EOF
}

log() { printf '[g7-search-ab] %s\n' "$*" >&2; }
fail() { printf '[g7-search-ab] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeats) shift; REPEATS="${1:-}" ;;
        --request-timeout) shift; REQUEST_TIMEOUT_SECONDS="${1:-}" ;;
        --sample-interval) shift; SAMPLE_INTERVAL_SECONDS="${1:-}" ;;
        --global-search) shift; GLOBAL_SEARCH="${1:-}" ;;
        --board-search) shift; BOARD_SEARCH="${1:-}" ;;
        --shop-search) shift; SHOP_SEARCH="${1:-}" ;;
        --board-slug) shift; BOARD_SLUG="${1:-}" ;;
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --app-user) shift; REMOTE_APP_USER="${1:-}" ;;
        --db) shift; REMOTE_DB_NAME="${1:-}" ;;
        --db-prefix) shift; REMOTE_DB_PREFIX="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        --baseline) shift; BASELINE_REF="${1:-}" ;;
        --optimized-ref) shift; OPTIMIZED_REF="${1:-}" ;;
        --output-dir) shift; OUTPUT_DIR="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[[ "${REPEATS}" =~ ^[0-9]+$ && "${REPEATS}" -ge 1 && "${REPEATS}" -le 10 ]] \
    || fail '--repeats must be between 1 and 10'
[[ "${REQUEST_TIMEOUT_SECONDS}" =~ ^[0-9]+$ \
    && "${REQUEST_TIMEOUT_SECONDS}" -ge 5 && "${REQUEST_TIMEOUT_SECONDS}" -le 120 ]] \
    || fail '--request-timeout must be between 5 and 120 seconds'
[[ "${SAMPLE_INTERVAL_SECONDS}" =~ ^[0-9]+$ \
    && "${SAMPLE_INTERVAL_SECONDS}" -ge 1 && "${SAMPLE_INTERVAL_SECONDS}" -le 10 ]] \
    || fail '--sample-interval must be between 1 and 10 seconds'
[[ "${REMOTE_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || fail 'invalid database name'
[[ "${REMOTE_DB_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]] || fail 'invalid database prefix'
[[ -n "${GLOBAL_SEARCH}" && -n "${BOARD_SEARCH}" && -n "${SHOP_SEARCH}" ]] \
    || fail 'search terms must not be empty'
[[ -x "${PERFORMANCE_TOGGLE}" && -x "${SEARCH_TOGGLE}" ]] || fail 'toggle harness is missing'
for command in "${SSH_BIN}" "${CURL_BIN}" "${JQ_BIN}" git awk; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command not found: ${command}"
done

BASE_URL="${BASE_URL%/}"
OPTIMIZED_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --verify "${OPTIMIZED_REF}^{commit}")" \
    || fail "optimized ref is not a commit: ${OPTIMIZED_REF}"
if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/storage/app/benchmark/reports/search-ab-$(date '+%Y%m%d-%H%M%S')"
elif [[ "${OUTPUT_DIR}" != /* ]]; then
    OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}"
fi
[[ ! -e "${OUTPUT_DIR}" ]] || fail "output directory already exists: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/resources" "${OUTPUT_DIR}/responses"
REQUESTS_JSONL="${OUTPUT_DIR}/requests.jsonl"
RESOURCES_JSONL="${OUTPUT_DIR}/resources.jsonl"
: > "${REQUESTS_JSONL}"
: > "${RESOURCES_JSONL}"

SSH_OPTIONS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
)
PERF_ARGS=(
    --scope all
    --host "${REMOTE_HOST}"
    --root "${REMOTE_ROOT}"
    --app-user "${REMOTE_APP_USER}"
    --db "${REMOTE_DB_NAME}"
    --db-prefix "${REMOTE_DB_PREFIX}"
    --base-url "${BASE_URL}"
    --baseline "${BASELINE_REF}"
    --optimized-ref "${OPTIMIZED_COMMIT}"
    --board-slug "${BOARD_SLUG}"
)
SEARCH_ARGS=(
    --host "${REMOTE_HOST}"
    --root "${REMOTE_ROOT}"
    --app-user "${REMOTE_APP_USER}"
    --base-url "${BASE_URL}"
)

FINALIZED=0
SAMPLER_PID=''
REMOTE_STOP_FILE=''

stop_sampler() {
    local result=0
    [[ -n "${SAMPLER_PID}" ]] || return 0
    "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo touch "${REMOTE_STOP_FILE}" \
        >/dev/null 2>&1 || result=1
    wait "${SAMPLER_PID}" || result=1
    SAMPLER_PID=''
    REMOTE_STOP_FILE=''
    return "${result}"
}

restore_final_state() {
    local result=0
    [[ "${FINALIZED}" == 0 ]] || return 0
    set +e
    stop_sampler || result=1
    "${PERFORMANCE_TOGGLE}" on "${PERF_ARGS[@]}" || {
        "${PERFORMANCE_TOGGLE}" on "${PERF_ARGS[@]}" --recover-fail-closed || result=1
    }
    "${SEARCH_TOGGLE}" manticore "${SEARCH_ARGS[@]}" || result=1
    set -e
    if [[ "${result}" == 0 ]]; then
        FINALIZED=1
        log 'final state: tuned + Manticore'
    else
        log 'FINAL FAILURE: tuned + Manticore restore did not fully verify'
    fi
    return "${result}"
}

cleanup() {
    local original_exit=$?
    trap - EXIT INT TERM
    restore_final_state || original_exit=1
    exit "${original_exit}"
}
trap cleanup EXIT INT TERM

prepare_services() {
    "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${BASE_URL}" "${BOARD_SLUG}" <<'REMOTE'
set -euo pipefail
app_root="$1"
base_url="$2"
board_slug="$3"
systemctl restart mysql
systemctl restart manticore
php_fpm_unit="$(systemctl list-units --type=service --all --no-legend 'php*-fpm.service' \
    | awk 'NR == 1 { print $1 }')"
[[ -n "${php_fpm_unit}" ]] && systemctl restart "${php_fpm_unit}"
deadline=$((SECONDS + 30))
until mysqladmin ping --silent >/dev/null 2>&1; do
    (( SECONDS < deadline )) || exit 1
    sleep 1
done
systemctl is-active --quiet manticore
curl --fail --silent --show-error --insecure --max-time 15 "${base_url}/" >/dev/null
curl --fail --silent --show-error --insecure --max-time 15 \
    "${base_url}/api/modules/sirsoft-board/boards/${board_slug}/posts?page=1&per_page=20" >/dev/null
REMOTE
}

start_sampler() {
    local phase="$1" output_file
    output_file="${OUTPUT_DIR}/resources/${phase}.csv"
    REMOTE_STOP_FILE="/tmp/g7-search-ab-$$-${phase}.stop"
    "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_STOP_FILE}" "${SAMPLE_INTERVAL_SECONDS}" \
        > "${output_file}" 2> "${OUTPUT_DIR}/resources/${phase}.log" <<'REMOTE' &
set -euo pipefail
stop_file="$1"
interval="$2"
rm -f -- "${stop_file}"
trap 'rm -f -- "${stop_file}"' EXIT

read_host() {
    local label user nice system idle iowait irq softirq steal guest guest_nice
    read -r label user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    HOST_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
    HOST_IDLE=$((idle + iowait))
}

read_processes() {
    local proc_dir comm stat_line stat_tail rss
    local -a fields
    PHP_TICKS=0; MYSQL_TICKS=0; SEARCHD_TICKS=0
    PHP_RSS_KB=0; MYSQL_RSS_KB=0; SEARCHD_RSS_KB=0
    for proc_dir in /proc/[0-9]*; do
        [[ -r "${proc_dir}/comm" && -r "${proc_dir}/stat" ]] || continue
        read -r comm < "${proc_dir}/comm" || continue
        case "${comm}" in
            php-fpm*|mysqld|mariadbd|searchd) ;;
            *) continue ;;
        esac
        stat_line="$(<"${proc_dir}/stat")" || continue
        stat_tail="${stat_line#*) }"
        read -r -a fields <<<"${stat_tail}"
        [[ ${#fields[@]} -gt 12 ]] || continue
        rss="$(awk '$1 == "VmRSS:" { print $2; exit }' "${proc_dir}/status" 2>/dev/null || true)"
        [[ "${rss}" =~ ^[0-9]+$ ]] || rss=0
        case "${comm}" in
            php-fpm*)
                PHP_TICKS=$((PHP_TICKS + fields[11] + fields[12]))
                PHP_RSS_KB=$((PHP_RSS_KB + rss))
                ;;
            mysqld|mariadbd)
                MYSQL_TICKS=$((MYSQL_TICKS + fields[11] + fields[12]))
                MYSQL_RSS_KB=$((MYSQL_RSS_KB + rss))
                ;;
            searchd)
                SEARCHD_TICKS=$((SEARCHD_TICKS + fields[11] + fields[12]))
                SEARCHD_RSS_KB=$((SEARCHD_RSS_KB + rss))
                ;;
        esac
    done
}

read_memory() {
    local available total free
    available="$(awk '$1 == "MemAvailable:" { print $2; exit }' /proc/meminfo)"
    total="$(awk '$1 == "SwapTotal:" { print $2; exit }' /proc/meminfo)"
    free="$(awk '$1 == "SwapFree:" { print $2; exit }' /proc/meminfo)"
    MEM_AVAILABLE_MB=$((available / 1024))
    SWAP_USED_MB=$(((total - free) / 1024))
    read -r LOAD1 _ < /proc/loadavg
}

read_host
read_processes
previous_total="${HOST_TOTAL}"
previous_idle="${HOST_IDLE}"
previous_php="${PHP_TICKS}"
previous_mysql="${MYSQL_TICKS}"
previous_searchd="${SEARCHD_TICKS}"
started="${SECONDS}"
sample=0
printf 'sample,elapsed_seconds,timestamp,cpu_count,host_busy_pct,php_cpu_host_pct,mysql_cpu_host_pct,searchd_cpu_host_pct,load1,mem_available_mb,swap_used_mb,php_rss_mb,mysql_rss_mb,searchd_rss_mb\n'
while [[ ! -e "${stop_file}" ]]; do
    sleep "${interval}"
    read_host
    read_processes
    read_memory
    total_delta=$((HOST_TOTAL - previous_total))
    idle_delta=$((HOST_IDLE - previous_idle))
    php_delta=$((PHP_TICKS - previous_php))
    mysql_delta=$((MYSQL_TICKS - previous_mysql))
    searchd_delta=$((SEARCHD_TICKS - previous_searchd))
    (( php_delta >= 0 )) || php_delta=0
    (( mysql_delta >= 0 )) || mysql_delta=0
    (( searchd_delta >= 0 )) || searchd_delta=0
    if (( total_delta > 0 )); then
        host_busy="$(awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN { printf "%.3f", (total-idle)*100/total }')"
        php_cpu="$(awk -v ticks="${php_delta}" -v total="${total_delta}" 'BEGIN { printf "%.3f", ticks*100/total }')"
        mysql_cpu="$(awk -v ticks="${mysql_delta}" -v total="${total_delta}" 'BEGIN { printf "%.3f", ticks*100/total }')"
        searchd_cpu="$(awk -v ticks="${searchd_delta}" -v total="${total_delta}" 'BEGIN { printf "%.3f", ticks*100/total }')"
        sample=$((sample + 1))
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.3f,%.3f,%.3f\n' \
            "${sample}" "$((SECONDS - started))" "$(date --iso-8601=seconds)" \
            "$(getconf _NPROCESSORS_ONLN)" "${host_busy}" "${php_cpu}" "${mysql_cpu}" \
            "${searchd_cpu}" "${LOAD1}" "${MEM_AVAILABLE_MB}" "${SWAP_USED_MB}" \
            "$(awk -v kb="${PHP_RSS_KB}" 'BEGIN { print kb/1024 }')" \
            "$(awk -v kb="${MYSQL_RSS_KB}" 'BEGIN { print kb/1024 }')" \
            "$(awk -v kb="${SEARCHD_RSS_KB}" 'BEGIN { print kb/1024 }')"
    fi
    previous_total="${HOST_TOTAL}"
    previous_idle="${HOST_IDLE}"
    previous_php="${PHP_TICKS}"
    previous_mysql="${MYSQL_TICKS}"
    previous_searchd="${SEARCHD_TICKS}"
done
REMOTE
    SAMPLER_PID=$!
    local ready=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -s "${output_file}" ]]; then ready=1; break; fi
        sleep 0.2
    done
    [[ "${ready}" == 1 ]] || fail "resource sampler did not start for ${phase}"
}

summarize_resources() {
    local phase="$1" file
    file="${OUTPUT_DIR}/resources/${phase}.csv"
    awk -F, -v phase="${phase}" '
        NR == 1 { next }
        {
            n++
            host_sum += $5; php_cpu_sum += $6; mysql_cpu_sum += $7; searchd_cpu_sum += $8
            if (n == 1 || $5 > host_max) host_max=$5
            if (n == 1 || $6 > php_cpu_max) php_cpu_max=$6
            if (n == 1 || $7 > mysql_cpu_max) mysql_cpu_max=$7
            if (n == 1 || $8 > searchd_cpu_max) searchd_cpu_max=$8
            if (n == 1 || $10 < mem_min) mem_min=$10
            if (n == 1 || $11 > swap_max) swap_max=$11
            if (n == 1) { php_rss_first=$12; mysql_rss_first=$13; searchd_rss_first=$14 }
            if (n == 1 || $12 > php_rss_max) php_rss_max=$12
            if (n == 1 || $13 > mysql_rss_max) mysql_rss_max=$13
            if (n == 1 || $14 > searchd_rss_max) searchd_rss_max=$14
        }
        END {
            if (n < 2) exit 1
            printf "{\"phase\":\"%s\",\"samples\":%d,", phase, n
            printf "\"host_cpu_avg_pct\":%.3f,\"host_cpu_max_pct\":%.3f,", host_sum/n, host_max
            printf "\"php_cpu_avg_pct\":%.3f,\"php_cpu_max_pct\":%.3f,", php_cpu_sum/n, php_cpu_max
            printf "\"mysql_cpu_avg_pct\":%.3f,\"mysql_cpu_max_pct\":%.3f,", mysql_cpu_sum/n, mysql_cpu_max
            printf "\"searchd_cpu_avg_pct\":%.3f,\"searchd_cpu_max_pct\":%.3f,", searchd_cpu_sum/n, searchd_cpu_max
            printf "\"mem_available_min_mb\":%.0f,\"swap_used_max_mb\":%.0f,", mem_min, swap_max
            printf "\"php_rss_first_mb\":%.3f,\"php_rss_max_mb\":%.3f,", php_rss_first, php_rss_max
            printf "\"mysql_rss_first_mb\":%.3f,\"mysql_rss_max_mb\":%.3f,", mysql_rss_first, mysql_rss_max
            printf "\"searchd_rss_first_mb\":%.3f,\"searchd_rss_max_mb\":%.3f}", searchd_rss_first, searchd_rss_max
        }
    ' "${file}" >> "${RESOURCES_JSONL}"
    printf '\n' >> "${RESOURCES_JSONL}"
}

urlencode() {
    "${JQ_BIN}" -nr --arg value "$1" '$value|@uri'
}

run_request() {
    local phase="$1" run="$2" route="$3" path="$4"
    local body="${OUTPUT_DIR}/responses/${phase}-${run}-${route}.json"
    local stats curl_exit=0 http_code seconds bytes valid=false complete=false total=null error=''
    local result_meta='{}'
    set +e
    stats="$("${CURL_BIN}" --silent --show-error --insecure \
        --max-time "${REQUEST_TIMEOUT_SECONDS}" --output "${body}" \
        --write-out $'%{http_code}\t%{time_total}\t%{size_download}' \
        "${BASE_URL}${path}")"
    curl_exit=$?
    set -e
    IFS=$'\t' read -r http_code seconds bytes <<<"${stats}"
    http_code="${http_code:-0}"
    http_code=$((10#${http_code}))
    seconds="${seconds:-${REQUEST_TIMEOUT_SECONDS}}"
    bytes="${bytes:-0}"
    if [[ "${curl_exit}" != 0 ]]; then
        error="curl-${curl_exit}"
    elif [[ "${http_code}" != 200 ]]; then
        error="http-${http_code}"
    else
        case "${route}" in
            integrated)
                if "${JQ_BIN}" -e --arg q "${GLOBAL_SEARCH}" \
                    '.success == true and .data.q == $q' \
                    "${body}" >/dev/null 2>&1; then
                    total="$("${JQ_BIN}" -r '.data.total' "${body}")"
                    result_meta="$("${JQ_BIN}" -c '{
                        posts_present:(.data|has("posts")),
                        posts_total:(.data.posts.total // 0),
                        posts_total_is_exact:(.data.posts.total_is_exact // false),
                        posts_total_relation:(.data.posts.total_relation // "unknown"),
                        search_truncated:(if (.data.posts|has("search_truncated"))
                                          then .data.posts.search_truncated else true end)
                    }' "${body}")"
                    valid="$("${JQ_BIN}" -r '(.data.posts.total // 0) > 0' "${body}")"
                    complete="$("${JQ_BIN}" -r '.data.posts.total_is_exact == true' "${body}")"
                fi
                ;;
            board)
                if "${JQ_BIN}" -e \
                    '.success == true and .data.pagination.current_page == 1 and (.data.data | type == "array")' \
                    "${body}" >/dev/null 2>&1; then
                    valid=true
                    total="$("${JQ_BIN}" -r '.data.pagination.total' "${body}")"
                    result_meta="$("${JQ_BIN}" -c '{
                        total_is_exact:(if (.data.pagination|has("total_is_exact")) then .data.pagination.total_is_exact else true end),
                        total_relation:(.data.pagination.total_relation // "eq"),
                        result_cap:(.data.pagination.result_cap // null),
                        search_truncated:(.data.pagination.search_truncated // false)
                    }' "${body}")"
                    complete="$("${JQ_BIN}" -r '
                        (if (.data.pagination|has("total_is_exact"))
                         then .data.pagination.total_is_exact else true end) == true
                    ' "${body}")"
                fi
                ;;
            shop)
                if "${JQ_BIN}" -e \
                    '.success == true and .data.pagination.current_page == 1 and (.data.data | type == "array")' \
                    "${body}" >/dev/null 2>&1; then
                    valid=true
                    total="$("${JQ_BIN}" -r '.data.pagination.total' "${body}")"
                    result_meta='{"total_is_exact":true,"total_relation":"eq","search_truncated":false}'
                    complete=true
                fi
                ;;
        esac
        [[ "${valid}" == true ]] || error='semantic-validation'
    fi
    "${JQ_BIN}" -nc \
        --arg phase "${phase}" --arg route "${route}" --arg path "${path}" \
        --argjson run "${run}" --argjson http_code "${http_code}" \
        --argjson seconds "${seconds}" --argjson bytes "${bytes}" \
        --argjson valid "${valid}" --argjson complete "${complete}" \
        --argjson total "${total}" --argjson result_meta "${result_meta}" --arg error "${error}" \
        '{phase:$phase,run:$run,route:$route,path:$path,http_code:$http_code,
          seconds:$seconds,bytes:$bytes,valid:$valid,complete:$complete,total:$total,
          result_meta:$result_meta,
          error:(if $error == "" then null else $error end)}' >> "${REQUESTS_JSONL}"
    log "${phase} run=${run} route=${route} status=${http_code} seconds=${seconds} valid=${valid} complete=${complete} total=${total}"
}

run_phase() {
    local phase="$1" run
    case "${phase}" in
        baseline_mysql)
            log 'phase baseline_mysql: official 7.0.5 + MySQL'
            "${PERFORMANCE_TOGGLE}" off "${PERF_ARGS[@]}"
            "${SEARCH_TOGGLE}" mysql "${SEARCH_ARGS[@]}"
            ;;
        tuned_mysql)
            log 'phase tuned_mysql: tuned 7.0.5 + MySQL'
            "${PERFORMANCE_TOGGLE}" on "${PERF_ARGS[@]}"
            "${SEARCH_TOGGLE}" mysql "${SEARCH_ARGS[@]}"
            ;;
        tuned_manticore)
            log 'phase tuned_manticore: tuned 7.0.5 + Manticore'
            "${PERFORMANCE_TOGGLE}" on "${PERF_ARGS[@]}"
            "${SEARCH_TOGGLE}" manticore "${SEARCH_ARGS[@]}"
            ;;
        *) fail "unknown phase: ${phase}" ;;
    esac
    prepare_services
    start_sampler "${phase}"
    sleep 2
    for ((run = 1; run <= REPEATS; run++)); do
        run_request "${phase}" "${run}" integrated \
            "/api/search?q=$(urlencode "${GLOBAL_SEARCH}")&type=all&page=1&per_page=10"
        run_request "${phase}" "${run}" board \
            "/api/modules/sirsoft-board/boards/$(urlencode "${BOARD_SLUG}")/posts?search=$(urlencode "${BOARD_SEARCH}")&search_field=all&page=1&per_page=20"
        run_request "${phase}" "${run}" shop \
            "/api/modules/sirsoft-ecommerce/products?search=$(urlencode "${SHOP_SEARCH}")&page=1&per_page=12"
    done
    sleep 2
    stop_sampler || fail "resource sampler failed for ${phase}"
    summarize_resources "${phase}"
}

generate_report() {
    local report_json="${OUTPUT_DIR}/comparison.json"
    local report_md="${OUTPUT_DIR}/comparison.md"
    "${JQ_BIN}" -s \
        --slurpfile resources "${RESOURCES_JSONL}" \
        --arg completed_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        --arg base_url "${BASE_URL}" --arg baseline_ref "${BASELINE_REF}" \
        --arg optimized_commit "${OPTIMIZED_COMMIT}" \
        --arg global_search "${GLOBAL_SEARCH}" --arg board_search "${BOARD_SEARCH}" \
        --arg shop_search "${SHOP_SEARCH}" --argjson repeats "${REPEATS}" '
        def median:
            sort | length as $n
            | if $n == 0 then null
              elif ($n % 2) == 1 then .[($n / 2 | floor)]
              else ((.[($n / 2) - 1] + .[$n / 2]) / 2)
              end;
        . as $requests
        | ["baseline_mysql", "tuned_mysql", "tuned_manticore"] as $phases
        | ["integrated", "board", "shop"] as $routes
        | {
            metadata: {
                completed_at: $completed_at,
                base_url: $base_url,
                baseline_ref: $baseline_ref,
                optimized_commit: $optimized_commit,
                repeats: $repeats,
                final_state: "tuned_manticore",
                manticore_preserved: true,
                search_terms: {integrated:$global_search, board:$board_search, shop:$shop_search}
            },
            results: [
                $phases[] as $phase | $routes[] as $route
                | [$requests[] | select(.phase == $phase and .route == $route)] as $items
                | {
                    phase:$phase,
                    route:$route,
                    requests:($items|length),
                    valid:(($items|length) == $repeats and all($items[]; .valid == true)),
                    complete:(($items|length) == $repeats and all($items[]; .complete == true)),
                    median_ms:([$items[].seconds * 1000] | median),
                    max_ms:([$items[].seconds * 1000] | max),
                    totals:([$items[].total] | unique),
                    result_meta:([$items[].result_meta] | unique),
                    errors:([$items[].error] | map(select(. != null)))
                }
            ],
            resources:$resources,
            requests:$requests
        }
    ' "${REQUESTS_JSONL}" > "${report_json}"

    {
        printf '# 그누보드7 검색 백엔드 A/B/C 벤치마크\n\n'
        printf -- '- 대상: `%s`\n' "${BASE_URL}"
        printf -- '- 데이터: 동일 복제 DB, 상태별 경로당 %s회\n' "${REPEATS}"
        printf -- '- 최종 상태: 튜닝 ON + Manticore 연결, 패키지·인덱스 유지\n\n'
        printf '## 응답시간\n\n'
        printf '| 상태 | 검색 | 중앙값(ms) | 최대(ms) | 응답 검증 | 결과 완전성 | 결과 수 |\n'
        printf '|---|---|---:|---:|---:|---:|---:|\n'
        "${JQ_BIN}" -r '.results[] | [
            .phase, .route, (.median_ms|round), (.max_ms|round), .valid, .complete,
            (.totals|map(tostring)|join("/"))
        ] | "| " + join(" | ") + " |"' "${report_json}"
        printf '\n## 서버 자원\n\n'
        printf '| 상태 | CPU 평균/최대(%%) | 가용 메모리 최소(MB) | MySQL RSS 처음/최대(MB) | searchd RSS 처음/최대(MB) | Swap 최대(MB) |\n'
        printf '|---|---:|---:|---:|---:|---:|\n'
        "${JQ_BIN}" -r '.resources[] | [
            .phase,
            ((.host_cpu_avg_pct|tostring) + "/" + (.host_cpu_max_pct|tostring)),
            (.mem_available_min_mb|tostring),
            ((.mysql_rss_first_mb|tostring) + "/" + (.mysql_rss_max_mb|tostring)),
            ((.searchd_rss_first_mb|tostring) + "/" + (.searchd_rss_max_mb|tostring)),
            (.swap_used_max_mb|tostring)
        ] | "| " + join(" | ") + " |"' "${report_json}"
    } > "${report_md}"
    log "JSON: ${report_json}"
    log "Markdown: ${report_md}"
}

log "reports: ${OUTPUT_DIR}"
run_phase baseline_mysql
run_phase tuned_mysql
run_phase tuned_manticore
"${PERFORMANCE_TOGGLE}" status "${PERF_ARGS[@]}" --strict
search_status="$("${SEARCH_TOGGLE}" status "${SEARCH_ARGS[@]}")"
[[ "${search_status}" == driver=manticore$'\n'* || "${search_status}" == driver=manticore ]]
FINALIZED=1
generate_report
