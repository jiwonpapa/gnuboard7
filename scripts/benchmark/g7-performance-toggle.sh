#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

ACTION="${1:-status}"
[[ $# -gt 0 ]] && shift

SCOPE="all"
STRICT=0
ASSUME_YES=0
RUN_SMOKE=1
REMOTE_HOST="${G7_PERF_HOST:-g7devops}"
REMOTE_ROOT="${G7_PERF_ROOT:-/home/g7devops/public_html}"
REMOTE_APP_USER="${G7_PERF_APP_USER:-g7devops}"
REMOTE_PHP_BIN="${G7_PERF_PHP_BIN:-php}"
REMOTE_DB_NAME="${G7_PERF_DB_NAME:-g7devops}"
REMOTE_DB_PREFIX="${G7_PERF_DB_PREFIX:-g7_}"
BASELINE_REF="${G7_PERF_BASELINE_REF:-7.0.4}"
OPTIMIZED_REF="${G7_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_PERF_BASE_URL:-https://www.g7devops.com}"
SSH_BIN="${G7_PERF_SSH_BIN:-ssh}"
SCP_BIN="${G7_PERF_SCP_BIN:-scp}"
BOARD_SCRIPT="${G7_PERF_BOARD_SCRIPT:-${SCRIPT_DIR}/board-performance-toggle.sh}"
ECOMMERCE_SCRIPT="${G7_PERF_ECOMMERCE_SCRIPT:-${SCRIPT_DIR}/ecommerce-performance-toggle.sh}"
DISABLE_REMOTE_LOCK="${G7_PERF_DISABLE_REMOTE_LOCK:-0}"

COMMON_PATHS=(
    "app/Extension/HookListenerRegistrar.php"
    "app/Http/Middleware/PermissionMiddleware.php"
    "app/Providers/ModuleRouteServiceProvider.php"
    "app/Services/LanguagePack/LanguagePackRegistry.php"
)
COMMON_OPTIMIZED_ONLY_PATHS=(
    "config/benchmark.php"
)

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/g7-performance-toggle.sh ACTION [options]

Actions:
  on                Apply optimized source/runtime/schema for the scope.
  off               Select baseline runtime and hide benchmark indexes.
  status            Show live source/runtime/schema/module/template state.
  restore-original  Restore official source and drop benchmark indexes.

Options:
  --scope SCOPE     all, common, board, or ecommerce. Default: all.
  --strict          With status, fail when state is mixed or drifted.
  --yes             Required for restore-original.
  --no-smoke        Skip HTTP smoke requests after a transition.
  --host HOST       SSH alias. Default: g7devops.
  --root PATH       Remote app root. Default: /home/g7devops/public_html.
  --app-user USER   Remote PHP-FPM/app user. Default: g7devops.
  --php-bin BIN     Remote PHP binary. Default: php.
  --db NAME         Remote database name. Default: g7devops.
  --db-prefix NAME  Remote table prefix. Default: g7_.
  --baseline REF    Exact official source ref. Default: 7.0.4.
  --optimized-ref REF
                    Reviewed optimized Git ref. Default: HEAD.
  --base-url URL    Base URL used by smoke requests.
  -h, --help        Show this help.

Examples:
  scripts/benchmark/g7-performance-toggle.sh on
  scripts/benchmark/g7-performance-toggle.sh off --scope board
  scripts/benchmark/g7-performance-toggle.sh status --strict
  scripts/benchmark/g7-performance-toggle.sh restore-original --scope all --yes
EOF
}

log() { printf '[g7-perf] %s\n' "$*"; }
fail() { printf '[g7-perf] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope) shift; SCOPE="${1:-}" ;;
        --strict) STRICT=1 ;;
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
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

case "${ACTION}" in
    on|off|status|restore-original) ;;
    -h|--help|help) usage; exit 0 ;;
    *) fail "unknown action: ${ACTION}" ;;
esac
case "${SCOPE}" in
    all|common|board|ecommerce) ;;
    *) fail "unknown scope: ${SCOPE}" ;;
esac
[[ "${STRICT}" == 0 || "${ACTION}" == status ]] \
    || fail '--strict is supported only with status'
[[ "${ACTION}" != restore-original || "${ASSUME_YES}" == 1 ]] \
    || fail 'restore-original drops indexes and requires --yes'
[[ -f "${REPO_ROOT}/artisan" ]] || fail "invalid repository root: ${REPO_ROOT}"

