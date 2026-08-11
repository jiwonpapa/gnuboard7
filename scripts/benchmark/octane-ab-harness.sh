#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
LOAD_SCRIPT="${SCRIPT_DIR}/octane-load.js"
RELOAD_PROBE_SCRIPT="${SCRIPT_DIR}/octane-reload-probe.php"

ACTION="${1:-doctor}"
[[ $# -gt 0 ]] && shift

PHP_BIN="${G7_OCTANE_PHP_BIN:-php}"
COMPOSER_BIN="${G7_OCTANE_COMPOSER_BIN:-composer}"
K6_BIN="${G7_OCTANE_K6_BIN:-k6}"
HOST="${G7_OCTANE_HOST:-127.0.0.1}"
BASELINE_PORT="${G7_OCTANE_BASELINE_PORT:-18080}"
OCTANE_PORT="${G7_OCTANE_PORT:-18081}"
OCTANE_RPC_PORT="${G7_OCTANE_RPC_PORT:-16001}"
FRANKENPHP_ADMIN_PORT="${G7_OCTANE_FRANKENPHP_ADMIN_PORT:-2019}"
FRANKENPHP_DB_SOCKET="${G7_OCTANE_FRANKENPHP_DB_SOCKET:-}"
OCTANE_SERVER="${G7_OCTANE_SERVER:-roadrunner}"
BASELINE_URL="${G7_OCTANE_BASELINE_URL:-}"
REQUEST_HOST="${G7_OCTANE_REQUEST_HOST:-}"
WORKERS="${G7_OCTANE_WORKERS:-2}"
MAX_REQUESTS="${G7_OCTANE_MAX_REQUESTS:-500}"
VUS="${G7_OCTANE_VUS:-5}"
DURATION="${G7_OCTANE_DURATION:-15s}"
WARMUP_REQUESTS="${G7_OCTANE_WARMUP_REQUESTS:-20}"
SMOKE_REPEATS="${G7_OCTANE_SMOKE_REPEATS:-3}"
PERF_PATH="${G7_OCTANE_PERF_PATH:-/}"
PERF_EXPECTED_STATUS="${G7_OCTANE_PERF_EXPECTED_STATUS:-200}"
MAX_P95_REGRESSION="${G7_OCTANE_MAX_P95_REGRESSION:-1.10}"
MIN_RPS_RATIO="${G7_OCTANE_MIN_RPS_RATIO:-0.90}"
READY_TIMEOUT="${G7_OCTANE_READY_TIMEOUT:-45}"
OUTPUT_DIR=""
RESTORE_RUN_DIR=""
PERFORMANCE_GATE=1
RELOAD_PROBE=0
CUSTOM_PROBES=0
PROBES=("/=200" "/admin=200" "/api/admin/license=401")

BASELINE_PID=""
OCTANE_PID=""
BASELINE_MANAGED=0
RUN_DIR=""
STATE_DIR=""
MUTATION_STARTED=0
RESTORE_COMPLETE=0
FINAL_EXIT=0

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/octane-ab-harness.sh ACTION [options]

Actions:
  doctor              Check whether an A/B run is safe to start.
  run                 Measure classic Laravel and temporary Octane, then restore.
  restore             Restore a run interrupted before automatic cleanup.
  help                Show this help.

Run options:
  --baseline-url URL  Existing PHP-FPM/Nginx URL. If omitted, the harness starts
                      a classic Laravel development server on the baseline port.
  --request-host HOST Send the same HTTP Host header to both runtimes. This is
                      useful for a real Nginx vhost and loopback Octane comparison.
  --baseline-port N   Managed baseline port. Default: 18080.
  --octane-port N     Temporary Octane HTTP port. Default: 18081.
  --server NAME       Octane server: roadrunner or frankenphp.
                      Default: roadrunner.
  --rpc-port N        Temporary RoadRunner RPC port. Default: 16001.
  --admin-port N      Temporary FrankenPHP admin port. Default: 2019.
  --frankenphp-db-socket PATH
                      Explicit MySQL socket for FrankenPHP's embedded PHP. If
                      omitted, a usable system PHP socket is detected when needed.
  --workers N         Octane worker count. The managed PHP baseline uses the same
                      value; an external PHP-FPM baseline must be matched separately.
                      Default: 2.
  --max-requests N    Octane worker recycle count. Default: 500.
  --vus N             k6 virtual users. Default: 5.
  --duration VALUE    k6 duration. Default: 15s.
  --warmup N          Warm-up requests per runtime. Default: 20.
  --probe PATH=STATUS Repeatable correctness probe. Supplying one replaces defaults.
  --performance-path PATH
                      Endpoint used for load. Default: /.
  --performance-status STATUS
                      Expected load endpoint status. Default: 200.
  --max-p95-regression RATIO
                      Maximum Octane/baseline p95 ratio. Default: 1.10.
  --min-rps-ratio RATIO
                      Minimum Octane/baseline requests-per-second ratio. Default: 0.90.
  --no-performance-gate
                      Record performance without failing on the ratios.
  --reload-probe      Fire a harmless plugin-updated hook. RoadRunner must
                      replace worker PIDs; FrankenPHP must accept a Caddy
                      worker reload and retain the configured worker count.
  --output-dir PATH   Result directory. Default: storage/app/benchmark/octane-ab/<UTC>.

Restore options:
  --run-dir PATH      Run directory containing state/manifest.sh.

Examples:
  scripts/benchmark/octane-ab-harness.sh doctor
  scripts/benchmark/octane-ab-harness.sh run --vus 10 --duration 30s
  scripts/benchmark/octane-ab-harness.sh run --server frankenphp \
    --workers 2 --admin-port 2019
  scripts/benchmark/octane-ab-harness.sh run \
    --baseline-url http://127.0.0.1 --request-host www.example.test \
    --performance-path /api/modules/sirsoft-board/boards
  scripts/benchmark/octane-ab-harness.sh restore --run-dir storage/app/benchmark/octane-ab/20260811T120000Z
EOF
}

log() { printf '[g7-octane-ab] %s\n' "$*"; }
fail() { printf '[g7-octane-ab] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-url) shift; BASELINE_URL="${1:-}" ;;
        --request-host) shift; REQUEST_HOST="${1:-}" ;;
        --baseline-port) shift; BASELINE_PORT="${1:-}" ;;
        --octane-port) shift; OCTANE_PORT="${1:-}" ;;
        --server) shift; OCTANE_SERVER="${1:-}" ;;
        --rpc-port) shift; OCTANE_RPC_PORT="${1:-}" ;;
        --admin-port) shift; FRANKENPHP_ADMIN_PORT="${1:-}" ;;
        --frankenphp-db-socket) shift; FRANKENPHP_DB_SOCKET="${1:-}" ;;
        --workers) shift; WORKERS="${1:-}" ;;
        --max-requests) shift; MAX_REQUESTS="${1:-}" ;;
        --vus) shift; VUS="${1:-}" ;;
        --duration) shift; DURATION="${1:-}" ;;
        --warmup) shift; WARMUP_REQUESTS="${1:-}" ;;
        --probe)
            shift
            if [[ "${CUSTOM_PROBES}" == 0 ]]; then
                PROBES=()
                CUSTOM_PROBES=1
            fi
            PROBES+=("${1:-}")
            ;;
        --performance-path) shift; PERF_PATH="${1:-}" ;;
        --performance-status) shift; PERF_EXPECTED_STATUS="${1:-}" ;;
        --max-p95-regression) shift; MAX_P95_REGRESSION="${1:-}" ;;
        --min-rps-ratio) shift; MIN_RPS_RATIO="${1:-}" ;;
        --no-performance-gate) PERFORMANCE_GATE=0 ;;
        --reload-probe) RELOAD_PROBE=1 ;;
        --output-dir) shift; OUTPUT_DIR="${1:-}" ;;
        --run-dir) shift; RESTORE_RUN_DIR="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

