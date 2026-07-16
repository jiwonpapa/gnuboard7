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
BASELINE_REF="${G7_BOARD_PERF_BASELINE_REF:-7.0.4}"
OPTIMIZED_REF="${G7_BOARD_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_BOARD_PERF_BASE_URL:-https://www.g7devops.com}"
ASSUME_YES=0
RUN_SMOKE=1
DEFER_RUNTIME=0
ORCHESTRATION_TOKEN="-"

COMMON_PATHS=(
    "modules/_bundled/sirsoft-board/CHANGELOG.md"
    "modules/_bundled/sirsoft-board/composer.json"
    "modules/_bundled/sirsoft-board/module.json"
    "modules/_bundled/sirsoft-board/package-lock.json"
    "modules/_bundled/sirsoft-board/package.json"
    "modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php"
    "modules/_bundled/sirsoft-board/src/Services/PostService.php"
)

OPTIMIZED_ONLY_PATHS=(
    "config/benchmark.php"
    "modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php"
)

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/board-performance-toggle.sh ACTION [options]

Actions:
  on                Deploy the optimized source, enable the optimized branch,
                    and create/show the benchmark indexes.
  off               Select the original G7 7.0.4 runtime branches and make the
                    benchmark indexes invisible. This is the fast A/B toggle.
  status            Report source integrity, effective branch, indexes, module,
                    PHP-FPM, and the last harness state.
  restore-original  Restore official 7.0.4 files and remove benchmark indexes
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
  --baseline REF    Git ref for exact source restore. Default: 7.0.4
  --optimized-ref REF
                    Reviewed optimized Git ref. Default: HEAD.
  --base-url URL    URL used by smoke requests.
  --defer-runtime   Internal: let the unified harness rebuild caches once.
  --lock-token ID   Internal: reuse the unified harness transaction lock.
  -h, --help        Show this help.

Environment variables use the same names with the G7_BOARD_PERF_ prefix.
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

copy_git_file() {
    local path="$1"
    local destination="$2"

    git -C "${REPO_ROOT}" cat-file -e "${BASELINE_REF}:${path}" 2>/dev/null \
        || fail "baseline file not found at ${BASELINE_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${BASELINE_REF}:${path}" > "${destination}/${path}"
}

build_source_archive() {
    local variant="$1"
    local stage_dir="${WORK_DIR}/${variant}"
    local archive="${WORK_DIR}/board-performance-${variant}.tar.gz"
    local path
    local -a manifest_paths

    mkdir -p "${stage_dir}/.harness"
    manifest_paths=()

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
        --optimized-ref)
            shift
            OPTIMIZED_REF="${1:-}"
            ;;
        --base-url)
            shift
            BASE_URL="${1:-}"
            ;;
        --defer-runtime)
            DEFER_RUNTIME=1
            ;;
        --lock-token)
            shift
            ORCHESTRATION_TOKEN="${1:-}"
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

