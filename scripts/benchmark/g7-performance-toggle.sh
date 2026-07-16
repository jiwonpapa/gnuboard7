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
RECOVER_FAIL_CLOSED=0
REMOTE_HOST="${G7_PERF_HOST:-g7devops}"
REMOTE_ROOT="${G7_PERF_ROOT:-/home/g7devops/public_html}"
REMOTE_APP_USER="${G7_PERF_APP_USER:-g7devops}"
REMOTE_PHP_BIN="${G7_PERF_PHP_BIN:-php}"
REMOTE_DB_NAME="${G7_PERF_DB_NAME:-g7devops}"
REMOTE_DB_PREFIX="${G7_PERF_DB_PREFIX:-g7_}"
BASELINE_REF="${G7_PERF_BASELINE_REF:-7.0.4}"
OPTIMIZED_REF="${G7_PERF_OPTIMIZED_REF:-HEAD}"
BASE_URL="${G7_PERF_BASE_URL:-https://www.g7devops.com}"
SMOKE_BOARD_SLUG="${G7_PERF_BOARD_SLUG:-freebd}"
DRAIN_TIMEOUT="${G7_PERF_DRAIN_TIMEOUT:-930}"
SSH_BIN="${G7_PERF_SSH_BIN:-ssh}"
SCP_BIN="${G7_PERF_SCP_BIN:-scp}"
BOARD_SCRIPT="${G7_PERF_BOARD_SCRIPT:-${SCRIPT_DIR}/board-performance-toggle.sh}"
ECOMMERCE_SCRIPT="${G7_PERF_ECOMMERCE_SCRIPT:-${SCRIPT_DIR}/ecommerce-performance-toggle.sh}"
DISABLE_REMOTE_LOCK="${G7_PERF_DISABLE_REMOTE_LOCK:-0}"
PARENT_LOCK_TOKEN="${G7_PERF_PARENT_LOCK_TOKEN:-}"

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
  --recover-fail-closed
                    With `on`, resume a prior fail-closed transition that left
                    maintenance/runtime snapshots on the server.
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
  --board-slug SLUG Public board used by transition smoke. Default: freebd.
  --drain-timeout SEC
                    Maximum worker drain time. Default: 930.
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
        --recover-fail-closed) RECOVER_FAIL_CLOSED=1 ;;
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --app-user) shift; REMOTE_APP_USER="${1:-}" ;;
        --php-bin) shift; REMOTE_PHP_BIN="${1:-}" ;;
        --db) shift; REMOTE_DB_NAME="${1:-}" ;;
        --db-prefix) shift; REMOTE_DB_PREFIX="${1:-}" ;;
        --baseline) shift; BASELINE_REF="${1:-}" ;;
        --optimized-ref) shift; OPTIMIZED_REF="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        --board-slug) shift; SMOKE_BOARD_SLUG="${1:-}" ;;
        --drain-timeout) shift; DRAIN_TIMEOUT="${1:-}" ;;
        --parent-lock-token) shift; PARENT_LOCK_TOKEN="${1:-}" ;;
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
[[ "${RECOVER_FAIL_CLOSED}" == 0 || "${ACTION}" == on ]] \
    || fail '--recover-fail-closed is supported only with on'
[[ "${RECOVER_FAIL_CLOSED}" == 0 || "${SCOPE}" == all ]] \
    || fail '--recover-fail-closed requires --scope all'
[[ "${ACTION}" != restore-original || "${ASSUME_YES}" == 1 ]] \
    || fail 'restore-original drops indexes and requires --yes'
[[ "${DRAIN_TIMEOUT}" =~ ^[0-9]+$ && "${DRAIN_TIMEOUT}" -ge 30 && "${DRAIN_TIMEOUT}" -le 3600 ]] \
    || fail '--drain-timeout must be between 30 and 3600 seconds'
[[ "${SMOKE_BOARD_SLUG}" =~ ^[A-Za-z0-9_-]+$ ]] \
    || fail '--board-slug contains unsupported characters'
[[ -z "${PARENT_LOCK_TOKEN}" || "${PARENT_LOCK_TOKEN}" =~ ^g7-[A-Za-z0-9_-]+$ ]] \
    || fail 'invalid parent performance lock token'
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
REMOTE_BOARD_ARCHIVE="-"
REMOTE_ECOMMERCE_ARCHIVE="-"
REMOTE_COMMON_VARIANT="-"
REMOTE_BOARD_VARIANT="-"
REMOTE_ECOMMERCE_VARIANT="-"
LOCK_TOKEN="g7-perf-$(date +%s)-$$"
LOCK_ACQUIRED=0
LOCK_BORROWED=0
MUTATION_STARTED=0
SOURCE_MUTATION_STARTED=0
PRESERVE_FAIL_CLOSED=0
FINALIZED=0