for command in "${SSH_BIN}" "${SCP_BIN}" git tar shasum; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command not found: ${command}"
done
[[ -x "${BOARD_SCRIPT}" ]] || fail "board harness is not executable: ${BOARD_SCRIPT}"
[[ -x "${ECOMMERCE_SCRIPT}" ]] || fail "ecommerce harness is not executable: ${ECOMMERCE_SCRIPT}"

DO_COMMON=0
DO_BOARD=0
DO_ECOMMERCE=0
case "${SCOPE}" in
    all) DO_COMMON=1; DO_BOARD=1; DO_ECOMMERCE=1 ;;
    common) DO_COMMON=1 ;;
    board) DO_BOARD=1 ;;
    ecommerce) DO_ECOMMERCE=1 ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-performance.XXXXXX")"
REMOTE_COMMON_ARCHIVE="-"
LOCK_TOKEN="g7-perf-$(date +%s)-$$"
LOCK_ACQUIRED=0
MUTATION_STARTED=0
FINALIZED=0

release_remote_lock() {
    [[ "${LOCK_ACQUIRED}" == 1 ]] || return 0
    if [[ "${DISABLE_REMOTE_LOCK}" == 1 ]]; then
        LOCK_ACQUIRED=0
        return 0
    fi
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- "${LOCK_TOKEN}" <<'REMOTE' >/dev/null
set -euo pipefail
token="$1"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ -f "${lock_dir}/owner" ]] || exit 0
[[ "$(<"${lock_dir}/owner")" == "${token}" ]] || exit 1
    rm -f "${lock_dir}/owner" "${lock_dir}/metadata"
rmdir "${lock_dir}"
REMOTE
    LOCK_ACQUIRED=0
}

emergency_rebuild() {
    [[ "${MUTATION_STARTED}" == 1 && "${FINALIZED}" == 0 ]] || return 0
    log 'transition failed; rebuilding runtime caches for the resulting mixed state'
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" <<'REMOTE' >/dev/null || true
set -euo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
cd "${app_root}"
sudo -u "${app_user}" "${php_bin}" artisan optimize:clear >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan config:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan route:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan view:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan hooks:cache >/dev/null
systemctl reload php8.5-fpm
REMOTE
}

cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    emergency_rebuild
    if [[ "${REMOTE_COMMON_ARCHIVE}" != - ]]; then
        "${SSH_BIN}" "${REMOTE_HOST}" rm -f -- "${REMOTE_COMMON_ARCHIVE}" >/dev/null 2>&1
    fi
    release_remote_lock
    rm -rf "${WORK_DIR}"
    exit "${result}"
}
trap cleanup EXIT INT TERM

acquire_remote_lock() {
    if [[ "${DISABLE_REMOTE_LOCK}" == 1 ]]; then
        LOCK_ACQUIRED=1
        return
    fi
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- "${LOCK_TOKEN}" "${ACTION}" "${SCOPE}" <<'REMOTE'
set -euo pipefail
token="$1"; action="$2"; scope="$3"
lock_dir=/var/lock/g7-performance-toggle.lock.d
if ! mkdir "${lock_dir}" 2>/dev/null; then
    owner=unknown
    [[ ! -f "${lock_dir}/owner" ]] || owner="$(<"${lock_dir}/owner")"
    printf 'another performance transition is running: %s\n' "${owner}" >&2
    exit 1
fi
printf '%s\n' "${token}" > "${lock_dir}/owner"
printf 'action=%s\nscope=%s\nstarted_at=%s\n' \
    "${action}" "${scope}" "$(date --iso-8601=seconds)" > "${lock_dir}/metadata"
REMOTE
    LOCK_ACQUIRED=1
}

copy_optimized_file() {
    local path="$1" destination="$2"
    git -C "${REPO_ROOT}" cat-file -e "${OPTIMIZED_REF}:${path}" 2>/dev/null \
        || fail "optimized common file not found at ${OPTIMIZED_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${OPTIMIZED_REF}:${path}" > "${destination}/${path}"
}

copy_git_file() {
    local path="$1" destination="$2"
    git -C "${REPO_ROOT}" cat-file -e "${BASELINE_REF}:${path}" 2>/dev/null \
        || fail "baseline common file not found at ${BASELINE_REF}: ${path}"
    mkdir -p "$(dirname -- "${destination}/${path}")"
    git -C "${REPO_ROOT}" show "${BASELINE_REF}:${path}" > "${destination}/${path}"
}

