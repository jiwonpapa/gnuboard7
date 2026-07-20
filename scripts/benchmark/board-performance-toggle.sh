#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

ACTION="${1:-status}"
[[ $# -gt 0 ]] && shift

REMOTE_HOST="${G7_BOARD_PERF_HOST:-g7devops}"
REMOTE_ROOT="${G7_BOARD_PERF_ROOT:-/home/g7devops/public_html}"
REMOTE_APP_USER="${G7_BOARD_PERF_APP_USER:-g7devops}"
REMOTE_PHP_BIN="${G7_BOARD_PERF_PHP_BIN:-php}"
REMOTE_DB_NAME="${G7_BOARD_PERF_DB_NAME:-g7devops}"
REMOTE_DB_PREFIX="${G7_BOARD_PERF_DB_PREFIX:-g7_}"
BASELINE_REF="${G7_BOARD_PERF_BASELINE_REF:-7.0.5}"
BENCHMARK_BASELINE_REF="${G7_BOARD_PERF_BENCHMARK_BASELINE_REF:-e64381ddb5ba02caed60933427fbb86ef72ef94e}"
OPTIMIZED_REF="${G7_BOARD_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_BOARD_PERF_BASE_URL:-https://www.g7devops.com}"
SSH_CONNECT_TIMEOUT_SECONDS="${G7_BOARD_PERF_SSH_CONNECT_TIMEOUT_SECONDS:-${G7_PERF_SSH_CONNECT_TIMEOUT_SECONDS:-10}}"
SSH_SERVER_ALIVE_INTERVAL_SECONDS="${G7_BOARD_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-${G7_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-15}}"
SSH_SERVER_ALIVE_COUNT_MAX="${G7_BOARD_PERF_SSH_SERVER_ALIVE_COUNT_MAX:-${G7_PERF_SSH_SERVER_ALIVE_COUNT_MAX:-3}}"
SSH_BIN="${G7_BOARD_PERF_SSH_BIN:-${G7_PERF_SSH_BIN:-ssh}}"
SCP_BIN="${G7_BOARD_PERF_SCP_BIN:-${G7_PERF_SCP_BIN:-scp}}"
FT_RESULT_CACHE_LIMIT_BYTES="${G7_BOARD_PERF_FT_RESULT_CACHE_LIMIT_BYTES:-33554432}"
FT_RESULT_CACHE_PREVIOUS_FALLBACK="${G7_BOARD_PERF_FT_RESULT_CACHE_PREVIOUS_FALLBACK:-2000000000}"
ASSUME_YES=0
RUN_SMOKE=1
DEFER_RUNTIME=0
ORCHESTRATION_TOKEN="-"
PREFLIGHT_ONLY=0
PREPARE_ARCHIVE="-"
PROVIDED_REMOTE_ARCHIVE="-"

COMMON_PATHS=(
    "app/Http/Requests/Public/SearchRequest.php"
    "app/Search/Engines/DatabaseFulltextEngine.php"
    "routes/api.php"
    "modules/_bundled/sirsoft-board/CHANGELOG.md"
    "modules/_bundled/sirsoft-board/composer.json"
    "modules/_bundled/sirsoft-board/module.json"
    "modules/_bundled/sirsoft-board/package-lock.json"
    "modules/_bundled/sirsoft-board/package.json"
    "modules/_bundled/sirsoft-board/database/seeders/Sample/PostSampleSeeder.php"
    "modules/_bundled/sirsoft-board/src/Http/Controllers/Admin/PostController.php"
    "modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php"
    "modules/_bundled/sirsoft-board/src/Http/Resources/PostCollection.php"
    "modules/_bundled/sirsoft-board/src/Listeners/SearchPostsListener.php"
    "modules/_bundled/sirsoft-board/src/Providers/BoardServiceProvider.php"
    "modules/_bundled/sirsoft-board/src/Repositories/Contracts/PostRepositoryInterface.php"
    "modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php"
    "modules/_bundled/sirsoft-board/src/Services/PostService.php"
    "modules/_bundled/sirsoft-board/src/routes/api.php"
)

OPTIMIZED_ONLY_PATHS=(
    "config/benchmark.php"
    "modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php"
    "modules/_bundled/sirsoft-board/database/migrations/2026_07_16_000001_create_board_post_author_terms_table.php"
    "modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php"
    "modules/_bundled/sirsoft-board/src/Observers/PostAuthorTermObserver.php"
)

BENCHMARK_PATHS=(
    "modules/_bundled/sirsoft-benchmark/CHANGELOG.md"
    "modules/_bundled/sirsoft-benchmark/composer.json"
    "modules/_bundled/sirsoft-benchmark/module.json"
    "modules/_bundled/sirsoft-benchmark/package.json"
    "modules/_bundled/sirsoft-benchmark/src/Services/Support/BoardCounterSyncService.php"
)

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/board-performance-toggle.sh ACTION [options]

Actions:
  on                Deploy the optimized source, enable the optimized branch,
                    and create/show the benchmark indexes.
  off               Select the original G7 7.0.5 runtime branches and make the
                    benchmark indexes invisible. This is the fast A/B toggle.
  status            Report source integrity, effective branch, indexes, module,
                    PHP-FPM, and the last harness state.
  restore-original  Restore official 7.0.5 files and remove benchmark indexes
                    and the migration row. Requires --yes.

Options:
  --yes             Required for restore-original.
  --no-smoke        Skip the first-page HTTP smoke request.
  --host HOST       SSH alias. Default: g7devops
  --root PATH       Remote app root. Default: /home/g7devops/public_html
  --app-user USER   Remote PHP-FPM/app user. Default: g7devops
  --php-bin BIN     Remote PHP binary. Default: php
  --db NAME         Remote database name. Default: g7devops
  --db-prefix NAME  Remote table prefix. Default: g7_
  --baseline REF    Git ref for exact source restore. Default: 7.0.5
  --benchmark-baseline-ref REF
                    Pre-tuning sirsoft-benchmark Git ref used by exact restore.
  --optimized-ref REF
                    Reviewed optimized Git ref. Default: HEAD.
  --base-url URL    URL used by smoke requests.
  --ssh-connect-timeout SEC
                    SSH connection timeout. Default: 10.
  --ssh-alive-interval SEC
                    SSH keepalive interval. Default: 15.
  --ssh-alive-count N
                    Missed keepalives before disconnect. Default: 3.
  --defer-runtime   Internal: let the unified harness rebuild caches once.
  --lock-token ID   Internal: reuse the unified harness transaction lock.
  --preflight-only  Internal: build and verify the source archive locally only.
  --prepare-archive PATH
                    Internal: write the exact verified archive to PATH and exit.
  --remote-archive PATH
                    Internal: apply a previously uploaded verified archive.
  -h, --help        Show this help.

Environment variables use the same names with the G7_BOARD_PERF_ prefix.
The FULLTEXT result cache safety guard is fixed at 33554432 bytes for ON/OFF.
EOF
}

log() {
    printf '[board-perf] %s\n' "$*"
}

fail() {
    printf '[board-perf] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

copy_optimized_file() {
    local path="$1"
    local destination="$2"

    git -C "${REPO_ROOT}" cat-file -e "${OPTIMIZED_REF}:${path}" 2>/dev/null \
        || fail "optimized file not found at ${OPTIMIZED_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${OPTIMIZED_REF}:${path}" > "${destination}/${path}"
}

copy_ref_file() {
    local ref="$1"
    local path="$2"
    local destination="$3"

    git -C "${REPO_ROOT}" cat-file -e "${ref}:${path}" 2>/dev/null \
        || fail "source file not found at ${ref}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${ref}:${path}" > "${destination}/${path}"
}

build_source_archive() {
    local variant="$1"
    local stage_dir="${WORK_DIR}/${variant}"
    local archive="${WORK_DIR}/board-performance-${variant}.tar.gz"
    local path source_ref source_ref_input
    local -a manifest_paths

    mkdir -p "${stage_dir}/.harness"
    manifest_paths=()

    for path in "${COMMON_PATHS[@]}"; do
        if [[ "${variant}" == "optimized" ]]; then
            copy_optimized_file "${path}" "${stage_dir}"
        else
            copy_ref_file "${BASELINE_REF}" "${path}" "${stage_dir}"
        fi
        manifest_paths+=("${path}")
    done

    if [[ "${variant}" == "optimized" ]]; then
        for path in "${OPTIMIZED_ONLY_PATHS[@]}"; do
            copy_optimized_file "${path}" "${stage_dir}"
            manifest_paths+=("${path}")
        done
    fi

    for path in "${BENCHMARK_PATHS[@]}"; do
        if [[ "${variant}" == "optimized" ]]; then
            copy_optimized_file "${path}" "${stage_dir}"
        else
            copy_ref_file "${BENCHMARK_BASELINE_REF}" "${path}" "${stage_dir}"
        fi
        manifest_paths+=("${path}")
    done

    source_ref_input="${OPTIMIZED_REF}"
    [[ "${variant}" == "optimized" ]] || source_ref_input="${BASELINE_REF}"
    source_ref="$(git -C "${REPO_ROOT}" rev-parse --verify "${source_ref_input}")"
    [[ "${source_ref}" =~ ^[0-9a-f]{40}$ ]] \
        || fail "could not resolve exact ${variant} board source ref"
    printf '%s\n' "${variant}" > "${stage_dir}/.harness/source-variant"
    printf '%s\n' "${source_ref}" > "${stage_dir}/.harness/source-ref"
    (
        cd "${stage_dir}"
        for path in "${manifest_paths[@]}"; do
            shasum -a 256 "${path}"
        done > ".harness/source.sha256"
        COPYFILE_DISABLE=1 tar --no-xattrs -czf "${archive}" .
    )

    printf '%s' "${archive}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES=1
            ;;
        --no-smoke)
            RUN_SMOKE=0
            ;;
        --host)
            shift
            REMOTE_HOST="${1:-}"
            ;;
        --root)
            shift
            REMOTE_ROOT="${1:-}"
            ;;
        --app-user)
            shift
            REMOTE_APP_USER="${1:-}"
            ;;
        --php-bin)
            shift
            REMOTE_PHP_BIN="${1:-}"
            ;;
        --db)
            shift
            REMOTE_DB_NAME="${1:-}"
            ;;
        --db-prefix)
            shift
            REMOTE_DB_PREFIX="${1:-}"
            ;;
        --baseline)
            shift
            BASELINE_REF="${1:-}"
            ;;
        --benchmark-baseline-ref)
            shift
            BENCHMARK_BASELINE_REF="${1:-}"
            ;;
        --optimized-ref)
            shift
            OPTIMIZED_REF="${1:-}"
            ;;
        --base-url)
            shift
            BASE_URL="${1:-}"
            ;;
        --ssh-connect-timeout)
            shift
            SSH_CONNECT_TIMEOUT_SECONDS="${1:-}"
            ;;
        --ssh-alive-interval)
            shift
            SSH_SERVER_ALIVE_INTERVAL_SECONDS="${1:-}"
            ;;
        --ssh-alive-count)
            shift
            SSH_SERVER_ALIVE_COUNT_MAX="${1:-}"
            ;;
        --defer-runtime)
            DEFER_RUNTIME=1
            ;;
        --lock-token)
            shift
            ORCHESTRATION_TOKEN="${1:-}"
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=1
            ;;
        --prepare-archive)
            shift
            PREPARE_ARCHIVE="${1:-}"
            ;;
        --remote-archive)
            shift
            PROVIDED_REMOTE_ARCHIVE="${1:-}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
    shift
