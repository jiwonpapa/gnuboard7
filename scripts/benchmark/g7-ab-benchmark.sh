#!/usr/bin/env bash

# shellcheck disable=SC2016,SC2329

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

TOGGLE_SCRIPT="${G7_AB_TOGGLE_SCRIPT:-${SCRIPT_DIR}/g7-performance-toggle.sh}"
K6_SCRIPT="${G7_AB_K6_SCRIPT:-${REPO_ROOT}/modules/_bundled/sirsoft-benchmark/tests/k6/g7-entry-routes.js}"
SSH_BIN="${G7_AB_SSH_BIN:-ssh}"
CURL_BIN="${G7_AB_CURL_BIN:-curl}"
JQ_BIN="${G7_AB_JQ_BIN:-jq}"
K6_BIN="${G7_AB_K6_BIN:-k6}"

REMOTE_HOST="${G7_PERF_HOST:-g7devops}"
REMOTE_ROOT="${G7_PERF_ROOT:-/home/g7devops/public_html}"
REMOTE_APP_USER="${G7_PERF_APP_USER:-g7devops}"
REMOTE_PHP_BIN="${G7_PERF_PHP_BIN:-php}"
REMOTE_DB_NAME="${G7_PERF_DB_NAME:-g7devops}"
REMOTE_DB_PREFIX="${G7_PERF_DB_PREFIX:-g7_}"
BASELINE_REF="${G7_PERF_BASELINE_REF:-7.0.4}"
OPTIMIZED_REF="${G7_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_PERF_BASE_URL:-https://www.g7devops.com}"
DRAIN_TIMEOUT="${G7_PERF_DRAIN_TIMEOUT:-930}"

REPEATS="${G7_AB_REPEATS:-3}"
HOT_VUS="${G7_AB_HOT_VUS:-10}"
HOT_ARRIVAL_RATE="${G7_AB_HOT_ARRIVAL_RATE:-1}"
HOT_DURATION_SECONDS="${G7_AB_HOT_DURATION_SECONDS:-30}"
REQUEST_TIMEOUT_SECONDS="${G7_AB_REQUEST_TIMEOUT_SECONDS:-20}"
BOARD_SLUG="${G7_AB_BOARD_SLUG:-freebd}"
DEEP_PAGE="${G7_AB_DEEP_PAGE:-59999}"
BOARD_SEARCH="${G7_AB_BOARD_SEARCH:-}"
GLOBAL_SEARCH="${G7_AB_GLOBAL_SEARCH:-}"
SHOP_SEARCH="${G7_AB_SHOP_SEARCH:-러닝화}"
POST_ID="${G7_AB_POST_ID:-}"
PRODUCT_ID="${G7_AB_PRODUCT_ID:-}"
STATEMENT_TIMEOUT_MS="${G7_AB_STATEMENT_TIMEOUT_MS:-15000}"
IDLE_TIMEOUT_SECONDS="${G7_AB_IDLE_TIMEOUT_SECONDS:-60}"
CPU_INTERVAL_SECONDS="${G7_AB_CPU_INTERVAL_SECONDS:-1}"
CPU_MAX_SECONDS="${G7_AB_CPU_MAX_SECONDS:-180}"
MEASUREMENT_WINDOW_SECONDS="${G7_AB_MEASUREMENT_WINDOW_SECONDS:-}"
OUTPUT_DIR="${G7_AB_OUTPUT_DIR:-}"

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/g7-ab-benchmark.sh [options]

Runs a safe before/after benchmark and always finishes by confirming tuning ON.

Sequence:
  OFF all + strict baseline check
  baseline route matrix + remote CPU sampling
  ON all at an immutable commit + strict optimized check
  optimized route matrix + remote CPU sampling
  Markdown, JSON, and CSV comparison reports

Benchmark options:
  --repeats N              Identical runs per phase. Default: 3.
  --hot-vus N              Preallocated/max VUs for ordinary routes. Default: 10.
  --hot-rate N             Fixed ordinary matrices per second. Default: 1.
  --hot-duration SEC       Ordinary-route load duration. Default: 30.
  --request-timeout SEC    Per-request k6 timeout. Default: 20.
  --board-slug SLUG        Public board slug. Default: freebd.
  --deep-page N            Single-VU deep page. Default: 59999.
  --board-search TERM      Single-VU board search; otherwise discover from a public post.
  --global-search TERM     Single-VU global search; otherwise reuse the discovered board term.
  --shop-search TERM       Shop list search. Default: 러닝화.
  --post-id ID             Fixed public post ID; otherwise discover it once.
  --product-id ID          Fixed public product ID; otherwise discover it once.
  --statement-timeout MS   Temporary global SELECT cap. Default: 15000.
  --idle-timeout SEC       Wait for SELECT/transaction drain. Default: 60.
  --cpu-interval SEC       /proc sampling interval. Default: 1.
  --cpu-max-seconds SEC    Remote sampler safety limit. Default: 180.
  --measurement-window SEC Fixed CPU window; default: hot-duration + 75.
  --output-dir PATH        Report directory.

Deployment options:
  --host HOST              SSH alias. Default: g7devops.
  --root PATH              Remote app root.
  --app-user USER          Remote application user.
  --php-bin BIN            Remote PHP binary.
  --db NAME                Remote database name.
  --db-prefix PREFIX       Remote database prefix.
  --base-url URL           Public origin.
  --baseline REF           Official baseline ref. Default: 7.0.4.
  --optimized-ref REF      Reviewed optimized ref; resolved to a commit SHA.
  --drain-timeout SEC      Runtime drain timeout. Default: 930.
  -h, --help               Show this help.

The deep page, board search, and global search run exactly once with one VU.
No benchmark query is killed automatically. The runner waits for DB idle state.
EOF
}

log() { printf '[g7-ab] %s\n' "$*" >&2; }
fail() { printf '[g7-ab] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeats) shift; REPEATS="${1:-}" ;;
        --hot-vus) shift; HOT_VUS="${1:-}" ;;
        --hot-rate) shift; HOT_ARRIVAL_RATE="${1:-}" ;;
        --hot-duration) shift; HOT_DURATION_SECONDS="${1:-}" ;;
        --request-timeout) shift; REQUEST_TIMEOUT_SECONDS="${1:-}" ;;
        --board-slug) shift; BOARD_SLUG="${1:-}" ;;
        --deep-page) shift; DEEP_PAGE="${1:-}" ;;
        --board-search) shift; BOARD_SEARCH="${1:-}" ;;
        --global-search) shift; GLOBAL_SEARCH="${1:-}" ;;
        --shop-search) shift; SHOP_SEARCH="${1:-}" ;;
        --post-id) shift; POST_ID="${1:-}" ;;
        --product-id) shift; PRODUCT_ID="${1:-}" ;;
        --statement-timeout) shift; STATEMENT_TIMEOUT_MS="${1:-}" ;;
        --idle-timeout) shift; IDLE_TIMEOUT_SECONDS="${1:-}" ;;
        --cpu-interval) shift; CPU_INTERVAL_SECONDS="${1:-}" ;;
        --cpu-max-seconds) shift; CPU_MAX_SECONDS="${1:-}" ;;
        --measurement-window) shift; MEASUREMENT_WINDOW_SECONDS="${1:-}" ;;
        --output-dir) shift; OUTPUT_DIR="${1:-}" ;;
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --app-user) shift; REMOTE_APP_USER="${1:-}" ;;
        --php-bin) shift; REMOTE_PHP_BIN="${1:-}" ;;
        --db) shift; REMOTE_DB_NAME="${1:-}" ;;
        --db-prefix) shift; REMOTE_DB_PREFIX="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        --baseline) shift; BASELINE_REF="${1:-}" ;;
        --optimized-ref) shift; OPTIMIZED_REF="${1:-}" ;;
        --drain-timeout) shift; DRAIN_TIMEOUT="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[[ "${REPEATS}" =~ ^[0-9]+$ && "${REPEATS}" -ge 1 && "${REPEATS}" -le 10 ]] \
    || fail '--repeats must be between 1 and 10'
[[ "${HOT_VUS}" =~ ^[0-9]+$ && "${HOT_VUS}" -ge 1 && "${HOT_VUS}" -le 50 ]] \
    || fail '--hot-vus must be between 1 and 50'
