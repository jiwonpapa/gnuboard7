#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
FILTER_FILE="${SCRIPT_DIR}/staging.rsync-filter"

REMOTE_HOST="${G7_REMOTE_HOST:-gnuboard7}"
REMOTE_ROOT="${G7_REMOTE_ROOT:-public_html}"
REMOTE_PHP_BIN="${G7_REMOTE_PHP_BIN:-php}"
REMOTE_COMPOSER_BIN="${G7_REMOTE_COMPOSER_BIN:-composer}"
DEPLOY_MODULES="${G7_DEPLOY_MODULES:-sirsoft-benchmark}"

DRY_RUN=0
USE_DELETE=1
SKIP_COMPOSER=0
SKIP_MODULE_SYNC=0
SKIP_REMOTE_HOOKS=0
SKIP_QUEUE_RESTART=0
SKIP_LOCAL_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/deploy/staging.sh [options]

Options:
  --dry-run              Show rsync changes without applying them.
  --no-delete            Do not delete remote files missing from local sync set.
  --skip-composer        Skip remote composer install.
  --skip-module-sync     Skip module update/install/activate hooks.
  --skip-remote-hooks    Sync files only. Do not run any remote post-deploy commands.
  --skip-queue-restart   Skip php artisan queue:restart.
  --skip-local-build     Skip local php artisan module:build before rsync.
  --host HOST            Override SSH host alias. Default: gnuboard7
  --root PATH            Override remote app root. Default: public_html
  --php-bin BIN          Override remote PHP binary. Default: php
  --composer-bin BIN     Override remote Composer binary. Default: composer
  --modules CSV          Comma-separated module identifiers to sync post-deploy.
  -h, --help             Show this help.

Environment overrides:
  G7_REMOTE_HOST
  G7_REMOTE_ROOT
  G7_REMOTE_PHP_BIN
  G7_REMOTE_COMPOSER_BIN
  G7_DEPLOY_MODULES
EOF
}

log() {
    printf '[deploy] %s\n' "$*"
}

fail() {
    printf '[deploy] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --no-delete)
            USE_DELETE=0
            ;;
        --skip-composer)
            SKIP_COMPOSER=1
            ;;
        --skip-module-sync)
            SKIP_MODULE_SYNC=1
            ;;
        --skip-remote-hooks)
            SKIP_REMOTE_HOOKS=1
            ;;
        --skip-queue-restart)
            SKIP_QUEUE_RESTART=1
            ;;
        --skip-local-build)
            SKIP_LOCAL_BUILD=1
            ;;
        --host)
            shift
            REMOTE_HOST="${1:-}"
            ;;
        --root)
            shift
            REMOTE_ROOT="${1:-}"
            ;;
        --php-bin)
            shift
            REMOTE_PHP_BIN="${1:-}"
            ;;
        --composer-bin)
            shift
            REMOTE_COMPOSER_BIN="${1:-}"
            ;;
        --modules)
            shift
            DEPLOY_MODULES="${1:-}"
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

[[ -f "${REPO_ROOT}/artisan" ]] || fail "artisan not found under repository root"
[[ -f "${FILTER_FILE}" ]] || fail "rsync filter file not found: ${FILTER_FILE}"

require_command ssh
require_command rsync
require_command php

if [[ -n "${DEPLOY_MODULES}" ]]; then
    IFS=',' read -r -a module_list <<< "${DEPLOY_MODULES}"
    for raw_module in "${module_list[@]}"; do
        module="$(trim "${raw_module}")"
        [[ -z "${module}" ]] && continue
        [[ -d "${REPO_ROOT}/modules/_bundled/${module}" ]] || fail "bundled module not found: modules/_bundled/${module}"
    done
fi

if [[ ${SKIP_LOCAL_BUILD} -ne 1 && -n "${DEPLOY_MODULES}" ]]; then
    IFS=',' read -r -a module_list <<< "${DEPLOY_MODULES}"
    for raw_module in "${module_list[@]}"; do
        module="$(trim "${raw_module}")"
        [[ -z "${module}" ]] && continue

        if [[ -f "${REPO_ROOT}/modules/_bundled/${module}/package.json" ]]; then
            log "building local module assets for ${module}"
            (
                cd "${REPO_ROOT}"
                php artisan module:build "${module}" --production
            )
        fi
    done
fi

log "checking remote path ${REMOTE_HOST}:${REMOTE_ROOT}"
ssh "${REMOTE_HOST}" "cd '${REMOTE_ROOT}' >/dev/null 2>&1 && pwd >/dev/null" \
    || fail "remote root not reachable: ${REMOTE_HOST}:${REMOTE_ROOT}"

declare -a rsync_args
rsync_args=(
    -az
    --filter="merge ${FILTER_FILE}"
)

if [[ ${USE_DELETE} -eq 1 ]]; then
    rsync_args+=(--delete)
fi

if [[ ${DRY_RUN} -eq 1 ]]; then
    rsync_args+=(--dry-run --itemize-changes)
fi

log "syncing repository to ${REMOTE_HOST}:${REMOTE_ROOT}"
(
    cd "${REPO_ROOT}"
    rsync "${rsync_args[@]}" ./ "${REMOTE_HOST}:${REMOTE_ROOT}/"
)

if [[ ${DRY_RUN} -eq 1 ]]; then
    log "dry-run complete"
    exit 0
fi