build_common_archive() {
    local variant="$1"
    local stage="${WORK_DIR}/common-${variant}"
    local archive="${WORK_DIR}/common-${variant}.tar.gz" path
    local -a paths=()
    mkdir -p "${stage}/.harness"
    for path in "${COMMON_PATHS[@]}"; do
        if [[ "${variant}" == optimized ]]; then
            copy_optimized_file "${path}" "${stage}"
        else
            copy_git_file "${path}" "${stage}"
        fi
        paths+=("${path}")
    done
    if [[ "${variant}" == optimized ]]; then
        for path in "${COMMON_OPTIMIZED_ONLY_PATHS[@]}"; do
            copy_optimized_file "${path}" "${stage}"
            paths+=("${path}")
        done
    fi
    printf '%s\n' "${variant}" > "${stage}/.harness/source-variant"
    (
        cd "${stage}"
        for path in "${paths[@]}"; do shasum -a 256 "${path}"; done > .harness/source.sha256
        COPYFILE_DISABLE=1 tar --no-xattrs -czf "${archive}" .
    )
    printf '%s' "${archive}"
}

upload_common_archive() {
    local variant="$1" archive
    archive="$(build_common_archive "${variant}")"
    REMOTE_COMMON_ARCHIVE="/tmp/g7-common-performance-${variant}-$$.tar.gz"
    log "uploading ${variant} common source snapshot"
    "${SCP_BIN}" -q "${archive}" "${REMOTE_HOST}:${REMOTE_COMMON_ARCHIVE}"
}