[[ "${HOT_ARRIVAL_RATE}" =~ ^[0-9]+$ && "${HOT_ARRIVAL_RATE}" -ge 1 && "${HOT_ARRIVAL_RATE}" -le 10 ]] \
    || fail '--hot-rate must be between 1 and 10 matrices per second'
[[ "${HOT_DURATION_SECONDS}" =~ ^[0-9]+$ && "${HOT_DURATION_SECONDS}" -ge 5 && "${HOT_DURATION_SECONDS}" -le 300 ]] \
    || fail '--hot-duration must be between 5 and 300 seconds'
[[ "${REQUEST_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${REQUEST_TIMEOUT_SECONDS}" -ge 5 && "${REQUEST_TIMEOUT_SECONDS}" -le 60 ]] \
    || fail '--request-timeout must be between 5 and 60 seconds'
[[ "${DEEP_PAGE}" =~ ^[0-9]+$ && "${DEEP_PAGE}" -ge 2 ]] \
    || fail '--deep-page must be an integer greater than 1'
[[ "${STATEMENT_TIMEOUT_MS}" =~ ^[0-9]+$ && "${STATEMENT_TIMEOUT_MS}" -ge 1000 && "${STATEMENT_TIMEOUT_MS}" -le 30000 ]] \
    || fail '--statement-timeout must be between 1000 and 30000 milliseconds'
[[ "${IDLE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${IDLE_TIMEOUT_SECONDS}" -ge 15 && "${IDLE_TIMEOUT_SECONDS}" -le 300 ]] \
    || fail '--idle-timeout must be between 15 and 300 seconds'
[[ "${CPU_INTERVAL_SECONDS}" =~ ^[0-9]+$ && "${CPU_INTERVAL_SECONDS}" -ge 1 && "${CPU_INTERVAL_SECONDS}" -le 10 ]] \
    || fail '--cpu-interval must be between 1 and 10 seconds'
[[ "${CPU_MAX_SECONDS}" =~ ^[0-9]+$ && "${CPU_MAX_SECONDS}" -ge 60 && "${CPU_MAX_SECONDS}" -le 900 ]] \
    || fail '--cpu-max-seconds must be between 60 and 900 seconds'
if [[ -z "${MEASUREMENT_WINDOW_SECONDS}" ]]; then
    MEASUREMENT_WINDOW_SECONDS=$((HOT_DURATION_SECONDS + 75))
fi
[[ "${MEASUREMENT_WINDOW_SECONDS}" =~ ^[0-9]+$ \
    && "${MEASUREMENT_WINDOW_SECONDS}" -ge $((HOT_DURATION_SECONDS + 75)) \
    && "${MEASUREMENT_WINDOW_SECONDS}" -le 900 ]] \
    || fail '--measurement-window must be between hot-duration + 75 and 900 seconds'
[[ "${CPU_MAX_SECONDS}" -ge "${MEASUREMENT_WINDOW_SECONDS}" ]] \
    || fail '--cpu-max-seconds must be at least measurement-window seconds'
board_requests_per_minute=$((HOT_ARRIVAL_RATE * 8 * 60 + 2))
[[ "${board_requests_per_minute}" -le 600 ]] \
    || fail '--hot-rate would exceed the shared board throttle (600 requests/minute)'
[[ "${DRAIN_TIMEOUT}" =~ ^[0-9]+$ && "${DRAIN_TIMEOUT}" -ge 30 && "${DRAIN_TIMEOUT}" -le 3600 ]] \
    || fail '--drain-timeout must be between 30 and 3600 seconds'
[[ "${REMOTE_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || fail 'database name contains unsupported characters'
[[ "${REMOTE_DB_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]] || fail 'database prefix contains unsupported characters'
[[ -n "${BOARD_SLUG}" && -n "${SHOP_SEARCH}" ]] \
    || fail 'board slug and shop search term must not be empty'

BASE_URL="${BASE_URL%/}"
[[ -x "${TOGGLE_SCRIPT}" ]] || fail "toggle harness is not executable: ${TOGGLE_SCRIPT}"
[[ -f "${K6_SCRIPT}" ]] || fail "k6 route script not found: ${K6_SCRIPT}"
[[ -f "${REPO_ROOT}/artisan" ]] || fail "invalid repository root: ${REPO_ROOT}"
for command in "${SSH_BIN}" "${CURL_BIN}" "${JQ_BIN}" "${K6_BIN}" git awk; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command not found: ${command}"
done

OPTIMIZED_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --verify "${OPTIMIZED_REF}^{commit}")" \
    || fail "optimized ref is not a commit: ${OPTIMIZED_REF}"
[[ "${OPTIMIZED_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail 'could not resolve immutable optimized commit'

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/storage/app/benchmark/reports/g7-ab-$(date '+%Y%m%d-%H%M%S')"
fi
[[ ! -e "${OUTPUT_DIR}/comparison.json" ]] || fail "output directory already contains a report: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/runs"
LOG_FILE="${OUTPUT_DIR}/g7-ab-benchmark.log"
MANIFEST_FILE="${OUTPUT_DIR}/route-manifest.json"
REPORT_JSON="${OUTPUT_DIR}/comparison.json"
REPORT_CSV="${OUTPUT_DIR}/comparison.csv"
CPU_REPORT_CSV="${OUTPUT_DIR}/cpu-comparison.csv"
REPORT_MD="${OUTPUT_DIR}/comparison.md"

TOKEN="g7-ab-$(date +%s)-$$"
AB_LOCK_DIR='/var/lock/g7-performance-toggle.lock.d'
AB_LOCK_ACQUIRED=0
MYSQL_GUARD_SNAPSHOT="/tmp/${TOKEN}-mysql-guard.env"
MYSQL_GUARD_ACTIVE=0
MYSQL_GUARD_KIND=''
MYSQL_GUARD_ORIGINAL=''
CPU_SAMPLER_PID=''
CPU_STOP_FILE=''
CPU_SAMPLE_FILE=''
AB_MUTATION_STARTED=0
CLEANUP_RUNNING=0
MAIN_STATUS=0
RUN_FILES=()

TOGGLE_OPTIONS=(
    --scope all
    --host "${REMOTE_HOST}"
    --root "${REMOTE_ROOT}"
    --app-user "${REMOTE_APP_USER}"
    --php-bin "${REMOTE_PHP_BIN}"
    --db "${REMOTE_DB_NAME}"
    --db-prefix "${REMOTE_DB_PREFIX}"
    --baseline "${BASELINE_REF}"
    --optimized-ref "${OPTIMIZED_COMMIT}"
    --base-url "${BASE_URL}"
    --board-slug "${BOARD_SLUG}"
    --drain-timeout "${DRAIN_TIMEOUT}"
    --parent-lock-token "${TOKEN}"
)

acquire_ab_lock() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- ab-lock-acquire "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
action="$1"; token="$2"; lock_dir="$3"
[[ "${action}" == ab-lock-acquire && "${token}" =~ ^g7-ab-[A-Za-z0-9_-]+$ ]]
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d ]]
if ! mkdir "${lock_dir}" 2>/dev/null; then
    owner=unknown
    [[ ! -r "${lock_dir}/owner" ]] || read -r owner < "${lock_dir}/owner"
    printf 'another A/B benchmark owns the remote lock: %s\n' "${owner}" >&2
    exit 1
fi
if ! { umask 077; printf '%s\n' "${token}" > "${lock_dir}/owner" && chmod 600 "${lock_dir}/owner"; }; then
    rm -f -- "${lock_dir}/owner"
    rmdir -- "${lock_dir}"
    exit 1
fi
REMOTE
    AB_LOCK_ACQUIRED=1
}

assert_ab_lock() {
    [[ "${AB_LOCK_ACQUIRED}" == 1 ]] || return 1
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- ab-lock-assert "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE' >/dev/null
set -euo pipefail
[[ "$1" == ab-lock-assert && "$3" == /var/lock/g7-performance-toggle.lock.d ]]
[[ -f "$3/owner" && "$(<"$3/owner")" == "$2" ]]
REMOTE
}

release_ab_lock() {
    [[ "${AB_LOCK_ACQUIRED}" == 1 ]] || return 0
    if ! "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- ab-lock-release "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
[[ "$1" == ab-lock-release && "$3" == /var/lock/g7-performance-toggle.lock.d ]]
[[ -f "$3/owner" && "$(<"$3/owner")" == "$2" ]]
rm -f -- "$3/owner"
rmdir -- "$3"
REMOTE
    then
        return 1
    fi
    AB_LOCK_ACQUIRED=0
}

run_toggle() {
    local action="$1" result
    shift
    assert_ab_lock || return 1
    log "tuning ${action} --scope all $*"
    set +e
    "${TOGGLE_SCRIPT}" "${action}" "${TOGGLE_OPTIONS[@]}" "$@" 2>&1 | tee -a "${LOG_FILE}"
    result=${PIPESTATUS[0]}
    set -e
    return "${result}"
}

confirm_state() {
    local expected="$1" output result
    assert_ab_lock || return 1
    set +e
    output="$("${TOGGLE_SCRIPT}" status "${TOGGLE_OPTIONS[@]}" --strict 2>&1)"
    result=$?
    set -e
    printf '%s\n' "${output}" | tee -a "${LOG_FILE}" >&2
    [[ "${result}" == 0 ]] || return "${result}"
    grep -qx "overall=${expected}" <<<"${output}"
}

install_mysql_guard() {
    local output result
    MYSQL_GUARD_ACTIVE=1
    set +e
    output="$("${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        mysql-guard-install "${REMOTE_DB_NAME}" "${STATEMENT_TIMEOUT_MS}" "${MYSQL_GUARD_SNAPSHOT}" \
        "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
action="$1"; db_name="$2"; cap_ms="$3"; snapshot="$4"; token="$5"; lock_dir="$6"
[[ "${action}" == mysql-guard-install ]]
[[ "${db_name}" =~ ^[A-Za-z0-9_]+$ && "${cap_ms}" =~ ^[0-9]+$ ]]
[[ "${snapshot}" =~ ^/tmp/g7-ab-[A-Za-z0-9_-]+-mysql-guard[.]env$ ]]
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d && "$(<"${lock_dir}/owner")" == "${token}" ]]

if original="$(mysql --batch --skip-column-names -e 'SELECT @@GLOBAL.max_execution_time' 2>/dev/null)"; then
    [[ "${original}" =~ ^[0-9]+$ ]]
    umask 077
    printf 'max_execution_time\t%s\n' "${original}" > "${snapshot}.tmp"
    mv "${snapshot}.tmp" "${snapshot}"
    mysql -e "SET GLOBAL max_execution_time=${cap_ms}"
    printf 'max_execution_time\t%s\n' "${original}"
elif original="$(mysql --batch --skip-column-names -e 'SELECT @@GLOBAL.max_statement_time' 2>/dev/null)"; then
    [[ "${original}" =~ ^[0-9]+([.][0-9]+)?$ ]]
    cap_seconds="$(awk -v ms="${cap_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
    umask 077
    printf 'max_statement_time\t%s\n' "${original}" > "${snapshot}.tmp"
    mv "${snapshot}.tmp" "${snapshot}"
    mysql -e "SET GLOBAL max_statement_time=${cap_seconds}"
    printf 'max_statement_time\t%s\n' "${original}"
else
    printf 'MySQL SELECT timeout variable is unavailable\n' >&2
    exit 1
fi
REMOTE
)"
    result=$?
    set -e
    [[ "${result}" == 0 ]] || fail 'could not install the temporary MySQL SELECT cap'
    IFS=$'\t' read -r MYSQL_GUARD_KIND MYSQL_GUARD_ORIGINAL <<<"${output}"
    [[ "${MYSQL_GUARD_KIND}" == max_execution_time || "${MYSQL_GUARD_KIND}" == max_statement_time ]] \
        || fail "invalid MySQL guard response: ${output}"
    [[ "${MYSQL_GUARD_ORIGINAL}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
        || fail "invalid original MySQL timeout: ${MYSQL_GUARD_ORIGINAL}"
    log "temporary MySQL SELECT cap=${STATEMENT_TIMEOUT_MS}ms (${MYSQL_GUARD_KIND}, original=${MYSQL_GUARD_ORIGINAL})"
}

restore_mysql_guard() {
    [[ "${MYSQL_GUARD_ACTIVE}" == 1 ]] || return 0
    if ! "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        mysql-guard-restore "${MYSQL_GUARD_SNAPSHOT}" "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
action="$1"; snapshot="$2"; token="$3"; lock_dir="$4"
[[ "${action}" == mysql-guard-restore ]]
[[ "${snapshot}" =~ ^/tmp/g7-ab-[A-Za-z0-9_-]+-mysql-guard[.]env$ ]]
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d && "$(<"${lock_dir}/owner")" == "${token}" ]]
[[ -f "${snapshot}" ]] || exit 0
IFS=$'\t' read -r kind original < "${snapshot}"
[[ "${original}" =~ ^[0-9]+([.][0-9]+)?$ ]]
case "${kind}" in
    max_execution_time) mysql -e "SET GLOBAL max_execution_time=${original}" ;;
    max_statement_time) mysql -e "SET GLOBAL max_statement_time=${original}" ;;
    *) exit 1 ;;
