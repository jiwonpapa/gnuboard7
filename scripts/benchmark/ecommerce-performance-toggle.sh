#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ACTION="${1:-status}"
[[ $# -gt 0 ]] && shift

REMOTE_HOST="${G7_ECOMMERCE_PERF_HOST:-g7devops}"
REMOTE_ROOT="${G7_ECOMMERCE_PERF_ROOT:-/home/g7devops/public_html}"
REMOTE_APP_USER="${G7_ECOMMERCE_PERF_APP_USER:-g7devops}"
REMOTE_PHP_BIN="${G7_ECOMMERCE_PERF_PHP_BIN:-php}"
REMOTE_DB_NAME="${G7_ECOMMERCE_PERF_DB_NAME:-g7devops}"
REMOTE_DB_PREFIX="${G7_ECOMMERCE_PERF_DB_PREFIX:-g7_}"
BASELINE_REF="${G7_ECOMMERCE_PERF_BASELINE_REF:-7.0.5}"
OPTIMIZED_REF="${G7_ECOMMERCE_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_ECOMMERCE_PERF_BASE_URL:-https://www.g7devops.com}"
SSH_CONNECT_TIMEOUT_SECONDS="${G7_ECOMMERCE_PERF_SSH_CONNECT_TIMEOUT_SECONDS:-${G7_PERF_SSH_CONNECT_TIMEOUT_SECONDS:-10}}"
SSH_SERVER_ALIVE_INTERVAL_SECONDS="${G7_ECOMMERCE_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-${G7_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS:-15}}"
SSH_SERVER_ALIVE_COUNT_MAX="${G7_ECOMMERCE_PERF_SSH_SERVER_ALIVE_COUNT_MAX:-${G7_PERF_SSH_SERVER_ALIVE_COUNT_MAX:-3}}"
SSH_BIN="${G7_ECOMMERCE_PERF_SSH_BIN:-${G7_PERF_SSH_BIN:-ssh}}"
SCP_BIN="${G7_ECOMMERCE_PERF_SCP_BIN:-${G7_PERF_SCP_BIN:-scp}}"
ASSUME_YES=0
RUN_SMOKE=1
DEFER_RUNTIME=0
ORCHESTRATION_TOKEN="-"
PREFLIGHT_ONLY=0
PREPARE_ARCHIVE="-"
PROVIDED_REMOTE_ARCHIVE="-"

COMMON_PATHS=(
    "modules/_bundled/sirsoft-ecommerce/CHANGELOG.md"
    "modules/_bundled/sirsoft-ecommerce/composer.json"
    "modules/_bundled/sirsoft-ecommerce/module.json"
    "modules/_bundled/sirsoft-ecommerce/package-lock.json"
    "modules/_bundled/sirsoft-ecommerce/package.json"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Controllers/Public/ProductController.php"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductCollection.php"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductListResource.php"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Resources/PublicCategoryResource.php"
    "modules/_bundled/sirsoft-ecommerce/src/Models/Category.php"
    "modules/_bundled/sirsoft-ecommerce/src/Models/Product.php"
    "modules/_bundled/sirsoft-ecommerce/src/Providers/EcommerceServiceProvider.php"
    "modules/_bundled/sirsoft-ecommerce/src/Repositories/ProductRepository.php"
    "modules/_bundled/sirsoft-ecommerce/src/Services/CategoryService.php"
    "modules/_bundled/sirsoft-ecommerce/src/Services/ProductService.php"
    "modules/_bundled/sirsoft-ecommerce/src/routes/api.php"
    "templates/_bundled/sirsoft-basic/layouts/shop/index.json"
    "templates/_bundled/sirsoft-basic/layouts/shop/show.json"
)

OPTIMIZED_ONLY_PATHS=(
    "config/benchmark.php"
    "modules/_bundled/sirsoft-benchmark/database/migrations/2026_07_15_000004_add_ecommerce_storefront_indexes.php"
)

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/ecommerce-performance-toggle.sh ACTION [options]

Actions:
  on                Deploy optimized-capable source, enable it, and show/create indexes.
  off               Deploy official source and make benchmark indexes invisible.
  status            Show source, runtime branch, index, active-module, and PHP-FPM state.
  restore-original  Restore official 7.0.5 ecommerce files and drop benchmark indexes.

Options:
  --yes             Required for restore-original.
  --no-smoke        Skip storefront API warm-up/smoke requests.
  --host HOST       SSH alias. Default: g7devops
  --root PATH       Remote app root. Default: /home/g7devops/public_html
  --app-user USER   Remote app user. Default: g7devops
  --php-bin BIN     Remote PHP binary. Default: php
  --db NAME         Remote database name. Default: g7devops
  --db-prefix NAME  Remote table prefix. Default: g7_
  --baseline REF    Exact source restore ref. Default: 7.0.5
  --optimized-ref REF
                    Reviewed optimized Git ref. Default: HEAD.
  --base-url URL    Storefront base URL.
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
EOF
}

log() { printf '[ecommerce-perf] %s\n' "$*"; }
fail() { printf '[ecommerce-perf] ERROR: %s\n' "$*" >&2; exit 1; }

copy_optimized_file() {
    local path="$1" destination="$2"
    git -C "${REPO_ROOT}" cat-file -e "${OPTIMIZED_REF}:${path}" 2>/dev/null \
        || fail "optimized file not found at ${OPTIMIZED_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${OPTIMIZED_REF}:${path}" > "${destination}/${path}"
}

copy_git_file() {
    local path="$1" destination="$2"
    git -C "${REPO_ROOT}" cat-file -e "${BASELINE_REF}:${path}" 2>/dev/null \
        || fail "baseline file not found at ${BASELINE_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${BASELINE_REF}:${path}" > "${destination}/${path}"
}

build_source_archive() {
    local variant="$1"
    local stage_dir="${WORK_DIR}/${variant}"
    local archive="${WORK_DIR}/ecommerce-performance-${variant}.tar.gz" path
    local -a manifest_paths=()

    mkdir -p "${stage_dir}/.harness"
    for path in "${COMMON_PATHS[@]}"; do
        if [[ "${variant}" == "optimized" ]]; then
            copy_optimized_file "${path}" "${stage_dir}"
        else
            copy_git_file "${path}" "${stage_dir}"
        fi
        manifest_paths+=("${path}")
    done

    if [[ "${variant}" == "optimized" ]]; then
        for path in "${OPTIMIZED_ONLY_PATHS[@]}"; do
            copy_optimized_file "${path}" "${stage_dir}"
            manifest_paths+=("${path}")
        done
    fi

    printf '%s\n' "${variant}" > "${stage_dir}/.harness/source-variant"
    (
        cd "${stage_dir}"
        for path in "${manifest_paths[@]}"; do shasum -a 256 "${path}"; done \
            > .harness/source.sha256
        COPYFILE_DISABLE=1 tar --no-xattrs -czf "${archive}" .
    )
    printf '%s' "${archive}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) ASSUME_YES=1 ;;
        --no-smoke) RUN_SMOKE=0 ;;
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --app-user) shift; REMOTE_APP_USER="${1:-}" ;;
        --php-bin) shift; REMOTE_PHP_BIN="${1:-}" ;;
        --db) shift; REMOTE_DB_NAME="${1:-}" ;;
        --db-prefix) shift; REMOTE_DB_PREFIX="${1:-}" ;;
        --baseline) shift; BASELINE_REF="${1:-}" ;;
        --optimized-ref) shift; OPTIMIZED_REF="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        --ssh-connect-timeout) shift; SSH_CONNECT_TIMEOUT_SECONDS="${1:-}" ;;
        --ssh-alive-interval) shift; SSH_SERVER_ALIVE_INTERVAL_SECONDS="${1:-}" ;;
        --ssh-alive-count) shift; SSH_SERVER_ALIVE_COUNT_MAX="${1:-}" ;;
        --defer-runtime) DEFER_RUNTIME=1 ;;
        --lock-token) shift; ORCHESTRATION_TOKEN="${1:-}" ;;
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        --prepare-archive) shift; PREPARE_ARCHIVE="${1:-}" ;;
        --remote-archive) shift; PROVIDED_REMOTE_ARCHIVE="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

