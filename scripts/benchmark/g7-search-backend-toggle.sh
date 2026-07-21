#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-status}"
[[ $# -gt 0 ]] && shift

REMOTE_HOST="${G7_SEARCH_HOST:-g7-benchmark}"
REMOTE_ROOT="${G7_SEARCH_ROOT:-/var/www/gnuboard7}"
REMOTE_APP_USER="${G7_SEARCH_APP_USER:-www-data}"
REMOTE_PHP_BIN="${G7_SEARCH_PHP_BIN:-php}"
BASE_URL="${G7_SEARCH_BASE_URL:-https://g7-benchmark.test}"
SSH_BIN="${G7_SEARCH_SSH_BIN:-ssh}"

usage() {
    cat <<'EOF'
Usage: scripts/benchmark/g7-search-backend-toggle.sh ACTION [options]

Actions:
  mysql       Route integrated search back to built-in MySQL FULLTEXT.
  manticore   Verify Manticore and route integrated search to it.
  status      Show the selected backend and daemon/table health.

The mysql action changes only the G7 connection setting. It intentionally
leaves the Manticore package, service, configuration, and indexes installed.

Options:
  --host HOST       SSH host or IP. Default: g7-benchmark.
  --root PATH       Remote G7 root. Default: /var/www/gnuboard7.
  --app-user USER   Remote application user. Default: www-data.
  --php-bin BIN     Remote PHP binary. Default: php.
  --base-url URL    HTTP smoke URL. Default: https://g7-benchmark.test.
  -h, --help        Show this help.
EOF
}

fail() { printf '[g7-search] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) shift; REMOTE_HOST="${1:-}" ;;
        --root) shift; REMOTE_ROOT="${1:-}" ;;
        --app-user) shift; REMOTE_APP_USER="${1:-}" ;;
        --php-bin) shift; REMOTE_PHP_BIN="${1:-}" ;;
        --base-url) shift; BASE_URL="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

case "${ACTION}" in
    mysql|manticore|status) ;;
    -h|--help|help) usage; exit 0 ;;
    *) fail "unknown action: ${ACTION}" ;;
esac

SSH_OPTIONS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
)

"${SSH_BIN}" "${SSH_OPTIONS[@]}" "${REMOTE_HOST}" sudo bash -s -- \
    "${ACTION}" "${REMOTE_ROOT}" "${REMOTE_APP_USER}" "${REMOTE_PHP_BIN}" "${BASE_URL}" <<'REMOTE'
set -euo pipefail

action="$1"
app_root="$2"
app_user="$3"
php_bin="$4"
base_url="$5"
env_file="${app_root}/.env"

[[ -f "${app_root}/artisan" ]] || { echo 'invalid application root' >&2; exit 1; }
[[ -f "${env_file}" ]] || { echo 'missing .env' >&2; exit 1; }

read_driver() {
    awk -F= '$1 == "G7_INTEGRATED_SEARCH_DRIVER" { value=$2 } END { print value }' "${env_file}" \
        | tr -d '\r"' | xargs
}

set_driver() {
    local driver="$1" temp
    temp="$(mktemp "${app_root}/.env.g7-search.XXXXXX")"
    awk -v driver="${driver}" '
        BEGIN { replaced=0 }
        $0 ~ /^G7_INTEGRATED_SEARCH_DRIVER=/ {
            if (!replaced) print "G7_INTEGRATED_SEARCH_DRIVER=" driver
            replaced=1
            next
        }
        { print }
        END {
            if (!replaced) print "G7_INTEGRATED_SEARCH_DRIVER=" driver
        }
    ' "${env_file}" > "${temp}"
    chown --reference="${env_file}" "${temp}"
    chmod --reference="${env_file}" "${temp}"
    mv "${temp}" "${env_file}"
}

manticore_check() {
    systemctl is-active --quiet manticore
    mysql --connect-timeout=2 -h127.0.0.1 -P9306 -N -e \
        "SELECT COUNT(*) FROM g7_posts WHERE MATCH('운영') LIMIT 1" >/dev/null
    mysql --connect-timeout=2 -h127.0.0.1 -P9306 -N -e \
        "SELECT COUNT(*) FROM g7_products WHERE MATCH('노트북 파우치') LIMIT 1" >/dev/null
    mysql --connect-timeout=2 -h127.0.0.1 -P9306 -N -e \
        "SELECT COUNT(*) FROM g7_pages LIMIT 1" >/dev/null
}

if [[ "${action}" == status ]]; then
    driver="$(read_driver)"
    [[ -n "${driver}" ]] || driver=mysql
    service_state="$(systemctl is-active manticore 2>/dev/null || true)"
    printf 'driver=%s\n' "${driver}"
    printf 'manticore_service=%s\n' "${service_state:-missing}"
    if [[ "${service_state}" == active ]]; then
        for table in g7_posts g7_products g7_pages; do
            status="$(mysql --connect-timeout=2 -h127.0.0.1 -P9306 -N -e \
                "SHOW TABLE ${table} STATUS" \
                | awk '$1 == "indexed_documents" { docs=$2 } $1 == "ram_bytes" { ram=$2 } $1 == "disk_bytes" { disk=$2 } END { printf "docs=%s ram_bytes=%s disk_bytes=%s", docs, ram, disk }')"
            printf 'table=%s %s\n' "${table}" "${status}"
        done
    fi
    exit 0
fi

if [[ "${action}" == manticore ]]; then
    manticore_check
fi

set_driver "${action}"
sudo -u "${app_user}" bash -lc \
    "cd '${app_root}' && '${php_bin}' artisan config:clear >/dev/null && '${php_bin}' artisan config:cache >/dev/null"

actual="$(sudo -u "${app_user}" bash -lc \
    "cd '${app_root}' && '${php_bin}' artisan tinker --execute=\"echo config('scout.integrated.driver');\"" 2>/dev/null)"
actual="$(printf '%s' "${actual}" | tr -d '\r\n ')"
[[ "${actual}" == "${action}" ]] || {
    echo "Laravel config mismatch: expected=${action} actual=${actual}" >&2
    exit 1
}

if [[ "${action}" == manticore ]]; then
    health="$(sudo -u "${app_user}" bash -lc \
        "cd '${app_root}' && '${php_bin}' artisan tinker --execute=\"echo app(\\App\\Search\\ManticoreIntegratedSearch::class)->isHealthy() ? 'healthy' : 'unhealthy';\"" 2>/dev/null)"
    health="$(printf '%s' "${health}" | tr -d '\r\n ')"
    [[ "${health}" == healthy ]] || { echo 'Laravel Manticore health check failed' >&2; exit 1; }
fi

curl --fail --silent --show-error --insecure --max-time 15 "${base_url}/api/search?q=%EC%9A%B4%EC%98%81&type=all&per_page=5" >/dev/null
printf 'driver=%s\n' "${action}"
printf 'manticore_preserved=yes\n'
printf 'smoke=pass\n'
REMOTE