esac
rm -f -- "${snapshot}"
REMOTE
    then
        return 1
    fi
    MYSQL_GUARD_ACTIVE=0
    log "restored MySQL ${MYSQL_GUARD_KIND}=${MYSQL_GUARD_ORIGINAL}"
}

wait_for_database_idle() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        mysql-idle-gate "${REMOTE_DB_NAME}" "${IDLE_TIMEOUT_SECONDS}" "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
action="$1"; db_name="$2"; timeout="$3"; token="$4"; lock_dir="$5"
[[ "${action}" == mysql-idle-gate ]]
[[ "${db_name}" =~ ^[A-Za-z0-9_]+$ && "${timeout}" =~ ^[0-9]+$ ]]
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d && "$(<"${lock_dir}/owner")" == "${token}" ]]
deadline=$((SECONDS + timeout))
while true; do
    selects="$(mysql --batch --skip-column-names -e "
        SELECT COUNT(*)
        FROM information_schema.PROCESSLIST
        WHERE ID <> CONNECTION_ID()
          AND DB='${db_name}'
          AND COMMAND='Query'
          AND LTRIM(COALESCE(INFO, '')) REGEXP '^SELECT'
    ")"
    transactions="$(mysql --batch --skip-column-names -e "
        SELECT COUNT(*)
        FROM information_schema.INNODB_TRX trx
        JOIN information_schema.PROCESSLIST p ON p.ID=trx.trx_mysql_thread_id
        WHERE p.DB='${db_name}'
    ")"
    if [[ "${selects}" == 0 && "${transactions}" == 0 ]]; then
        exit 0
    fi
    if (( SECONDS >= deadline )); then
        printf 'database did not become idle: selects=%s transactions=%s\n' "${selects}" "${transactions}" >&2
        mysql --table -e "
            SELECT ID, USER, DB, COMMAND, TIME, STATE, LEFT(INFO, 180) AS INFO
            FROM information_schema.PROCESSLIST
            WHERE DB='${db_name}' AND COMMAND <> 'Sleep'
            ORDER BY TIME DESC
        " >&2 || true
        mysql --table -e "
            SELECT trx_mysql_thread_id, trx_started, trx_state, trx_query
            FROM information_schema.INNODB_TRX trx
            JOIN information_schema.PROCESSLIST p ON p.ID=trx.trx_mysql_thread_id
            WHERE p.DB='${db_name}'
        " >&2 || true
        exit 1
    fi
    sleep 1
done
REMOTE
}

assert_xdebug_disabled() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        xdebug-check "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE'
set -euo pipefail
action="$1"; app_user="$2"; php_bin="$3"; token="$4"; lock_dir="$5"
[[ "${action}" == xdebug-check ]]
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d && "$(<"${lock_dir}/owner")" == "${token}" ]]
if sudo -u "${app_user}" "${php_bin}" -m | grep -Eqi '^[[:space:]]*xdebug[[:space:]]*$'; then
    printf 'Xdebug is loaded in CLI; benchmark refused\n' >&2
    exit 1
fi
for proc_dir in /proc/[0-9]*; do
    [[ -r "${proc_dir}/comm" && -r "${proc_dir}/maps" ]] || continue
    read -r comm < "${proc_dir}/comm" || continue
    [[ "${comm}" == php-fpm* ]] || continue
    if grep -Eqi '(^|/)xdebug[.]so([[:space:]]|$)' "${proc_dir}/maps"; then
        printf 'Xdebug is loaded by PHP-FPM pid %s; benchmark refused\n' "${proc_dir##*/}" >&2
        exit 1
    fi