run_common() {
    local action="$1"
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${action}" "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" \
        "${REMOTE_COMMON_ARCHIVE}" "${LOCK_TOKEN}" <<'REMOTE'
set -euo pipefail

ACTION="$1"; APP_ROOT="$2"; APP_USER="$3"; PHP_BIN="$4"; SOURCE_ARCHIVE="$5"; TOKEN="$6"
ENV_KEY=G7_COMMON_PERFORMANCE_VARIANT
STATE_DIR="${APP_ROOT}/storage/app/benchmark"
STATE_FILE="${STATE_DIR}/common-performance-variant.env"
SOURCE_MANIFEST="${STATE_DIR}/common-performance-source.sha256"
LOCK_DIR=/var/lock/g7-performance-toggle.lock.d

[[ -f "${APP_ROOT}/artisan" ]] || { printf 'invalid app root\n' >&2; exit 1; }
[[ -f "${LOCK_DIR}/owner" && "$(<"${LOCK_DIR}/owner")" == "${TOKEN}" ]] \
    || { printf 'unified performance lock owner mismatch\n' >&2; exit 1; }

set_env_variant() {
    local value="$1" temp
    temp="$(mktemp)"
    awk -v key="${ENV_KEY}" -v value="${value}" '
        BEGIN { replaced = 0 }
        $0 ~ "^" key "=" { if (!replaced) { print key "=" value; replaced = 1 }; next }
        { print }
        END { if (!replaced) print key "=" value }
    ' "${APP_ROOT}/.env" > "${temp}"
    chown --reference="${APP_ROOT}/.env" "${temp}"
    chmod --reference="${APP_ROOT}/.env" "${temp}"
    mv "${temp}" "${APP_ROOT}/.env"
}

remove_env_variant() {
    local temp
    temp="$(mktemp)"
    awk -v key="${ENV_KEY}" '$0 !~ "^" key "=" { print }' "${APP_ROOT}/.env" > "${temp}"
    chown --reference="${APP_ROOT}/.env" "${temp}"
    chmod --reference="${APP_ROOT}/.env" "${temp}"
    mv "${temp}" "${APP_ROOT}/.env"
}

backup_source() {
    local dir file path
    local -a paths=()
    dir="/home/${APP_USER}/backups/g7-performance-harness"
    file="${dir}/$(date +%Y%m%d-%H%M%S)-common-before-${ACTION}.tar.gz"
    mkdir -p "${dir}"
    for path in \
        config/benchmark.php \
        app/Extension/HookListenerRegistrar.php \
        app/Http/Middleware/PermissionMiddleware.php \
        app/Providers/ModuleRouteServiceProvider.php \
        app/Services/LanguagePack/LanguagePackRegistry.php; do
        [[ ! -e "${APP_ROOT}/${path}" ]] || paths+=("${path}")
    done
    if [[ ${#paths[@]} -gt 0 ]]; then
        tar -czf "${file}" -C "${APP_ROOT}" "${paths[@]}"
        chown "${APP_USER}:www-data" "${file}"
    fi
    find "${dir}" -maxdepth 1 -type f -name '*-common-before-*.tar.gz' -printf '%T@ %p\n' \
        | sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f
}

apply_archive() {
    local expected="$1" stage manifest checksum path source mode
    [[ -f "${SOURCE_ARCHIVE}" ]] || { printf 'common source archive missing\n' >&2; exit 1; }
    stage="$(mktemp -d)"
    tar -xzf "${SOURCE_ARCHIVE}" -C "${stage}"
    [[ "$(<"${stage}/.harness/source-variant")" == "${expected}" ]] \
        || { printf 'common source archive variant mismatch\n' >&2; exit 1; }
    manifest="${stage}/.harness/source.sha256"
    backup_source
    while read -r checksum path; do
        path="${path#\*}"
        source="${stage}/${path}"
        mode="$(stat -c '%a' "${source}")"
        install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${APP_ROOT}/${path}"
    done < "${manifest}"
    mkdir -p "${STATE_DIR}"
    install -o "${APP_USER}" -g www-data -m 664 "${manifest}" "${SOURCE_MANIFEST}"
    rm -rf "${stage}"
}

source_variant() {
    if grep -q 'benchmark.common_variant' "${APP_ROOT}/app/Extension/HookListenerRegistrar.php" \
        && grep -q 'benchmark.common_variant' "${APP_ROOT}/app/Http/Middleware/PermissionMiddleware.php" \
        && grep -q 'benchmark.common_variant' "${APP_ROOT}/app/Providers/ModuleRouteServiceProvider.php" \
        && grep -q 'benchmark.common_variant' "${APP_ROOT}/app/Services/LanguagePack/LanguagePackRegistry.php"; then
        printf 'optimized-capable'
    else
        printf 'official-7.0.4'
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
    if [[ "$(source_variant)" != optimized-capable ]]; then
        printf 'baseline'
        return
    fi
    value="$(awk -F= -v key="${ENV_KEY}" '$1 == key { value=$2 } END { print value }' "${APP_ROOT}/.env")"
    printf '%s' "${value:-optimized}"
}

write_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}.tmp" <<EOF
source=$(source_variant)
source_integrity=$(source_integrity)
runtime=$(effective_variant)
changed_at=$(date --iso-8601=seconds)
EOF
    install -o "${APP_USER}" -g www-data -m 664 "${STATE_FILE}.tmp" "${STATE_FILE}"
    rm -f "${STATE_FILE}.tmp"
}

show_status() {
    printf 'source=%s\n' "$(source_variant)"
    printf 'source_integrity=%s\n' "$(source_integrity)"
    printf 'runtime=%s\n' "$(effective_variant)"
    if [[ -f "${APP_ROOT}/config/benchmark.php" ]]; then
        printf 'shared_config=present\n'
    else
        printf 'shared_config=missing\n'
    fi
    printf 'php_fpm=%s\n' "$(systemctl is-active php8.5-fpm)"
    [[ ! -f "${STATE_FILE}" ]] || { printf 'last_state:\n'; sed 's/^/  /' "${STATE_FILE}"; }
}

case "${ACTION}" in
    on) apply_archive optimized; set_env_variant optimized; write_state; show_status ;;
    off) apply_archive optimized; set_env_variant baseline; write_state; show_status ;;
    restore-original) apply_archive baseline; remove_env_variant; write_state; show_status ;;
    status) show_status ;;
esac
REMOTE
}

legacy_options() {
    LEGACY_OPTIONS=(
        --host "${REMOTE_HOST}"
        --root "${REMOTE_ROOT}"
        --app-user "${REMOTE_APP_USER}"
        --php-bin "${REMOTE_PHP_BIN}"
        --db "${REMOTE_DB_NAME}"
        --db-prefix "${REMOTE_DB_PREFIX}"
        --baseline "${BASELINE_REF}"
        --optimized-ref "${OPTIMIZED_REF}"
        --base-url "${BASE_URL}"
        --defer-runtime
        --lock-token "${LOCK_TOKEN}"
        --no-smoke
    )
}

run_board() {
    local action="$1"
    legacy_options
    [[ "${action}" != restore-original ]] || LEGACY_OPTIONS+=(--yes)
    "${BOARD_SCRIPT}" "${action}" "${LEGACY_OPTIONS[@]}"
}

run_ecommerce() {
    local action="$1"
    legacy_options
    [[ "${action}" != restore-original ]] || LEGACY_OPTIONS+=(--yes)
    "${ECOMMERCE_SCRIPT}" "${action}" "${LEGACY_OPTIONS[@]}"
}