done

case "${ACTION}" in
    on|off|status|restore-original)
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        fail "unknown action: ${ACTION}"
        ;;
esac

if [[ "${ACTION}" == "restore-original" && ${ASSUME_YES} -ne 1 ]]; then
    fail "restore-original drops indexes and requires --yes"
fi
if [[ "${ACTION}" != "status" && "${ORCHESTRATION_TOKEN}" == "-" ]]; then
    fail "mutating actions must run through scripts/benchmark/g7-performance-toggle.sh --scope board"
fi
[[ "${PREPARE_ARCHIVE}" == "-" || "${PROVIDED_REMOTE_ARCHIVE}" == "-" ]] \
    || fail '--prepare-archive and --remote-archive are mutually exclusive'
[[ "${SSH_CONNECT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ \
    && "${SSH_CONNECT_TIMEOUT_SECONDS}" -ge 1 && "${SSH_CONNECT_TIMEOUT_SECONDS}" -le 60 ]] \
    || fail '--ssh-connect-timeout must be between 1 and 60 seconds'
[[ "${SSH_SERVER_ALIVE_INTERVAL_SECONDS}" =~ ^[0-9]+$ \
    && "${SSH_SERVER_ALIVE_INTERVAL_SECONDS}" -ge 5 \
    && "${SSH_SERVER_ALIVE_INTERVAL_SECONDS}" -le 300 ]] \
    || fail '--ssh-alive-interval must be between 5 and 300 seconds'
[[ "${SSH_SERVER_ALIVE_COUNT_MAX}" =~ ^[0-9]+$ \
    && "${SSH_SERVER_ALIVE_COUNT_MAX}" -ge 1 && "${SSH_SERVER_ALIVE_COUNT_MAX}" -le 10 ]] \
    || fail '--ssh-alive-count must be between 1 and 10'
[[ "${FT_RESULT_CACHE_LIMIT_BYTES}" =~ ^[0-9]+$ \
    && "${FT_RESULT_CACHE_LIMIT_BYTES}" -ge 1048576 \
    && "${FT_RESULT_CACHE_LIMIT_BYTES}" -le 268435456 ]] \
    || fail 'G7_BOARD_PERF_FT_RESULT_CACHE_LIMIT_BYTES must be between 1MiB and 256MiB'
[[ "${FT_RESULT_CACHE_PREVIOUS_FALLBACK}" =~ ^[0-9]+$ \
    && "${FT_RESULT_CACHE_PREVIOUS_FALLBACK}" -ge 1048576 ]] \
    || fail 'G7_BOARD_PERF_FT_RESULT_CACHE_PREVIOUS_FALLBACK must be at least 1MiB'

[[ -f "${REPO_ROOT}/artisan" ]] || fail "repository root is invalid: ${REPO_ROOT}"
require_command "${SSH_BIN}"
require_command "${SCP_BIN}"
require_command git
require_command tar
require_command shasum
SSH_OPTIONS=(
    -o BatchMode=yes
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT_SECONDS}"
    -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL_SECONDS}"
    -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"
)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-board-performance.XXXXXX")"
REMOTE_ARCHIVE="-"
REMOTE_ARCHIVE_OWNED=0
cleanup() {
    rm -rf "${WORK_DIR}"
    if [[ "${REMOTE_ARCHIVE_OWNED}" == 1 && "${REMOTE_ARCHIVE}" != "-" ]]; then
        "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" \
            rm -f -- "${REMOTE_ARCHIVE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ "${ACTION}" == "on" || "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]]; then
    source_variant="optimized"
    [[ "${ACTION}" == "restore-original" ]] && source_variant="baseline"
    if [[ "${PROVIDED_REMOTE_ARCHIVE}" != "-" ]]; then
        [[ "${PROVIDED_REMOTE_ARCHIVE}" == /tmp/g7-board-performance-*.tar.gz ]] \
            || fail 'invalid prepared board archive path'
        REMOTE_ARCHIVE="${PROVIDED_REMOTE_ARCHIVE}"
    else
        local_archive="$(build_source_archive "${source_variant}")"
        if [[ "${PREPARE_ARCHIVE}" != "-" ]]; then
            [[ -n "${PREPARE_ARCHIVE}" ]] || fail '--prepare-archive requires a path'
            install -m 600 "${local_archive}" "${PREPARE_ARCHIVE}"
            log "${source_variant} source archive prepared"
            exit 0
        fi
        if [[ "${PREFLIGHT_ONLY}" == 1 ]]; then
            log "${source_variant} source archive preflight complete"
            exit 0
        fi
        REMOTE_ARCHIVE="/tmp/g7-board-performance-${source_variant}-$$.tar.gz"
        REMOTE_ARCHIVE_OWNED=1
        log "uploading ${source_variant} source snapshot"
        "${SCP_BIN}" "${SSH_OPTIONS[@]}" -q \
            "${local_archive}" "${REMOTE_HOST}:${REMOTE_ARCHIVE}"
    fi
fi

log "running ${ACTION} on ${REMOTE_HOST}:${REMOTE_ROOT}"
"${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo bash -s -- \
    "${ACTION}" \
    "${REMOTE_ROOT}" \
    "${REMOTE_APP_USER}" \
    "${REMOTE_PHP_BIN}" \
    "${REMOTE_DB_NAME}" \
    "${REMOTE_DB_PREFIX}" \
    "${BASE_URL}" \
    "${REMOTE_ARCHIVE}" \
    "${RUN_SMOKE}" \
    "${DEFER_RUNTIME}" \
    "${ORCHESTRATION_TOKEN}" \
    "${FT_RESULT_CACHE_LIMIT_BYTES}" \
    "${FT_RESULT_CACHE_PREVIOUS_FALLBACK}" <<'REMOTE'
set -Eeuo pipefail
trap 'result=$?; printf "[remote-board-perf] ERROR line=%s exit=%s command=%q\n" "${LINENO}" "${result}" "${BASH_COMMAND}" >&2; exit "${result}"' ERR

ACTION="$1"
APP_ROOT="$2"
APP_USER="$3"
PHP_BIN="$4"
DB_NAME="$5"
DB_PREFIX="$6"
BASE_URL="${7%/}"
SOURCE_ARCHIVE="$8"
RUN_SMOKE="$9"
DEFER_RUNTIME="${10}"
ORCHESTRATION_TOKEN="${11}"
FT_RESULT_CACHE_LIMIT_BYTES="${12}"
FT_RESULT_CACHE_PREVIOUS_FALLBACK="${13}"