case "${ACTION}" in
    on|off|status|restore-original) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 1 ;;
esac
[[ "${ACTION}" != "restore-original" || ${ASSUME_YES} -eq 1 ]] \
    || fail 'restore-original drops indexes and requires --yes'
if [[ "${ACTION}" != "status" && "${ORCHESTRATION_TOKEN}" == "-" ]]; then
    fail "mutating actions must run through scripts/benchmark/g7-performance-toggle.sh --scope ecommerce"
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

for command in "${SSH_BIN}" "${SCP_BIN}" git tar shasum; do
    command -v "${command}" >/dev/null || fail "missing ${command}"
done
[[ -f "${REPO_ROOT}/artisan" ]] || fail "invalid repository root: ${REPO_ROOT}"
SSH_OPTIONS=(
    -o BatchMode=yes
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT_SECONDS}"
    -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL_SECONDS}"
    -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"
)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-ecommerce-performance.XXXXXX")"
REMOTE_ARCHIVE="-"
REMOTE_ARCHIVE_OWNED=0
cleanup() {
    rm -rf "${WORK_DIR}"
    [[ "${REMOTE_ARCHIVE_OWNED}" != 1 || "${REMOTE_ARCHIVE}" == "-" ]] \
        || "${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" \
            rm -f -- "${REMOTE_ARCHIVE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "${ACTION}" == "on" || "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]]; then
    variant=optimized
    [[ "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]] && variant=baseline
    if [[ "${PROVIDED_REMOTE_ARCHIVE}" != "-" ]]; then
        [[ "${PROVIDED_REMOTE_ARCHIVE}" == /tmp/g7-ecommerce-performance-*.tar.gz ]] \
            || fail 'invalid prepared ecommerce archive path'
        REMOTE_ARCHIVE="${PROVIDED_REMOTE_ARCHIVE}"
    else
        archive="$(build_source_archive "${variant}")"
        if [[ "${PREPARE_ARCHIVE}" != "-" ]]; then
            [[ -n "${PREPARE_ARCHIVE}" ]] || fail '--prepare-archive requires a path'
            install -m 600 "${archive}" "${PREPARE_ARCHIVE}"
            log "${variant} source archive prepared"
            exit 0
        fi
        if [[ "${PREFLIGHT_ONLY}" == 1 ]]; then
            log "${variant} source archive preflight complete"
            exit 0
        fi
        REMOTE_ARCHIVE="/tmp/g7-ecommerce-performance-${variant}-$$.tar.gz"
        REMOTE_ARCHIVE_OWNED=1
        log "uploading ${variant} source snapshot"
        "${SCP_BIN}" "${SSH_OPTIONS[@]}" -q \
            "${archive}" "${REMOTE_HOST}:${REMOTE_ARCHIVE}"
    fi
fi

log "running ${ACTION} on ${REMOTE_HOST}:${REMOTE_ROOT}"
"${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo bash -s -- \
    "${ACTION}" "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" \
    "${REMOTE_DB_NAME}" "${REMOTE_DB_PREFIX}" "${BASE_URL}" "${REMOTE_ARCHIVE}" "${RUN_SMOKE}" \
    "${DEFER_RUNTIME}" "${ORCHESTRATION_TOKEN}" <<'REMOTE'
set -Eeuo pipefail
trap 'result=$?; printf "[remote-ecommerce-perf] ERROR line=%s exit=%s command=%q\n" "${LINENO}" "${result}" "${BASH_COMMAND}" >&2; exit "${result}"' ERR

ACTION="$1"; APP_ROOT="$2"; APP_USER="$3"; PHP_BIN="$4"; DB_NAME="$5"; DB_PREFIX="$6"
BASE_URL="${7%/}"; SOURCE_ARCHIVE="$8"; RUN_SMOKE="$9"
DEFER_RUNTIME="${10}"; ORCHESTRATION_TOKEN="${11}"
ENV_KEY="G7_ECOMMERCE_PERFORMANCE_VARIANT"
PRODUCTS_TABLE="${DB_PREFIX}ecommerce_products"
OPTIONS_TABLE="${DB_PREFIX}ecommerce_order_options"
MODULES_TABLE="${DB_PREFIX}modules"
MIGRATIONS_TABLE="${DB_PREFIX}migrations"
MIGRATION_NAME="2026_07_15_000004_add_ecommerce_storefront_indexes"
MIGRATION_PATH="modules/_bundled/sirsoft-benchmark/database/migrations/${MIGRATION_NAME}.php"
ACTIVE_MIGRATION_PATH="modules/sirsoft-benchmark/database/migrations/${MIGRATION_NAME}.php"
INDEX_LATEST="idx_ecommerce_products_public_latest"
INDEX_PRICE="idx_ecommerce_products_public_price"
INDEX_SALES="idx_ecommerce_order_options_recent_sales"
STATE_DIR="${APP_ROOT}/storage/app/benchmark"
STATE_FILE="${STATE_DIR}/ecommerce-performance-variant.env"
SOURCE_MANIFEST="${STATE_DIR}/ecommerce-performance-source.sha256"

[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ && "${DB_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]] || exit 1
[[ -f "${APP_ROOT}/artisan" ]] || exit 1
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
    printf 'direct-ecommerce-%s\n' "$$" > "${GLOBAL_LOCK_DIR}/owner"
    LOCK_OWNED=1
    trap release_global_lock EXIT
fi

log() { printf '[remote-ecommerce-perf] %s\n' "$*"; }
mysql_scalar() { mysql --batch --skip-column-names -e "$1"; }
mysql_ddl() {
    mysql "${DB_NAME}" -e \
        "SET SESSION lock_wait_timeout=15; SET SESSION innodb_lock_wait_timeout=15; $1"
}

index_table() {
    case "$1" in
        "${INDEX_LATEST}"|"${INDEX_PRICE}") printf '%s' "${PRODUCTS_TABLE}" ;;
        "${INDEX_SALES}") printf '%s' "${OPTIONS_TABLE}" ;;
    esac
}

index_exists() {
    local index="$1" table
    table="$(index_table "${index}")"
    mysql_scalar "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND INDEX_NAME='${index}'"
}

index_visibility() {
    local index="$1" table
    table="$(index_table "${index}")"
    mysql_scalar "SELECT CASE WHEN COUNT(*)=0 THEN 'MISSING' WHEN COUNT(IS_VISIBLE)=COUNT(*) AND COUNT(DISTINCT IS_VISIBLE)=1 THEN MIN(IS_VISIBLE) ELSE 'DRIFTED' END FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND INDEX_NAME='${index}'"
}

index_expected_columns() {
    case "$1" in
        "${INDEX_LATEST}") printf 'display_status,deleted_at,created_at,id' ;;
        "${INDEX_PRICE}") printf 'display_status,deleted_at,selling_price,id' ;;
        "${INDEX_SALES}") printf 'created_at,product_id,quantity' ;;
    esac
}

