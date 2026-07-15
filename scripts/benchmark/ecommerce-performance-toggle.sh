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
BASELINE_REF="${G7_ECOMMERCE_PERF_BASELINE_REF:-7.0.4}"
BASE_URL="${G7_ECOMMERCE_PERF_BASE_URL:-https://www.g7devops.com}"
ASSUME_YES=0
RUN_SMOKE=1

COMMON_PATHS=(
    "modules/_bundled/sirsoft-ecommerce/src/Http/Controllers/Public/ProductController.php"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductCollection.php"
    "modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductListResource.php"
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
  restore-original  Restore official 7.0.4 ecommerce files and drop benchmark indexes.

Options:
  --yes             Required for restore-original.
  --no-smoke        Skip storefront API warm-up/smoke requests.
  --host HOST       SSH alias. Default: g7devops
  --root PATH       Remote app root. Default: /home/g7devops/public_html
  --app-user USER   Remote app user. Default: g7devops
  --php-bin BIN     Remote PHP binary. Default: php
  --db NAME         Remote database name. Default: g7devops
  --db-prefix NAME  Remote table prefix. Default: g7_
  --baseline REF    Exact source restore ref. Default: 7.0.4
  --base-url URL    Storefront base URL.
EOF
}

log() { printf '[ecommerce-perf] %s\n' "$*"; }
fail() { printf '[ecommerce-perf] ERROR: %s\n' "$*" >&2; exit 1; }

copy_worktree_file() {
    local path="$1" destination="$2"
    [[ -f "${REPO_ROOT}/${path}" ]] || fail "optimized file not found: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    cp "${REPO_ROOT}/${path}" "${destination}/${path}"
}

copy_git_file() {
    local path="$1" destination="$2"
    git -C "${REPO_ROOT}" cat-file -e "${BASELINE_REF}:${path}" 2>/dev/null \
        || fail "baseline file not found at ${BASELINE_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${BASELINE_REF}:${path}" > "${destination}/${path}"
}

build_source_archive() {
    local variant="$1" stage_dir="${WORK_DIR}/${variant}"
    local archive="${WORK_DIR}/ecommerce-performance-${variant}.tar.gz" path
    local -a manifest_paths=()

    mkdir -p "${stage_dir}/.harness"
    for path in "${COMMON_PATHS[@]}"; do
        if [[ "${variant}" == "optimized" ]]; then
            copy_worktree_file "${path}" "${stage_dir}"
        else
            copy_git_file "${path}" "${stage_dir}"
        fi
        manifest_paths+=("${path}")
    done

    if [[ "${variant}" == "optimized" ]]; then
        for path in "${OPTIMIZED_ONLY_PATHS[@]}"; do
            copy_worktree_file "${path}" "${stage_dir}"
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
        --base-url) shift; BASE_URL="${1:-}" ;;
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