done
REMOTE
}

start_cpu_sampler() {
    local phase="$1" run="$2" readiness=0
    CPU_SAMPLE_FILE="${OUTPUT_DIR}/runs/${phase}-${run}-cpu.csv"
    CPU_STOP_FILE="/tmp/${TOKEN}-${phase}-${run}.stop"
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        cpu-sample "${CPU_STOP_FILE}" "${CPU_INTERVAL_SECONDS}" "${MEASUREMENT_WINDOW_SECONDS}" \
        "${CPU_MAX_SECONDS}" "${TOKEN}" "${AB_LOCK_DIR}" \
        >"${CPU_SAMPLE_FILE}" 2>"${OUTPUT_DIR}/runs/${phase}-${run}-cpu.log" <<'REMOTE' &
set -euo pipefail
action="$1"; stop_file="$2"; interval="$3"; window_seconds="$4"; max_seconds="$5"
token="$6"; lock_dir="$7"
[[ "${action}" == cpu-sample ]]
[[ "${stop_file}" =~ ^/tmp/g7-ab-[A-Za-z0-9_-]+[.]stop$ ]]
[[ "${interval}" =~ ^[0-9]+$ && "${window_seconds}" =~ ^[0-9]+$ && "${max_seconds}" =~ ^[0-9]+$ ]]
(( window_seconds <= max_seconds ))
[[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d && "$(<"${lock_dir}/owner")" == "${token}" ]]
rm -f -- "${stop_file}"
trap 'rm -f -- "${stop_file}"' EXIT

declare -A last_ticks=()
PHP_DELTA=0
MYSQL_DELTA=0

read_host() {
    local label user nice system idle iowait irq softirq steal guest guest_nice
    read -r label user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    HOST_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
    HOST_IDLE=$((idle + iowait))
}

read_process_deltas() {
    local proc_dir pid comm stat_line stat_tail key ticks previous delta start_time
    local -a fields
    PHP_DELTA=0
    MYSQL_DELTA=0
    for proc_dir in /proc/[0-9]*; do
        [[ -r "${proc_dir}/comm" && -r "${proc_dir}/stat" ]] || continue
        pid="${proc_dir##*/}"
        read -r comm < "${proc_dir}/comm" || continue
        case "${comm}" in
            php-fpm*|mysqld|mariadbd) ;;
            *) continue ;;
        esac
        stat_line="$(<"${proc_dir}/stat")" || continue
        stat_tail="${stat_line#*) }"
        read -r -a fields <<<"${stat_tail}"
        [[ ${#fields[@]} -gt 19 ]] || continue
        ticks=$((fields[11] + fields[12]))
        start_time="${fields[19]}"
        key="${pid}:${start_time}"
        previous="${last_ticks[${key}]:-${ticks}}"
        delta=$((ticks - previous))
        (( delta >= 0 )) || delta=0
        last_ticks["${key}"]="${ticks}"
        case "${comm}" in
            php-fpm*) PHP_DELTA=$((PHP_DELTA + delta)) ;;
            mysqld|mariadbd) MYSQL_DELTA=$((MYSQL_DELTA + delta)) ;;
        esac
    done
}

printf 'sample,elapsed_seconds,timestamp,host_busy_pct,php_fpm_host_capacity_pct,mysql_host_capacity_pct\n'
read_host
previous_total="${HOST_TOTAL}"
previous_idle="${HOST_IDLE}"
read_process_deltas
started="${SECONDS}"
sample=0
while [[ ! -e "${stop_file}" ]] && (( SECONDS - started < window_seconds )); do
    sleep "${interval}"
    read_host
    read_process_deltas
    total_delta=$((HOST_TOTAL - previous_total))
    idle_delta=$((HOST_IDLE - previous_idle))
    if (( total_delta > 0 )); then
        host_busy="$(awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN { printf "%.3f", (total-idle)*100/total }')"
        php_cpu="$(awk -v ticks="${PHP_DELTA}" -v total="${total_delta}" 'BEGIN { printf "%.3f", ticks*100/total }')"
        mysql_cpu="$(awk -v ticks="${MYSQL_DELTA}" -v total="${total_delta}" 'BEGIN { printf "%.3f", ticks*100/total }')"
        sample=$((sample + 1))
        printf '%s,%s,%s,%s,%s,%s\n' "${sample}" "$((SECONDS - started))" \
            "$(date --iso-8601=seconds)" "${host_busy}" "${php_cpu}" "${mysql_cpu}"
    fi
    previous_total="${HOST_TOTAL}"
    previous_idle="${HOST_IDLE}"
done
REMOTE
    CPU_SAMPLER_PID=$!

    while (( readiness < 100 )); do
        if [[ -s "${CPU_SAMPLE_FILE}" ]]; then
            return 0
        fi
        kill -0 "${CPU_SAMPLER_PID}" >/dev/null 2>&1 || break
        sleep 0.1
        readiness=$((readiness + 1))
    done
    wait "${CPU_SAMPLER_PID}" || true
    CPU_SAMPLER_PID=''
    return 1
}

wait_cpu_sampler() {
    local sampler_result=0
    [[ -n "${CPU_SAMPLER_PID}" ]] || return 1
    wait "${CPU_SAMPLER_PID}" || sampler_result=$?
    CPU_SAMPLER_PID=''
    CPU_STOP_FILE=''
    return "${sampler_result}"
}

stop_cpu_sampler() {
    local sampler_result=0
    [[ -n "${CPU_SAMPLER_PID}" ]] || return 0
    if ! "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        cpu-stop "${CPU_STOP_FILE}" "${TOKEN}" "${AB_LOCK_DIR}" <<'REMOTE' >/dev/null 2>&1
set -euo pipefail
[[ "$1" == cpu-stop && "$2" =~ ^/tmp/g7-ab-[A-Za-z0-9_-]+[.]stop$ && "$4" == /var/lock/g7-performance-toggle.lock.d ]]
[[ "$(<"$4/owner")" == "$3" ]]
touch -- "$2"
REMOTE
    then
        kill "${CPU_SAMPLER_PID}" >/dev/null 2>&1 || true
        sampler_result=1
    fi
    wait "${CPU_SAMPLER_PID}" || sampler_result=1
    CPU_SAMPLER_PID=''
    CPU_STOP_FILE=''
    return "${sampler_result}"
}

summarize_cpu() {
    local source_file="$1" target_file="$2" window_seconds="$3" interval_seconds="$4"
    awk -F, -v window="${window_seconds}" -v interval="${interval_seconds}" '
        NR == 1 { next }
        NF >= 6 {
            samples++
            elapsed = $2
            host_sum += $4; php_sum += $5; mysql_sum += $6
            if (samples == 1 || $4 > host_max) host_max = $4
            if (samples == 1 || $5 > php_max) php_max = $5
            if (samples == 1 || $6 > mysql_max) mysql_max = $6
        }
        END {
            if (samples == 0 || elapsed < window) exit 2
            expected = int((window + interval - 1) / interval)
            printf "{\"samples\":%d,\"expected_samples\":%d,\"configured_window_seconds\":%d,\"actual_elapsed_seconds\":%d,\"sample_interval_seconds\":%d,\"host_busy_avg_pct\":%.3f,\"host_busy_max_pct\":%.3f,\"php_fpm_cpu_avg_pct\":%.3f,\"php_fpm_cpu_max_pct\":%.3f,\"mysql_cpu_avg_pct\":%.3f,\"mysql_cpu_max_pct\":%.3f}\n", samples, expected, window, elapsed, interval, host_sum/samples, host_max, php_sum/samples, php_max, mysql_sum/samples, mysql_max
        }
    ' "${source_file}" > "${target_file}"
    "${JQ_BIN}" -e . "${target_file}" >/dev/null
}

api_get() {
    local path="$1"
    "${CURL_BIN}" --fail --silent --show-error --max-time "${REQUEST_TIMEOUT_SECONDS}" \
        -H 'Accept: application/json' -H 'Cache-Control: no-cache' "${BASE_URL}${path}"
}