ENV_KEY="G7_BOARD_PERFORMANCE_VARIANT"
POSTS_TABLE="${DB_PREFIX}board_posts"
AUTHOR_TERMS_TABLE="${DB_PREFIX}board_post_author_terms"
MODULES_TABLE="${DB_PREFIX}modules"
MIGRATIONS_TABLE="${DB_PREFIX}migrations"
LIST_MIGRATION_NAME="2026_07_15_000001_add_high_volume_list_indexes"
AUTHOR_TERMS_MIGRATION_NAME="2026_07_16_000001_create_board_post_author_terms_table"
INDEX_ID="idx_board_posts_list_id"
INDEX_VIEWS="idx_board_posts_list_views"
INDEX_FULLTEXT="ft_board_posts_title_content"
INDEX_BOARD_AUTHOR="idx_board_posts_board_author"
LIST_MIGRATION_PATH="modules/_bundled/sirsoft-board/database/migrations/${LIST_MIGRATION_NAME}.php"
ACTIVE_LIST_MIGRATION_PATH="modules/sirsoft-board/database/migrations/${LIST_MIGRATION_NAME}.php"
AUTHOR_TERMS_MIGRATION_PATH="modules/_bundled/sirsoft-board/database/migrations/${AUTHOR_TERMS_MIGRATION_NAME}.php"
ACTIVE_AUTHOR_TERMS_MIGRATION_PATH="modules/sirsoft-board/database/migrations/${AUTHOR_TERMS_MIGRATION_NAME}.php"
STATE_DIR="${APP_ROOT}/storage/app/benchmark"
STATE_FILE="${STATE_DIR}/board-performance-variant.env"
SOURCE_MANIFEST="${STATE_DIR}/board-performance-source.sha256"
SOURCE_REF_FILE="${STATE_DIR}/board-performance-source.ref"
FT_RESULT_CACHE_PREVIOUS_FILE="${STATE_DIR}/board-search-ft-result-cache.previous"
FT_PERSISTENCE_UNSUPPORTED_FILE="${STATE_DIR}/board-search-ft-result-cache.persist-unsupported"

[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || { printf 'invalid DB name\n' >&2; exit 1; }
[[ "${DB_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]] || { printf 'invalid DB prefix\n' >&2; exit 1; }
[[ "${FT_RESULT_CACHE_LIMIT_BYTES}" =~ ^[0-9]+$ \
    && "${FT_RESULT_CACHE_PREVIOUS_FALLBACK}" =~ ^[0-9]+$ ]] \
    || { printf 'invalid FULLTEXT safety guard values\n' >&2; exit 1; }
[[ -d "${APP_ROOT}" && -f "${APP_ROOT}/artisan" ]] || { printf 'invalid app root\n' >&2; exit 1; }

GLOBAL_LOCK_DIR="/var/lock/g7-performance-toggle.lock.d"
LOCK_OWNED=0

release_global_lock() {
    if [[ "${LOCK_OWNED}" == "1" ]]; then
        rm -f "${GLOBAL_LOCK_DIR}/owner"
        rmdir "${GLOBAL_LOCK_DIR}" 2>/dev/null || true
    fi
}

if [[ "${ORCHESTRATION_TOKEN}" != "-" ]]; then
    [[ -f "${GLOBAL_LOCK_DIR}/owner" ]] \
        || { printf 'unified performance lock is missing\n' >&2; exit 1; }
    [[ "$(<"${GLOBAL_LOCK_DIR}/owner")" == "${ORCHESTRATION_TOKEN}" ]] \
        || { printf 'unified performance lock owner mismatch\n' >&2; exit 1; }
else
    mkdir "${GLOBAL_LOCK_DIR}" 2>/dev/null \
        || { printf 'another performance toggle is running\n' >&2; exit 1; }
    printf 'direct-board-%s\n' "$$" > "${GLOBAL_LOCK_DIR}/owner"
    LOCK_OWNED=1
    trap release_global_lock EXIT
fi

log() {
    printf '[remote-board-perf] %s\n' "$*"
}

mysql_scalar() {
    mysql --batch --skip-column-names -e "$1"
}

mysql_ddl() {
    mysql "${DB_NAME}" -e \
        "SET SESSION lock_wait_timeout=15; SET SESSION innodb_lock_wait_timeout=15; $1"
}

ft_result_cache_limit() {
    mysql_scalar 'SELECT @@GLOBAL.innodb_ft_result_cache_limit'
}

search_sync_cap() {
    local configured
    if [[ ! -f "${APP_ROOT}/config/benchmark.php" ]] \
        || ! grep -q "'board_search_sync_cap'" "${APP_ROOT}/config/benchmark.php"; then
        printf 'unavailable'
        return
    fi
    configured="$(awk -F= '$1 == "G7_BOARD_SEARCH_SYNC_CAP" { value=$2 } END { print value }' "${APP_ROOT}/.env")"
    [[ -n "${configured}" ]] || configured=1000
    if [[ "${configured}" =~ ^[0-9]+$ ]]; then
        printf '%s' "${configured}"
    else
        printf 'invalid'
    fi
}

search_fallback_scan_cap() {
    local configured
    if [[ ! -f "${APP_ROOT}/config/benchmark.php" ]] \
        || ! grep -q "'board_search_fallback_scan_cap'" "${APP_ROOT}/config/benchmark.php"; then
        printf 'unavailable'
        return
    fi
    configured="$(awk -F= '$1 == "G7_BOARD_SEARCH_FALLBACK_SCAN_CAP" { value=$2 } END { print value }' "${APP_ROOT}/.env")"
    [[ -n "${configured}" ]] || configured=1000
    if [[ "${configured}" =~ ^[0-9]+$ ]]; then
        (( configured < 100 )) && configured=100
        (( configured > 5000 )) && configured=5000
        printf '%s' "${configured}"
    else
        printf 'invalid'
    fi
}

ft_persisted_value() {
    local available value
    if ! available="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='performance_schema' AND TABLE_NAME='persisted_variables'")"; then
        printf 'failed to inspect MySQL persisted variable support\n' >&2
        return 1
    fi
    if [[ "${available}" != "1" ]]; then
        printf 'unsupported'
        return
    fi
    if ! value="$(mysql_scalar "SELECT VARIABLE_VALUE FROM performance_schema.persisted_variables WHERE UPPER(VARIABLE_NAME)='INNODB_FT_RESULT_CACHE_LIMIT'")"; then
        printf 'failed to inspect persisted FULLTEXT result cache value\n' >&2
        return 1
    fi
    if [[ -z "${value}" ]]; then
        printf 'missing'
    else
        printf '%s' "${value}"
    fi
}

search_safety_guard_persistence() {
    local persisted
    persisted="$(ft_persisted_value)"
    if [[ "${persisted}" == "${FT_RESULT_CACHE_LIMIT_BYTES}" ]]; then
        printf 'persisted'
    elif [[ "${persisted}" == unsupported ]]; then
        printf 'unsupported'
    else
        printf 'drifted'
    fi
}

search_safety_guard_state() {
    local current sync_cap fallback_scan_cap
    current="$(ft_result_cache_limit 2>/dev/null || true)"
    sync_cap="$(search_sync_cap)"
    fallback_scan_cap="$(search_fallback_scan_cap)"
    if [[ "${current}" == "${FT_RESULT_CACHE_LIMIT_BYTES}" \
        && "${sync_cap}" == "1000" \
        && "${fallback_scan_cap}" == "1000" ]]; then
        printf 'enabled'
    else
        printf 'drifted'
    fi
}

ensure_search_safety_guard() {
    local current previous persisted persisted_state persisted_value persist_error
    current="$(ft_result_cache_limit)"
    [[ "${current}" =~ ^[0-9]+$ ]] \
        || { printf 'innodb_ft_result_cache_limit is unavailable\n' >&2; exit 1; }
    mkdir -p "${STATE_DIR}"
    if [[ ! -f "${FT_RESULT_CACHE_PREVIOUS_FILE}" ]]; then
        previous="${current}"
        [[ "${current}" != "${FT_RESULT_CACHE_LIMIT_BYTES}" ]] \
            || previous="${FT_RESULT_CACHE_PREVIOUS_FALLBACK}"
        persisted="$(ft_persisted_value)"
        persisted_state=present
        persisted_value="${persisted}"
        if [[ "${persisted}" == missing || "${persisted}" == unsupported ]]; then
            persisted_state="${persisted}"
            persisted_value='-'
        fi
        cat > "${FT_RESULT_CACHE_PREVIOUS_FILE}.tmp" <<EOF
global=${previous}
persisted_state=${persisted_state}
persisted_value=${persisted_value}
EOF
        install -o "${APP_USER}" -g www-data -m 600 \
            "${FT_RESULT_CACHE_PREVIOUS_FILE}.tmp" "${FT_RESULT_CACHE_PREVIOUS_FILE}"
        rm -f "${FT_RESULT_CACHE_PREVIOUS_FILE}.tmp"
    fi
    [[ "$(ft_persisted_value)" != unsupported ]] \
        || { printf 'persistent FULLTEXT safety guard is unsupported; refusing non-persistent activation\n' >&2; exit 1; }
    if ! persist_error="$(mysql -e "SET PERSIST innodb_ft_result_cache_limit=${FT_RESULT_CACHE_LIMIT_BYTES}" 2>&1)"; then
        printf 'SET PERSIST for FULLTEXT safety guard failed: %s\n' "${persist_error}" >&2
        exit 1
    fi
    rm -f "${FT_PERSISTENCE_UNSUPPORTED_FILE}"
    [[ "$(ft_result_cache_limit)" == "${FT_RESULT_CACHE_LIMIT_BYTES}" ]] \
        || { printf 'FULLTEXT result cache safety guard activation failed\n' >&2; exit 1; }
}

restore_search_safety_guard() {
    local previous persisted_state persisted_value persist_error
    [[ -f "${FT_RESULT_CACHE_PREVIOUS_FILE}" ]] || return 0
    previous="$(awk -F= '$1 == "global" { print $2 }' "${FT_RESULT_CACHE_PREVIOUS_FILE}")"
    persisted_state="$(awk -F= '$1 == "persisted_state" { print $2 }' "${FT_RESULT_CACHE_PREVIOUS_FILE}")"
    persisted_value="$(awk -F= '$1 == "persisted_value" { print $2 }' "${FT_RESULT_CACHE_PREVIOUS_FILE}")"
    [[ "${previous}" =~ ^[0-9]+$ ]] \
        || { printf 'saved FULLTEXT result cache value is invalid\n' >&2; exit 1; }
    case "${persisted_state}" in
        present)
            [[ "${persisted_value}" =~ ^[0-9]+$ ]] \
                || { printf 'saved persisted FULLTEXT value is invalid\n' >&2; exit 1; }
            if ! persist_error="$(mysql -e "SET PERSIST innodb_ft_result_cache_limit=${persisted_value}" 2>&1)"; then
                printf 'restoring persisted FULLTEXT value failed: %s\n' "${persist_error}" >&2
                exit 1
            fi
            ;;
        missing)
            if ! persist_error="$(mysql -e 'RESET PERSIST innodb_ft_result_cache_limit' 2>&1)"; then
                printf 'resetting persisted FULLTEXT value failed: %s\n' "${persist_error}" >&2
                exit 1
            fi
            ;;
        unsupported) ;;
        *) printf 'saved FULLTEXT persistence state is invalid\n' >&2; exit 1 ;;
    esac
    mysql -e "SET GLOBAL innodb_ft_result_cache_limit=${previous}"
    [[ "$(ft_result_cache_limit)" == "${previous}" ]] \
        || { printf 'FULLTEXT result cache safety guard restoration failed\n' >&2; exit 1; }
    rm -f "${FT_RESULT_CACHE_PREVIOUS_FILE}" "${FT_PERSISTENCE_UNSUPPORTED_FILE}"
}