for command in ssh scp git tar shasum; do command -v "${command}" >/dev/null || fail "missing ${command}"; done
[[ -f "${REPO_ROOT}/artisan" ]] || fail "invalid repository root: ${REPO_ROOT}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-ecommerce-performance.XXXXXX")"
REMOTE_ARCHIVE="-"
cleanup() {
    rm -rf "${WORK_DIR}"
    [[ "${REMOTE_ARCHIVE}" == "-" ]] || ssh "${REMOTE_HOST}" rm -f -- "${REMOTE_ARCHIVE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "${ACTION}" == "on" || "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]]; then
    variant=optimized
    [[ "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]] && variant=baseline
    archive="$(build_source_archive "${variant}")"
    REMOTE_ARCHIVE="/tmp/g7-ecommerce-performance-${variant}-$$.tar.gz"
    log "uploading ${variant} source snapshot"
    scp -q "${archive}" "${REMOTE_HOST}:${REMOTE_ARCHIVE}"
fi

log "running ${ACTION} on ${REMOTE_HOST}:${REMOTE_ROOT}"
ssh "${REMOTE_HOST}" sudo bash -s -- \
    "${ACTION}" "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" \
    "${REMOTE_DB_NAME}" "${REMOTE_DB_PREFIX}" "${BASE_URL}" "${REMOTE_ARCHIVE}" "${RUN_SMOKE}" <<'REMOTE'
set -euo pipefail

ACTION="$1"; APP_ROOT="$2"; APP_USER="$3"; PHP_BIN="$4"; DB_NAME="$5"; DB_PREFIX="$6"
BASE_URL="${7%/}"; SOURCE_ARCHIVE="$8"; RUN_SMOKE="$9"
ENV_KEY="G7_ECOMMERCE_PERFORMANCE_VARIANT"
PRODUCTS_TABLE="${DB_PREFIX}ecommerce_products"
OPTIONS_TABLE="${DB_PREFIX}ecommerce_order_options"
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
exec 9>/var/lock/g7-ecommerce-performance-toggle.lock
flock -n 9 || { printf 'another ecommerce performance toggle is running\n' >&2; exit 1; }

log() { printf '[remote-ecommerce-perf] %s\n' "$*"; }
mysql_scalar() { mysql --batch --skip-column-names -e "$1"; }

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
    mysql_scalar "SELECT COALESCE(MIN(IS_VISIBLE), 'MISSING') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${table}' AND INDEX_NAME='${index}'"
}

ensure_idle_database() {
    local count
    count="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='${DB_NAME}' AND COMMAND <> 'Sleep' AND ID <> CONNECTION_ID() AND TIME >= 5")"
    [[ "${count}" == "0" ]] || { printf 'long-running DB query detected; aborting DDL\n' >&2; exit 1; }
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

backup_source() {
    local dir file path
    local -a paths=()
    dir="/home/${APP_USER}/backups/ecommerce-performance-harness"
    file="${dir}/$(date +%Y%m%d-%H%M%S)-before-${ACTION}.tar.gz"
    mkdir -p "${dir}"
    while read -r path; do [[ -e "${APP_ROOT}/${path}" ]] && paths+=("${path}"); done <<'PATHS'
config/benchmark.php
modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductCollection.php
modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductListResource.php
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
    rm -rf "${stage}"
}

ensure_indexes() {
    local -a product_add=() product_show=() option_add=() option_show=()
    ensure_idle_database
    [[ "$(index_exists "${INDEX_LATEST}")" != 0 ]] || product_add+=("ADD INDEX ${INDEX_LATEST} (display_status, deleted_at, created_at, id)")
    [[ "$(index_exists "${INDEX_PRICE}")" != 0 ]] || product_add+=("ADD INDEX ${INDEX_PRICE} (display_status, deleted_at, selling_price, id)")
    [[ "$(index_exists "${INDEX_SALES}")" != 0 ]] || option_add+=("ADD INDEX ${INDEX_SALES} (created_at, product_id, quantity)")
    [[ ${#product_add[@]} -eq 0 ]] || mysql "${DB_NAME}" -e "ALTER TABLE ${PRODUCTS_TABLE} $(IFS=', '; printf '%s' "${product_add[*]}")"
    [[ ${#option_add[@]} -eq 0 ]] || mysql "${DB_NAME}" -e "ALTER TABLE ${OPTIONS_TABLE} $(IFS=', '; printf '%s' "${option_add[*]}")"
    [[ "$(index_visibility "${INDEX_LATEST}")" != NO ]] || product_show+=("ALTER INDEX ${INDEX_LATEST} VISIBLE")
    [[ "$(index_visibility "${INDEX_PRICE}")" != NO ]] || product_show+=("ALTER INDEX ${INDEX_PRICE} VISIBLE")
    [[ "$(index_visibility "${INDEX_SALES}")" != NO ]] || option_show+=("ALTER INDEX ${INDEX_SALES} VISIBLE")
    [[ ${#product_show[@]} -eq 0 ]] || mysql "${DB_NAME}" -e "ALTER TABLE ${PRODUCTS_TABLE} $(IFS=', '; printf '%s' "${product_show[*]}")"
    [[ ${#option_show[@]} -eq 0 ]] || mysql "${DB_NAME}" -e "ALTER TABLE ${OPTIONS_TABLE} $(IFS=', '; printf '%s' "${option_show[*]}")"
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
            mysql "${DB_NAME}" -e "ALTER TABLE ${table} ALTER INDEX ${index} INVISIBLE"
        fi
    done
}

drop_indexes() {
    local index table
    ensure_idle_database
    for index in "${INDEX_SALES}" "${INDEX_PRICE}" "${INDEX_LATEST}"; do
        if [[ "$(index_exists "${index}")" != 0 ]]; then
            table="$(index_table "${index}")"
            mysql "${DB_NAME}" -e "ALTER TABLE ${table} DROP INDEX ${index}"
        fi
    done
    mysql "${DB_NAME}" -e "DELETE FROM ${MIGRATIONS_TABLE} WHERE migration='${MIGRATION_NAME}'"
    rm -f "${APP_ROOT}/${MIGRATION_PATH}" "${APP_ROOT}/${ACTIVE_MIGRATION_PATH}"
}

clear_runtime() {
    cd "${APP_ROOT}"
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan optimize:clear >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan config:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan route:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan view:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan hooks:cache >/dev/null
    systemctl reload php8.5-fpm
}

warm_and_smoke() {
    [[ "${RUN_SMOKE}" == 1 ]] || return
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
        printf 'official-7.0.4'
    fi
}

effective_variant() {
    local value
    [[ "$(source_variant)" == optimized-capable ]] || { printf 'baseline'; return; }
    value="$(awk -F= -v key="${ENV_KEY}" '$1 == key { value=$2 } END { print value }' "${APP_ROOT}/.env")"
    printf '%s' "${value:-optimized}"
}

schema_variant() {
    local a b c
    a="$(index_visibility "${INDEX_LATEST}")"; b="$(index_visibility "${INDEX_PRICE}")"; c="$(index_visibility "${INDEX_SALES}")"
    if [[ "${a}${b}${c}" == MISSINGMISSINGMISSING ]]; then printf 'original'
    elif [[ "${a}${b}${c}" == YESYESYES ]]; then printf 'optimized'
    elif [[ "${a}${b}${c}" == NONONO ]]; then printf 'baseline-invisible'
    else printf 'mixed'; fi
}

write_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}.tmp" <<EOF
source=$(source_variant)
runtime=$(effective_variant)
schema=$(schema_variant)
changed_at=$(date --iso-8601=seconds)
EOF
    install -o "${APP_USER}" -g www-data -m 664 "${STATE_FILE}.tmp" "${STATE_FILE}"
    rm -f "${STATE_FILE}.tmp"
}

show_status() {
    local active_sync=missing
    if [[ -d "${APP_ROOT}/modules/sirsoft-ecommerce" ]]; then
        active_sync=verified
        for path in \
            src/Repositories/ProductRepository.php src/Models/Product.php src/Models/Category.php \
            src/Services/ProductService.php src/Services/CategoryService.php; do
            cmp -s "${APP_ROOT}/modules/_bundled/sirsoft-ecommerce/${path}" "${APP_ROOT}/modules/sirsoft-ecommerce/${path}" || active_sync=drifted
        done
    fi
    printf 'source=%s\n' "$(source_variant)"
    printf 'runtime=%s\n' "$(effective_variant)"
    printf 'schema=%s\n' "$(schema_variant)"
    printf 'index.%s=%s\n' "${INDEX_LATEST}" "$(index_visibility "${INDEX_LATEST}")"
    printf 'index.%s=%s\n' "${INDEX_PRICE}" "$(index_visibility "${INDEX_PRICE}")"
    printf 'index.%s=%s\n' "${INDEX_SALES}" "$(index_visibility "${INDEX_SALES}")"
    printf 'active_module_sync=%s\n' "${active_sync}"
    printf 'php_fpm=%s\n' "$(systemctl is-active php8.5-fpm)"
    [[ ! -f "${STATE_FILE}" ]] || { printf 'last_state:\n'; sed 's/^/  /' "${STATE_FILE}"; }
}

case "${ACTION}" in
    on)
        apply_archive optimized; ensure_indexes; set_env_variant optimized
        clear_runtime; warm_and_smoke; write_state; show_status
        ;;
    off)
        apply_archive baseline; set_env_variant baseline; hide_indexes
        clear_runtime; warm_and_smoke; write_state; show_status
        ;;
    restore-original)
        apply_archive baseline; set_env_variant baseline; clear_runtime
        drop_indexes; remove_env_variant; clear_runtime; warm_and_smoke; write_state; show_status
        ;;
    status) show_status ;;
esac
REMOTE