prepare_restore() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" \
        "${DO_COMMON}" "${DO_BOARD}" "${DO_ECOMMERCE}" <<'REMOTE'
set -euo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"
do_common="$5"; do_board="$6"; do_ecommerce="$7"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]

set_env_variant() {
    local key="$1" temp
    temp="$(mktemp)"
    awk -v key="${key}" '
        BEGIN { replaced = 0 }
        $0 ~ "^" key "=" { if (!replaced) { print key "=baseline"; replaced = 1 }; next }
        { print }
        END { if (!replaced) print key "=baseline" }
    ' "${app_root}/.env" > "${temp}"
    chown --reference="${app_root}/.env" "${temp}"
    chmod --reference="${app_root}/.env" "${temp}"
    mv "${temp}" "${app_root}/.env"
}

[[ "${do_common}" != 1 ]] || set_env_variant G7_COMMON_PERFORMANCE_VARIANT
[[ "${do_board}" != 1 ]] || set_env_variant G7_BOARD_PERFORMANCE_VARIANT
[[ "${do_ecommerce}" != 1 ]] || set_env_variant G7_ECOMMERCE_PERFORMANCE_VARIANT

cd "${app_root}"
sudo -u "${app_user}" "${php_bin}" artisan optimize:clear >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan config:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan route:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan view:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan hooks:cache >/dev/null
systemctl reload php8.5-fpm
REMOTE
}

remove_shared_config_for_full_restore() {
    [[ "${SCOPE}" == all ]] || return 0
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- "${REMOTE_ROOT}" "${LOCK_TOKEN}" <<'REMOTE'
set -euo pipefail
app_root="$1"; token="$2"; lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
rm -f "${app_root}/config/benchmark.php"
REMOTE
}

finalize_runtime() {
    local smoke="$1"
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" \
        "${ACTION}" "${SCOPE}" "${BASE_URL}" "${smoke}" \
        "${DO_COMMON}" "${DO_BOARD}" "${DO_ECOMMERCE}" <<'REMOTE'
set -euo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"; action="$5"; scope="$6"
base_url="${7%/}"; run_smoke="$8"; do_common="$9"; do_board="${10}"; do_ecommerce="${11}"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]

cd "${app_root}"
sudo -u "${app_user}" "${php_bin}" artisan optimize:clear >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan config:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan route:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan view:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan hooks:cache >/dev/null
systemctl reload php8.5-fpm

state_dir="${app_root}/storage/app/benchmark"
mkdir -p "${state_dir}"
cat > "${state_dir}/g7-performance-transaction.env.tmp" <<EOF
action=${action}
scope=${scope}
changed_at=$(date --iso-8601=seconds)
EOF
install -o "${app_user}" -g www-data -m 664 \
    "${state_dir}/g7-performance-transaction.env.tmp" \
    "${state_dir}/g7-performance-transaction.env"
rm -f "${state_dir}/g7-performance-transaction.env.tmp"

[[ "${run_smoke}" == 1 ]] || exit 0
smoke() {
    local path="$1" result
    result="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code} %{time_total}' "${base_url}${path}")"
    printf '[remote-g7-perf] smoke %s %s\n' "${path}" "${result}"
    [[ "${result%% *}" == 200 ]]
}
[[ "${do_common}" != 1 ]] || smoke '/'
[[ "${do_board}" != 1 ]] || smoke '/api/modules/sirsoft-board/boards/gallery/posts?page=1&per_page=20'
[[ "${do_ecommerce}" != 1 ]] || smoke '/api/modules/sirsoft-ecommerce/products?page=1&per_page=12'
REMOTE
}

extract_status() {
    local file="$1" key="$2"
    awk -F= -v wanted="${key}" '$1 == wanted { value=substr($0, index($0, "=") + 1) } END { print value }' "${file}"
}