table_index_exists() {
    local table_name="$1" index_name="$2"
    mysql_scalar "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table_name}' AND INDEX_NAME='${index_name}'"
}

table_index_visibility() {
    local table_name="$1" index_name="$2"
    mysql_scalar "SELECT CASE WHEN COUNT(*)=0 THEN 'MISSING' WHEN COUNT(IS_VISIBLE)=COUNT(*) AND COUNT(DISTINCT IS_VISIBLE)=1 THEN MIN(IS_VISIBLE) ELSE 'DRIFTED' END FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table_name}' AND INDEX_NAME='${index_name}'"
}

index_exists() {
    table_index_exists "${POSTS_TABLE}" "$1"
}

index_visibility() {
    table_index_visibility "${POSTS_TABLE}" "$1"
}

index_shape() {
    local index_name="$1" expected_columns="$2" expected_count="$3"
    local expected_sequence expected_directions metadata
    case "${expected_count}" in
        5) expected_sequence='1,2,3,4,5'; expected_directions='A,A,A,A,A' ;;
        6) expected_sequence='1,2,3,4,5,6'; expected_directions='A,A,A,A,A,A' ;;
        *) return 1 ;;
    esac
    metadata="$(mysql_scalar "SELECT CONCAT(COUNT(*), '|', COALESCE(GROUP_CONCAT(SEQ_IN_INDEX ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(GROUP_CONCAT(COALESCE(COLLATION, 'NULL') ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(MIN(NON_UNIQUE), ''), '|', COALESCE(MAX(NON_UNIQUE), ''), '|', COALESCE(MIN(INDEX_TYPE), ''), '|', COALESCE(MAX(INDEX_TYPE), ''), '|', COALESCE(SUM(SUB_PART IS NOT NULL), 0), '|', COALESCE(SUM(COLUMN_NAME IS NULL), 0)) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND INDEX_NAME='${index_name}'")"
    if [[ "${metadata%%|*}" == "0" ]]; then
        printf 'missing'
    elif [[ "${metadata}" == "${expected_count}|${expected_sequence}|${expected_columns}|${expected_directions}|1|1|BTREE|BTREE|0|0" ]]; then
        printf 'verified'
    else
        printf 'drifted'
    fi
}

list_id_index_shape() {
    index_shape "${INDEX_ID}" 'board_id,is_notice,parent_id,deleted_at,id' 5
}

list_views_index_shape() {
    index_shape "${INDEX_VIEWS}" 'board_id,is_notice,parent_id,deleted_at,view_count,id' 6
}

fulltext_search_index_shape() {
    local metadata create_sql server_version
    metadata="$(mysql_scalar "SELECT CONCAT(COUNT(*), '|', COALESCE(GROUP_CONCAT(SEQ_IN_INDEX ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(MIN(INDEX_TYPE), ''), '|', COALESCE(MAX(INDEX_TYPE), '')) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND INDEX_NAME='${INDEX_FULLTEXT}'")"
    if [[ "${metadata%%|*}" == "0" ]]; then
        printf 'missing'
        return
    fi
    if [[ "${metadata}" != '2|1,2|title,content|FULLTEXT|FULLTEXT' ]]; then
        printf 'drifted'
        return
    fi

    server_version="$(mysql_scalar 'SELECT VERSION()')"
    if [[ "${server_version}" != *MariaDB* ]]; then
        create_sql="$(mysql --batch --skip-column-names "${DB_NAME}" -e "SHOW CREATE TABLE ${POSTS_TABLE}")"
        if ! grep -Eiq 'FULLTEXT KEY.*ft_board_posts_title_content.*title.*content.*WITH PARSER.*ngram' \
            <<<"${create_sql}"; then
            printf 'drifted'
            return
        fi
    fi
    printf 'verified'
}

board_author_index_shape() {
    local metadata
    metadata="$(mysql_scalar "SELECT CONCAT(COUNT(*), '|', COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), '')) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND INDEX_NAME='${INDEX_BOARD_AUTHOR}' AND SEQ_IN_INDEX <= 2")"
    if [[ "${metadata%%|*}" == "0" ]]; then
        printf 'missing'
    elif [[ "${metadata}" == '2|board_id,author_name' ]]; then
        printf 'verified'
    else
        printf 'drifted'
    fi
}

user_leading_index_shape() {
    if [[ "$(mysql_scalar "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND SEQ_IN_INDEX=1 AND COLUMN_NAME='user_id' AND INDEX_TYPE='BTREE'")" != "0" ]]; then
        printf 'verified'
    else
        printf 'missing'
    fi
}

table_exists() {
    local table_name="$1"
    mysql_scalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table_name}'"
}

author_terms_structure() {
    local total_columns column_shape primary_columns source_collation terms_collation engine
    if [[ "$(table_exists "${AUTHOR_TERMS_TABLE}")" == "0" ]]; then
        printf 'missing'
        return
    fi

    engine="$(mysql_scalar "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${AUTHOR_TERMS_TABLE}'")"
    total_columns="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${AUTHOR_TERMS_TABLE}'")"
    column_shape="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${AUTHOR_TERMS_TABLE}' AND ((COLUMN_NAME='board_id' AND COLUMN_TYPE='bigint unsigned' AND IS_NULLABLE='NO') OR (COLUMN_NAME='author_name' AND DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=50 AND IS_NULLABLE='NO'))")"
    primary_columns="$(mysql_scalar "SELECT COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), '') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${AUTHOR_TERMS_TABLE}' AND INDEX_NAME='PRIMARY'")"
    source_collation="$(mysql_scalar "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND COLUMN_NAME='author_name'")"
    terms_collation="$(mysql_scalar "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${AUTHOR_TERMS_TABLE}' AND COLUMN_NAME='author_name'")"

    if [[ "${engine}" == "InnoDB" && "${total_columns}" == "2" \
        && "${column_shape}" == "2" \
        && "${primary_columns}" == "board_id,author_name" \
        && -n "${source_collation}" && "${terms_collation}" == "${source_collation}" ]]; then
        printf 'verified'
    else
        printf 'drifted'
    fi
}

author_terms_status() {
    local structure missing
    structure="$(author_terms_structure)"
    if [[ "${structure}" != "verified" ]]; then
        printf '%s|unknown' "${structure}"
        return
    fi

    missing="$(mysql_scalar "SELECT EXISTS(SELECT 1 FROM ${DB_NAME}.${POSTS_TABLE} AS p LEFT JOIN ${DB_NAME}.${AUTHOR_TERMS_TABLE} AS t ON t.board_id=p.board_id AND t.author_name=p.author_name WHERE p.author_name IS NOT NULL AND p.author_name <> '' AND t.board_id IS NULL LIMIT 1)")"
    printf '%s|%s' "${structure}" "${missing}"
}