validate_number() {
    local name="$1" value="$2" minimum="$3"
    [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge "${minimum}" ]] \
        || fail "${name} must be an integer greater than or equal to ${minimum}"
}

validate_options() {
    [[ "${OCTANE_SERVER}" == roadrunner || "${OCTANE_SERVER}" == frankenphp ]] \
        || fail 'server must be roadrunner or frankenphp'
    validate_number workers "${WORKERS}" 1
    validate_number max-requests "${MAX_REQUESTS}" 1
    validate_number vus "${VUS}" 1
    validate_number warmup "${WARMUP_REQUESTS}" 0
    validate_number smoke-repeats "${SMOKE_REPEATS}" 1
    validate_number baseline-port "${BASELINE_PORT}" 1024
    validate_number octane-port "${OCTANE_PORT}" 1024
    if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
        validate_number rpc-port "${OCTANE_RPC_PORT}" 1024
    else
        validate_number admin-port "${FRANKENPHP_ADMIN_PORT}" 1024
        [[ "${HOST}" == 127.0.0.1 || "${HOST}" == ::1 ]] \
            || fail 'FrankenPHP harness runs must bind to a loopback host'
    fi
    validate_number performance-status "${PERF_EXPECTED_STATUS}" 100
    [[ "${DURATION}" =~ ^[1-9][0-9]*(ms|s|m)$ ]] || fail 'duration must look like 500ms, 15s, or 2m'
    [[ "${PERF_PATH}" == /* ]] || fail 'performance-path must start with /'
    [[ "${MAX_P95_REGRESSION}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'invalid max-p95-regression'
    [[ "${MIN_RPS_RATIO}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'invalid min-rps-ratio'
    if [[ -n "${REQUEST_HOST}" ]]; then
        [[ "${REQUEST_HOST}" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
            || fail 'request-host must be a DNS host with an optional port'
    fi
    if [[ -n "${FRANKENPHP_DB_SOCKET}" ]]; then
        [[ "${FRANKENPHP_DB_SOCKET}" == /* ]] \
            || fail 'frankenphp-db-socket must be an absolute path'
    fi

    local probe path status
    for probe in "${PROBES[@]}"; do
        path="${probe%=*}"
        status="${probe##*=}"
        [[ "${path}" == /* && "${status}" =~ ^[1-5][0-9][0-9]$ && "${path}" != "${probe}" ]] \
            || fail "invalid probe '${probe}'; expected PATH=STATUS"
    done
}

require_commands() {
    local command_name
    for command_name in "${PHP_BIN}" "${COMPOSER_BIN}" "${K6_BIN}" curl jq tar shasum; do
        command -v "${command_name}" >/dev/null 2>&1 || fail "required command not found: ${command_name}"
    done
    [[ -f "${REPO_ROOT}/artisan" && -f "${REPO_ROOT}/composer.json" ]] \
        || fail "invalid Gnuboard7 repository: ${REPO_ROOT}"
    [[ -f "${LOAD_SCRIPT}" ]] || fail "k6 scenario not found: ${LOAD_SCRIPT}"
    [[ -f "${RELOAD_PROBE_SCRIPT}" ]] || fail "reload probe not found: ${RELOAD_PROBE_SCRIPT}"
}

port_is_open() {
    # PHP source must receive literal $argv variables.
    # shellcheck disable=SC2016
    "${PHP_BIN}" -r '$s=@fsockopen($argv[1],(int)$argv[2],$e,$m,0.5); if($s){fclose($s);exit(0);} exit(1);' "$1" "$2"
}

doctor() {
    validate_options
    require_commands

    local failed=0
    log "repository=${REPO_ROOT}"
    log "octane_server=${OCTANE_SERVER}"
    log "php=$(${PHP_BIN} -r 'echo PHP_VERSION;')"
    log "composer=$(${COMPOSER_BIN} --version --no-ansi 2>/dev/null | head -1)"
    log "k6=$(${K6_BIN} version 2>/dev/null | head -1)"

    if "${PHP_BIN}" artisan about --only=environment --no-ansi >/dev/null 2>&1; then
        log 'application_boot=ok'
    else
        log 'application_boot=failed'
        failed=1
    fi

    if "${PHP_BIN}" artisan migrate:status --no-ansi >/dev/null 2>&1; then
        log 'database=ok'
    else
        log 'database=failed'
        failed=1
    fi

    if [[ -z "${BASELINE_URL}" ]] && port_is_open "${HOST}" "${BASELINE_PORT}"; then
        log "baseline_port=busy:${BASELINE_PORT}"
        failed=1
    fi
    if port_is_open "${HOST}" "${OCTANE_PORT}"; then
        log "octane_port=busy:${OCTANE_PORT}"
        failed=1
    fi
    if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
        if port_is_open "${HOST}" "${OCTANE_RPC_PORT}"; then
            log "octane_rpc_port=busy:${OCTANE_RPC_PORT}"
            failed=1
        fi
    elif port_is_open "${HOST}" "${FRANKENPHP_ADMIN_PORT}"; then
        log "frankenphp_admin_port=busy:${FRANKENPHP_ADMIN_PORT}"
        failed=1
    fi

    if grep -q '"name": "laravel/octane"' composer.lock 2>/dev/null; then
        log 'octane_dependency=present (exact state will still be restored)'
    else
        log 'octane_dependency=absent'
    fi

    [[ "${failed}" == 0 ]] || fail 'doctor failed; fix the checks above before running a benchmark'
    log 'overall=ready'
}

stop_owned_processes() {
    if [[ -n "${OCTANE_PID}" ]] && kill -0 "${OCTANE_PID}" 2>/dev/null; then
        if [[ -f "${REPO_ROOT}/artisan" ]] && "${PHP_BIN}" artisan list --raw 2>/dev/null | grep -q '^octane:stop'; then
            "${PHP_BIN}" artisan octane:stop --server="${OCTANE_SERVER}" --no-interaction >/dev/null 2>&1 || true
        fi
        kill "${OCTANE_PID}" 2>/dev/null || true
        wait "${OCTANE_PID}" 2>/dev/null || true
    fi
    OCTANE_PID=""

    if [[ -n "${BASELINE_PID}" ]] && kill -0 "${BASELINE_PID}" 2>/dev/null; then
        kill "${BASELINE_PID}" 2>/dev/null || true
        wait "${BASELINE_PID}" 2>/dev/null || true
    fi
    BASELINE_PID=""
}

snapshot_state() {
    STATE_DIR="${RUN_DIR}/state"
    mkdir -p "${STATE_DIR}/files"

    local original_vendor=0
    [[ -d "${REPO_ROOT}/vendor" ]] && original_vendor=1

    local managed_files=(
        composer.json composer.lock .gitignore config/octane.php
        rr .rr.yaml frankenphp frankenphp.backup public/frankenphp-worker.php
        storage/app/g7_installed
    )
    local path
    : > "${STATE_DIR}/existing-files.txt"
    for path in "${managed_files[@]}"; do
        if [[ -e "${REPO_ROOT}/${path}" || -L "${REPO_ROOT}/${path}" ]]; then
            mkdir -p "${STATE_DIR}/files/$(dirname -- "${path}")"
            cp -p "${REPO_ROOT}/${path}" "${STATE_DIR}/files/${path}"
            printf '%s\n' "${path}" >> "${STATE_DIR}/existing-files.txt"
        fi
    done

    tar -cf "${STATE_DIR}/bootstrap-cache.tar" -C "${REPO_ROOT}" bootstrap/cache

    local composer_json_sha composer_lock_sha env_sha octane_server_line octane_server_count
    composer_json_sha="$(shasum -a 256 "${REPO_ROOT}/composer.json" | awk '{print $1}')"
    composer_lock_sha="-"
    [[ -f "${REPO_ROOT}/composer.lock" ]] \
        && composer_lock_sha="$(shasum -a 256 "${REPO_ROOT}/composer.lock" | awk '{print $1}')"
    env_sha='-'
    octane_server_line=''
    octane_server_count=0
    if [[ -f "${REPO_ROOT}/.env" ]]; then
        env_sha="$(shasum -a 256 "${REPO_ROOT}/.env" | awk '{print $1}')"
        octane_server_count="$(grep -c '^OCTANE_SERVER=' "${REPO_ROOT}/.env" || true)"
        [[ "${octane_server_count}" -le 1 ]] \
            || fail '.env must not contain more than one OCTANE_SERVER entry'
        [[ "${octane_server_count}" == 0 ]] \
            || octane_server_line="$(grep '^OCTANE_SERVER=' "${REPO_ROOT}/.env")"
    fi

    {
        printf 'SNAPSHOT_REPO_ROOT=%q\n' "${REPO_ROOT}"
        printf 'ORIGINAL_VENDOR=%q\n' "${original_vendor}"
        printf 'ORIGINAL_COMPOSER_JSON_SHA=%q\n' "${composer_json_sha}"
        printf 'ORIGINAL_COMPOSER_LOCK_SHA=%q\n' "${composer_lock_sha}"
        printf 'ORIGINAL_ENV_SHA=%q\n' "${env_sha}"
        printf 'ORIGINAL_OCTANE_SERVER_COUNT=%q\n' "${octane_server_count}"
        printf 'ORIGINAL_OCTANE_SERVER_LINE=%q\n' "${octane_server_line}"
        printf 'RUN_OCTANE_SERVER=%q\n' "${OCTANE_SERVER}"
    } > "${STATE_DIR}/manifest.sh"
    printf 'snapshot\n' > "${STATE_DIR}/phase"
}

restore_snapshot() {
    local restore_state_dir="$1"
    [[ -f "${restore_state_dir}/manifest.sh" ]] || fail "restore manifest not found: ${restore_state_dir}"

    # The run-specific manifest path is validated above.
    # shellcheck disable=SC1090,SC1091
    source "${restore_state_dir}/manifest.sh"
    : "${ORIGINAL_VENDOR:?restore manifest is missing ORIGINAL_VENDOR}"
    ORIGINAL_ENV_SHA="${ORIGINAL_ENV_SHA:--}"
    ORIGINAL_OCTANE_SERVER_COUNT="${ORIGINAL_OCTANE_SERVER_COUNT:-0}"
    ORIGINAL_OCTANE_SERVER_LINE="${ORIGINAL_OCTANE_SERVER_LINE:-}"
    RUN_OCTANE_SERVER="${RUN_OCTANE_SERVER:-roadrunner}"
    [[ "${SNAPSHOT_REPO_ROOT}" == "${REPO_ROOT}" ]] \
        || fail "snapshot belongs to another repository: ${SNAPSHOT_REPO_ROOT}"

    log 'restoring original Composer, Octane, and cache state'
    local managed_files=(
        composer.json composer.lock .gitignore config/octane.php
        rr .rr.yaml frankenphp frankenphp.backup public/frankenphp-worker.php
        storage/app/g7_installed
    )
    local path
    for path in "${managed_files[@]}"; do
        rm -f "${REPO_ROOT}/${path}"
    done
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        mkdir -p "${REPO_ROOT}/$(dirname -- "${path}")"
        cp -p "${restore_state_dir}/files/${path}" "${REPO_ROOT}/${path}"
    done < "${restore_state_dir}/existing-files.txt"

    restore_octane_environment

    if [[ "${ORIGINAL_VENDOR}" == 1 ]]; then
        "${COMPOSER_BIN}" install --no-interaction --no-progress --prefer-dist \
            > "${RUN_DIR}/restore-composer.log" 2>&1
    else
        rm -rf "${REPO_ROOT}/vendor"
    fi

    restore_bootstrap_cache "${restore_state_dir}"

    local restored_json_sha restored_lock_sha
    restored_json_sha="$(shasum -a 256 "${REPO_ROOT}/composer.json" | awk '{print $1}')"
    restored_lock_sha="-"
    [[ -f "${REPO_ROOT}/composer.lock" ]] \
        && restored_lock_sha="$(shasum -a 256 "${REPO_ROOT}/composer.lock" | awk '{print $1}')"

    [[ "${restored_json_sha}" == "${ORIGINAL_COMPOSER_JSON_SHA}" ]] \
        || fail 'composer.json checksum mismatch after restore'
    [[ "${restored_lock_sha}" == "${ORIGINAL_COMPOSER_LOCK_SHA}" ]] \
        || fail 'composer.lock checksum mismatch after restore'
    if [[ "${ORIGINAL_ENV_SHA}" != '-' ]]; then
        [[ "$(shasum -a 256 "${REPO_ROOT}/.env" | awk '{print $1}')" == "${ORIGINAL_ENV_SHA}" ]] \
            || fail '.env checksum mismatch after restore'
    fi
    "${PHP_BIN}" artisan about --only=environment --no-ansi > "${RUN_DIR}/restore-artisan-about.log" 2>&1 \
        || fail 'application does not boot after restore'

    printf 'restored\n' > "${restore_state_dir}/phase"
    RESTORE_COMPLETE=1
    MUTATION_STARTED=0
    log 'restore=verified'
}

restore_octane_environment() {
    local env_file="${REPO_ROOT}/.env"
    [[ "${ORIGINAL_ENV_SHA}" != '-' && -f "${env_file}" ]] || return

    "${PHP_BIN}" -r '
        [$path, $count, $original] = array_slice($argv, 1);
        $contents = file_get_contents($path);
        if ((int) $count === 1) {
            $contents = preg_replace("/^OCTANE_SERVER=.*$/m", $original, $contents);
        } else {
            $contents = preg_replace("/(?:\\r?\\n)OCTANE_SERVER=[^\\r\\n]*(?:\\r?\\n)\\z/", "", $contents);
        }
        if (file_put_contents($path, $contents) === false) {
            exit(1);
        }
    ' "${env_file}" "${ORIGINAL_OCTANE_SERVER_COUNT}" "${ORIGINAL_OCTANE_SERVER_LINE}" \
        || fail 'failed to restore OCTANE_SERVER in .env'
}

restore_bootstrap_cache() {
    local restore_state_dir="$1"
    find "${REPO_ROOT}/bootstrap/cache" -mindepth 1 -maxdepth 1 -type f -delete
    tar -xf "${restore_state_dir}/bootstrap-cache.tar" -C "${REPO_ROOT}"
}

cleanup_on_exit() {
    local exit_code=$?
    set +e
    stop_owned_processes
    if [[ "${MUTATION_STARTED}" == 1 && "${RESTORE_COMPLETE}" == 0 && -n "${STATE_DIR}" ]]; then
        restore_snapshot "${STATE_DIR}"
        local restore_code=$?
        if [[ "${restore_code}" != 0 ]]; then
            printf '[g7-octane-ab] ERROR: automatic restore failed; run restore --run-dir %s\n' "${RUN_DIR}" >&2
            exit_code=2
        fi
    fi
    set -e
    exit "${exit_code}"
}

trap cleanup_on_exit EXIT INT TERM

wait_for_http() {
    local url="$1" expected="$2" deadline=$((SECONDS + READY_TIMEOUT)) code
    local body="${RUN_DIR}/.ready-body"
    local host_args=()
    [[ -z "${REQUEST_HOST}" ]] || host_args=(-H "Host: ${REQUEST_HOST}")
    while (( SECONDS < deadline )); do
        code="$(curl -sS "${host_args[@]}" -o "${body}" -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || true)"
        if [[ "${code}" == "${expected}" && -s "${body}" ]]; then
            rm -f "${body}"
            return 0
        fi
        sleep 1
    done
    rm -f "${body}"
    return 1
}

start_baseline() {
    if [[ "${BASELINE_MANAGED}" == 0 ]]; then
        BASELINE_URL="${BASELINE_URL%/}"
        log "using external baseline=${BASELINE_URL}"
        log "external baseline worker count is not controlled; verify it matches Octane workers=${WORKERS}"
        return
    fi

    BASELINE_URL="http://${HOST}:${BASELINE_PORT}"
    log "starting managed classic baseline=${BASELINE_URL}"
    # Run PHP's server directly. Artisan ServeCommand forwards only $_ENV and
    # can lose process-only APP_KEY/DB variables in checkouts without .env.
    (
        cd "${REPO_ROOT}/public"
        PHP_CLI_SERVER_WORKERS="${WORKERS}" exec "${PHP_BIN}" \
            -d variables_order=EGPCS -S "${HOST}:${BASELINE_PORT}" \
            "${REPO_ROOT}/vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php"
    ) > "${RUN_DIR}/baseline-server.log" 2>&1 &
    BASELINE_PID=$!

    local first_probe="${PROBES[0]}"
    wait_for_http "${BASELINE_URL}${first_probe%=*}" "${first_probe##*=}" \
        || fail "baseline did not become ready; see ${RUN_DIR}/baseline-server.log"
}

start_octane() {
    local octane_url="http://${HOST}:${OCTANE_PORT}"
    log "starting temporary Octane server=${OCTANE_SERVER} url=${octane_url}"
    local start_env=(OCTANE_HTTPS=false)
    [[ -z "${FRANKENPHP_DB_SOCKET}" ]] \
        || start_env+=("DB_SOCKET=${FRANKENPHP_DB_SOCKET}")
    if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
        env "${start_env[@]}" "${PHP_BIN}" artisan octane:start \
            --server=roadrunner --host="${HOST}" --port="${OCTANE_PORT}" \
            --rpc-port="${OCTANE_RPC_PORT}" --workers="${WORKERS}" \
            --max-requests="${MAX_REQUESTS}" --no-interaction \
            > "${RUN_DIR}/octane-server.log" 2>&1 &
    else
        env "${start_env[@]}" "${PHP_BIN}" artisan octane:start \
            --server=frankenphp --host="${HOST}" --port="${OCTANE_PORT}" \
            --admin-port="${FRANKENPHP_ADMIN_PORT}" --workers="${WORKERS}" \
            --max-requests="${MAX_REQUESTS}" \
            --caddyfile="${RUN_DIR}/frankenphp.Caddyfile" --no-interaction \
            > "${RUN_DIR}/octane-server.log" 2>&1 &
    fi
    OCTANE_PID=$!

    local first_probe="${PROBES[0]}"
    wait_for_http "${octane_url}${first_probe%=*}" "${first_probe##*=}" \
        || fail "Octane did not become ready; see ${RUN_DIR}/octane-server.log"
}

run_smoke() {
    local phase="$1" base_url="$2"
    local output="${RUN_DIR}/${phase}-smoke.tsv"
    local failures=0 probe path expected repeat body headers code content_type
    local host_args=()
    [[ -z "${REQUEST_HOST}" ]] || host_args=(-H "Host: ${REQUEST_HOST}")
    printf 'path\texpected\tactual\tcontent_type\tbody_bytes\n' > "${output}"

    for probe in "${PROBES[@]}"; do
        path="${probe%=*}"
        expected="${probe##*=}"
        for ((repeat = 1; repeat <= SMOKE_REPEATS; repeat++)); do
            body="${RUN_DIR}/.${phase}-body-${repeat}"
            headers="${RUN_DIR}/.${phase}-headers-${repeat}"
            code="$(curl -sS "${host_args[@]}" --max-time 20 -D "${headers}" -o "${body}" -w '%{http_code}' "${base_url}${path}" || true)"
            content_type="$(awk 'tolower($0) ~ /^content-type:/{gsub(/\r/,""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "${headers}")"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "${path}" "${expected}" "${code}" "${content_type:--}" "$(wc -c < "${body}" | tr -d ' ')" \
                >> "${output}"
            if [[ "${code}" != "${expected}" || ! -s "${body}" ]]; then
                failures=$((failures + 1))
            fi
            rm -f "${body}" "${headers}"
        done
    done

    [[ "${failures}" == 0 ]] || return 1
}

warm_up() {
    local base_url="$1" i code
    local host_args=()
    [[ -z "${REQUEST_HOST}" ]] || host_args=(-H "Host: ${REQUEST_HOST}")
    for ((i = 1; i <= WARMUP_REQUESTS; i++)); do
        code="$(curl -sS "${host_args[@]}" -o /dev/null -w '%{http_code}' --max-time 20 "${base_url}${PERF_PATH}" || true)"
        [[ "${code}" == "${PERF_EXPECTED_STATUS}" ]] \
            || fail "warm-up failed for ${base_url}${PERF_PATH}: expected ${PERF_EXPECTED_STATUS}, got ${code}"
    done
}

run_load() {
    local phase="$1" base_url="$2"
    local summary="${RUN_DIR}/${phase}-k6-summary.json"
    BASE_URL="${base_url}" REQUEST_HOST="${REQUEST_HOST}" PERF_PATH="${PERF_PATH}" EXPECTED_STATUS="${PERF_EXPECTED_STATUS}" \
        VUS="${VUS}" DURATION="${DURATION}" SUMMARY_PATH="${summary}" \
        "${K6_BIN}" run --quiet "${LOAD_SCRIPT}" \
        > "${RUN_DIR}/${phase}-k6.log" 2>&1
}

octane_worker_pids() {
    [[ "${OCTANE_SERVER}" == roadrunner ]] || return 0
    pgrep -f "${REPO_ROOT}/vendor/bin/roadrunner-worker$" 2>/dev/null \
        | sort -n | tr '\n' ',' | sed 's/,$//' || true
}

run_reload_probe() {
    local before after deadline=$((SECONDS + 15))
    if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
        before="$(octane_worker_pids)"
        [[ -n "${before}" ]] || return 1
    else
        before="$(curl -sS --max-time 5 "http://${HOST}:${FRANKENPHP_ADMIN_PORT}/config/apps/frankenphp/workers" \
            | jq -c . 2>/dev/null || true)"
        [[ -n "${before}" ]] || return 1
    fi

    CACHE_STORE="${CACHE_STORE:-file}" SESSION_DRIVER="${SESSION_DRIVER:-array}" \
        QUEUE_CONNECTION="${QUEUE_CONNECTION:-sync}" \
        "${PHP_BIN}" "${RELOAD_PROBE_SCRIPT}" \
        > "${RUN_DIR}/octane-reload-probe.log" 2>&1 || return 1

    while (( SECONDS < deadline )); do
        if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
            after="$(octane_worker_pids)"
            if [[ -n "${after}" && "${after}" != "${before}" ]]; then
                printf 'before=%s\nafter=%s\n' "${before}" "${after}" \
                    >> "${RUN_DIR}/octane-reload-probe.log"
                local first_probe="${PROBES[0]}"
                wait_for_http "http://${HOST}:${OCTANE_PORT}${first_probe%=*}" "${first_probe##*=}" \
                    && return 0
            fi
        else
            after="$(curl -sS --max-time 5 "http://${HOST}:${FRANKENPHP_ADMIN_PORT}/config/apps/frankenphp/workers" \
                | jq -c . 2>/dev/null || true)"
            if jq -en --argjson workers "${after:-null}" --argjson expected "${WORKERS}" \
                '($workers | type) == "array" and ($workers | length) > 0 and $workers[0].num == $expected' >/dev/null; then
                printf 'reload_via=caddy_admin_config_patch\nbefore=%s\nafter=%s\n' "${before}" "${after}" \
                    >> "${RUN_DIR}/octane-reload-probe.log"
                local first_probe="${PROBES[0]}"
                wait_for_http "http://${HOST}:${OCTANE_PORT}${first_probe%=*}" "${first_probe##*=}" \
                    && return 0
            fi
        fi
        sleep 1
    done

    printf 'before=%s\nafter=%s\n' "${before}" "${after:-}" \
        >> "${RUN_DIR}/octane-reload-probe.log"
    return 1
}

compare_smoke_contracts() {
    awk -F '\t' '
        NR == FNR { if (FNR > 1) baseline[FNR] = $1 FS $3 FS $4; next }
        FNR > 1 && baseline[FNR] != ($1 FS $3 FS $4) { mismatches++ }
        END { exit mismatches > 0 ? 1 : 0 }
    ' "${RUN_DIR}/baseline-smoke.tsv" "${RUN_DIR}/octane-smoke.tsv"
}

process_tree_rss_kb() {
    local root_pid="$1"
    if [[ -z "${root_pid}" ]] || ! kill -0 "${root_pid}" 2>/dev/null; then
        printf 'null\n'
        return
    fi

    local queue=("${root_pid}") pids=() current child total=0 rss
    while [[ "${#queue[@]}" -gt 0 ]]; do
        current="${queue[0]}"
        queue=("${queue[@]:1}")
        pids+=("${current}")
        while IFS= read -r child; do
            [[ -n "${child}" ]] && queue+=("${child}")
        done < <(pgrep -P "${current}" 2>/dev/null || true)
    done
    for current in "${pids[@]}"; do
        rss="$(ps -o rss= -p "${current}" 2>/dev/null | tr -d ' ' || true)"
        [[ "${rss}" =~ ^[0-9]+$ ]] && total=$((total + rss))
    done
    printf '%s\n' "${total}"
}

snapshot_log_offsets() {
    local phase="$1"
    local offsets="${RUN_DIR}/.${phase}-log-offsets.tsv"
    local log_file
    : > "${offsets}"
    while IFS= read -r log_file; do
        printf '%s\t%s\n' "${log_file}" "$(wc -c < "${log_file}" | tr -d ' ')" >> "${offsets}"
    done < <(find "${REPO_ROOT}/storage/logs" -maxdepth 1 -type f -name 'laravel*.log' -print 2>/dev/null | sort)
}

extract_new_errors() {
    local phase="$1"
    local offsets="${RUN_DIR}/.${phase}-log-offsets.tsv"
    local output="${RUN_DIR}/${phase}-new-errors.log"
    local log_file start_offset
    : > "${output}"
    while IFS= read -r log_file; do
        start_offset="$(awk -F '\t' -v path="${log_file}" '$1 == path { print $2; found=1 } END { if (! found) print 0 }' "${offsets}")"
        tail -c "+$((start_offset + 1))" "${log_file}" \
            | grep -E '\.(WARNING|ERROR|CRITICAL|ALERT|EMERGENCY):|Fatal error|Uncaught ' \
            >> "${output}" || true
    done < <(find "${REPO_ROOT}/storage/logs" -maxdepth 1 -type f -name 'laravel*.log' -print 2>/dev/null | sort)
}

app_config_value() {
    local key="$1"
    "${PHP_BIN}" -r '
        $root = $argv[1];
        require $root."/vendor/autoload.php";
        $app = require $root."/bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        echo (string) config($argv[2], "");
    ' "${REPO_ROOT}" "${key}"
}

prepare_frankenphp_runtime() {
    local stub="${REPO_ROOT}/vendor/laravel/octane/src/Commands/stubs/Caddyfile"
    local caddyfile="${RUN_DIR}/frankenphp.Caddyfile"
    [[ -x "${REPO_ROOT}/frankenphp" ]] || fail 'FrankenPHP binary was not installed'
    [[ -f "${stub}" ]] || fail 'Laravel Octane FrankenPHP Caddyfile stub is missing'

    # Keep Laravel's host-agnostic http://:<port> site address so an Nginx vhost
    # Host header is accepted, while binding the actual listener to loopback only.
    awk -v bind_host="${HOST}" '
        { print }
        $0 == "{$CADDY_SERVER_SERVER_NAME} {" { print "\tbind " bind_host }
    ' "${stub}" > "${caddyfile}"
    grep -q "^[[:space:]]*bind ${HOST}$" "${caddyfile}" \
        || fail 'failed to create loopback-only FrankenPHP Caddyfile'

    local configured_host configured_socket system_socket embedded_socket
    configured_host="$(app_config_value 'database.connections.mysql.host')"
    configured_socket="$(app_config_value 'database.connections.mysql.unix_socket')"
    system_socket="$(${PHP_BIN} -r 'echo (string) ini_get("pdo_mysql.default_socket");')"
    embedded_socket="$("${REPO_ROOT}/frankenphp" php-cli -r 'echo (string) ini_get("pdo_mysql.default_socket");')"

    {
        "${REPO_ROOT}/frankenphp" version
        printf 'system_php=%s\n' "$(${PHP_BIN} -r 'echo PHP_VERSION;')"
        printf 'embedded_php=%s\n' "$("${REPO_ROOT}/frankenphp" php-cli -r 'echo PHP_VERSION;')"
        printf 'configured_db_host=%s\n' "${configured_host}"
        printf 'configured_db_socket=%s\n' "${configured_socket}"
        printf 'system_default_socket=%s\n' "${system_socket}"
        printf 'embedded_default_socket=%s\n' "${embedded_socket}"
    } > "${RUN_DIR}/frankenphp-runtime.txt"

    if [[ -n "${FRANKENPHP_DB_SOCKET}" ]]; then
        [[ -S "${FRANKENPHP_DB_SOCKET}" ]] \
            || fail "FrankenPHP DB socket is not available: ${FRANKENPHP_DB_SOCKET}"
    elif [[ "${configured_host}" == localhost && -z "${configured_socket}" \
        && -n "${system_socket}" && "${system_socket}" != "${embedded_socket}" \
        && -S "${system_socket}" ]]; then
        FRANKENPHP_DB_SOCKET="${system_socket}"
        log "FrankenPHP DB socket compatibility=${FRANKENPHP_DB_SOCKET}"
    fi

    "${REPO_ROOT}/frankenphp" php-cli -m > "${RUN_DIR}/frankenphp-extensions.txt"
    local extension
    for extension in pdo_mysql redis mbstring intl gd curl openssl zip pcntl sodium fileinfo; do
        grep -iq "^${extension}$" "${RUN_DIR}/frankenphp-extensions.txt" \
            || fail "FrankenPHP embedded PHP extension is missing: ${extension}"
    done
}

install_octane() {
    MUTATION_STARTED=1
    printf 'installing\n' > "${STATE_DIR}/phase"
    log "installing temporary Octane server=${OCTANE_SERVER}"
    local packages=('laravel/octane:^2.18')
    if [[ "${OCTANE_SERVER}" == roadrunner ]]; then
        packages+=('spiral/roadrunner-cli:^2.6' 'spiral/roadrunner-http:^3.3')
    fi
    "${COMPOSER_BIN}" require "${packages[@]}" \
        --with-all-dependencies --no-interaction --no-progress \
        > "${RUN_DIR}/octane-composer-install.log" 2>&1

    "${PHP_BIN}" artisan octane:install --server="${OCTANE_SERVER}" --no-interaction \
        > "${RUN_DIR}/octane-install.log" 2>&1

    # Composer package discovery는 확장 PSR-4/classmap 캐시를 만들지 않습니다.
    # Octane worker가 모듈 미들웨어 등을 해석할 수 있도록 설치 직후 갱신합니다.
    if "${PHP_BIN}" artisan list --raw 2>/dev/null | grep -q '^extension:update-autoload'; then
        "${PHP_BIN}" artisan extension:update-autoload --no-interaction \
            >> "${RUN_DIR}/octane-install.log" 2>&1
    fi

    if [[ "${OCTANE_SERVER}" == roadrunner && ! -x "${REPO_ROOT}/rr" ]]; then
        "${REPO_ROOT}/vendor/bin/rr" get-binary \
            >> "${RUN_DIR}/octane-install.log" 2>&1
        chmod +x "${REPO_ROOT}/rr"
    elif [[ "${OCTANE_SERVER}" == frankenphp ]]; then
        prepare_frankenphp_runtime
    fi

    local cache_env=()
    [[ -z "${FRANKENPHP_DB_SOCKET}" ]] \
        || cache_env+=("DB_SOCKET=${FRANKENPHP_DB_SOCKET}")
    env "${cache_env[@]}" "${PHP_BIN}" artisan config:cache --no-interaction \
        >> "${RUN_DIR}/octane-install.log" 2>&1
    printf 'installed\n' > "${STATE_DIR}/phase"
}

metric_value() {
    local file="$1" expression="$2"
    jq -r "${expression} // 0" "${file}"
}

write_report() {
    local baseline_summary="${RUN_DIR}/baseline-k6-summary.json"
    local octane_summary="${RUN_DIR}/octane-k6-summary.json"
    local baseline_avg baseline_p95 baseline_p99 baseline_rps baseline_count
    local octane_avg octane_p95 octane_p99 octane_rps octane_count
    baseline_avg="$(metric_value "${baseline_summary}" '.metrics.http_req_duration.values.avg')"
    baseline_p95="$(metric_value "${baseline_summary}" '.metrics.http_req_duration.values["p(95)"]')"
    baseline_p99="$(metric_value "${baseline_summary}" '.metrics.http_req_duration.values["p(99)"]')"
    baseline_rps="$(metric_value "${baseline_summary}" '.metrics.http_reqs.values.rate')"
    baseline_count="$(metric_value "${baseline_summary}" '.metrics.http_reqs.values.count')"
    octane_avg="$(metric_value "${octane_summary}" '.metrics.http_req_duration.values.avg')"
    octane_p95="$(metric_value "${octane_summary}" '.metrics.http_req_duration.values["p(95)"]')"
    octane_p99="$(metric_value "${octane_summary}" '.metrics.http_req_duration.values["p(99)"]')"
    octane_rps="$(metric_value "${octane_summary}" '.metrics.http_reqs.values.rate')"
    octane_count="$(metric_value "${octane_summary}" '.metrics.http_reqs.values.count')"

    local p95_ratio rps_ratio performance_pass=true
    p95_ratio="$(jq -n --argjson o "${octane_p95}" --argjson b "${baseline_p95}" 'if $b > 0 then $o / $b else 0 end')"
    rps_ratio="$(jq -n --argjson o "${octane_rps}" --argjson b "${baseline_rps}" 'if $b > 0 then $o / $b else 0 end')"
    if [[ "${PERFORMANCE_GATE}" == 1 ]] && ! jq -en \
        --argjson p95 "${p95_ratio}" --argjson max "${MAX_P95_REGRESSION}" \
        --argjson rps "${rps_ratio}" --argjson min "${MIN_RPS_RATIO}" \
        '$p95 <= $max and $rps >= $min' >/dev/null; then
        performance_pass=false
        FINAL_EXIT=1
    fi

    local baseline_errors octane_errors
    baseline_errors="$(wc -l < "${RUN_DIR}/baseline-new-errors.log" | tr -d ' ')"
    octane_errors="$(wc -l < "${RUN_DIR}/octane-new-errors.log" | tr -d ' ')"
    if [[ "${baseline_errors}" -gt 0 || "${octane_errors}" -gt 0 ]]; then
        FINAL_EXIT=1
    fi

    jq -n \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg octane_server "${OCTANE_SERVER}" \
        --arg baseline_url "${BASELINE_URL}" \
        --arg octane_url "http://${HOST}:${OCTANE_PORT}" \
        --argjson workers "${WORKERS}" --argjson vus "${VUS}" \
        --arg duration "${DURATION}" --arg path "${PERF_PATH}" \
        --arg request_host "${REQUEST_HOST}" \
        --argjson baseline_avg "${baseline_avg}" --argjson baseline_p95 "${baseline_p95}" \
        --argjson baseline_p99 "${baseline_p99}" --argjson baseline_rps "${baseline_rps}" \
        --argjson baseline_count "${baseline_count}" --argjson baseline_rss "${BASELINE_RSS_KB}" \
        --argjson octane_avg "${octane_avg}" --argjson octane_p95 "${octane_p95}" \
        --argjson octane_p99 "${octane_p99}" --argjson octane_rps "${octane_rps}" \
        --argjson octane_count "${octane_count}" --argjson octane_rss "${OCTANE_RSS_KB}" \
        --argjson p95_ratio "${p95_ratio}" --argjson rps_ratio "${rps_ratio}" \
        --argjson baseline_errors "${baseline_errors}" --argjson octane_errors "${octane_errors}" \
        --argjson performance_pass "${performance_pass}" \
        --arg reload_probe "${RELOAD_PROBE_RESULT}" \
        '{generated_at:$generated_at,scenario:{octane_server:$octane_server,workers:$workers,vus:$vus,duration:$duration,path:$path,request_host:$request_host,reload_probe:$reload_probe},
          baseline:{url:$baseline_url,avg_ms:$baseline_avg,p95_ms:$baseline_p95,p99_ms:$baseline_p99,rps:$baseline_rps,requests:$baseline_count,rss_kb:$baseline_rss,new_errors:$baseline_errors},
          octane:{url:$octane_url,avg_ms:$octane_avg,p95_ms:$octane_p95,p99_ms:$octane_p99,rps:$octane_rps,requests:$octane_count,rss_kb:$octane_rss,new_errors:$octane_errors},
          comparison:{p95_ratio:$p95_ratio,rps_ratio:$rps_ratio,performance_gate_passed:$performance_pass},restore:{verified:true}}' \
        > "${RUN_DIR}/comparison.json"

    {
        printf '# 그누보드7 PHP 기본 실행 방식 / Octane A/B 결과\n\n'
        printf -- '- 측정 시각: `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf -- '- Octane 서버: `%s`\n' "${OCTANE_SERVER}"
        printf -- '- 시나리오: `%s`, VU `%s`, `%s`, 워커 `%s`\n' "${PERF_PATH}" "${VUS}" "${DURATION}" "${WORKERS}"
        [[ -z "${REQUEST_HOST}" ]] || printf -- '- 요청 Host: `%s`\n' "${REQUEST_HOST}"
        printf -- '- 확장 변경 후 워커 재적용: `%s`\n' "${RELOAD_PROBE_RESULT}"
        printf -- '- 복구 검증: `완료`\n\n'
        printf '| 항목 | 기본 실행 | Octane | 비율 |\n'
        printf '|---|---:|---:|---:|\n'
        printf '| 평균 응답(ms) | %.2f | %.2f | - |\n' "${baseline_avg}" "${octane_avg}"
        printf '| p95(ms) | %.2f | %.2f | %.3f |\n' "${baseline_p95}" "${octane_p95}" "${p95_ratio}"
        printf '| p99(ms) | %.2f | %.2f | - |\n' "${baseline_p99}" "${octane_p99}"
        printf '| 요청/초 | %.2f | %.2f | %.3f |\n' "${baseline_rps}" "${octane_rps}" "${rps_ratio}"
        printf '| 요청 수 | %.0f | %.0f | - |\n' "${baseline_count}" "${octane_count}"
        printf '| 프로세스 RSS(KB) | %s | %s | - |\n' "${BASELINE_RSS_KB}" "${OCTANE_RSS_KB}"
        printf '| 새 경고·오류 로그 | %s | %s | - |\n\n' "${baseline_errors}" "${octane_errors}"
        printf -- '- 성능 기준 통과: `%s`\n' "${performance_pass}"
        printf -- '- 원본 체크섬과 애플리케이션 부팅 복구: `통과`\n'
    } > "${RUN_DIR}/report.md"
}

verify_restored_http() {
    if [[ "${BASELINE_URL}" == http://${HOST}:${BASELINE_PORT} ]]; then
        local marker="${REPO_ROOT}/storage/app/g7_installed"
        local temporary_marker=0
        local smoke_status=0
        if [[ ! -e "${marker}" ]]; then
            touch "${marker}"
            temporary_marker=1
        fi

        # 원본 상태에 확장 오토로드 캐시가 없던 격리 복제본도 HTTP 검증은
        # 수행하되, 검증이 끝나면 snapshot의 bootstrap/cache를 다시 복원합니다.
        if "${PHP_BIN}" artisan list --raw 2>/dev/null | grep -q '^extension:update-autoload'; then
            "${PHP_BIN}" artisan extension:update-autoload --no-interaction \
                > "${RUN_DIR}/restore-extension-autoload.log" 2>&1
        fi
        start_baseline
        run_smoke restored "${BASELINE_URL}" || smoke_status=$?
        stop_owned_processes
        restore_bootstrap_cache "${STATE_DIR}"
        [[ "${temporary_marker}" == 0 ]] || rm -f "${marker}"
        [[ "${smoke_status}" == 0 ]] || fail 'restored classic runtime failed HTTP smoke'
    else
        run_smoke restored "${BASELINE_URL}" \
            || fail 'external baseline failed after restore'
    fi
}

run_benchmark() {
    [[ -z "${BASELINE_URL}" ]] && BASELINE_MANAGED=1
    doctor

    if [[ -z "${OUTPUT_DIR}" ]]; then
        OUTPUT_DIR="${REPO_ROOT}/storage/app/benchmark/octane-ab/$(date -u +%Y%m%dT%H%M%SZ)"
    elif [[ "${OUTPUT_DIR}" != /* ]]; then
        OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}"
    fi
    RUN_DIR="${OUTPUT_DIR}"
    [[ ! -e "${RUN_DIR}" ]] || fail "output directory already exists: ${RUN_DIR}"
    mkdir -p "${RUN_DIR}"
    snapshot_state
    MUTATION_STARTED=1
    printf 'preparing\n' > "${STATE_DIR}/phase"

    # public/index.php checks this file before Laravel is bootstrapped. A healthy
    # benchmark database is sufficient for this isolated run; the snapshot makes
    # sure a marker that did not exist beforehand is removed during restoration.
    touch "${REPO_ROOT}/storage/app/g7_installed"

    # 관리형 Classic 서버도 일반 웹 요청처럼 확장 미들웨어를 해석하므로,
    # 복제 환경에서 bootstrap/cache를 비운 경우 기준선 측정 전에 재생성합니다.
    if "${PHP_BIN}" artisan list --raw 2>/dev/null | grep -q '^extension:update-autoload'; then
        "${PHP_BIN}" artisan extension:update-autoload --no-interaction \
            > "${RUN_DIR}/baseline-extension-autoload.log" 2>&1
    fi

    snapshot_log_offsets baseline
    start_baseline
    run_smoke baseline "${BASELINE_URL}" || fail 'baseline correctness smoke failed'
    warm_up "${BASELINE_URL}"
    run_load baseline "${BASELINE_URL}" || FINAL_EXIT=1
    BASELINE_RSS_KB="$(process_tree_rss_kb "${BASELINE_PID}")"
    extract_new_errors baseline
    stop_owned_processes

    install_octane
    snapshot_log_offsets octane
    start_octane
    local octane_url="http://${HOST}:${OCTANE_PORT}"
    run_smoke octane "${octane_url}" || fail 'Octane correctness smoke failed'
    compare_smoke_contracts || fail 'baseline and Octane smoke response contracts differ'
    RELOAD_PROBE_RESULT='not_run'
    if [[ "${RELOAD_PROBE}" == 1 ]]; then
        if run_reload_probe; then
            RELOAD_PROBE_RESULT='passed'
        else
            RELOAD_PROBE_RESULT='failed'
            FINAL_EXIT=1
        fi
    fi
    warm_up "${octane_url}"
    run_load octane "${octane_url}" || FINAL_EXIT=1
    OCTANE_RSS_KB="$(process_tree_rss_kb "${OCTANE_PID}")"
    extract_new_errors octane
    stop_owned_processes

    restore_snapshot "${STATE_DIR}"
    verify_restored_http
    write_report

    log "report=${RUN_DIR}/report.md"
    log "comparison=${RUN_DIR}/comparison.json"
    [[ "${FINAL_EXIT}" == 0 ]] || fail 'comparison completed and restored, but one or more acceptance gates failed'
    log 'overall=pass'
}

manual_restore() {
    [[ -n "${RESTORE_RUN_DIR}" ]] || fail 'restore requires --run-dir'
    if [[ "${RESTORE_RUN_DIR}" != /* ]]; then
        RESTORE_RUN_DIR="${REPO_ROOT}/${RESTORE_RUN_DIR}"
    fi
    RUN_DIR="${RESTORE_RUN_DIR}"
    STATE_DIR="${RUN_DIR}/state"
    if [[ -f "${STATE_DIR}/manifest.sh" ]]; then
        # Run metadata contains no credentials and selects the server that must stop.
        # shellcheck disable=SC1090,SC1091
        source "${STATE_DIR}/manifest.sh"
        OCTANE_SERVER="${RUN_OCTANE_SERVER:-roadrunner}"
    fi
    MUTATION_STARTED=1
    stop_owned_processes
    if "${PHP_BIN}" artisan list --raw 2>/dev/null | grep -q '^octane:stop'; then
        "${PHP_BIN}" artisan octane:stop --server="${OCTANE_SERVER}" --no-interaction >/dev/null 2>&1 || true
    fi
    restore_snapshot "${STATE_DIR}"
}

case "${ACTION}" in
    doctor) doctor ;;
    run) run_benchmark ;;
    restore) manual_restore ;;
    help|-h|--help) usage ;;
    *) fail "unknown action: ${ACTION}" ;;
esac