release_remote_lock() {
    [[ "${LOCK_ACQUIRED}" == 1 ]] || return 0
    if [[ "${LOCK_BORROWED}" == 1 ]]; then
        LOCK_ACQUIRED=0
        return 0
    fi
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
    if [[ "${SOURCE_MUTATION_STARTED}" == 0 && "${PRESERVE_FAIL_CLOSED}" == 0 ]]; then
        log 'transition stopped before source/schema mutation; restoring only the captured runtime state'
        if ! "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
            "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" <<'REMOTE' >/dev/null
set -Eeuo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
state_dir="${app_root}/storage/app/benchmark"
units_file="${state_dir}/g7-performance-stopped-units"
before_file="${state_dir}/g7-performance-runtime-before.env"
quiesced_file="${state_dir}/g7-performance-quiesced.env"
maintenance_marker="${state_dir}/g7-performance-maintenance-entered"
[[ -f "${before_file}" ]] || exit 0

assert_fail_closed() {
    local deadline pending unit fpm_state
    deadline=$((SECONDS + 30))
    while true; do
        pending=0
        if [[ -f "${units_file}" ]]; then
            while IFS= read -r unit; do
                [[ -n "${unit}" ]] || continue
                [[ "$(systemctl is-active "${unit}" || true)" == inactive ]] || pending=1
            done < "${units_file}"
        fi
        fpm_state="$(systemctl is-active php8.5-fpm || true)"
        [[ "${pending}" == 0 && "${fpm_state}" == inactive ]] && return 0
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
}
force_fail_closed() {
    local result=$?
    trap - ERR
    cd "${app_root}"
    sudo -u "${app_user}" "${php_bin}" artisan down --retry=60 >/dev/null 2>&1 || true
    systemctl stop --no-block php8.5-fpm || true
    if [[ -f "${units_file}" ]]; then
        while IFS= read -r unit; do
            [[ -n "${unit}" ]] && systemctl stop --no-block "${unit}" || true
        done < "${units_file}"
    fi
    assert_fail_closed || printf 'could not verify fail-closed runtime state\n' >&2
    exit "${result}"
}
trap force_fail_closed ERR

if [[ ! -f "${quiesced_file}" && -f "${maintenance_marker}" ]]; then
    printf 'quiesce did not complete; preserving maintenance and stopped runtimes\n' >&2
    systemctl stop --no-block php8.5-fpm
    if [[ -f "${units_file}" ]]; then
        while IFS= read -r unit; do
            [[ -n "${unit}" ]] && systemctl stop --no-block "${unit}"
        done < "${units_file}"
    fi
    assert_fail_closed
    trap - ERR
    exit 0
fi

read_state() {
    awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${before_file}"
}
if [[ -f "${units_file}" ]]; then
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        rm -f "/run/systemd/system/${unit}.d/50-g7-performance-toggle.conf"
        rmdir "/run/systemd/system/${unit}.d" 2>/dev/null || true
    done < "${units_file}"
fi
rm -f /run/systemd/system/php8.5-fpm.service.d/50-g7-performance-toggle.conf
rmdir /run/systemd/system/php8.5-fpm.service.d 2>/dev/null || true
systemctl daemon-reload

if [[ "$(read_state php_fpm_was_active)" == 1 ]]; then
    systemctl start php8.5-fpm
else
    systemctl stop php8.5-fpm
fi
if [[ -f "${units_file}" ]]; then
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        systemctl start "${unit}"
        [[ "$(systemctl is-active "${unit}")" == active ]]
    done < "${units_file}"
fi
cd "${app_root}"
if [[ "$(read_state maintenance_was_active)" == 0 ]]; then
    sudo -u "${app_user}" "${php_bin}" artisan up >/dev/null
    [[ ! -f storage/framework/down ]]
else
    sudo -u "${app_user}" "${php_bin}" artisan down --retry=60 >/dev/null
    [[ -f storage/framework/down ]]
fi
if [[ "$(read_state php_fpm_was_active)" == 1 ]]; then
    [[ "$(systemctl is-active php8.5-fpm)" == active ]]
else
    [[ "$(systemctl is-active php8.5-fpm || true)" == inactive ]]
fi
rm -f "${units_file}" "${before_file}" "${quiesced_file}" "${maintenance_marker}"
trap - ERR
REMOTE
        then
            log 'FINAL FAILURE: captured runtime state could not be restored; fail-closed snapshot was preserved'
            return 1
        fi
    else
        log 'transition failed after mutation; keeping the application in maintenance mode'
        if ! "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
            "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" <<'REMOTE' >/dev/null
set -Eeuo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
cd "${app_root}"
sudo -u "${app_user}" "${php_bin}" artisan down --retry=60 >/dev/null || true
units_file="${app_root}/storage/app/benchmark/g7-performance-stopped-units"
systemctl stop --no-block php8.5-fpm
if [[ -f "${units_file}" ]]; then
    tac "${units_file}" | while IFS= read -r unit; do
        [[ -n "${unit}" ]] && systemctl stop --no-block "${unit}"
    done
fi
deadline=$((SECONDS + 30))
while true; do
    pending=0
    if [[ -f "${units_file}" ]]; then
        while IFS= read -r unit; do
            [[ -n "${unit}" ]] || continue
            [[ "$(systemctl is-active "${unit}" || true)" == inactive ]] || pending=1
        done < "${units_file}"
    fi
    fpm_state="$(systemctl is-active php8.5-fpm || true)"
    [[ "${pending}" == 0 && "${fpm_state}" == inactive ]] && break
    (( SECONDS < deadline )) || {
        printf 'fail-closed runtime verification failed: fpm=%s pending_units=%s\n' "${fpm_state}" "${pending}" >&2
        exit 1
    }
    sleep 1
done
REMOTE
        then
            log 'FINAL FAILURE: fail-closed runtime state could not be verified'
            return 1
        fi
    fi
}

cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    emergency_rebuild || result=1
    "${SSH_BIN}" "${REMOTE_HOST}" rm -f -- \
        "${REMOTE_COMMON_ARCHIVE}" "${REMOTE_BOARD_ARCHIVE}" \
        "${REMOTE_ECOMMERCE_ARCHIVE}" >/dev/null 2>&1 || true
    release_remote_lock || result=1
    rm -rf "${WORK_DIR}"
    exit "${result}"
}
trap cleanup EXIT INT TERM

acquire_remote_lock() {
    if [[ -n "${PARENT_LOCK_TOKEN}" ]]; then
        LOCK_TOKEN="${PARENT_LOCK_TOKEN}"
        "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- "${LOCK_TOKEN}" <<'REMOTE'
set -euo pipefail
token="$1"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ -f "${lock_dir}/owner" && "$(<"${lock_dir}/owner")" == "${token}" ]] || {
    printf 'parent performance lock owner mismatch\n' >&2
    exit 1
}
REMOTE
        LOCK_ACQUIRED=1
        LOCK_BORROWED=1
        return
    fi
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
    REMOTE_COMMON_VARIANT="${variant}"
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
    trap 'rm -rf "${stage}"' RETURN
    tar -xzf "${SOURCE_ARCHIVE}" -C "${stage}"
    [[ "$(<"${stage}/.harness/source-variant")" == "${expected}" ]] \
        || { printf 'common source archive variant mismatch\n' >&2; exit 1; }
    manifest="${stage}/.harness/source.sha256"
    [[ -f "${manifest}" ]] || { printf 'common source archive manifest missing\n' >&2; exit 1; }
    (cd "${stage}" && sha256sum -c .harness/source.sha256 >/dev/null) \
        || { printf 'common source archive checksum mismatch\n' >&2; exit 1; }
    backup_source
    while read -r checksum path; do
        path="${path#\*}"
        source="${stage}/${path}"
        mode="$(stat -c '%a' "${source}")"
        install -D -o "${APP_USER}" -g www-data -m "${mode}" "${source}" "${APP_ROOT}/${path}"
    done < "${manifest}"
    mkdir -p "${STATE_DIR}"
    install -o "${APP_USER}" -g www-data -m 664 "${manifest}" "${SOURCE_MANIFEST}"
    (cd "${APP_ROOT}" && sha256sum -c "${SOURCE_MANIFEST}" >/dev/null)
    rm -rf "${stage}"
    trap - RETURN
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
    on) apply_archive optimized; set_env_variant optimized; write_state ;;
    off) apply_archive optimized; set_env_variant baseline; write_state ;;
    restore-original) apply_archive baseline; remove_env_variant; write_state ;;
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
    [[ "${REMOTE_BOARD_ARCHIVE}" == - ]] \
        || LEGACY_OPTIONS+=(--remote-archive "${REMOTE_BOARD_ARCHIVE}")
    "${BOARD_SCRIPT}" "${action}" "${LEGACY_OPTIONS[@]}"
}

run_ecommerce() {
    local action="$1"
    legacy_options
    [[ "${action}" != restore-original ]] || LEGACY_OPTIONS+=(--yes)
    [[ "${REMOTE_ECOMMERCE_ARCHIVE}" == - ]] \
        || LEGACY_OPTIONS+=(--remote-archive "${REMOTE_ECOMMERCE_ARCHIVE}")
    "${ECOMMERCE_SCRIPT}" "${action}" "${LEGACY_OPTIONS[@]}"
}

prepare_component_archives() {
    local board_archive="${WORK_DIR}/board-source.tar.gz"
    local ecommerce_archive="${WORK_DIR}/ecommerce-source.tar.gz"

    legacy_options
    LEGACY_OPTIONS+=(--prepare-archive "${board_archive}")
    if [[ "${DO_BOARD}" == 1 ]]; then
        [[ "${ACTION}" != restore-original ]] || LEGACY_OPTIONS+=(--yes)
        "${BOARD_SCRIPT}" "${ACTION}" "${LEGACY_OPTIONS[@]}"
        REMOTE_BOARD_ARCHIVE="/tmp/g7-board-performance-prepared-${LOCK_TOKEN}.tar.gz"
        REMOTE_BOARD_VARIANT=optimized
        [[ "${ACTION}" != restore-original ]] || REMOTE_BOARD_VARIANT=baseline
        "${SCP_BIN}" -q "${board_archive}" "${REMOTE_HOST}:${REMOTE_BOARD_ARCHIVE}"
    fi

    legacy_options
    LEGACY_OPTIONS+=(--prepare-archive "${ecommerce_archive}")
    if [[ "${DO_ECOMMERCE}" == 1 ]]; then
        [[ "${ACTION}" != restore-original ]] || LEGACY_OPTIONS+=(--yes)
        "${ECOMMERCE_SCRIPT}" "${ACTION}" "${LEGACY_OPTIONS[@]}"
        REMOTE_ECOMMERCE_ARCHIVE="/tmp/g7-ecommerce-performance-prepared-${LOCK_TOKEN}.tar.gz"
        REMOTE_ECOMMERCE_VARIANT=optimized
        [[ "${ACTION}" != off && "${ACTION}" != restore-original ]] \
            || REMOTE_ECOMMERCE_VARIANT=baseline
        "${SCP_BIN}" -q "${ecommerce_archive}" "${REMOTE_HOST}:${REMOTE_ECOMMERCE_ARCHIVE}"
    fi
}