search_physical_structure() {
    local author_status="${1:-}" author_structure author_missing
    [[ -n "${author_status}" ]] || author_status="$(author_terms_status)"
    author_structure="${author_status%%|*}"
    author_missing="${author_status#*|}"

    if [[ "$(fulltext_search_index_shape)" != "verified" \
        || "$(board_author_index_shape)" != "verified" \
        || "$(user_leading_index_shape)" != "verified" ]]; then
        printf 'drifted'
    elif [[ "${author_structure}" == "verified" && "${author_missing}" == "0" ]]; then
        printf 'verified'
    elif [[ "${author_structure}" == "missing" ]]; then
        printf 'core-only'
    else
        printf 'drifted'
    fi
}

ensure_no_long_queries() {
    local count
    count="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.PROCESSLIST AS p LEFT JOIN information_schema.INNODB_TRX AS t ON t.trx_mysql_thread_id=p.ID WHERE p.ID <> CONNECTION_ID() AND ((p.COMMAND IN ('Query','Execute') AND p.TIME >= 5) OR t.trx_mysql_thread_id IS NOT NULL)")"
    if [[ "${count}" != "0" ]]; then
        mysql --table -e "SELECT p.ID,p.USER,p.DB,p.COMMAND,p.TIME,p.STATE,t.trx_started,LEFT(p.INFO,180) AS INFO FROM information_schema.PROCESSLIST AS p LEFT JOIN information_schema.INNODB_TRX AS t ON t.trx_mysql_thread_id=p.ID WHERE p.ID <> CONNECTION_ID() AND ((p.COMMAND IN ('Query','Execute') AND p.TIME >= 5) OR t.trx_mysql_thread_id IS NOT NULL) ORDER BY p.TIME DESC"
        printf 'long-running query or open transaction detected; toggle aborted before DDL\n' >&2
        exit 1
    fi
}

set_env_variant() {
    local variant="$1"
    local temp_file
    temp_file="$(mktemp)"

    awk -v key="${ENV_KEY}" -v value="${variant}" '
        BEGIN { replaced = 0 }
        $0 ~ "^" key "=" {
            if (!replaced) {
                print key "=" value
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print key "=" value
            }
        }
    ' "${APP_ROOT}/.env" > "${temp_file}"

    chown --reference="${APP_ROOT}/.env" "${temp_file}"
    chmod --reference="${APP_ROOT}/.env" "${temp_file}"
    mv "${temp_file}" "${APP_ROOT}/.env"
}

remove_env_variant() {
    local temp_file
    temp_file="$(mktemp)"
    awk -v key="${ENV_KEY}" '$0 !~ "^" key "=" { print }' "${APP_ROOT}/.env" > "${temp_file}"
    chown --reference="${APP_ROOT}/.env" "${temp_file}"
    chmod --reference="${APP_ROOT}/.env" "${temp_file}"
    mv "${temp_file}" "${APP_ROOT}/.env"
}

capture_runtime_generation() {
    local app_uid pid started owner process_rows candidate_pids
    app_uid="$(id -u "${APP_USER}")"
    [[ "${app_uid}" =~ ^[0-9]+$ ]] || return 1
    process_rows="$(ps -u "${APP_USER}" -o pid=,args= 2>/dev/null || true)"
    candidate_pids="$(awk '
        {
            pid = $1
            $1 = ""
            sub(/^[[:space:]]+/, "")
            artisan = "(^|[[:space:]/])artisan([[:space:]]|$)"
            fpm = "(^|[[:space:]/])php-fpm[^[:space:]]*:[[:space:]]+pool([[:space:]]|$)"
            if ($0 ~ artisan || $0 ~ fpm) print pid
        }
    ' <<<"${process_rows}")" || return 1

    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]] || continue
        owner="$(stat -c '%u' "/proc/${pid}" 2>/dev/null || true)"
        [[ "${owner}" == "${app_uid}" ]] || continue
        started="$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $20 }' "/proc/${pid}/stat" 2>/dev/null || true)"
        [[ "${started}" =~ ^[0-9]+$ ]] || continue
        printf '%s:%s\n' "${pid}" "${started}"
    done <<<"${candidate_pids}"
}