index_expected_count() {
    case "$1" in
        "${INDEX_LATEST}"|"${INDEX_PRICE}") printf '4' ;;
        "${INDEX_SALES}") printf '3' ;;
    esac
}

index_shape() {
    local index="$1" table expected_columns expected_count expected_sequence expected_directions metadata
    table="$(index_table "${index}")"
    expected_columns="$(index_expected_columns "${index}")"
    expected_count="$(index_expected_count "${index}")"
    case "${expected_count}" in
        3) expected_sequence='1,2,3'; expected_directions='A,A,A' ;;
        4) expected_sequence='1,2,3,4'; expected_directions='A,A,A,A' ;;
        *) return 1 ;;
    esac
    metadata="$(mysql_scalar "SELECT CONCAT(COUNT(*), '|', COALESCE(GROUP_CONCAT(SEQ_IN_INDEX ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(GROUP_CONCAT(COALESCE(COLLATION, 'NULL') ORDER BY SEQ_IN_INDEX SEPARATOR ','), ''), '|', COALESCE(MIN(NON_UNIQUE), ''), '|', COALESCE(MAX(NON_UNIQUE), ''), '|', COALESCE(MIN(INDEX_TYPE), ''), '|', COALESCE(MAX(INDEX_TYPE), ''), '|', COALESCE(SUM(SUB_PART IS NOT NULL), 0), '|', COALESCE(SUM(COLUMN_NAME IS NULL), 0)) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND INDEX_NAME='${index}'")"
    if [[ "${metadata%%|*}" == "0" ]]; then
        printf 'missing'
    elif [[ "${metadata}" == "${expected_count}|${expected_sequence}|${expected_columns}|${expected_directions}|1|1|BTREE|BTREE|0|0" ]]; then
        printf 'verified'
    else
        printf 'drifted'
    fi
}

ensure_idle_database() {
    local count
    count="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.PROCESSLIST AS p LEFT JOIN information_schema.INNODB_TRX AS t ON t.trx_mysql_thread_id=p.ID WHERE p.ID <> CONNECTION_ID() AND ((p.COMMAND IN ('Query','Execute') AND p.TIME >= 5) OR t.trx_mysql_thread_id IS NOT NULL)")"
    if [[ "${count}" != "0" ]]; then
        mysql --table -e "SELECT p.ID,p.USER,p.DB,p.COMMAND,p.TIME,p.STATE,t.trx_started,LEFT(p.INFO,180) AS INFO FROM information_schema.PROCESSLIST AS p LEFT JOIN information_schema.INNODB_TRX AS t ON t.trx_mysql_thread_id=p.ID WHERE p.ID <> CONNECTION_ID() AND ((p.COMMAND IN ('Query','Execute') AND p.TIME >= 5) OR t.trx_mysql_thread_id IS NOT NULL) ORDER BY p.TIME DESC"
        printf 'long-running query or open transaction detected; toggle aborted before DDL\n' >&2
        exit 1
    fi
}