[[ -f "${REPO_ROOT}/artisan" ]] || fail "repository root is invalid: ${REPO_ROOT}"
require_command ssh
require_command scp
require_command git
require_command tar
require_command shasum

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-board-performance.XXXXXX")"
REMOTE_ARCHIVE="-"
cleanup() {
    rm -rf "${WORK_DIR}"
    if [[ "${REMOTE_ARCHIVE}" != "-" ]]; then
        ssh "${REMOTE_HOST}" rm -f -- "${REMOTE_ARCHIVE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ "${ACTION}" == "on" || "${ACTION}" == "off" || "${ACTION}" == "restore-original" ]]; then
    source_variant="optimized"
    [[ "${ACTION}" == "restore-original" ]] && source_variant="baseline"
    local_archive="$(build_source_archive "${source_variant}")"
    REMOTE_ARCHIVE="/tmp/g7-board-performance-${source_variant}-$$.tar.gz"
    log "uploading ${source_variant} source snapshot"
    scp -q "${local_archive}" "${REMOTE_HOST}:${REMOTE_ARCHIVE}"
fi

log "running ${ACTION} on ${REMOTE_HOST}:${REMOTE_ROOT}"
ssh "${REMOTE_HOST}" sudo bash -s -- \
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
    "${ORCHESTRATION_TOKEN}" <<'REMOTE'
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

ENV_KEY="G7_BOARD_PERFORMANCE_VARIANT"
POSTS_TABLE="${DB_PREFIX}board_posts"
MODULES_TABLE="${DB_PREFIX}modules"
MIGRATIONS_TABLE="${DB_PREFIX}migrations"
MIGRATION_NAME="2026_07_15_000001_add_high_volume_list_indexes"
INDEX_ID="idx_board_posts_list_id"
INDEX_VIEWS="idx_board_posts_list_views"
MIGRATION_PATH="modules/_bundled/sirsoft-board/database/migrations/${MIGRATION_NAME}.php"
ACTIVE_MIGRATION_PATH="modules/sirsoft-board/database/migrations/${MIGRATION_NAME}.php"
STATE_DIR="${APP_ROOT}/storage/app/benchmark"
STATE_FILE="${STATE_DIR}/board-performance-variant.env"
SOURCE_MANIFEST="${STATE_DIR}/board-performance-source.sha256"

[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || { printf 'invalid DB name\n' >&2; exit 1; }
[[ "${DB_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]] || { printf 'invalid DB prefix\n' >&2; exit 1; }
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

index_exists() {
    local index_name="$1"
    mysql_scalar "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND INDEX_NAME='${index_name}'"
}

index_visibility() {
    local index_name="$1"
    mysql_scalar "SELECT COALESCE(MIN(IS_VISIBLE), 'MISSING') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='${POSTS_TABLE}' AND INDEX_NAME='${index_name}'"
}

ensure_no_long_queries() {
    local count
    count="$(mysql_scalar "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='${DB_NAME}' AND COMMAND <> 'Sleep' AND ID <> CONNECTION_ID() AND TIME >= 5")"
    if [[ "${count}" != "0" ]]; then
        mysql --table -e "SELECT ID,USER,COMMAND,TIME,STATE,LEFT(INFO,180) AS INFO FROM information_schema.PROCESSLIST WHERE DB='${DB_NAME}' AND COMMAND <> 'Sleep' AND ID <> CONNECTION_ID() AND TIME >= 5 ORDER BY TIME DESC"
        printf 'long-running DB work detected; toggle aborted before DDL\n' >&2
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

clear_runtime() {
    [[ "${DEFER_RUNTIME}" == "0" ]] || return 0
    log "rebuilding Laravel production caches"
    cd "${APP_ROOT}"
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan optimize:clear >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan config:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan route:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan view:cache >/dev/null
    sudo -u "${APP_USER}" "${PHP_BIN}" artisan hooks:cache >/dev/null
    systemctl reload php8.5-fpm
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
modules/_bundled/sirsoft-board/CHANGELOG.md
modules/_bundled/sirsoft-board/composer.json
modules/_bundled/sirsoft-board/module.json
modules/_bundled/sirsoft-board/package-lock.json
modules/_bundled/sirsoft-board/package.json
modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php
modules/_bundled/sirsoft-board/src/Services/PostService.php
modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php
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
src/Repositories/PostRepository.php
src/Services/PostService.php
database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php
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
    local stage_dir manifest variant checksum path source mode relative active_destination

    [[ -f "${SOURCE_ARCHIVE}" ]] || { printf 'source archive missing\n' >&2; exit 1; }
    stage_dir="$(mktemp -d)"
    tar -xzf "${SOURCE_ARCHIVE}" -C "${stage_dir}"
    variant="$(<"${stage_dir}/.harness/source-variant")"
    [[ "${variant}" == "${expected_variant}" ]] || { printf 'source archive variant mismatch\n' >&2; exit 1; }
    manifest="${stage_dir}/.harness/source.sha256"

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
        esac
    done < "${manifest}"

    if [[ "${variant}" == "baseline" ]]; then
        rm -f "${APP_ROOT}/${MIGRATION_PATH}"
        rm -f "${APP_ROOT}/${ACTIVE_MIGRATION_PATH}"
    fi

    mkdir -p "${STATE_DIR}"
    install -o "${APP_USER}" -g www-data -m 664 "${manifest}" "${SOURCE_MANIFEST}"
    (
        cd "${APP_ROOT}"
        sha256sum -c "${SOURCE_MANIFEST}" >/dev/null
    )
    rm -rf "${stage_dir}"
}

ensure_indexes_visible() {
    local id_exists views_exists
    local -a add_clauses visibility_clauses
    ensure_no_long_queries
    id_exists="$(index_exists "${INDEX_ID}")"
    views_exists="$(index_exists "${INDEX_VIEWS}")"
    add_clauses=()

    if [[ "${id_exists}" == "0" ]]; then
        add_clauses+=("ADD INDEX ${INDEX_ID} (board_id, is_notice, parent_id, deleted_at, id)")
    fi
    if [[ "${views_exists}" == "0" ]]; then
        add_clauses+=("ADD INDEX ${INDEX_VIEWS} (board_id, is_notice, parent_id, deleted_at, view_count, id)")
    fi
    if [[ ${#add_clauses[@]} -gt 0 ]]; then
        local joined
        joined="$(IFS=', '; printf '%s' "${add_clauses[*]}")"
        log "creating missing indexes; this may take time"
        mysql "${DB_NAME}" -e "ALTER TABLE ${POSTS_TABLE} ${joined}"
    fi

    visibility_clauses=()
    [[ "$(index_visibility "${INDEX_ID}")" == "NO" ]] && visibility_clauses+=("ALTER INDEX ${INDEX_ID} VISIBLE")
    [[ "$(index_visibility "${INDEX_VIEWS}")" == "NO" ]] && visibility_clauses+=("ALTER INDEX ${INDEX_VIEWS} VISIBLE")
    if [[ ${#visibility_clauses[@]} -gt 0 ]]; then
        local visibility_joined
        visibility_joined="$(IFS=', '; printf '%s' "${visibility_clauses[*]}")"
        mysql "${DB_NAME}" -e "ALTER TABLE ${POSTS_TABLE} ${visibility_joined}"
    fi

    if [[ "$(mysql_scalar "SELECT COUNT(*) FROM ${DB_NAME}.${MIGRATIONS_TABLE} WHERE migration='${MIGRATION_NAME}'")" == "0" ]]; then
        local next_batch
        next_batch="$(mysql_scalar "SELECT COALESCE(MAX(batch), 0) + 1 FROM ${DB_NAME}.${MIGRATIONS_TABLE}")"
        mysql "${DB_NAME}" -e "INSERT INTO ${MIGRATIONS_TABLE} (migration, batch) VALUES ('${MIGRATION_NAME}', ${next_batch})"
    fi
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
        mysql "${DB_NAME}" -e "ALTER TABLE ${POSTS_TABLE} ${joined}"
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
        mysql "${DB_NAME}" -e "ALTER TABLE ${POSTS_TABLE} ${joined}"
    fi
    mysql "${DB_NAME}" -e "DELETE FROM ${MIGRATIONS_TABLE} WHERE migration='${MIGRATION_NAME}'"
}

source_integrity() {
    local filtered_manifest
    if [[ ! -f "${SOURCE_MANIFEST}" ]]; then
        printf 'unknown'
        return
    fi
    filtered_manifest="$(mktemp)"
    awk '$2 == "config/benchmark.php" || $2 ~ "^modules/_bundled/sirsoft-board/" { print }' \
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
        printf 'official-7.0.4'
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
    local id_visibility views_visibility
    id_visibility="$(index_visibility "${INDEX_ID}")"
    views_visibility="$(index_visibility "${INDEX_VIEWS}")"
    if [[ "${id_visibility}" == "MISSING" && "${views_visibility}" == "MISSING" ]]; then
        printf 'original'
    elif [[ "${id_visibility}" == "YES" && "${views_visibility}" == "YES" ]]; then
        printf 'optimized'
    elif [[ "${id_visibility}" == "NO" && "${views_visibility}" == "NO" ]]; then
        printf 'baseline-invisible'
    else
        printf 'mixed'
    fi
}

write_state() {
    local runtime_variant="$1"
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}.tmp" <<EOF
source=$(source_variant)
source_integrity=$(source_integrity)
runtime=${runtime_variant}
schema=$(schema_variant)
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
        src/Repositories/PostRepository.php src/Services/PostService.php; do
        cmp -s "${APP_ROOT}/modules/_bundled/sirsoft-board/${path}" \
            "${APP_ROOT}/modules/sirsoft-board/${path}" || active_sync="drifted"
    done

    printf 'source=%s\n' "$(source_variant)"
    printf 'source_integrity=%s\n' "$(source_integrity)"
    printf 'runtime=%s\n' "$(effective_variant)"
    printf 'schema=%s\n' "$(schema_variant)"
    printf 'index.%s=%s\n' "${INDEX_ID}" "$(index_visibility "${INDEX_ID}")"
    printf 'index.%s=%s\n' "${INDEX_VIEWS}" "$(index_visibility "${INDEX_VIEWS}")"
    printf 'active_module_sync=%s\n' "${active_sync}"
    printf 'module_version_sync=%s\n' "${module_version_sync}"
    printf 'module=%s\n' "${module_row}"
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

sync_module_version() {
    local version
    version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${APP_ROOT}/modules/_bundled/sirsoft-board/module.json" | head -n 1)"
    [[ "${version}" =~ ^[0-9A-Za-z.+-]+$ ]] \
        || { printf 'invalid board module version\n' >&2; exit 1; }
    mysql "${DB_NAME}" -e "UPDATE ${MODULES_TABLE} SET version='${version}' WHERE identifier='sirsoft-board'"
}

case "${ACTION}" in
    on)
        ensure_no_long_queries
        apply_source_archive optimized
        ensure_indexes_visible
        set_env_variant optimized
        sync_module_version
        clear_runtime
        write_state optimized
        smoke
        show_status
        ;;
    off)
        ensure_no_long_queries
        apply_source_archive optimized
        set_env_variant baseline
        sync_module_version
        clear_runtime
        hide_indexes
        write_state baseline
        smoke
        show_status
        ;;
    restore-original)
        ensure_no_long_queries
        if [[ -f "${APP_ROOT}/config/benchmark.php" ]]; then
            set_env_variant baseline
            clear_runtime
        fi
        drop_indexes_and_migration
        apply_source_archive baseline
        remove_env_variant
        sync_module_version
        clear_runtime
        write_state baseline
        smoke
        show_status
        ;;
    status)
        show_status
        ;;
esac
REMOTE

log "${ACTION} complete"