runtime_generation_entry_alive() {
    local entry="$1" app_uid="$2" pid expected current owner
    [[ "${entry}" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
    pid="${BASH_REMATCH[1]}"
    expected="${BASH_REMATCH[2]}"
    [[ -r "/proc/${pid}/stat" ]] || return 1
    owner="$(stat -c '%u' "/proc/${pid}" 2>/dev/null || true)"
    [[ "${owner}" == "${app_uid}" ]] || return 1
    current="$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $20 }' "/proc/${pid}/stat" 2>/dev/null || true)"
    [[ "${current}" == "${expected}" ]]
}

wait_for_runtime_generation() {
    local app_uid deadline entry pid
    local -a live=()
    [[ $# -gt 0 ]] || return 0
    app_uid="$(id -u "${APP_USER}")"
    [[ "${app_uid}" =~ ^[0-9]+$ ]] || return 1
    deadline=$((SECONDS + 60))

    while true; do
        live=()
        for entry in "$@"; do
            runtime_generation_entry_alive "${entry}" "${app_uid}" && live+=("${entry}")
        done
        [[ ${#live[@]} -gt 0 ]] || return 0
        if (( SECONDS >= deadline )); then
            printf 'baseline runtime activation timed out; previous process generation is still alive\n' >&2
            for entry in "${live[@]}"; do
                pid="${entry%%:*}"
                printf '  stale pid=%s\n' "${pid}" >&2
                ps -o pid=,user=,etime=,args= -p "${pid}" >&2 || true
            done
            return 1
        fi
        sleep 1
    done
}

clear_runtime() {
    local force="${1:-0}" artisan_commands generation generation_output
    local -a previous_generation=()
    [[ "${DEFER_RUNTIME}" == "0" ]] || return 0
    if [[ "${force}" == "1" ]]; then
        generation_output="$(capture_runtime_generation)"
        while IFS= read -r generation; do
            [[ "${generation}" =~ ^[0-9]+:[0-9]+$ ]] && previous_generation+=("${generation}")
        done <<<"${generation_output}"
    fi
    log "rebuilding Laravel production caches"
    cd "${APP_ROOT}"
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan optimize:clear >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan config:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan route:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan view:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan hooks:cache >/dev/null
    artisan_commands="$(sudo -u "${APP_USER}" "${PHP_BIN}" artisan list --raw)"
    if grep -q '^queue:restart[[:space:]]' <<<"${artisan_commands}"; then
        sudo -u "${APP_USER}" "${PHP_BIN}" artisan queue:restart >/dev/null
    fi
    if grep -q '^horizon:terminate[[:space:]]' <<<"${artisan_commands}"; then
        sudo -u "${APP_USER}" "${PHP_BIN}" artisan horizon:terminate >/dev/null
    fi
    if grep -q '^reverb:restart[[:space:]]' <<<"${artisan_commands}"; then
        sudo -u "${APP_USER}" "${PHP_BIN}" artisan reverb:restart >/dev/null
    fi
    systemctl reload php8.5-fpm
    [[ "${force}" != "1" ]] || wait_for_runtime_generation "${previous_generation[@]}"
}

backup_current_source() {
    local backup_dir backup_file path
    local -a existing_paths
    backup_dir="/home/${APP_USER}/backups/board-performance-harness"
    backup_file="${backup_dir}/$(date +%Y%m%d-%H%M%S)-before-${ACTION}.tar.gz"
    mkdir -p "${backup_dir}"
    existing_paths=()

    while read -r path; do
        [[ -n "${path}" && -e "${APP_ROOT}/${path}" ]] && existing_paths+=("${path}")
    done <<'PATHS'
config/benchmark.php
app/Http/Requests/Public/SearchRequest.php
app/Search/Engines/DatabaseFulltextEngine.php
routes/api.php
modules/_bundled/sirsoft-board/CHANGELOG.md
modules/_bundled/sirsoft-board/composer.json
modules/_bundled/sirsoft-board/module.json
modules/_bundled/sirsoft-board/package-lock.json
modules/_bundled/sirsoft-board/package.json
modules/_bundled/sirsoft-board/database/seeders/Sample/PostSampleSeeder.php
modules/_bundled/sirsoft-board/src/Http/Controllers/Admin/PostController.php
modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php
modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php
modules/_bundled/sirsoft-board/src/Http/Resources/PostCollection.php
modules/_bundled/sirsoft-board/src/Listeners/SearchPostsListener.php
modules/_bundled/sirsoft-board/src/Observers/PostAuthorTermObserver.php
modules/_bundled/sirsoft-board/src/Providers/BoardServiceProvider.php
modules/_bundled/sirsoft-board/src/Repositories/Contracts/PostRepositoryInterface.php
modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php
modules/_bundled/sirsoft-board/src/Services/PostService.php
modules/_bundled/sirsoft-board/src/routes/api.php
modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php
modules/_bundled/sirsoft-board/database/migrations/2026_07_16_000001_create_board_post_author_terms_table.php
modules/_bundled/sirsoft-benchmark/CHANGELOG.md
modules/_bundled/sirsoft-benchmark/composer.json
modules/_bundled/sirsoft-benchmark/module.json
modules/_bundled/sirsoft-benchmark/package.json
modules/_bundled/sirsoft-benchmark/src/Services/Support/BoardCounterSyncService.php
PATHS

    while read -r path; do
        [[ -n "${path}" && -e "${APP_ROOT}/modules/sirsoft-board/${path}" ]] \
            && existing_paths+=("modules/sirsoft-board/${path}")
    done <<'PATHS'
CHANGELOG.md
composer.json
module.json
package-lock.json
package.json
database/seeders/Sample/PostSampleSeeder.php
src/Http/Controllers/Admin/PostController.php
src/Http/Controllers/User/PostController.php
src/Http/Middleware/SearchRequestThrottle.php
src/Http/Resources/PostCollection.php
src/Listeners/SearchPostsListener.php
src/Observers/PostAuthorTermObserver.php
src/Providers/BoardServiceProvider.php
src/Repositories/Contracts/PostRepositoryInterface.php
src/Repositories/PostRepository.php
src/Services/PostService.php
src/routes/api.php
database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php
database/migrations/2026_07_16_000001_create_board_post_author_terms_table.php
PATHS

    while read -r path; do
        [[ -n "${path}" && -e "${APP_ROOT}/modules/sirsoft-benchmark/${path}" ]] \
            && existing_paths+=("modules/sirsoft-benchmark/${path}")
    done <<'PATHS'
CHANGELOG.md
composer.json
module.json
package.json
src/Services/Support/BoardCounterSyncService.php
PATHS

    if [[ ${#existing_paths[@]} -gt 0 ]]; then
        tar -czf "${backup_file}" -C "${APP_ROOT}" "${existing_paths[@]}"
        chown "${APP_USER}:www-data" "${backup_file}"
    fi

    find "${backup_dir}" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
        | sort -nr \
        | tail -n +11 \
        | cut -d' ' -f2- \
        | xargs -r rm -f
}

apply_source_archive() {
    local expected_variant="$1"
    local stage_dir manifest variant source_ref checksum path source mode relative active_destination

    [[ -f "${SOURCE_ARCHIVE}" ]] || { printf 'source archive missing\n' >&2; exit 1; }
    stage_dir="$(mktemp -d)"
    tar -xzf "${SOURCE_ARCHIVE}" -C "${stage_dir}"
    variant="$(<"${stage_dir}/.harness/source-variant")"
    [[ "${variant}" == "${expected_variant}" ]] || { printf 'source archive variant mismatch\n' >&2; exit 1; }
    [[ -f "${stage_dir}/.harness/source-ref" ]] \
        || { printf 'source archive ref missing\n' >&2; exit 1; }
    source_ref="$(<"${stage_dir}/.harness/source-ref")"
    [[ "${source_ref}" =~ ^[0-9a-f]{40}$ ]] \
        || { printf 'source archive ref is invalid\n' >&2; exit 1; }
    manifest="${stage_dir}/.harness/source.sha256"
    [[ -f "${manifest}" ]] || { printf 'source archive manifest missing\n' >&2; exit 1; }
    (cd "${stage_dir}" && sha256sum -c .harness/source.sha256 >/dev/null) \
        || { printf 'source archive checksum mismatch\n' >&2; exit 1; }

    backup_current_source

    while read -r checksum path; do
        path="${path#\*}"
        source="${stage_dir}/${path}"
        [[ -f "${source}" ]] || { printf 'archive path missing: %s\n' "${path}" >&2; exit 1; }
        mode="$(stat -c '%a' "${source}")"
        install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${APP_ROOT}/${path}"

        case "${path}" in
            modules/_bundled/sirsoft-board/*)
                relative="${path#modules/_bundled/sirsoft-board/}"
                active_destination="${APP_ROOT}/modules/sirsoft-board/${relative}"
                install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${active_destination}"
                ;;
            modules/_bundled/sirsoft-benchmark/*)
                relative="${path#modules/_bundled/sirsoft-benchmark/}"
                active_destination="${APP_ROOT}/modules/sirsoft-benchmark/${relative}"
                [[ ! -d "${APP_ROOT}/modules/sirsoft-benchmark" ]] \
                    || install -D -o "${APP_USER}" -g www-data -m "${mode}" \
                        "${source}" "${active_destination}"
                ;;
        esac
    done < "${manifest}"

    if [[ "${variant}" == "baseline" ]]; then
        rm -f "${APP_ROOT}/${LIST_MIGRATION_PATH}"
        rm -f "${APP_ROOT}/${ACTIVE_LIST_MIGRATION_PATH}"
        rm -f "${APP_ROOT}/${AUTHOR_TERMS_MIGRATION_PATH}"
        rm -f "${APP_ROOT}/${ACTIVE_AUTHOR_TERMS_MIGRATION_PATH}"
        rm -f "${APP_ROOT}/modules/_bundled/sirsoft-board/src/Observers/PostAuthorTermObserver.php"
        rm -f "${APP_ROOT}/modules/sirsoft-board/src/Observers/PostAuthorTermObserver.php"
        rm -f "${APP_ROOT}/modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php"
        rm -f "${APP_ROOT}/modules/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php"
    fi

    mkdir -p "${STATE_DIR}"
    install -o "${APP_USER}" -g www-data -m 664 "${manifest}" "${SOURCE_MANIFEST}"
    install -o "${APP_USER}" -g www-data -m 664 \
        "${stage_dir}/.harness/source-ref" "${SOURCE_REF_FILE}"
    (
        cd "${APP_ROOT}"
        sha256sum -c "${SOURCE_MANIFEST}" >/dev/null
    )
    rm -rf "${stage_dir}"
}

ensure_indexes_visible() {
    local id_shape views_shape author_charset author_collation author_status author_structure
    local -a index_clauses visibility_clauses
    ensure_no_long_queries
    id_shape="$(list_id_index_shape)"
    views_shape="$(list_views_index_shape)"
    index_clauses=()

    if [[ "${id_shape}" == "drifted" ]]; then
        index_clauses+=("DROP INDEX ${INDEX_ID}")
    fi
    if [[ "${id_shape}" != "verified" ]]; then
        index_clauses+=("ADD INDEX ${INDEX_ID} (board_id, is_notice, parent_id, deleted_at, id)")
    fi
    if [[ "${views_shape}" == "drifted" ]]; then
        index_clauses+=("DROP INDEX ${INDEX_VIEWS}")
    fi
    if [[ "${views_shape}" != "verified" ]]; then
        index_clauses+=("ADD INDEX ${INDEX_VIEWS} (board_id, is_notice, parent_id, deleted_at, view_count, id)")
    fi
    if [[ ${#index_clauses[@]} -gt 0 ]]; then
        local joined
        joined="$(IFS=', '; printf '%s' "${index_clauses[*]}")"
        log "creating or repairing benchmark indexes; this may take time"
        mysql_ddl "ALTER TABLE ${POSTS_TABLE} ${joined}"
    fi
    [[ "$(list_id_index_shape)" == "verified" \
        && "$(list_views_index_shape)" == "verified" ]] \
        || { printf 'board benchmark index definition drifted\n' >&2; exit 1; }

    ensure_no_long_queries
    author_structure="$(author_terms_structure)"
    if [[ "${author_structure}" == "drifted" ]]; then
        log "recreating drifted board author search dictionary"
        mysql_ddl "DROP TABLE ${AUTHOR_TERMS_TABLE}"
    fi
    if [[ "$(table_exists "${AUTHOR_TERMS_TABLE}")" == "0" ]]; then
        author_charset="$(mysql_scalar "SELECT CHARACTER_SET_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND COLUMN_NAME='author_name'")"
        author_collation="$(mysql_scalar "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND COLUMN_NAME='author_name'")"
        [[ "${author_charset}" =~ ^[A-Za-z0-9_]+$ ]] \
            || { printf 'invalid board author charset\n' >&2; exit 1; }
        [[ "${author_collation}" =~ ^[A-Za-z0-9_]+$ ]] \
            || { printf 'invalid board author collation\n' >&2; exit 1; }
        log "creating compact board author search dictionary"
        mysql_ddl \
            "CREATE TABLE ${AUTHOR_TERMS_TABLE} (board_id BIGINT UNSIGNED NOT NULL, author_name VARCHAR(50) NOT NULL, PRIMARY KEY (board_id, author_name)) ENGINE=InnoDB DEFAULT CHARACTER SET ${author_charset} COLLATE ${author_collation}"
    fi
    [[ "$(author_terms_structure)" == "verified" ]] \
        || { printf 'board author search dictionary schema drifted\n' >&2; exit 1; }
    author_status="$(author_terms_status)"
    if [[ "${author_status}" != "verified|0" ]]; then
        log "synchronizing board author search dictionary"
        mysql "${DB_NAME}" -e \
            "INSERT IGNORE INTO ${AUTHOR_TERMS_TABLE} (board_id, author_name) SELECT DISTINCT board_id, author_name FROM ${POSTS_TABLE} WHERE author_name IS NOT NULL AND author_name <> ''"
        author_status="$(author_terms_status)"
    else
        log "board author search dictionary already current"
    fi
    [[ "${author_status}" == "verified|0" ]] \
        || { printf 'board author search dictionary is incomplete\n' >&2; exit 1; }
    [[ "$(search_physical_structure "${author_status}")" == "verified" ]] \
        || { printf 'board search core index/schema prerequisites drifted\n' >&2; exit 1; }

    visibility_clauses=()
    [[ "$(index_visibility "${INDEX_ID}")" == "NO" ]] && visibility_clauses+=("ALTER INDEX ${INDEX_ID} VISIBLE")
    [[ "$(index_visibility "${INDEX_VIEWS}")" == "NO" ]] && visibility_clauses+=("ALTER INDEX ${INDEX_VIEWS} VISIBLE")
    if [[ ${#visibility_clauses[@]} -gt 0 ]]; then
        local visibility_joined
        visibility_joined="$(IFS=', '; printf '%s' "${visibility_clauses[*]}")"
        mysql_ddl "ALTER TABLE ${POSTS_TABLE} ${visibility_joined}"
    fi
    [[ "$(index_visibility "${INDEX_ID}")" == "YES" \
        && "$(index_visibility "${INDEX_VIEWS}")" == "YES" ]] \
        || { printf 'board benchmark indexes are not visible after activation\n' >&2; exit 1; }

    ensure_migration_records
}

ensure_migration_records() {
    local list_exists author_exists next_batch joined
    local -a values=()
    list_exists="$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${MIGRATIONS_TABLE} WHERE migration='${LIST_MIGRATION_NAME}'")"
    author_exists="$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${MIGRATIONS_TABLE} WHERE migration='${AUTHOR_TERMS_MIGRATION_NAME}'")"
    [[ "${list_exists}" == "0" || "${author_exists}" == "0" ]] || return 0

    next_batch="$(mysql_scalar "SELECT COALESCE(MAX(batch), 0) + 1 FROM ${DB_NAME}.${MIGRATIONS_TABLE}")"
    [[ "${list_exists}" != "0" ]] \
        || values+=("('${LIST_MIGRATION_NAME}', ${next_batch})")
    [[ "${author_exists}" != "0" ]] \
        || values+=("('${AUTHOR_TERMS_MIGRATION_NAME}', ${next_batch})")
    joined="$(IFS=', '; printf '%s' "${values[*]}")"
    mysql "${DB_NAME}" -e \
        "INSERT INTO ${MIGRATIONS_TABLE} (migration, batch) VALUES ${joined}"
}

hide_indexes() {
    local -a clauses
    ensure_no_long_queries
    clauses=()
    [[ "$(index_visibility "${INDEX_ID}")" == "YES" ]] && clauses+=("ALTER INDEX ${INDEX_ID} INVISIBLE")
    [[ "$(index_visibility "${INDEX_VIEWS}")" == "YES" ]] && clauses+=("ALTER INDEX ${INDEX_VIEWS} INVISIBLE")
    if [[ ${#clauses[@]} -gt 0 ]]; then
        local joined
        joined="$(IFS=', '; printf '%s' "${clauses[*]}")"
        mysql_ddl "ALTER TABLE ${POSTS_TABLE} ${joined}"
    fi
}

drop_indexes_and_migration() {
    local -a clauses
    ensure_no_long_queries
    clauses=()
    [[ "$(index_exists "${INDEX_VIEWS}")" != "0" ]] && clauses+=("DROP INDEX ${INDEX_VIEWS}")
    [[ "$(index_exists "${INDEX_ID}")" != "0" ]] && clauses+=("DROP INDEX ${INDEX_ID}")
    if [[ ${#clauses[@]} -gt 0 ]]; then
        local joined
        joined="$(IFS=', '; printf '%s' "${clauses[*]}")"
        mysql_ddl "ALTER TABLE ${POSTS_TABLE} ${joined}"
    fi
    if [[ "$(table_exists "${AUTHOR_TERMS_TABLE}")" != "0" ]]; then
        mysql_ddl "DROP TABLE ${AUTHOR_TERMS_TABLE}"
    fi
    mysql "${DB_NAME}" -e \
        "DELETE FROM ${MIGRATIONS_TABLE} WHERE migration IN ('${LIST_MIGRATION_NAME}', '${AUTHOR_TERMS_MIGRATION_NAME}')"
}

source_integrity() {
    local filtered_manifest
    if [[ ! -f "${SOURCE_MANIFEST}" ]]; then
        printf 'unknown'
        return
    fi
    filtered_manifest="$(mktemp)"
    awk '$2 == "config/benchmark.php" \
        || $2 == "app/Http/Requests/Public/SearchRequest.php" \
        || $2 == "app/Search/Engines/DatabaseFulltextEngine.php" \
        || $2 == "routes/api.php" \
        || $2 ~ "^modules/_bundled/sirsoft-(board|benchmark)/" { print }' \
        "${SOURCE_MANIFEST}" > "${filtered_manifest}"
    if [[ ! -s "${filtered_manifest}" ]]; then
        rm -f "${filtered_manifest}"
        printf 'unknown'
        return
    fi
    if (cd "${APP_ROOT}" && sha256sum -c "${filtered_manifest}" >/dev/null 2>&1); then
        printf 'verified'
    else
        printf 'drifted'
    fi
    rm -f "${filtered_manifest}"
}

source_variant() {
    if grep -q "benchmark.board_list_variant" \
        "${APP_ROOT}/modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php"; then
        printf 'optimized-capable'
    else
        printf 'official-7.0.5'
    fi
}

source_ref() {
    if [[ -f "${SOURCE_REF_FILE}" ]] \
        && [[ "$(<"${SOURCE_REF_FILE}")" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "$(<"${SOURCE_REF_FILE}")"
    else
        printf 'unknown'
    fi
}

effective_variant() {
    local value
    if [[ "$(source_variant)" != "optimized-capable" ]]; then
        printf 'baseline'
        return
    fi
    value="$(awk -F= -v key="${ENV_KEY}" '$1 == key { result = $2 } END { print result }' "${APP_ROOT}/.env")"
    [[ -z "${value}" ]] && value="optimized"
    printf '%s' "${value}"
}

schema_variant() {
    local author_status="${1:-}" id_visibility views_visibility author_structure author_missing
    local id_shape views_shape search_physical
    id_visibility="$(index_visibility "${INDEX_ID}")"
    views_visibility="$(index_visibility "${INDEX_VIEWS}")"
    id_shape="$(list_id_index_shape)"
    views_shape="$(list_views_index_shape)"
    [[ -n "${author_status}" ]] || author_status="$(author_terms_status)"
    author_structure="${author_status%%|*}"
    author_missing="${author_status#*|}"
    search_physical="$(search_physical_structure "${author_status}")"
    if [[ "${id_shape}" == "missing" && "${views_shape}" == "missing" \
        && "${id_visibility}" == "MISSING" && "${views_visibility}" == "MISSING" \
        && "${author_structure}" == "missing" && "${search_physical}" == "core-only" ]]; then
        printf 'original'
    elif [[ "${id_shape}" == "verified" && "${views_shape}" == "verified" \
        && "${id_visibility}" == "YES" && "${views_visibility}" == "YES" \
        && "${author_structure}" == "verified" && "${author_missing}" == "0" \
        && "${search_physical}" == "verified" ]]; then
        printf 'optimized'
    elif [[ "${id_shape}" == "verified" && "${views_shape}" == "verified" \
        && "${id_visibility}" == "NO" && "${views_visibility}" == "NO" \
        && "${author_structure}" == "verified" && "${author_missing}" == "0" \
        && "${search_physical}" == "verified" ]]; then
        printf 'baseline-invisible'
    else
        printf 'mixed'
    fi
}

search_schema_variant() {
    local author_status="${1:-}" runtime="${2:-}" physical
    [[ -n "${author_status}" ]] || author_status="$(author_terms_status)"
    [[ -n "${runtime}" ]] || runtime="$(effective_variant)"
    physical="$(search_physical_structure "${author_status}")"

    if [[ "${physical}" == "verified" ]]; then
        if [[ "${runtime}" == "optimized" ]]; then
            printf 'optimized'
        elif [[ "${runtime}" == "baseline" ]]; then
            printf 'baseline-dormant'
        else
            printf 'mixed'
        fi
    elif [[ "${physical}" == "core-only" && "${runtime}" == "baseline" ]]; then
        printf 'original'
    else
        printf 'mixed'
    fi
}

write_state() {
    local runtime_variant="$1" author_status
    author_status="$(author_terms_status)"
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}.tmp" <<EOF
source=$(source_variant)
source_ref=$(source_ref)
source_integrity=$(source_integrity)
runtime=${runtime_variant}
schema=$(schema_variant "${author_status}")
search.source=$(source_variant)
search.source_ref=$(source_ref)
search.config=${runtime_variant}
search.algorithm=${runtime_variant}
search.schema=$(search_schema_variant "${author_status}" "${runtime_variant}")
search.sync_cap=$(search_sync_cap)
search.fallback_scan_cap=$(search_fallback_scan_cap)
search.ft_result_cache_limit=$(ft_result_cache_limit 2>/dev/null || printf unavailable)
search.safety_guard=$(search_safety_guard_state)
search.safety_guard_persistence=$(search_safety_guard_persistence)
changed_at=$(date --iso-8601=seconds)
EOF
    install -o "${APP_USER}" -g www-data -m 664 "${STATE_FILE}.tmp" "${STATE_FILE}"
    rm -f "${STATE_FILE}.tmp"
}

smoke() {
    local result
    [[ "${RUN_SMOKE}" == "1" && "${DEFER_RUNTIME}" == "0" ]] || return 0
    result="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{time_total}' \
        "${BASE_URL}/api/modules/sirsoft-board/boards/gallery/posts?page=1&per_page=20")"
    log "smoke ${result}"
    [[ "${result%% *}" == "200" ]] || { printf 'smoke request failed\n' >&2; exit 1; }
}

show_status() {
    local module_row module_db_version module_source_version module_version_sync active_sync path
    local author_status author_structure author_missing schema runtime search_schema
    local benchmark_module_row benchmark_db_version benchmark_source_version
    local benchmark_module_version_sync=not-installed active_benchmark_sync=not-installed
    module_row="$(mysql_scalar "SELECT CONCAT(identifier, ' ', version, ' ', status) FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-board'")"
    module_db_version="$(mysql_scalar "SELECT version FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-board'")"
    module_source_version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-board/module.json" | head -n 1)"
    module_version_sync=drifted
    [[ -n "${module_source_version}" && "${module_source_version}" == "${module_db_version}" ]] \
        && module_version_sync=verified
    active_sync="verified"
    for path in \
        CHANGELOG.md composer.json module.json package-lock.json package.json \
        database/seeders/Sample/PostSampleSeeder.php \
        src/Http/Controllers/Admin/PostController.php \
        src/Http/Controllers/User/PostController.php \
        src/Http/Resources/PostCollection.php \
        src/Listeners/SearchPostsListener.php \
        src/Providers/BoardServiceProvider.php \
        src/Repositories/Contracts/PostRepositoryInterface.php \
        src/Repositories/PostRepository.php src/Services/PostService.php \
        src/routes/api.php; do
        cmp -s "${APP_ROOT}/modules/_bundled/sirsoft-board/${path}" \
            "${APP_ROOT}/modules/sirsoft-board/${path}" || active_sync="drifted"
    done
    if [[ "$(source_variant)" == "optimized-capable" ]]; then
        cmp -s \
            "${APP_ROOT}/modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php" \
            "${APP_ROOT}/modules/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php" \
            || active_sync="drifted"
        cmp -s \
            "${APP_ROOT}/modules/_bundled/sirsoft-board/src/Observers/PostAuthorTermObserver.php" \
            "${APP_ROOT}/modules/sirsoft-board/src/Observers/PostAuthorTermObserver.php" \
            || active_sync="drifted"
    fi

    benchmark_module_row="$(mysql_scalar "SELECT CONCAT(identifier, ' ', version, ' ', status) FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-benchmark'")"
    benchmark_db_version="$(mysql_scalar "SELECT version FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-benchmark'")"
    benchmark_source_version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-benchmark/module.json" 2>/dev/null | head -n 1)"
    if [[ -n "${benchmark_module_row}" ]]; then
        benchmark_module_version_sync=drifted
        [[ -n "${benchmark_source_version}" \
            && "${benchmark_source_version}" == "${benchmark_db_version}" ]] \
            && benchmark_module_version_sync=verified
    fi
    if [[ -d "${APP_ROOT}/modules/sirsoft-benchmark" ]]; then
        active_benchmark_sync=verified
        for path in \
            CHANGELOG.md composer.json module.json package.json \
            src/Services/Support/BoardCounterSyncService.php; do
            cmp -s "${APP_ROOT}/modules/_bundled/sirsoft-benchmark/${path}" \
                "${APP_ROOT}/modules/sirsoft-benchmark/${path}" \
                || active_benchmark_sync=drifted
        done
    fi
    if [[ -n "${benchmark_module_row}" && "${active_benchmark_sync}" == not-installed ]] \
        || [[ -z "${benchmark_module_row}" && "${active_benchmark_sync}" != not-installed ]]; then
        active_benchmark_sync=drifted
        benchmark_module_version_sync=drifted
    fi
    benchmark_module_row="${benchmark_module_row:-not-installed}"

    author_status="$(author_terms_status)"
    author_structure="${author_status%%|*}"
    author_missing="${author_status#*|}"
    schema="$(schema_variant "${author_status}")"
    runtime="$(effective_variant)"
    search_schema="$(search_schema_variant "${author_status}" "${runtime}")"

    printf 'source=%s\n' "$(source_variant)"
    printf 'source_ref=%s\n' "$(source_ref)"
    printf 'source_integrity=%s\n' "$(source_integrity)"
    printf 'runtime=%s\n' "${runtime}"
    printf 'schema=%s\n' "${schema}"
    printf 'search.source=%s\n' "$(source_variant)"
    printf 'search.source_ref=%s\n' "$(source_ref)"
    printf 'search.config=%s\n' "${runtime}"
    printf 'search.algorithm=%s\n' "${runtime}"
    printf 'search.schema=%s\n' "${search_schema}"
    printf 'search.sync_cap=%s\n' "$(search_sync_cap)"
    printf 'search.fallback_scan_cap=%s\n' "$(search_fallback_scan_cap)"
    printf 'search.ft_result_cache_limit=%s\n' "$(ft_result_cache_limit 2>/dev/null || printf unavailable)"
    printf 'search.safety_guard=%s\n' "$(search_safety_guard_state)"
    printf 'search.safety_guard_persistence=%s\n' "$(search_safety_guard_persistence)"
    printf 'search.index.%s.shape=%s\n' "${INDEX_FULLTEXT}" "$(fulltext_search_index_shape)"
    printf 'search.index.%s.shape=%s\n' "${INDEX_BOARD_AUTHOR}" "$(board_author_index_shape)"
    printf 'search.index.user_id_leading=%s\n' "$(user_leading_index_shape)"
    printf 'index.%s=%s\n' "${INDEX_ID}" "$(index_visibility "${INDEX_ID}")"
    printf 'index.%s.shape=%s\n' "${INDEX_ID}" "$(list_id_index_shape)"
    printf 'index.%s=%s\n' "${INDEX_VIEWS}" "$(index_visibility "${INDEX_VIEWS}")"
    printf 'index.%s.shape=%s\n' "${INDEX_VIEWS}" "$(list_views_index_shape)"
    if [[ "$(table_exists "${AUTHOR_TERMS_TABLE}")" == "1" ]]; then
        printf 'table.board_post_author_terms=present\n'
        printf 'author_terms.schema=%s\n' "${author_structure}"
        printf 'author_terms.missing=%s\n' "${author_missing}"
        printf 'author_terms.rows=%s\n' \
            "$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${AUTHOR_TERMS_TABLE}")"
    else
        printf 'table.board_post_author_terms=missing\n'
    fi
    printf 'active_module_sync=%s\n' "${active_sync}"
    printf 'module_version_sync=%s\n' "${module_version_sync}"
    printf 'module=%s\n' "${module_row}"
    printf 'active_benchmark_sync=%s\n' "${active_benchmark_sync}"
    printf 'benchmark_module_version_sync=%s\n' "${benchmark_module_version_sync}"
    printf 'benchmark_module=%s\n' "${benchmark_module_row}"
    if [[ -f "${APP_ROOT}/config/benchmark.php" ]]; then
        printf 'shared_config=present\n'
    else
        printf 'shared_config=missing\n'
    fi
    printf 'php_fpm=%s\n' "$(systemctl is-active php8.5-fpm)"
    if [[ -f "${STATE_FILE}" ]]; then
        printf 'last_state:\n'
        sed 's/^/  /' "${STATE_FILE}"
    fi
}

sync_module_versions() {
    local version benchmark_version
    version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-board/module.json" | head -n 1)"
    [[ "${version}" =~ ^[0-9A-Za-z.+-]+$ ]] \
        || { printf 'invalid board module version\n' >&2; exit 1; }
    mysql "${DB_NAME}" -e "UPDATE ${MODULES_TABLE} SET version='${version}' WHERE identifier='sirsoft-board'"

    if [[ "$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-benchmark'")" != "0" ]]; then
        benchmark_version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
            "${APP_ROOT}/modules/_bundled/sirsoft-benchmark/module.json" | head -n 1)"
        [[ "${benchmark_version}" =~ ^[0-9A-Za-z.+-]+$ ]] \
            || { printf 'invalid benchmark module version\n' >&2; exit 1; }
        mysql "${DB_NAME}" -e \
            "UPDATE ${MODULES_TABLE} SET version='${benchmark_version}' WHERE identifier='sirsoft-benchmark'"
    fi
}

case "${ACTION}" in
    on)
        ensure_no_long_queries
        ensure_search_safety_guard
        apply_source_archive optimized
        ensure_indexes_visible
        set_env_variant optimized
        sync_module_versions
        clear_runtime
        write_state optimized
        smoke
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    off)
        ensure_no_long_queries
        ensure_search_safety_guard
        apply_source_archive optimized
        ensure_indexes_visible
        set_env_variant baseline
        sync_module_versions
        clear_runtime
        hide_indexes
        write_state baseline
        smoke
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    restore-original)
        ensure_no_long_queries
        apply_source_archive baseline
        set_env_variant baseline
        clear_runtime 1
        drop_indexes_and_migration
        restore_search_safety_guard
        remove_env_variant
        sync_module_versions
        clear_runtime
        write_state baseline
        smoke
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    status)
        show_status
        ;;
esac
REMOTE

log "${ACTION} complete"