discover_targets() {
    local encoded_board board_payload board_detail product_payload product_detail discovered_term
    encoded_board="$("${JQ_BIN}" -rn --arg value "${BOARD_SLUG}" '$value|@uri')"
    if [[ -z "${POST_ID}" ]]; then
        board_payload="$(api_get "/api/modules/sirsoft-board/boards/${encoded_board}/posts?page=1&per_page=20")"
        POST_ID="$("${JQ_BIN}" -r '
            [.data.data[]? | select(.is_secret != true and .status == "published") | .id][0] // empty
        ' <<<"${board_payload}")"
    fi
    [[ "${POST_ID}" =~ ^[0-9]+$ ]] || fail 'could not discover a public post; pass --post-id'
    board_detail="$(api_get "/api/modules/sirsoft-board/boards/${encoded_board}/posts/${POST_ID}")"
    "${JQ_BIN}" -e --arg id "${POST_ID}" \
        '.success == true and ((.data.id | tostring) == $id) and ((.data.title // "") | length > 0)' \
        <<<"${board_detail}" >/dev/null || fail 'public post target failed semantic validation'
    if [[ -z "${BOARD_SEARCH}" ]]; then
        discovered_term="$("${JQ_BIN}" -r '
            (.data.title // "") as $title
            | ([($title | scan("[0-9]{4,}"))][0]
                // ($title | gsub("[^[:alnum:]가-힣]+"; " ") | split(" ")
                    | map(select(length >= 2)) | sort_by(-length) | .[0])
                // empty)
        ' <<<"${board_detail}")"
        [[ -n "${discovered_term}" ]] || fail 'could not discover a safe board search hit; pass --board-search'
        BOARD_SEARCH="${discovered_term}"
        SEARCH_TARGET_SOURCE='discovered-post-title'
    else
        SEARCH_TARGET_SOURCE='explicit'
    fi
    [[ -n "${GLOBAL_SEARCH}" ]] || GLOBAL_SEARCH="${BOARD_SEARCH}"
    [[ ${#BOARD_SEARCH} -ge 2 && ${#GLOBAL_SEARCH} -ge 2 ]] \
        || fail 'board/global search terms must contain at least two characters'
    if [[ -z "${PRODUCT_ID}" ]]; then
        product_payload="$(api_get '/api/modules/sirsoft-ecommerce/products?page=1&per_page=12')"
        PRODUCT_ID="$("${JQ_BIN}" -r '.data.data[0].id // empty' <<<"${product_payload}")"
    fi
    [[ "${PRODUCT_ID}" =~ ^[0-9A-Za-z]+$ ]] || fail 'could not discover a public product; pass --product-id'
    product_detail="$(api_get "/api/modules/sirsoft-ecommerce/products/${PRODUCT_ID}")"
    "${JQ_BIN}" -e --arg id "${PRODUCT_ID}" \
        '.success == true and ((.data.id | tostring) == $id)' \
        <<<"${product_detail}" >/dev/null || fail 'public product target failed semantic validation'
    log "fixed A/B targets: board=${BOARD_SLUG} post=${POST_ID} product=${PRODUCT_ID} search=${BOARD_SEARCH} (${SEARCH_TARGET_SOURCE})"
}

validate_search_targets() {
    local shop_term page_one page_two
    shop_term="$("${JQ_BIN}" -rn --arg value "${SHOP_SEARCH}" '$value|@uri')"
    page_one="$(api_get "/api/modules/sirsoft-ecommerce/products?search=${shop_term}&page=1&per_page=12")"
    page_two="$(api_get "/api/modules/sirsoft-ecommerce/products?search=${shop_term}&page=2&per_page=12")"
    "${JQ_BIN}" -e '
        .success == true
        and .data.pagination.current_page == 1
        and .data.pagination.total > 0
        and (.data.data | type == "array" and length > 0)
    ' <<<"${page_one}" >/dev/null || fail 'shop search target has no verified first-page hit'
    "${JQ_BIN}" -e '
        .success == true
        and .data.pagination.current_page == 2
        and (.data.data | type == "array")
    ' <<<"${page_two}" >/dev/null || fail 'shop search second-page contract failed validation'
}

write_route_manifest() {
    local board_encoded post_encoded product_encoded board_search_encoded global_search_encoded shop_search_encoded
    board_encoded="$("${JQ_BIN}" -rn --arg value "${BOARD_SLUG}" '$value|@uri')"
    post_encoded="$("${JQ_BIN}" -rn --arg value "${POST_ID}" '$value|@uri')"
    product_encoded="$("${JQ_BIN}" -rn --arg value "${PRODUCT_ID}" '$value|@uri')"
    board_search_encoded="$("${JQ_BIN}" -rn --arg value "${BOARD_SEARCH}" '$value|@uri')"
    global_search_encoded="$("${JQ_BIN}" -rn --arg value "${GLOBAL_SEARCH}" '$value|@uri')"
    shop_search_encoded="$("${JQ_BIN}" -rn --arg value "${SHOP_SEARCH}" '$value|@uri')"

    "${JQ_BIN}" -n \
        --arg board_base "/api/modules/sirsoft-board/boards/${board_encoded}/posts" \
        --arg post "${post_encoded}" \
        --arg product "${product_encoded}" \
        --arg board_search "${board_search_encoded}" \
        --arg global_search "${global_search_encoded}" \
        --arg shop_search "${shop_search_encoded}" \
        --argjson deep_page "${DEEP_PAGE}" '
        def route($key; $label; $workload; $path): {
            key: $key,
            label: $label,
            workload: $workload,
            path: $path,
            duration_metric: ("g7_route_" + $key + "_duration"),
            valid_metric: ("g7_route_" + $key + "_valid")
        };
        [
            route("home"; "홈"; "hot"; "/"),
            route("home_stats"; "홈 게시판 통계"; "hot"; "/api/modules/sirsoft-board/boards/stats"),
            route("home_recent"; "홈 최근 게시글"; "hot"; "/api/modules/sirsoft-board/boards/posts/recent?limit=5"),
            route("home_popular_boards"; "홈 인기 게시판"; "hot"; "/api/modules/sirsoft-board/boards/popular-boards?limit=4"),
            route("home_boards"; "홈 게시판 목록"; "hot"; "/api/modules/sirsoft-board/boards?limit=3"),
            route("board_list_p1"; "게시판 목록 1페이지"; "hot"; ($board_base + "?page=1&per_page=20")),
            route("board_list_p2"; "게시판 목록 2페이지"; "hot"; ($board_base + "?page=2&per_page=20")),
            route("board_deep"; "게시판 깊은 페이지"; "risky-single-vu"; ($board_base + "?page=" + ($deep_page|tostring) + "&per_page=20")),
            route("board_detail"; "게시글 내용"; "hot"; ($board_base + "/" + $post)),
            route("board_navigation"; "게시글 이전·다음"; "hot"; ($board_base + "/" + $post + "/navigation")),
            route("board_search"; "게시판 검색"; "risky-single-vu"; ($board_base + "?search=" + $board_search + "&search_field=all&page=1&per_page=20")),
            route("global_search"; "전역 검색"; "risky-single-vu"; ("/api/search?q=" + $global_search + "&page=1&per_page=10")),
            route("shop_home_categories"; "쇼핑 홈 분류"; "hot"; "/api/modules/sirsoft-ecommerce/categories"),
            route("shop_list_p1"; "쇼핑 홈·상품 목록 1페이지"; "hot"; "/api/modules/sirsoft-ecommerce/products?page=1&per_page=12"),
            route("shop_list_p2"; "상품 목록 2페이지"; "hot"; "/api/modules/sirsoft-ecommerce/products?page=2&per_page=12"),
            route("shop_home_recent"; "쇼핑 홈 최근 상품"; "hot"; "/api/modules/sirsoft-ecommerce/products/recent?ids="),
            route("shop_home_popular"; "쇼핑 홈 인기 상품"; "hot"; "/api/modules/sirsoft-ecommerce/products/popular?limit=8"),
            route("shop_home_new"; "쇼핑 홈 신상품"; "hot"; "/api/modules/sirsoft-ecommerce/products/new?limit=8"),
            route("shop_detail"; "상품 내용"; "hot"; ("/api/modules/sirsoft-ecommerce/products/" + $product)),
            route("shop_detail_reviews"; "상품 내용 리뷰"; "hot"; ("/api/modules/sirsoft-ecommerce/products/" + $product + "/reviews?page=1&per_page=10")),
            route("shop_detail_inquiries"; "상품 내용 문의"; "hot"; ("/api/modules/sirsoft-ecommerce/products/" + $product + "/inquiries?page=1&per_page=10")),
            route("shop_detail_coupons"; "상품 내용 쿠폰"; "hot"; ("/api/modules/sirsoft-ecommerce/products/" + $product + "/downloadable-coupons")),
            route("shop_search_p1"; "상품 검색 1페이지"; "hot"; ("/api/modules/sirsoft-ecommerce/products?search=" + $shop_search + "&page=1&per_page=12")),
            route("shop_search_p2"; "상품 검색 2페이지"; "hot"; ("/api/modules/sirsoft-ecommerce/products?search=" + $shop_search + "&page=2&per_page=12"))
        ]
    ' > "${MANIFEST_FILE}"
}

normalize_k6_summary() {
    local raw_file="$1" phase="$2" run="$3" k6_exit="$4" cpu_file="$5" target_file="$6"
    if ! "${JQ_BIN}" \
        --arg phase "${phase}" \
        --argjson run "${run}" \
        --argjson k6_exit "${k6_exit}" \
        --argjson expected_iterations "$((HOT_ARRIVAL_RATE * HOT_DURATION_SECONDS + 1))" \
        --slurpfile manifest "${MANIFEST_FILE}" '
        .metrics as $metrics
        | {
            phase: $phase,
            run: $run,
            k6_exit: $k6_exit,
            http_failure_rate: ($metrics.http_req_failed.values.rate // null),
            http_requests: ($metrics.http_reqs.values.count // null),
            http_requests_per_second: ($metrics.http_reqs.values.rate // null),
            iterations: ($metrics.iterations.values.count // null),
            expected_iterations: $expected_iterations,
            dropped_iterations: ($metrics.dropped_iterations.values.count // 0),
            routes: ($manifest[0] | map(
                . as $route
                | ($metrics[$route.duration_metric].values // {}) as $duration
                | ($metrics[$route.valid_metric].values // {}) as $valid
                | {
                    key: $route.key,
                    label: $route.label,
                    workload: $route.workload,
                    path: $route.path,
                    requests: (($valid.passes // 0) + ($valid.fails // 0)),
                    avg_ms: ($duration.avg // null),
                    median_ms: ($duration.med // null),
                    p95_ms: ($duration["p(95)"] // null),
                    p99_ms: ($duration["p(99)"] // null),
                    max_ms: ($duration.max // null),
                    error_rate: (if ($valid.rate // null) == null then null else (1 - $valid.rate) end)
                }
            ))
        }
    ' "${raw_file}" > "${target_file}.tmp"; then
        return 1
    fi
    if ! "${JQ_BIN}" --slurpfile cpu "${cpu_file}" '. + {cpu: $cpu[0]}' \
        "${target_file}.tmp" > "${target_file}"; then
        return 1
    fi
    rm -f "${target_file}.tmp"
}

run_one_benchmark() {
    local phase="$1" run="$2" raw_file cpu_summary normalized_file console_file k6_exit=0 sampler_exit=0
    raw_file="${OUTPUT_DIR}/runs/${phase}-${run}-k6-summary.json"
    cpu_summary="${OUTPUT_DIR}/runs/${phase}-${run}-cpu-summary.json"
    normalized_file="${OUTPUT_DIR}/runs/${phase}-${run}.json"
    console_file="${OUTPUT_DIR}/runs/${phase}-${run}-k6.log"

    log "${phase} run ${run}/${REPEATS}: hot=${HOT_VUS}VU/${HOT_DURATION_SECONDS}s, risky=1VU/1 iteration"
    start_cpu_sampler "${phase}" "${run}" || return 2
    set +e
    BASE_URL="${BASE_URL}" \
    BOARD_SLUG="${BOARD_SLUG}" \
    POST_ID="${POST_ID}" \
    PRODUCT_ID="${PRODUCT_ID}" \
    BOARD_SEARCH="${BOARD_SEARCH}" \
    GLOBAL_SEARCH="${GLOBAL_SEARCH}" \
    SHOP_SEARCH="${SHOP_SEARCH}" \
    DEEP_PAGE="${DEEP_PAGE}" \
    HOT_VUS="${HOT_VUS}" \
    HOT_ARRIVAL_RATE="${HOT_ARRIVAL_RATE}" \
    HOT_DURATION="${HOT_DURATION_SECONDS}s" \
    RISKY_START="$((HOT_DURATION_SECONDS + 11))s" \
    REQUEST_TIMEOUT="${REQUEST_TIMEOUT_SECONDS}s" \
        "${K6_BIN}" run --quiet --summary-export "${raw_file}" "${K6_SCRIPT}" \
        >"${console_file}" 2>&1
    k6_exit=$?
    set -e
    wait_cpu_sampler || sampler_exit=$?

    [[ -s "${raw_file}" ]] || {
        log "${phase} run ${run}: k6 did not produce a summary (exit=${k6_exit})"
        return 2
    }
    summarize_cpu "${CPU_SAMPLE_FILE}" "${cpu_summary}" \
        "${MEASUREMENT_WINDOW_SECONDS}" "${CPU_INTERVAL_SECONDS}" || {
        log "${phase} run ${run}: CPU sampler did not produce usable samples"
        return 2
    }
    normalize_k6_summary "${raw_file}" "${phase}" "${run}" "${k6_exit}" "${cpu_summary}" "${normalized_file}" \
        || return 2
    RUN_FILES+=("${normalized_file}")
    wait_for_database_idle || return 2
    [[ "${sampler_exit}" == 0 ]] || return 2

    if ! "${JQ_BIN}" -e '
        (.dropped_iterations // 0) == 0 and .iterations == .expected_iterations
    ' "${normalized_file}" >/dev/null; then
        log "${phase} run ${run}: fixed arrival schedule was not completed"
        return 1
    fi

    if ! "${JQ_BIN}" -e '
        [.routes[] | (.error_rate == 0 and .p95_ms != null)] | all
    ' "${normalized_file}" >/dev/null; then
        log "${phase} run ${run}: one or more routes failed semantic validation"
        return 1
    fi

    if [[ "${k6_exit}" != 0 ]]; then
        log "${phase} run ${run}: k6 checks/thresholds failed (exit=${k6_exit})"
        return 1
    fi
    return 0
}

run_phase() {
    local phase="$1" run result phase_status=0
    for ((run = 1; run <= REPEATS; run++)); do
        result=0
        run_one_benchmark "${phase}" "${run}" || result=$?
        if [[ "${result}" == 2 ]]; then
            return 2
        fi
        [[ "${result}" == 0 ]] || phase_status=1
    done
    return "${phase_status}"
}

generate_reports() {
    local expected_runs baseline_runs optimized_runs
    expected_runs=$((REPEATS * 2))
    if [[ ${#RUN_FILES[@]} -ne ${expected_runs} ]]; then
        log "report refused: expected ${expected_runs} complete runs, got ${#RUN_FILES[@]}"
        return 1
    fi
    baseline_runs="$("${JQ_BIN}" -s '[.[] | select(.phase == "baseline") | .run] | unique | length' "${RUN_FILES[@]}")"
    optimized_runs="$("${JQ_BIN}" -s '[.[] | select(.phase == "optimized") | .run] | unique | length' "${RUN_FILES[@]}")"
    if [[ "${baseline_runs}" -ne "${REPEATS}" || "${optimized_runs}" -ne "${REPEATS}" ]]; then
        log "report refused: incomplete phase runs (baseline=${baseline_runs}, optimized=${optimized_runs}, expected=${REPEATS})"
        return 1
    fi
    "${JQ_BIN}" -s \
        --slurpfile manifest "${MANIFEST_FILE}" \
        --arg completed_at "$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
        --arg base_url "${BASE_URL}" \
        --arg baseline_ref "${BASELINE_REF}" \
        --arg optimized_commit "${OPTIMIZED_COMMIT}" \
        --arg board_slug "${BOARD_SLUG}" \
        --arg post_id "${POST_ID}" \
        --arg product_id "${PRODUCT_ID}" \
        --arg board_search "${BOARD_SEARCH}" \
        --arg global_search "${GLOBAL_SEARCH}" \
        --arg shop_search "${SHOP_SEARCH}" \
        --arg search_target_source "${SEARCH_TARGET_SOURCE}" \
        --argjson repeats "${REPEATS}" \
        --argjson hot_vus "${HOT_VUS}" \
        --argjson hot_arrival_rate "${HOT_ARRIVAL_RATE}" \
        --argjson hot_duration "${HOT_DURATION_SECONDS}" \
        --argjson measurement_window "${MEASUREMENT_WINDOW_SECONDS}" \
        --argjson cpu_interval "${CPU_INTERVAL_SECONDS}" \
        --argjson deep_page "${DEEP_PAGE}" \
        --argjson statement_timeout "${STATEMENT_TIMEOUT_MS}" '
        def present: map(select(. != null));
        def median:
            present | sort | length as $n
            | if $n == 0 then null
              elif ($n % 2) == 1 then .[($n / 2 | floor)]
              else ((.[($n / 2) - 1] + .[$n / 2]) / 2)
              end;
        def average: present | if length == 0 then null else (add / length) end;
        def maximum: present | if length == 0 then null else max end;
        def minimum: present | if length == 0 then null else min end;
        . as $runs
        | def cpu_values($phase; $field):
            [$runs[] | select(.phase == $phase) | .cpu[$field]];
        def run_values($phase; $field):
            [$runs[] | select(.phase == $phase) | .[$field]];
        def phase_runs($phase): [$runs[] | select(.phase == $phase)];
        def phase_schedule_valid($phase):
            phase_runs($phase) as $phase_runs
            | (($phase_runs | length) == $repeats)
              and all($phase_runs[];
                (.dropped_iterations // 0) == 0
                and .iterations == .expected_iterations
              );
        def route_phase($phase; $key):
            [$runs[] | select(.phase == $phase) | .routes[] | select(.key == $key)] as $items
            | ((($items | length) == $repeats)
                and phase_schedule_valid($phase)
                and all($items[]; .error_rate == 0 and .p95_ms != null)) as $valid
            | {
                valid: $valid,
                invalid_reason: (if $valid then null else "semantic-or-schedule-failure" end),
                avg_ms: (if $valid then ([$items[].avg_ms] | median) else null end),
                p50_ms: (if $valid then ([$items[].median_ms] | median) else null end),
                p95_ms: (if $valid then ([$items[].p95_ms] | median) else null end),
                p99_ms: (if $valid then ([$items[].p99_ms] | median) else null end),
                error_rate: ([$items[].error_rate] | median)
            };
        def cpu_phase($phase): {
            phase: $phase,
            schedule_valid: phase_schedule_valid($phase),
            dropped_iterations: (run_values($phase; "dropped_iterations") | maximum),
            http_requests_per_second: (run_values($phase; "http_requests_per_second") | median),
            http_failure_rate: (run_values($phase; "http_failure_rate") | median),
            configured_window_seconds: $measurement_window,
            sample_interval_seconds: $cpu_interval,
            samples_min: (cpu_values($phase; "samples") | minimum),
            samples_max: (cpu_values($phase; "samples") | maximum),
            actual_elapsed_seconds_min: (cpu_values($phase; "actual_elapsed_seconds") | minimum),
            actual_elapsed_seconds_max: (cpu_values($phase; "actual_elapsed_seconds") | maximum),
            host_busy_avg_pct: (cpu_values($phase; "host_busy_avg_pct") | average),
            host_busy_max_pct: (cpu_values($phase; "host_busy_max_pct") | maximum),
            php_fpm_cpu_avg_pct: (cpu_values($phase; "php_fpm_cpu_avg_pct") | average),
            php_fpm_cpu_max_pct: (cpu_values($phase; "php_fpm_cpu_max_pct") | maximum),
            mysql_cpu_avg_pct: (cpu_values($phase; "mysql_cpu_avg_pct") | average),
            mysql_cpu_max_pct: (cpu_values($phase; "mysql_cpu_max_pct") | maximum)
        };
        {
            metadata: {
                completed_at: $completed_at,
                base_url: $base_url,
                baseline_ref: $baseline_ref,
                optimized_commit: $optimized_commit,
                repeats: $repeats,
                hot_vus: $hot_vus,
                hot_arrival_rate_per_second: $hot_arrival_rate,
                hot_duration_seconds: $hot_duration,
                expected_hot_iterations_per_run: ($hot_arrival_rate * $hot_duration),
                risky_vus: 1,
                risky_iterations_per_run: 1,
                deep_page: $deep_page,
                statement_timeout_ms: $statement_timeout,
                cpu_measurement_window_seconds: $measurement_window,
                cpu_sample_interval_seconds: $cpu_interval,
                process_cpu_basis: "percentage of total host CPU capacity",
                complete: true,
                final_state: "optimized"
            },
            targets: {
                board_slug: $board_slug,
                post_id: $post_id,
                product_id: $product_id,
                board_search: $board_search,
                global_search: $global_search,
                shop_search: $shop_search,
                search_target_source: $search_target_source
            },
            routes: [
                $manifest[0][] | . as $route
                | {
                    key: $route.key,
                    label: $route.label,
                    workload: $route.workload,
                    path: $route.path,
                    baseline: route_phase("baseline"; $route.key),
                    optimized: route_phase("optimized"; $route.key)
                }
                | . + {
                    p95_change_pct: (
                        if (.baseline.valid | not) or (.optimized.valid | not)
                            or .baseline.p95_ms == 0
                        then null
                        else ((.optimized.p95_ms - .baseline.p95_ms) * 100 / .baseline.p95_ms)
                        end
                    )
                }
            ],
            cpu: [cpu_phase("baseline"), cpu_phase("optimized")],
            runs: $runs
        }
    ' "${RUN_FILES[@]}" > "${REPORT_JSON}"

    "${JQ_BIN}" -r '
        ["route", "label", "workload", "path", "baseline_valid", "baseline_avg_ms", "baseline_p50_ms", "baseline_p95_ms", "baseline_p99_ms", "optimized_valid", "optimized_avg_ms", "optimized_p50_ms", "optimized_p95_ms", "optimized_p99_ms", "p95_change_pct", "baseline_error_rate", "optimized_error_rate"],
        (.routes[] | [
            .key, .label, .workload, .path,
            .baseline.valid,
            .baseline.avg_ms, .baseline.p50_ms, .baseline.p95_ms, .baseline.p99_ms,
            .optimized.valid,
            .optimized.avg_ms, .optimized.p50_ms, .optimized.p95_ms, .optimized.p99_ms,
            .p95_change_pct,
            .baseline.error_rate, .optimized.error_rate
        ]) | @csv
    ' "${REPORT_JSON}" > "${REPORT_CSV}"

    "${JQ_BIN}" -r '
        ["phase", "schedule_valid", "dropped_iterations", "configured_window_seconds", "sample_interval_seconds", "samples_min", "samples_max", "actual_elapsed_seconds_min", "actual_elapsed_seconds_max", "http_requests_per_second", "http_failure_rate", "host_busy_avg_pct", "host_busy_max_pct", "php_fpm_cpu_avg_pct", "php_fpm_cpu_max_pct", "mysql_cpu_avg_pct", "mysql_cpu_max_pct"],
        (.cpu[] | [
            .phase, .schedule_valid, .dropped_iterations,
            .configured_window_seconds, .sample_interval_seconds,
            .samples_min, .samples_max, .actual_elapsed_seconds_min, .actual_elapsed_seconds_max,
            .http_requests_per_second, .http_failure_rate,
            .host_busy_avg_pct, .host_busy_max_pct,
            .php_fpm_cpu_avg_pct, .php_fpm_cpu_max_pct,
            .mysql_cpu_avg_pct, .mysql_cpu_max_pct
        ]) | @csv
    ' "${REPORT_JSON}" > "${CPU_REPORT_CSV}"

    {
        printf '# 그누보드7 튜닝 전·후 A/B 벤치마크\n\n'
        printf -- '- 대상: `%s`\n' "${BASE_URL}"
        printf -- '- 기준: `%s`\n' "${BASELINE_REF}"
        printf -- '- 튜닝: `%s`\n' "${OPTIMIZED_COMMIT}"
        printf -- '- 반복: 상태별 %s회, 일반 경로 %s VU / %s초\n' "${REPEATS}" "${HOT_VUS}" "${HOT_DURATION_SECONDS}"
        printf -- '- 요청 스케줄: 일반 경로 매트릭스 초당 %s회 고정, 상태별 예정 %s회\n' \
            "${HOT_ARRIVAL_RATE}" "$((HOT_ARRIVAL_RATE * HOT_DURATION_SECONDS))"
        printf -- '- CPU 측정창: 매 실행 %s초 고정, %s초 간격, 프로세스 값은 전체 호스트 CPU 용량 기준\n' \
            "${MEASUREMENT_WINDOW_SECONDS}" "${CPU_INTERVAL_SECONDS}"
        printf -- '- 안전: 깊은 페이지·게시판 검색·전역 검색은 1 VU 단건, SELECT 최대 %sms\n\n' "${STATEMENT_TIMEOUT_MS}"
        printf '## 경로별 결과\n\n'
        printf '| 경로 | 부하 | OFF p50(ms) | ON p50(ms) | OFF p95(ms) | ON p95(ms) | p95 변화(%%) | OFF 오류율 | ON 오류율 |\n'
        printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|\n'
        "${JQ_BIN}" -r '
            def value: if . == null then "invalid" else (.*1000|round/1000|tostring) end;
            .routes[] | [
                .label,
                .workload,
                (.baseline.p50_ms | value),
                (.optimized.p50_ms | value),
                (.baseline.p95_ms | value),
                (.optimized.p95_ms | value),
                (.p95_change_pct | value),
                (.baseline.error_rate | value),
                (.optimized.error_rate | value)
            ] | @tsv
        ' "${REPORT_JSON}" | while IFS=$'\t' read -r label workload baseline_p50 optimized_p50 baseline_p95 optimized_p95 change baseline_error optimized_error; do
            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                "${label}" "${workload}" "${baseline_p50}" "${optimized_p50}" "${baseline_p95}" "${optimized_p95}" "${change}" "${baseline_error}" "${optimized_error}"
        done
        printf '\n## CPU 결과\n\n'
        printf '| 상태 | 스케줄 | drop | 창(초) | 샘플(min~max) | HTTP req/s | HTTP 오류율 | 호스트 평균(%%) | 호스트 최대(%%) | PHP-FPM 평균(%%) | PHP-FPM 최대(%%) | MySQL 평균(%%) | MySQL 최대(%%) |\n'
        printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'
        "${JQ_BIN}" -r '
            def value: if . == null then "n/a" else (.*1000|round/1000|tostring) end;
            .cpu[] | [
                .phase,
                (.schedule_valid | tostring),
                (.dropped_iterations | value),
                (.configured_window_seconds | value),
                ((.samples_min | tostring) + "~" + (.samples_max | tostring)),
                (.http_requests_per_second | value),
                (.http_failure_rate | value),
                (.host_busy_avg_pct | value),
                (.host_busy_max_pct | value),
                (.php_fpm_cpu_avg_pct | value),
                (.php_fpm_cpu_max_pct | value),
                (.mysql_cpu_avg_pct | value),
                (.mysql_cpu_max_pct | value)
            ] | @tsv
        ' "${REPORT_JSON}" | while IFS=$'\t' read -r phase schedule dropped window samples http_rate http_error host_avg host_max php_avg php_max mysql_avg mysql_max; do
            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                "${phase}" "${schedule}" "${dropped}" "${window}" "${samples}" "${http_rate}" "${http_error}" "${host_avg}" "${host_max}" "${php_avg}" "${php_max}" "${mysql_avg}" "${mysql_max}"
        done
        printf '\n변화율은 `(튜닝 ON - OFF) / OFF` 기준이므로, 음수일수록 빨라진 것입니다.\n'
    } > "${REPORT_MD}"

    [[ -s "${REPORT_JSON}" && -s "${REPORT_CSV}" && -s "${CPU_REPORT_CSV}" && -s "${REPORT_MD}" ]] \
        && "${JQ_BIN}" -e '.metadata.final_state == "optimized" and (.routes | length > 0)' "${REPORT_JSON}" >/dev/null
}

ensure_final_on() {
    if assert_final_live_health; then
        return 0
    fi
    log 'retrying normal tuning ON, strict verification, and live health'
    if wait_for_database_idle \
        && run_toggle on \
        && assert_final_live_health; then
        return 0
    fi
    log 'retrying fail-closed recovery, strict verification, and live health'
    wait_for_database_idle || return 1
    run_toggle on --recover-fail-closed || return 1
    assert_final_live_health
}

assert_final_live_health() {
    local board_encoded board_payload product_payload
    assert_ab_lock || return 1
    confirm_state optimized || return 1
    "${CURL_BIN}" --fail --silent --show-error --max-time "${REQUEST_TIMEOUT_SECONDS}" \
        -o /dev/null "${BASE_URL}/" || {
        log 'final home health request failed'
        return 1
    }
    board_encoded="$("${JQ_BIN}" -rn --arg value "${BOARD_SLUG}" '$value|@uri')"
    board_payload="$(api_get "/api/modules/sirsoft-board/boards/${board_encoded}/posts?page=1&per_page=20")" \
        || return 1
    product_payload="$(api_get '/api/modules/sirsoft-ecommerce/products?page=1&per_page=12')" \
        || return 1
    if ! "${JQ_BIN}" -e '
        .success == true
        and .data.pagination.current_page == 1
        and (.data.data | type == "array" and length > 0)
    ' <<<"${board_payload}" >/dev/null; then
        log 'final board-list health response failed semantic validation'
        return 1
    fi
    if ! "${JQ_BIN}" -e '
        .success == true
        and .data.pagination.current_page == 1
        and (.data.data | type == "array" and length > 0)
    ' <<<"${product_payload}" >/dev/null; then
        log 'final product-list health response failed semantic validation'
        return 1
    fi
}

cleanup() {
    local original_status=$? cleanup_status=0 pre_restore_healthy=1
    [[ "${CLEANUP_RUNNING}" == 0 ]] || return
    CLEANUP_RUNNING=1
    trap - EXIT INT TERM
    set +e
    stop_cpu_sampler
    if [[ "${AB_MUTATION_STARTED}" == 1 ]] && ! ensure_final_on; then
        log 'tuning ON with strict/live health was not confirmed while the temporary SELECT cap was active'
        pre_restore_healthy=0
    fi
    if ! restore_mysql_guard; then
        log 'FINAL FAILURE: MySQL SELECT timeout could not be restored'
        cleanup_status=1
    fi
    if [[ "${AB_MUTATION_STARTED}" == 1 ]]; then
        if [[ "${pre_restore_healthy}" == 0 ]]; then
            log 'retrying tuning ON recovery after restoring the MySQL SELECT cap'
        fi
        if ! ensure_final_on; then
            log 'FINAL FAILURE: tuning ON strict/live health could not be recovered after guard restoration'
            cleanup_status=1
        fi
    fi
    if ! release_ab_lock; then
        log 'FINAL FAILURE: remote A/B lock could not be released by its owner'
        cleanup_status=1
    fi
    if [[ "${cleanup_status}" != 0 ]]; then
        rm -f -- "${REPORT_JSON}" "${REPORT_CSV}" "${CPU_REPORT_CSV}" "${REPORT_MD}"
        exit 1
    fi
    exit "${original_status}"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

log "reports: ${OUTPUT_DIR}"
"${SSH_BIN}" "${REMOTE_HOST}" true >/dev/null
acquire_ab_lock
"${CURL_BIN}" --fail --silent --show-error --max-time "${REQUEST_TIMEOUT_SECONDS}" \
    -o /dev/null "${BASE_URL}/"
install_mysql_guard
wait_for_database_idle

AB_MUTATION_STARTED=1
run_toggle off
confirm_state baseline || fail 'OFF transition did not reach a strict baseline state'
assert_xdebug_disabled
discover_targets
validate_search_targets
write_route_manifest

baseline_result=0
run_phase baseline || baseline_result=$?
[[ "${baseline_result}" == 0 ]] || MAIN_STATUS=1

wait_for_database_idle || fail 'database remained busy after baseline runs; arbitrary query kill is prohibited'
run_toggle on
confirm_state optimized || fail 'ON transition did not reach a strict optimized state'
assert_xdebug_disabled

optimized_result=0
run_phase optimized || optimized_result=$?
[[ "${optimized_result}" == 0 ]] || MAIN_STATUS=1
wait_for_database_idle || fail 'database remained busy after optimized runs'
confirm_state optimized || fail 'optimized state drifted during benchmark'

generate_reports || MAIN_STATUS=1
if [[ -f "${REPORT_MD}" ]]; then
    log "Markdown: ${REPORT_MD}"
    log "JSON: ${REPORT_JSON}"
    log "CSV: ${REPORT_CSV}"
    log "CPU CSV: ${CPU_REPORT_CSV}"
fi

exit "${MAIN_STATUS}"