component_state() {
    local component="$1" file="$2" source integrity runtime schema shared_config
    local module_sync module_version_sync template_sync module php
    source="$(extract_status "${file}" source)"
    integrity="$(extract_status "${file}" source_integrity)"
    runtime="$(extract_status "${file}" runtime)"
    shared_config="$(extract_status "${file}" shared_config)"
    php="$(extract_status "${file}" php_fpm)"
    [[ "${integrity}" == verified && "${php}" == active ]] || { printf 'drift'; return; }
    if [[ "${source}" == optimized-capable && "${shared_config}" != present ]]; then
        printf 'drift'
        return
    fi

    case "${component}" in
        common)
            if [[ "${source}" == optimized-capable && "${runtime}" == optimized ]]; then
                printf 'optimized'
            elif [[ "${runtime}" == baseline && ( "${source}" == optimized-capable || "${source}" == official-7.0.4 ) ]]; then
                printf 'baseline'
            else
                printf 'mixed'
            fi
            ;;
        board|ecommerce)
            schema="$(extract_status "${file}" schema)"
            module_sync="$(extract_status "${file}" active_module_sync)"
            module_version_sync="$(extract_status "${file}" module_version_sync)"
            module="$(extract_status "${file}" module)"
            [[ "${module_sync}" == verified && "${module_version_sync}" == verified \
                && "${module}" == *' active' ]] \
                || { printf 'drift'; return; }
            if [[ "${component}" == ecommerce ]]; then
                template_sync="$(extract_status "${file}" active_template_sync)"
                [[ "${template_sync}" == verified ]] || { printf 'drift'; return; }
            fi
            if [[ "${source}" == optimized-capable && "${runtime}" == optimized && "${schema}" == optimized ]]; then
                printf 'optimized'
            elif [[ "${runtime}" == baseline \
                && ( "${schema}" == baseline-invisible || "${schema}" == original ) \
                && ( "${source}" == optimized-capable || "${source}" == official-7.0.4 ) ]]; then
                printf 'baseline'
            else
                printf 'mixed'
            fi
            ;;
    esac
}

print_component_status() {
    local component="$1" file="$2" key value
    local -a keys=(source source_integrity runtime schema shared_config active_module_sync active_template_sync module_version_sync module php_fpm)
    for key in "${keys[@]}"; do
        value="$(extract_status "${file}" "${key}")"
        [[ -z "${value}" ]] || printf '%s.%s=%s\n' "${component}" "${key}" "${value}"
    done
    printf '%s.state=%s\n' "${component}" "$(component_state "${component}" "${file}")"
}

show_unified_status() {
    local strict="$1" overall=unknown state component file
    local -a states=()

    if [[ "${DO_COMMON}" == 1 ]]; then
        file="${WORK_DIR}/status-common"
        run_common status > "${file}"
        print_component_status common "${file}"
        states+=("$(component_state common "${file}")")
    fi
    if [[ "${DO_BOARD}" == 1 ]]; then
        file="${WORK_DIR}/status-board"
        run_board status > "${file}"
        print_component_status board "${file}"
        states+=("$(component_state board "${file}")")
    fi
    if [[ "${DO_ECOMMERCE}" == 1 ]]; then
        file="${WORK_DIR}/status-ecommerce"
        run_ecommerce status > "${file}"
        print_component_status ecommerce "${file}"
        states+=("$(component_state ecommerce "${file}")")
    fi

    overall="${states[0]}"
    for state in "${states[@]}"; do
        if [[ "${state}" == drift ]]; then
            overall=drift
            break
        fi
        [[ "${state}" == "${overall}" ]] || overall=mixed
    done
    printf 'overall=%s\n' "${overall}"
    if [[ "${strict}" == 1 && ( "${overall}" == mixed || "${overall}" == drift ) ]]; then
        return 2
    fi
}

acquire_remote_lock

if [[ "${ACTION}" == status ]]; then
    show_unified_status "${STRICT}"
    FINALIZED=1
    exit 0
fi

MUTATION_STARTED=1
if [[ "${DO_COMMON}" == 1 && ( "${ACTION}" == on || "${ACTION}" == off || "${ACTION}" == restore-original ) ]]; then
    common_variant=optimized
    [[ "${ACTION}" != restore-original ]] || common_variant=baseline
    upload_common_archive "${common_variant}"
fi

if [[ "${ACTION}" == restore-original ]]; then
    log 'selecting baseline runtime before source and schema restore'
    prepare_restore
fi

[[ "${DO_COMMON}" != 1 ]] || run_common "${ACTION}"
[[ "${DO_BOARD}" != 1 ]] || run_board "${ACTION}"
[[ "${DO_ECOMMERCE}" != 1 ]] || run_ecommerce "${ACTION}"

if [[ "${ACTION}" == restore-original ]]; then
    remove_shared_config_for_full_restore
fi

log 'rebuilding production caches and reloading PHP-FPM once'
finalize_runtime "${RUN_SMOKE}"
FINALIZED=1

show_unified_status 1
log "${ACTION} complete for scope ${SCOPE}"