if [[ ${SKIP_REMOTE_HOOKS} -eq 1 ]]; then
    log "file sync complete; remote hooks skipped"
    exit 0
fi

log "running remote post-deploy commands"
ssh "${REMOTE_HOST}" bash -s -- \
    "${REMOTE_ROOT}" \
    "${REMOTE_PHP_BIN}" \
    "${REMOTE_COMPOSER_BIN}" \
    "${DEPLOY_MODULES}" \
    "${SKIP_COMPOSER}" \
    "${SKIP_MODULE_SYNC}" \
    "${SKIP_QUEUE_RESTART}" <<'REMOTE'
set -euo pipefail

REMOTE_ROOT="$1"
REMOTE_PHP_BIN="$2"
REMOTE_COMPOSER_BIN="$3"
DEPLOY_MODULES="$4"
SKIP_COMPOSER="$5"
SKIP_MODULE_SYNC="$6"
SKIP_QUEUE_RESTART="$7"

umask 0002

log() {
    printf '[remote] %s\n' "$*"
}

ensure_queue_worker_running() {
    local worker_pattern worker_log systemd_unit

    worker_pattern="artisan queue:work database --queue=benchmark,default"
    worker_log="storage/logs/benchmark-queue.log"
    systemd_unit="gnuboard7-benchmark-queue.service"

    if systemctl --user list-unit-files "${systemd_unit}" >/dev/null 2>&1; then
        if systemctl --user is-active --quiet "${systemd_unit}"; then
            log "queue worker service already running"
            return
        fi

        log "starting queue worker via user systemd service"
        systemctl --user start "${systemd_unit}"
        return
    fi

    if pgrep -f "${worker_pattern}" >/dev/null 2>&1; then
        log "queue worker already running"
        return
    fi

    log "starting queue worker"
    nohup bash -lc "cd '${REMOTE_ROOT}' && exec '${REMOTE_PHP_BIN}' artisan queue:work database --queue=benchmark,default --sleep=1 --tries=1 --timeout=900 --backoff=3 >> '${worker_log}' 2>&1" >/dev/null 2>&1 &
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

ensure_shared_writable_log() {
    local log_file="$1"
    local temp_file

    if [[ ! -e "${log_file}" ]]; then
        install -m 664 /dev/null "${log_file}"
        return
    fi

    if [[ -w "${log_file}" ]]; then
        return
    fi

    temp_file="${log_file}.codex.$$"
    cp "${log_file}" "${temp_file}"
    chmod 664 "${temp_file}"
    mv "${temp_file}" "${log_file}"
}

ensure_shared_writable_dir() {
    local dir_path="$1"

    mkdir -p "${dir_path}"
    chmod 2775 "${dir_path}" 2>/dev/null || true
    chgrp www-data "${dir_path}" 2>/dev/null || true
}

ensure_shared_writable_cache_file() {
    local cache_file="$1"
    local temp_file

    if [[ ! -e "${cache_file}" ]]; then
        install -m 664 /dev/null "${cache_file}"
        chgrp www-data "${cache_file}" 2>/dev/null || true
        return
    fi

    temp_file="${cache_file}.codex.$$"
    cp "${cache_file}" "${temp_file}"
    chmod 664 "${temp_file}"
    chgrp www-data "${temp_file}" 2>/dev/null || true
    mv "${temp_file}" "${cache_file}"
}

cd "${REMOTE_ROOT}"

ensure_shared_writable_dir "bootstrap/cache"
ensure_shared_writable_dir "storage/logs"

today="$(date +%F)"
ensure_shared_writable_log "storage/logs/laravel-${today}.log"
ensure_shared_writable_log "storage/logs/query-${today}.log"
ensure_shared_writable_cache_file "bootstrap/cache/autoload-extensions.php"

if [[ "${SKIP_COMPOSER}" != "1" ]]; then
    log "composer install"
    "${REMOTE_COMPOSER_BIN}" install --no-dev --optimize-autoloader --no-interaction
fi

log "clearing optimized caches"
"${REMOTE_PHP_BIN}" artisan optimize:clear

log "refreshing extension autoload"
"${REMOTE_PHP_BIN}" artisan extension:update-autoload
ensure_shared_writable_cache_file "bootstrap/cache/autoload-extensions.php"

if [[ "${SKIP_MODULE_SYNC}" != "1" && -n "${DEPLOY_MODULES}" ]]; then
    IFS=',' read -r -a module_list <<< "${DEPLOY_MODULES}"
    for raw_module in "${module_list[@]}"; do
        module="$(trim "${raw_module}")"
        [[ -z "${module}" ]] && continue

        log "syncing module ${module}"
        if "${REMOTE_PHP_BIN}" artisan module:update "${module}" --force; then
            continue
        fi

        log "module ${module} not installed; running install/activate"
        "${REMOTE_PHP_BIN}" artisan module:install "${module}"
        "${REMOTE_PHP_BIN}" artisan module:activate "${module}"
    done
fi

log "rebuilding production caches"
"${REMOTE_PHP_BIN}" artisan config:cache
"${REMOTE_PHP_BIN}" artisan route:cache
"${REMOTE_PHP_BIN}" artisan view:cache
"${REMOTE_PHP_BIN}" artisan hooks:cache

if [[ "${SKIP_QUEUE_RESTART}" != "1" ]]; then
    log "restarting queue workers"
    "${REMOTE_PHP_BIN}" artisan queue:restart
    ensure_queue_worker_running
fi
REMOTE

log "deploy complete"