verify_remote_archives() {
    "${SSH_BIN}" "${REMOTE_HOST}" bash -s -- \
        "${REMOTE_COMMON_ARCHIVE}" "${REMOTE_COMMON_VARIANT}" \
        "${REMOTE_BOARD_ARCHIVE}" "${REMOTE_BOARD_VARIANT}" \
        "${REMOTE_ECOMMERCE_ARCHIVE}" "${REMOTE_ECOMMERCE_VARIANT}" <<'REMOTE'
set -euo pipefail
stage=''
trap '[[ -z "${stage}" ]] || rm -rf "${stage}"' EXIT
while [[ $# -gt 0 ]]; do
    archive="$1"; expected_variant="$2"; shift 2
    [[ "${archive}" != - ]] || continue
    [[ -f "${archive}" ]] || { printf 'prepared archive missing: %s\n' "${archive}" >&2; exit 1; }
    stage="$(mktemp -d)"
    tar -xzf "${archive}" -C "${stage}"
    [[ -f "${stage}/.harness/source-variant" \
        && -f "${stage}/.harness/source.sha256" ]] \
        || { printf 'prepared archive metadata missing: %s\n' "${archive}" >&2; exit 1; }
    [[ "$(<"${stage}/.harness/source-variant")" == "${expected_variant}" ]] \
        || { printf 'prepared archive variant mismatch: %s\n' "${archive}" >&2; exit 1; }
    (cd "${stage}" && sha256sum -c .harness/source.sha256 >/dev/null)
    rm -rf "${stage}"
    stage=''
done
trap - EXIT
REMOTE
}

preflight_transition_snapshot() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${LOCK_TOKEN}" "${RECOVER_FAIL_CLOSED}" <<'REMOTE'
set -euo pipefail
app_root="$1"; token="$2"; recover="$3"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
[[ "${recover}" == 0 || "${recover}" == 1 ]]

state_dir="${app_root}/storage/app/benchmark"
units_file="${state_dir}/g7-performance-stopped-units"
before_file="${state_dir}/g7-performance-runtime-before.env"
quiesced_file="${state_dir}/g7-performance-quiesced.env"
maintenance_marker="${state_dir}/g7-performance-maintenance-entered"
transaction_file="${state_dir}/g7-performance-transaction.env"
snapshot_present=0
for file in "${units_file}" "${before_file}" "${quiesced_file}" "${maintenance_marker}"; do
    [[ ! -e "${file}" ]] || snapshot_present=1
done

if [[ "${recover}" == 1 ]]; then
    [[ "${snapshot_present}" == 1 && -f "${units_file}" && -f "${before_file}" \
        && -f "${maintenance_marker}" && -f "${app_root}/storage/framework/down" ]] || {
        printf 'no recoverable fail-closed runtime snapshot was found\n' >&2
        exit 1
    }
    maintenance_before="$(awk -F= '$1 == "maintenance_was_active" { print $2; exit }' "${before_file}")"
    fpm_before="$(awk -F= '$1 == "php_fpm_was_active" { print $2; exit }' "${before_file}")"
    [[ "${maintenance_before}" == 0 && "${fpm_before}" == 1 ]] || {
        printf 'fail-closed snapshot did not originate from an available application\n' >&2
        exit 1
    }
    exit 0
fi

[[ "${snapshot_present}" == 0 ]] && exit 0
phase=''
[[ ! -f "${transaction_file}" ]] \
    || phase="$(awk -F= '$1 == "phase" { value=$2 } END { print value }' "${transaction_file}")"
if [[ "${phase}" == complete && ! -f "${app_root}/storage/framework/down" \
    && "$(systemctl is-active php8.5-fpm || true)" == active ]]; then
    exit 0
fi
printf 'unfinished fail-closed transition snapshot exists; rerun `on --recover-fail-closed`\n' >&2
exit 1
REMOTE
}

quiesce_runtime() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" \
        "${DRAIN_TIMEOUT}" "${REMOTE_DB_NAME}" "${REMOTE_DB_PREFIX}" \
        "${RECOVER_FAIL_CLOSED}" <<'REMOTE'
set -Eeuo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"; drain_timeout="$5"
db_name="$6"; db_prefix="$7"; recover="$8"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
[[ "${drain_timeout}" =~ ^[0-9]+$ ]]
[[ "${db_name}" =~ ^[A-Za-z0-9_]+$ && "${db_prefix}" =~ ^[A-Za-z0-9_]*$ ]]
[[ "${recover}" == 0 || "${recover}" == 1 ]]

state_dir="${app_root}/storage/app/benchmark"
units_file="${state_dir}/g7-performance-stopped-units"
before_file="${state_dir}/g7-performance-runtime-before.env"
quiesced_file="${state_dir}/g7-performance-quiesced.env"
maintenance_marker="${state_dir}/g7-performance-maintenance-entered"
transaction_file="${state_dir}/g7-performance-transaction.env"
mkdir -p "${state_dir}"

snapshot_present=0
for file in "${units_file}" "${before_file}" "${quiesced_file}" "${maintenance_marker}"; do
    [[ ! -e "${file}" ]] || snapshot_present=1
done
if [[ "${recover}" == 1 ]]; then
    [[ "${snapshot_present}" == 1 && -f "${units_file}" && -f "${before_file}" \
        && -f "${maintenance_marker}" && -f "${app_root}/storage/framework/down" ]] || {
        printf 'recoverable fail-closed snapshot disappeared before drain\n' >&2
        exit 1
    }
else
    if [[ "${snapshot_present}" == 1 ]]; then
        phase=''
        [[ ! -f "${transaction_file}" ]] \
            || phase="$(awk -F= '$1 == "phase" { value=$2 } END { print value }' "${transaction_file}")"
        [[ "${phase}" == complete && ! -f "${app_root}/storage/framework/down" \
            && "$(systemctl is-active php8.5-fpm || true)" == active ]] || {
            printf 'unfinished fail-closed transition snapshot exists; recovery required\n' >&2
            exit 1
        }
        while IFS= read -r unit; do
            [[ -n "${unit}" ]] || continue
            rm -f "/run/systemd/system/${unit}.d/50-g7-performance-toggle.conf"
            rmdir "/run/systemd/system/${unit}.d" 2>/dev/null || true
        done < "${units_file}"
        rm -f /run/systemd/system/php8.5-fpm.service.d/50-g7-performance-toggle.conf
        rmdir /run/systemd/system/php8.5-fpm.service.d 2>/dev/null || true
        systemctl daemon-reload
    fi
    rm -f "${units_file}" "${before_file}" "${quiesced_file}" "${maintenance_marker}"
fi

benchmark_jobs_table="${db_prefix}generation_jobs"
if [[ "$(mysql --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_name}' AND TABLE_NAME='${benchmark_jobs_table}'")" != 0 ]]; then
    active_jobs="$(mysql --batch --skip-column-names "${db_name}" -e "SELECT COUNT(*) FROM ${benchmark_jobs_table} WHERE status IN ('running','stopping')")"
    [[ "${active_jobs}" == 0 ]] || {
        printf 'active benchmark generation/reset job detected; stop it before tuning\n' >&2
        exit 1
    }
fi
queue_jobs_table="${db_prefix}jobs"
if [[ "$(mysql --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_name}' AND TABLE_NAME='${queue_jobs_table}'")" != 0 ]]; then
    reserved_jobs="$(mysql --batch --skip-column-names "${db_name}" -e "SELECT COUNT(*) FROM ${queue_jobs_table} WHERE reserved_at IS NOT NULL")"
    [[ "${reserved_jobs}" == 0 ]] || {
        printf 'active database queue job detected; wait for it before tuning\n' >&2
        exit 1
    }
fi

cd "${app_root}"
maintenance_driver="$(awk -F= '$1 == "APP_MAINTENANCE_DRIVER" { print $2; exit }' .env | tr -d '\r\"' | xargs)"
[[ -z "${maintenance_driver}" || "${maintenance_driver}" == file ]] || {
    printf 'only APP_MAINTENANCE_DRIVER=file is supported by the safe transition\n' >&2
    exit 1
}

runtime_artisan_pids() {
    local pid command cwd
    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cmdline" ]] || continue
        command="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
        [[ "${command}" == *artisan* ]] || continue
        cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
        if [[ "${command}" == *"${app_root}/artisan"* \
            || "${cwd}" == "${app_root}" \
            || "${cwd}" == "${app_root}/"* ]]; then
            printf '%s\n' "${pid}"
        fi
    done < <(ps -e -o pid= | tr -d ' ')
}

if [[ "${recover}" == 0 ]]; then
    : > "${units_file}"
fi
mapfile -t runtime_pids < <(runtime_artisan_pids)
unmanaged_pids=()
for pid in "${runtime_pids[@]}"; do
    cgroup="$(awk -F: '$3 ~ /\.service(\/|$)/ { print $3; exit }' "/proc/${pid}/cgroup" 2>/dev/null || true)"
    unit="$(tr '/' '\n' <<<"${cgroup}" | awk '/\.service$/ { print; exit }')"
    if [[ "${unit}" == *.service && "${unit}" != php*-fpm.service ]]; then
        if [[ "${recover}" == 0 ]]; then
            printf '%s\n' "${unit}" >> "${units_file}"
        elif ! grep -Fxq -- "${unit}" "${units_file}"; then
            unmanaged_pids+=("${pid}")
        fi
    else
        unmanaged_pids+=("${pid}")
    fi
done
if [[ ${#unmanaged_pids[@]} -gt 0 ]]; then
    printf 'unmanaged application Artisan process detected; source/schema unchanged\n' >&2
    ps -o pid=,user=,etime=,args= -p "$(IFS=,; printf '%s' "${unmanaged_pids[*]}")" >&2 || true
    [[ "${recover}" == 1 ]] || rm -f "${units_file}"
    exit 1
fi
if [[ "${recover}" == 0 ]]; then
    if [[ "$(systemctl is-active cron.service || true)" == active ]]; then
        printf 'cron.service\n' >> "${units_file}"
    fi
    sort -u -o "${units_file}" "${units_file}"

    maintenance_was_active=0
    [[ ! -f storage/framework/down ]] || maintenance_was_active=1
    php_fpm_was_active=0
    [[ "$(systemctl is-active php8.5-fpm || true)" != active ]] || php_fpm_was_active=1
    if [[ "${maintenance_was_active}" == 1 || "${php_fpm_was_active}" == 0 ]]; then
        printf 'transition requires an available application (maintenance=off, php-fpm=active)\n' >&2
        rm -f "${units_file}"
        exit 1
    fi
    cat > "${before_file}.tmp" <<EOF
maintenance_was_active=${maintenance_was_active}
php_fpm_was_active=${php_fpm_was_active}
captured_at=$(date --iso-8601=seconds)
EOF
    install -o "${app_user}" -g www-data -m 664 "${before_file}.tmp" "${before_file}"
    rm -f "${before_file}.tmp"
fi
chown "${app_user}:www-data" "${units_file}"

# Prevent restarts; systemd may force-stop only after the harness drain gate has failed closed.
systemd_stop_timeout=$((drain_timeout + 30))
while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    [[ "${unit}" =~ ^[A-Za-z0-9_.@:-]+[.]service$ ]] || {
        printf 'invalid captured systemd unit: %s\n' "${unit}" >&2
        exit 1
    }
    mkdir -p "/run/systemd/system/${unit}.d"
    cat > "/run/systemd/system/${unit}.d/50-g7-performance-toggle.conf" <<EOF
[Service]
Restart=no
TimeoutStopSec=${systemd_stop_timeout}s
EOF
done < "${units_file}"
mkdir -p /run/systemd/system/php8.5-fpm.service.d
cat > /run/systemd/system/php8.5-fpm.service.d/50-g7-performance-toggle.conf <<EOF
[Service]
TimeoutStopSec=${systemd_stop_timeout}s
EOF
systemctl daemon-reload

artisan_commands=''
if [[ "${recover}" == 0 ]]; then
    sudo -u "${app_user}" "${php_bin}" artisan down --retry=60 >/dev/null
    artisan_commands="$(sudo -u "${app_user}" "${php_bin}" artisan list --raw)"
    install -o "${app_user}" -g www-data -m 664 /dev/null "${maintenance_marker}"
fi
if grep -q '^queue:restart[[:space:]]' <<<"${artisan_commands}"; then
    sudo -u "${app_user}" "${php_bin}" artisan queue:restart >/dev/null
fi
if grep -q '^horizon:terminate[[:space:]]' <<<"${artisan_commands}"; then
    sudo -u "${app_user}" "${php_bin}" artisan horizon:terminate >/dev/null
fi
if grep -q '^reverb:restart[[:space:]]' <<<"${artisan_commands}"; then
    sudo -u "${app_user}" "${php_bin}" artisan reverb:restart >/dev/null
fi
if grep -q '^schedule:interrupt[[:space:]]' <<<"${artisan_commands}"; then
    sudo -u "${app_user}" "${php_bin}" artisan schedule:interrupt >/dev/null
fi
if grep -q '^octane:reload[[:space:]]' <<<"${artisan_commands}"; then
    sudo -u "${app_user}" "${php_bin}" artisan octane:reload >/dev/null
fi

while IFS= read -r unit; do
    [[ -n "${unit}" ]] && systemctl stop --no-block "${unit}"
done < "${units_file}"
systemctl stop --no-block php8.5-fpm
deadline=$((SECONDS + drain_timeout))
while true; do
    mapfile -t runtime_pids < <(runtime_artisan_pids)
    pending_units=()
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        [[ "$(systemctl is-active "${unit}" || true)" == inactive ]] \
            || pending_units+=("${unit}")
    done < "${units_file}"
    fpm_state="$(systemctl is-active php8.5-fpm || true)"
    if [[ ${#runtime_pids[@]} -eq 0 && ${#pending_units[@]} -eq 0 \
        && "${fpm_state}" == inactive ]]; then
        break
    fi
    if (( SECONDS >= deadline )); then
        printf 'application runtime drain timed out; source/schema unchanged\n' >&2
        if [[ ${#runtime_pids[@]} -gt 0 ]]; then
            ps -o pid=,user=,etime=,args= -p "$(IFS=,; printf '%s' "${runtime_pids[*]}")" >&2 || true
        fi
        printf 'pending units: %s; php-fpm: %s\n' "${pending_units[*]:-none}" "${fpm_state}" >&2
        exit 1
    fi
    sleep 1
done

printf 'quiesced_at=%s\n' "$(date --iso-8601=seconds)" \
    > "${quiesced_file}"
chown "${app_user}:www-data" "${quiesced_file}"
REMOTE
}

prepare_restore() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${LOCK_TOKEN}" \
        "${DO_COMMON}" "${DO_BOARD}" "${DO_ECOMMERCE}" <<'REMOTE'
set -euo pipefail
app_root="$1"; token="$2"; do_common="$3"; do_board="$4"; do_ecommerce="$5"
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
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" \
        "${ACTION}" "${SCOPE}" <<'REMOTE'
set -euo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"; action="$5"; scope="$6"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
[[ "$(systemctl is-active php8.5-fpm || true)" == inactive ]] \
    || { printf 'php8.5-fpm must remain stopped until source/schema activation\n' >&2; exit 1; }

cd "${app_root}"
sudo -u "${app_user}" "${php_bin}" artisan optimize:clear >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan config:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan route:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan view:cache >/dev/null
sudo -u "${app_user}" "${php_bin}" artisan hooks:cache >/dev/null
systemctl start php8.5-fpm
[[ "$(systemctl is-active php8.5-fpm)" == active ]]

state_dir="${app_root}/storage/app/benchmark"
mkdir -p "${state_dir}"
cat > "${state_dir}/g7-performance-transaction.env.tmp" <<EOF
action=${action}
scope=${scope}
phase=runtime-ready
changed_at=$(date --iso-8601=seconds)
EOF
install -o "${app_user}" -g www-data -m 664 \
    "${state_dir}/g7-performance-transaction.env.tmp" \
    "${state_dir}/g7-performance-transaction.env"
rm -f "${state_dir}/g7-performance-transaction.env.tmp"
REMOTE
}

release_maintenance_and_smoke() {
    local smoke="$1"
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${LOCK_TOKEN}" \
        "${ACTION}" "${SCOPE}" "${BASE_URL}" "${smoke}" \
        "${DO_COMMON}" "${DO_BOARD}" "${DO_ECOMMERCE}" \
        "${SMOKE_BOARD_SLUG}" <<'REMOTE'
set -Eeuo pipefail
app_root="$1"; app_user="$2"; php_bin="$3"; token="$4"; action="$5"; scope="$6"
base_url="${7%/}"; run_smoke="$8"; do_common="$9"; do_board="${10}"; do_ecommerce="${11}"
board_slug="${12}"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
state_dir="${app_root}/storage/app/benchmark"
units_file="${state_dir}/g7-performance-stopped-units"
fail_closed() {
    local result=$?
    trap - ERR
    cd "${app_root}"
    sudo -u "${app_user}" "${php_bin}" artisan down --retry=60 >/dev/null || true
    systemctl stop --no-block php8.5-fpm || true
    if [[ -f "${units_file}" ]]; then
        tac "${units_file}" | while IFS= read -r unit; do
            [[ -n "${unit}" ]] && systemctl stop --no-block "${unit}" || true
        done
    fi
    exit "${result}"
}
trap fail_closed ERR

assert_runtime_healthy() {
    local unit
    [[ ! -f "${app_root}/storage/framework/down" ]]
    [[ "$(systemctl is-active php8.5-fpm)" == active ]]
    if [[ -f "${units_file}" ]]; then
        while IFS= read -r unit; do
            [[ -n "${unit}" ]] || continue
            [[ "$(systemctl is-active "${unit}")" == active ]] || {
                printf 'captured runtime unit is not active: %s\n' "${unit}" >&2
                return 1
            }
        done < "${units_file}"
    fi
}

cd "${app_root}"
if [[ -f "${units_file}" ]]; then
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        rm -f "/run/systemd/system/${unit}.d/50-g7-performance-toggle.conf"
        rmdir "/run/systemd/system/${unit}.d" 2>/dev/null || true
    done < "${units_file}"
fi
rm -f /run/systemd/system/php8.5-fpm.service.d/50-g7-performance-toggle.conf
rmdir /run/systemd/system/php8.5-fpm.service.d 2>/dev/null || true
systemctl daemon-reload

if [[ -f "${units_file}" ]]; then
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] && systemctl start "${unit}"
    done < "${units_file}"
fi
sudo -u "${app_user}" "${php_bin}" artisan up >/dev/null
assert_runtime_healthy

smoke() {
    local path="$1" result
    result="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code} %{time_total}' "${base_url}${path}")"
    printf '[remote-g7-perf] smoke %s %s\n' "${path}" "${result}"
    [[ "${result%% *}" == 200 ]]
}
if [[ "${run_smoke}" == 1 ]]; then
    [[ "${do_common}" != 1 ]] || smoke '/'
    [[ "${do_board}" != 1 ]] || smoke "/api/modules/sirsoft-board/boards/${board_slug}/posts?page=1&per_page=20"
    [[ "${do_ecommerce}" != 1 ]] || smoke '/api/modules/sirsoft-ecommerce/products?page=1&per_page=12'
fi
sleep 2
assert_runtime_healthy

cat > "${state_dir}/g7-performance-transaction.env.tmp" <<EOF
action=${action}
scope=${scope}
phase=smoke-passed
changed_at=$(date --iso-8601=seconds)
EOF
install -o "${app_user}" -g www-data -m 664 \
    "${state_dir}/g7-performance-transaction.env.tmp" \
    "${state_dir}/g7-performance-transaction.env"
rm -f "${state_dir}/g7-performance-transaction.env.tmp"
trap - ERR
REMOTE
}

complete_transition() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${LOCK_TOKEN}" \
        "${ACTION}" "${SCOPE}" <<'REMOTE'
set -euo pipefail
app_root="$1"; app_user="$2"; token="$3"; action="$4"; scope="$5"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
state_dir="${app_root}/storage/app/benchmark"
units_file="${state_dir}/g7-performance-stopped-units"
[[ ! -f "${app_root}/storage/framework/down" ]]
[[ "$(systemctl is-active php8.5-fpm)" == active ]]
if [[ -f "${units_file}" ]]; then
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        [[ "$(systemctl is-active "${unit}")" == active ]] || {
            printf 'captured runtime unit is not active at commit point: %s\n' "${unit}" >&2
            exit 1
        }
    done < "${units_file}"
fi
cat > "${state_dir}/g7-performance-transaction.env.tmp" <<EOF
action=${action}
scope=${scope}
phase=complete
changed_at=$(date --iso-8601=seconds)
EOF
install -o "${app_user}" -g www-data -m 664 \
    "${state_dir}/g7-performance-transaction.env.tmp" \
    "${state_dir}/g7-performance-transaction.env"
rm -f "${state_dir}/g7-performance-transaction.env.tmp"
REMOTE
}

remove_transition_snapshot() {
    "${SSH_BIN}" "${REMOTE_HOST}" sudo bash -s -- \
        "${REMOTE_ROOT}" "${LOCK_TOKEN}" <<'REMOTE'
set -euo pipefail
app_root="$1"; token="$2"
lock_dir=/var/lock/g7-performance-toggle.lock.d
[[ "$(<"${lock_dir}/owner")" == "${token}" ]]
state_dir="${app_root}/storage/app/benchmark"
rm -f "${state_dir}/g7-performance-stopped-units" \
    "${state_dir}/g7-performance-runtime-before.env" \
    "${state_dir}/g7-performance-quiesced.env" \
    "${state_dir}/g7-performance-maintenance-entered"
REMOTE
}

extract_status() {
    local file="$1" key="$2"
    awk -F= -v wanted="${key}" '$1 == wanted { value=substr($0, index($0, "=") + 1) } END { print value }' "${file}"
}

component_state() {
    local component="$1" file="$2" source integrity runtime schema shared_config
    local module_sync module_version_sync template_sync module php
    local benchmark_sync benchmark_version_sync
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
            else
                benchmark_sync="$(extract_status "${file}" active_benchmark_sync)"
                benchmark_version_sync="$(extract_status "${file}" benchmark_module_version_sync)"
                [[ -z "${benchmark_sync}" \
                    || "${benchmark_sync}" == verified \
                    || "${benchmark_sync}" == not-installed ]] \
                    || { printf 'drift'; return; }
                [[ -z "${benchmark_version_sync}" \
                    || "${benchmark_version_sync}" == verified \
                    || "${benchmark_version_sync}" == not-installed ]] \
                    || { printf 'drift'; return; }
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
    local -a keys=(source source_integrity runtime schema shared_config active_module_sync active_template_sync module_version_sync module active_benchmark_sync benchmark_module_version_sync benchmark_module php_fpm)
    for key in "${keys[@]}"; do
        value="$(extract_status "${file}" "${key}")"
        [[ -z "${value}" ]] || printf '%s.%s=%s\n' "${component}" "${key}" "${value}"
    done
    printf '%s.state=%s\n' "${component}" "$(component_state "${component}" "${file}")"
}

show_unified_status() {
    local strict="$1" expected="${2:-}" overall=unknown state component file
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
    if [[ "${strict}" == 1 \
        && ( "${overall}" == mixed || "${overall}" == drift \
            || ( -n "${expected}" && "${overall}" != "${expected}" ) ) ]]; then
        return 2
    fi
}

acquire_remote_lock

if [[ "${ACTION}" == status ]]; then
    show_unified_status "${STRICT}" ''
    FINALIZED=1
    exit 0
fi

if [[ "${DO_COMMON}" == 1 && ( "${ACTION}" == on || "${ACTION}" == off || "${ACTION}" == restore-original ) ]]; then
    common_variant=optimized
    [[ "${ACTION}" != restore-original ]] || common_variant=baseline
    upload_common_archive "${common_variant}"
fi

log 'preparing and verifying the exact source archives before maintenance'
prepare_component_archives
verify_remote_archives
preflight_transition_snapshot

MUTATION_STARTED=1
[[ "${RECOVER_FAIL_CLOSED}" == 0 ]] || PRESERVE_FAIL_CLOSED=1
log 'entering maintenance mode and stopping application runtimes'
quiesce_runtime

if [[ "${ACTION}" == restore-original ]]; then
    log 'selecting baseline runtime before source and schema restore'
    SOURCE_MUTATION_STARTED=1
    prepare_restore
fi

SOURCE_MUTATION_STARTED=1
[[ "${DO_COMMON}" != 1 ]] || run_common "${ACTION}"
[[ "${DO_BOARD}" != 1 ]] || run_board "${ACTION}"
[[ "${DO_ECOMMERCE}" != 1 ]] || run_ecommerce "${ACTION}"

if [[ "${ACTION}" == restore-original ]]; then
    remove_shared_config_for_full_restore
fi

log 'rebuilding production caches and starting the new runtime generation'
finalize_runtime
EXPECTED_STATE=optimized
[[ "${ACTION}" == on ]] || EXPECTED_STATE=baseline
show_unified_status 1 "${EXPECTED_STATE}"
log 'strict state verified; leaving maintenance mode'
release_maintenance_and_smoke "${RUN_SMOKE}"
show_unified_status 1 "${EXPECTED_STATE}"
complete_transition
FINALIZED=1
remove_transition_snapshot || log 'warning: completed transition snapshot cleanup failed'
log "${ACTION} complete for scope ${SCOPE}"