set_env_variant() {
    local value="$1" temp
    temp="$(mktemp)"
    awk -v key="${ENV_KEY}" -v value="${value}" '
        BEGIN { replaced = 0 }
        $0 ~ "^" key "=" { if (!replaced) { print key "=" value; replaced = 1 }; next }
        { print }
        END { if (!replaced) print key "=" value }
    ' "${APP_ROOT}/.env" > "${temp}"
    chown --reference="${APP_ROOT}/.env" "${temp}"; chmod --reference="${APP_ROOT}/.env" "${temp}"
    mv "${temp}" "${APP_ROOT}/.env"
}

remove_env_variant() {
    local temp
    temp="$(mktemp)"
    awk -v key="${ENV_KEY}" '$0 !~ "^" key "=" { print }' "${APP_ROOT}/.env" > "${temp}"
    chown --reference="${APP_ROOT}/.env" "${temp}"; chmod --reference="${APP_ROOT}/.env" "${temp}"
    mv "${temp}" "${APP_ROOT}/.env"
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

backup_source() {
    local dir file path
    local -a paths=()
    dir="/home/${APP_USER}/backups/ecommerce-performance-harness"
    file="${dir}/$(date +%Y%m%d-%H%M%S)-before-${ACTION}.tar.gz"
    mkdir -p "${dir}"
    while read -r path; do [[ -e "${APP_ROOT}/${path}" ]] && paths+=("${path}"); done <<'PATHS'
config/benchmark.php
modules/_bundled/sirsoft-ecommerce/CHANGELOG.md
modules/_bundled/sirsoft-ecommerce/composer.json
modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductCollection.php
modules/_bundled/sirsoft-ecommerce/module.json
modules/_bundled/sirsoft-ecommerce/package-lock.json
modules/_bundled/sirsoft-ecommerce/package.json
modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductListResource.php
modules/_bundled/sirsoft-ecommerce/src/Http/Resources/PublicCategoryResource.php
modules/_bundled/sirsoft-ecommerce/src/Http/Controllers/Public/ProductController.php
modules/_bundled/sirsoft-ecommerce/src/Models/Category.php
modules/_bundled/sirsoft-ecommerce/src/Models/Product.php
modules/_bundled/sirsoft-ecommerce/src/Providers/EcommerceServiceProvider.php
modules/_bundled/sirsoft-ecommerce/src/Repositories/ProductRepository.php
modules/_bundled/sirsoft-ecommerce/src/Services/CategoryService.php
modules/_bundled/sirsoft-ecommerce/src/Services/ProductService.php
modules/_bundled/sirsoft-ecommerce/src/routes/api.php
modules/_bundled/sirsoft-benchmark/database/migrations/2026_07_15_000004_add_ecommerce_storefront_indexes.php
templates/_bundled/sirsoft-basic/layouts/shop/index.json
templates/_bundled/sirsoft-basic/layouts/shop/show.json
PATHS
    while read -r path; do
        [[ -e "${APP_ROOT}/modules/sirsoft-ecommerce/${path}" ]] \
            && paths+=("modules/sirsoft-ecommerce/${path}")
    done <<'PATHS'
CHANGELOG.md
composer.json
module.json
package-lock.json
package.json
src/Http/Controllers/Public/ProductController.php
src/Http/Resources/ProductCollection.php
src/Http/Resources/ProductListResource.php
src/Http/Resources/PublicCategoryResource.php
src/Models/Category.php
src/Models/Product.php
src/Providers/EcommerceServiceProvider.php
src/Repositories/ProductRepository.php
src/Services/CategoryService.php
src/Services/ProductService.php
src/routes/api.php
PATHS
    while read -r path; do
        [[ -e "${APP_ROOT}/templates/sirsoft-basic/${path}" ]] \
            && paths+=("templates/sirsoft-basic/${path}")
    done <<'PATHS'
layouts/shop/index.json
layouts/shop/show.json
PATHS
    [[ ! -e "${APP_ROOT}/${ACTIVE_MIGRATION_PATH}" ]] \
        || paths+=("${ACTIVE_MIGRATION_PATH}")
    if [[ ${#paths[@]} -gt 0 ]]; then
        tar -czf "${file}" -C "${APP_ROOT}" "${paths[@]}"
        chown "${APP_USER}:www-data" "${file}"
    fi
    find "${dir}" -maxdepth 1 -name '*.tar.gz' -type f -printf '%T@ %p\n' | sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f
}

apply_archive() {
    local expected="$1" stage manifest checksum path source mode relative active
    stage="$(mktemp -d)"; tar -xzf "${SOURCE_ARCHIVE}" -C "${stage}"
    [[ "$(<"${stage}/.harness/source-variant")" == "${expected}" ]] || exit 1
    manifest="${stage}/.harness/source.sha256"
    [[ -f "${manifest}" ]] || { printf 'source archive manifest missing\n' >&2; exit 1; }
    (cd "${stage}" && sha256sum -c .harness/source.sha256 >/dev/null) \
        || { printf 'source archive checksum mismatch\n' >&2; exit 1; }
    backup_source
    while read -r checksum path; do
        path="${path#\*}"; source="${stage}/${path}"; mode="$(stat -c '%a' "${source}")"
        install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${APP_ROOT}/${path}"
        case "${path}" in
            modules/_bundled/sirsoft-ecommerce/*)
                relative="${path#modules/_bundled/sirsoft-ecommerce/}"
                active="${APP_ROOT}/modules/sirsoft-ecommerce/${relative}"
                [[ -d "${APP_ROOT}/modules/sirsoft-ecommerce" ]] && install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${active}"
                ;;
            modules/_bundled/sirsoft-benchmark/*)
                relative="${path#modules/_bundled/sirsoft-benchmark/}"
                active="${APP_ROOT}/modules/sirsoft-benchmark/${relative}"
                [[ -d "${APP_ROOT}/modules/sirsoft-benchmark" ]] && install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${active}"
                ;;
            templates/_bundled/sirsoft-basic/*)
                relative="${path#templates/_bundled/sirsoft-basic/}"
                active="${APP_ROOT}/templates/sirsoft-basic/${relative}"
                [[ -d "${APP_ROOT}/templates/sirsoft-basic" ]] && install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${active}"
                ;;
        esac
    done < "${manifest}"
    mkdir -p "${STATE_DIR}"
    install -o "${APP_USER}" -g www-data -m 664 "${manifest}" "${SOURCE_MANIFEST}"
    (cd "${APP_ROOT}" && sha256sum -c "${SOURCE_MANIFEST}" >/dev/null)
    rm -rf "${stage}"
}

ensure_indexes() {
    local latest_shape price_shape sales_shape
    local -a product_add=() product_show=() option_add=() option_show=()
    ensure_idle_database
    latest_shape="$(index_shape "${INDEX_LATEST}")"
    price_shape="$(index_shape "${INDEX_PRICE}")"
    sales_shape="$(index_shape "${INDEX_SALES}")"
    [[ "${latest_shape}" != drifted ]] || product_add+=("DROP INDEX ${INDEX_LATEST}")
    [[ "${latest_shape}" == verified ]] || product_add+=("ADD INDEX ${INDEX_LATEST} (display_status, deleted_at, created_at, id)")
    [[ "${price_shape}" != drifted ]] || product_add+=("DROP INDEX ${INDEX_PRICE}")
    [[ "${price_shape}" == verified ]] || product_add+=("ADD INDEX ${INDEX_PRICE} (display_status, deleted_at, selling_price, id)")
    [[ "${sales_shape}" != drifted ]] || option_add+=("DROP INDEX ${INDEX_SALES}")
    [[ "${sales_shape}" == verified ]] || option_add+=("ADD INDEX ${INDEX_SALES} (created_at, product_id, quantity)")
    [[ ${#product_add[@]} -eq 0 ]] || mysql_ddl "ALTER TABLE ${PRODUCTS_TABLE} $(IFS=', '; printf '%s' "${product_add[*]}")"
    [[ ${#option_add[@]} -eq 0 ]] || mysql_ddl "ALTER TABLE ${OPTIONS_TABLE} $(IFS=', '; printf '%s' "${option_add[*]}")"
    [[ "$(index_shape "${INDEX_LATEST}")" == verified \
        && "$(index_shape "${INDEX_PRICE}")" == verified \
        && "$(index_shape "${INDEX_SALES}")" == verified ]] \
        || { printf 'ecommerce benchmark index definition drifted\n' >&2; exit 1; }
    [[ "$(index_visibility "${INDEX_LATEST}")" != NO ]] || product_show+=("ALTER INDEX ${INDEX_LATEST} VISIBLE")
    [[ "$(index_visibility "${INDEX_PRICE}")" != NO ]] || product_show+=("ALTER INDEX ${INDEX_PRICE} VISIBLE")
    [[ "$(index_visibility "${INDEX_SALES}")" != NO ]] || option_show+=("ALTER INDEX ${INDEX_SALES} VISIBLE")
    [[ ${#product_show[@]} -eq 0 ]] || mysql_ddl "ALTER TABLE ${PRODUCTS_TABLE} $(IFS=', '; printf '%s' "${product_show[*]}")"
    [[ ${#option_show[@]} -eq 0 ]] || mysql_ddl "ALTER TABLE ${OPTIONS_TABLE} $(IFS=', '; printf '%s' "${option_show[*]}")"
    [[ "$(index_visibility "${INDEX_LATEST}")" == YES \
        && "$(index_visibility "${INDEX_PRICE}")" == YES \
        && "$(index_visibility "${INDEX_SALES}")" == YES ]] \
        || { printf 'ecommerce benchmark indexes are not visible after activation\n' >&2; exit 1; }
    if [[ "$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${MIGRATIONS_TABLE} WHERE migration='${MIGRATION_NAME}'")" == 0 ]]; then
        batch="$(mysql_scalar "SELECT COALESCE(MAX(batch), 0) + 1 FROM ${DB_NAME}.${MIGRATIONS_TABLE}")"
        mysql "${DB_NAME}" -e "INSERT INTO ${MIGRATIONS_TABLE} (migration,batch) VALUES ('${MIGRATION_NAME}',${batch})"
    fi
}

hide_indexes() {
    local index table
    ensure_idle_database
    for index in "${INDEX_LATEST}" "${INDEX_PRICE}" "${INDEX_SALES}"; do
        if [[ "$(index_visibility "${index}")" == YES ]]; then
            table="$(index_table "${index}")"
            mysql_ddl "ALTER TABLE ${table} ALTER INDEX ${index} INVISIBLE"
        fi
    done
}

drop_indexes() {
    local index table
    ensure_idle_database
    for index in "${INDEX_SALES}" "${INDEX_PRICE}" "${INDEX_LATEST}"; do
        if [[ "$(index_exists "${index}")" != 0 ]]; then
            table="$(index_table "${index}")"
            mysql_ddl "ALTER TABLE ${table} DROP INDEX ${index}"
        fi
    done
    mysql "${DB_NAME}" -e "DELETE FROM ${MIGRATIONS_TABLE} WHERE migration='${MIGRATION_NAME}'"
    rm -f "${APP_ROOT}/${MIGRATION_PATH}" "${APP_ROOT}/${ACTIVE_MIGRATION_PATH}"
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

warm_and_smoke() {
    [[ "${RUN_SMOKE}" == 1 && "${DEFER_RUNTIME}" == 0 ]] || return 0
    local path result
    local -a paths=('/api/modules/sirsoft-ecommerce/products?page=1&per_page=12')
    if [[ "$(source_variant)" == optimized-capable ]]; then
        paths=('/api/modules/sirsoft-ecommerce/storefront' "${paths[@]}")
    else
        paths=('/api/modules/sirsoft-ecommerce/categories' '/api/modules/sirsoft-ecommerce/products/popular?limit=8' "${paths[@]}")
    fi
    for path in "${paths[@]}"; do
        result="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code} %{time_total}' "${BASE_URL}${path}")"
        log "smoke ${path} ${result}"
        [[ "${result%% *}" == 200 ]] || exit 1
    done
}

source_variant() {
    if grep -q "benchmark.ecommerce_variant" "${APP_ROOT}/modules/_bundled/sirsoft-ecommerce/src/Repositories/ProductRepository.php"; then
        printf 'optimized-capable'
    else
        printf 'official-7.0.5'
    fi
}

source_integrity() {
    if [[ ! -f "${SOURCE_MANIFEST}" ]]; then
        printf 'unknown'
    elif (cd "${APP_ROOT}" && sha256sum -c "${SOURCE_MANIFEST}" >/dev/null 2>&1); then
        printf 'verified'
    else
        printf 'drifted'
    fi
}

effective_variant() {
    local value
    [[ "$(source_variant)" == optimized-capable ]] || { printf 'baseline'; return; }
    value="$(awk -F= -v key="${ENV_KEY}" '$1 == key { value=$2 } END { print value }' "${APP_ROOT}/.env")"
    printf '%s' "${value:-optimized}"
}

schema_variant() {
    local a b c sa sb sc
    a="$(index_visibility "${INDEX_LATEST}")"; b="$(index_visibility "${INDEX_PRICE}")"; c="$(index_visibility "${INDEX_SALES}")"
    sa="$(index_shape "${INDEX_LATEST}")"; sb="$(index_shape "${INDEX_PRICE}")"; sc="$(index_shape "${INDEX_SALES}")"
    if [[ "${sa}${sb}${sc}" == missingmissingmissing && "${a}${b}${c}" == MISSINGMISSINGMISSING ]]; then printf 'original'
    elif [[ "${sa}${sb}${sc}" == verifiedverifiedverified && "${a}${b}${c}" == YESYESYES ]]; then printf 'optimized'
    elif [[ "${sa}${sb}${sc}" == verifiedverifiedverified && "${a}${b}${c}" == NONONO ]]; then printf 'baseline-invisible'
    else printf 'mixed'; fi
}

write_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}.tmp" <<EOF
source=$(source_variant)
source_integrity=$(source_integrity)
runtime=$(effective_variant)
schema=$(schema_variant)
changed_at=$(date --iso-8601=seconds)
EOF
    install -o "${APP_USER}" -g www-data -m 664 "${STATE_FILE}.tmp" "${STATE_FILE}"
    rm -f "${STATE_FILE}.tmp"
}

show_status() {
    local active_sync=missing template_sync=missing module_row module_db_version
    local module_source_version module_version_sync=drifted
    if [[ -d "${APP_ROOT}/modules/sirsoft-ecommerce" ]]; then
        active_sync=verified
        for path in \
            CHANGELOG.md composer.json module.json package-lock.json package.json \
            src/Http/Controllers/Public/ProductController.php \
            src/Http/Resources/ProductCollection.php \
            src/Http/Resources/ProductListResource.php \
            src/Http/Resources/PublicCategoryResource.php \
            src/Models/Category.php src/Models/Product.php \
            src/Providers/EcommerceServiceProvider.php \
            src/Repositories/ProductRepository.php \
            src/Services/CategoryService.php src/Services/ProductService.php \
            src/routes/api.php; do
            cmp -s "${APP_ROOT}/modules/_bundled/sirsoft-ecommerce/${path}" "${APP_ROOT}/modules/sirsoft-ecommerce/${path}" || active_sync=drifted
        done
    fi
    if [[ -d "${APP_ROOT}/templates/sirsoft-basic" ]]; then
        template_sync=verified
        for path in layouts/shop/index.json layouts/shop/show.json; do
            cmp -s "${APP_ROOT}/templates/_bundled/sirsoft-basic/${path}" \
                "${APP_ROOT}/templates/sirsoft-basic/${path}" || template_sync=drifted
        done
    fi
    module_row="$(mysql_scalar "SELECT CONCAT(identifier, ' ', version, ' ', status) FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-ecommerce'")"
    module_db_version="$(mysql_scalar "SELECT version FROM ${DB_NAME}.${MODULES_TABLE} WHERE identifier='sirsoft-ecommerce'")"
    module_source_version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-ecommerce/module.json" | head -n 1)"
    [[ -n "${module_source_version}" && "${module_source_version}" == "${module_db_version}" ]] \
        && module_version_sync=verified
    printf 'source=%s\n' "$(source_variant)"
    printf 'source_integrity=%s\n' "$(source_integrity)"
    printf 'runtime=%s\n' "$(effective_variant)"
    printf 'schema=%s\n' "$(schema_variant)"
    printf 'index.%s=%s\n' "${INDEX_LATEST}" "$(index_visibility "${INDEX_LATEST}")"
    printf 'index.%s.shape=%s\n' "${INDEX_LATEST}" "$(index_shape "${INDEX_LATEST}")"
    printf 'index.%s=%s\n' "${INDEX_PRICE}" "$(index_visibility "${INDEX_PRICE}")"
    printf 'index.%s.shape=%s\n' "${INDEX_PRICE}" "$(index_shape "${INDEX_PRICE}")"
    printf 'index.%s=%s\n' "${INDEX_SALES}" "$(index_visibility "${INDEX_SALES}")"
    printf 'index.%s.shape=%s\n' "${INDEX_SALES}" "$(index_shape "${INDEX_SALES}")"
    printf 'active_module_sync=%s\n' "${active_sync}"
    printf 'active_template_sync=%s\n' "${template_sync}"
    printf 'module_version_sync=%s\n' "${module_version_sync}"
    printf 'module=%s\n' "${module_row}"
    if [[ -f "${APP_ROOT}/config/benchmark.php" ]]; then
        printf 'shared_config=present\n'
    else
        printf 'shared_config=missing\n'
    fi
    printf 'php_fpm=%s\n' "$(systemctl is-active php8.5-fpm)"
    [[ ! -f "${STATE_FILE}" ]] || { printf 'last_state:\n'; sed 's/^/  /' "${STATE_FILE}"; }
}

sync_module_version() {
    local version
    version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-ecommerce/module.json" | head -n 1)"
    [[ "${version}" =~ ^[0-9A-Za-z.+-]+$ ]] \
        || { printf 'invalid ecommerce module version\n' >&2; exit 1; }
    mysql "${DB_NAME}" -e "UPDATE ${MODULES_TABLE} SET version='${version}' WHERE identifier='sirsoft-ecommerce'"
}

case "${ACTION}" in
    on)
        apply_archive optimized; ensure_indexes; set_env_variant optimized; sync_module_version
        clear_runtime; warm_and_smoke; write_state
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    off)
        apply_archive baseline; ensure_indexes; set_env_variant baseline; hide_indexes; sync_module_version
        clear_runtime; warm_and_smoke; write_state
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    restore-original)
        apply_archive baseline
        set_env_variant baseline
        clear_runtime 1
        drop_indexes
        remove_env_variant
        sync_module_version
        clear_runtime
        warm_and_smoke
        write_state
        [[ "${DEFER_RUNTIME}" == 1 ]] || show_status
        ;;
    status) show_status ;;
esac
REMOTE
