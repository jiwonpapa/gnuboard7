#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd -- "${SCRIPT_DIR}/.." && pwd)/g7-performance-toggle.sh"
BOARD_HARNESS="$(cd -- "${SCRIPT_DIR}/.." && pwd)/board-performance-toggle.sh"
ECOMMERCE_HARNESS="$(cd -- "${SCRIPT_DIR}/.." && pwd)/ecommerce-performance-toggle.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/g7-performance-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

FAKE_BIN="${TMP_ROOT}/bin"
mkdir -p "${FAKE_BIN}"
CALL_LOG="${TMP_ROOT}/calls.log"
: > "${CALL_LOG}"

cat > "${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${FAKE_CALL_LOG}"
if [[ " $* " == *" bash -s -- status /srv/g7 "* ]]; then
    cat <<STATUS
source=optimized-capable
source_integrity=${FAKE_COMMON_INTEGRITY:-verified}
runtime=${FAKE_COMMON_RUNTIME:-optimized}
shared_config=present
php_fpm=active
STATUS
fi
EOF

cat > "${FAKE_BIN}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >> "${FAKE_CALL_LOG}"
if [[ -n "${FAKE_ARCHIVE_CAPTURE:-}" ]]; then
    positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o)
                [[ $# -ge 2 ]] || exit 2
                shift 2
                ;;
            -q)
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    positional+=("$1")
                    shift
                done
                ;;
            -*)
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done
    [[ ${#positional[@]} -ge 2 ]] || exit 2
    cp "${positional[0]}" "${FAKE_ARCHIVE_CAPTURE}"
fi
EOF

cat > "${FAKE_BIN}/board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'board %s\n' "$*" >> "${FAKE_CALL_LOG}"
[[ "${1:-}" == status ]] || exit 0
runtime="${FAKE_BOARD_RUNTIME:-optimized}"
search_schema="${FAKE_BOARD_SEARCH_SCHEMA:-}"
if [[ -z "${search_schema}" ]]; then
    search_schema=optimized
    [[ "${runtime}" == optimized ]] || search_schema=baseline-dormant
fi
cat <<STATUS
source=optimized-capable
source_ref=${FAKE_BOARD_SOURCE_REF:-0123456789abcdef0123456789abcdef01234567}
source_integrity=${FAKE_BOARD_INTEGRITY:-verified}
runtime=${runtime}
schema=${FAKE_BOARD_SCHEMA:-optimized}
search.source=${FAKE_BOARD_SEARCH_SOURCE:-optimized-capable}
search.source_ref=${FAKE_BOARD_SEARCH_SOURCE_REF:-0123456789abcdef0123456789abcdef01234567}
search.config=${FAKE_BOARD_SEARCH_CONFIG:-${runtime}}
search.algorithm=${FAKE_BOARD_SEARCH_ALGORITHM:-${runtime}}
search.schema=${search_schema}
search.sync_cap=${FAKE_BOARD_SEARCH_SYNC_CAP:-1000}
search.ft_result_cache_limit=${FAKE_BOARD_FT_RESULT_CACHE_LIMIT:-33554432}
search.safety_guard=${FAKE_BOARD_SAFETY_GUARD:-enabled}
search.safety_guard_persistence=${FAKE_BOARD_SAFETY_PERSISTENCE:-persisted}
active_module_sync=verified
module_version_sync=${FAKE_BOARD_VERSION_SYNC:-verified}
module=sirsoft-board 1.1.3 active
active_benchmark_sync=${FAKE_BENCHMARK_SYNC:-verified}
benchmark_module_version_sync=${FAKE_BENCHMARK_VERSION_SYNC:-verified}
benchmark_module=sirsoft-benchmark 0.2.6 active
shared_config=present
php_fpm=active
STATUS
EOF

cat > "${FAKE_BIN}/ecommerce" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ecommerce %s\n' "$*" >> "${FAKE_CALL_LOG}"
[[ "${1:-}" == status ]] || exit 0
cat <<STATUS
source=optimized-capable
source_integrity=${FAKE_ECOMMERCE_INTEGRITY:-verified}
runtime=${FAKE_ECOMMERCE_RUNTIME:-optimized}
schema=${FAKE_ECOMMERCE_SCHEMA:-optimized}
active_module_sync=verified
active_template_sync=verified
module_version_sync=${FAKE_ECOMMERCE_VERSION_SYNC:-verified}
module=sirsoft-ecommerce 1.0.4 active
shared_config=present
php_fpm=active
STATUS
EOF
chmod +x "${FAKE_BIN}/ssh" "${FAKE_BIN}/scp" "${FAKE_BIN}/board" "${FAKE_BIN}/ecommerce"

run_harness() {
    FAKE_CALL_LOG="${CALL_LOG}" \
    G7_PERF_DISABLE_REMOTE_LOCK=1 \
    G7_PERF_SSH_BIN="${FAKE_BIN}/ssh" \
    G7_PERF_SCP_BIN="${FAKE_BIN}/scp" \
    G7_PERF_BOARD_SCRIPT="${FAKE_BIN}/board" \
    G7_PERF_ECOMMERCE_SCRIPT="${FAKE_BIN}/ecommerce" \
    "${HARNESS}" "$@" --host fake --root /srv/g7 --app-user g7
}

assert_contains() {
    local haystack="$1" needle="$2"
    [[ "${haystack}" == *"${needle}"* ]] || {
        printf 'expected output to contain: %s\n%s\n' "${needle}" "${haystack}" >&2
        exit 1
    }
}

assert_equals() {
    local actual="$1" expected="$2"
    [[ "${actual}" == "${expected}" ]] || {
        printf 'expected %s, got %s\n' "${expected}" "${actual}" >&2
        exit 1
    }
}

assert_file_contains() {
    local file="$1" needle="$2"
    grep -Fq -- "${needle}" "${file}" || {
        printf 'expected %s to contain: %s\n' "${file}" "${needle}" >&2
        exit 1
    }
}

assert_file_not_contains() {
    local file="$1" needle="$2"
    if grep -Fq -- "${needle}" "${file}"; then
        printf 'expected %s not to contain: %s\n' "${file}" "${needle}" >&2
        exit 1
    fi
}

assert_text_order() {
    local haystack="$1" first="$2" second="$3" first_line second_line
    first_line="$(printf '%s\n' "${haystack}" | awk -v needle="${first}" 'index($0, needle) { print NR; exit }')"
    second_line="$(printf '%s\n' "${haystack}" | awk -v needle="${second}" 'index($0, needle) { print NR; exit }')"
    [[ -n "${first_line}" && -n "${second_line}" && ${first_line} -lt ${second_line} ]] || {
        printf 'expected ordered text: %s before %s\n%s\n' "${first}" "${second}" "${haystack}" >&2
        exit 1
    }
}

output="$(run_harness status --strict)"
assert_contains "${output}" 'common.state=optimized'
assert_contains "${output}" 'board.state=optimized'
assert_contains "${output}" 'board.source_ref=0123456789abcdef0123456789abcdef01234567'
assert_contains "${output}" 'board.search.config=optimized'
assert_contains "${output}" 'board.search.safety_guard=enabled'
assert_contains "${output}" 'board.search.schema=optimized'
assert_contains "${output}" 'ecommerce.state=optimized'
assert_contains "${output}" 'overall=optimized'

output="$(
    FAKE_COMMON_RUNTIME=baseline \
    FAKE_BOARD_RUNTIME=baseline \
    FAKE_BOARD_SCHEMA=baseline-invisible \
    FAKE_ECOMMERCE_RUNTIME=baseline \
    FAKE_ECOMMERCE_SCHEMA=baseline-invisible \
    run_harness status --strict
)"
assert_contains "${output}" 'common.state=baseline'
assert_contains "${output}" 'board.state=baseline'
assert_contains "${output}" 'board.search.config=baseline'
assert_contains "${output}" 'board.search.schema=baseline-dormant'
assert_contains "${output}" 'ecommerce.state=baseline'
assert_contains "${output}" 'overall=baseline'

set +e
output="$(FAKE_BOARD_SCHEMA=baseline-invisible run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'strict mixed status must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.state=mixed'
assert_contains "${output}" 'overall=mixed'

set +e
output="$(FAKE_BOARD_SEARCH_SCHEMA=baseline-dormant run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'search schema drift must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.search.schema=baseline-dormant'
assert_contains "${output}" 'board.state=drift'

set +e
output="$(FAKE_BOARD_SAFETY_GUARD=drifted run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'search safety guard drift must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.search.safety_guard=drifted'
assert_contains "${output}" 'board.state=drift'

set +e
output="$(FAKE_BOARD_SAFETY_PERSISTENCE=unsupported run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'non-persistent search guard must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.search.safety_guard_persistence=unsupported'
assert_contains "${output}" 'board.state=drift'

set +e
output="$(FAKE_ECOMMERCE_INTEGRITY=drifted run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'strict drift status must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'ecommerce.state=drift'
assert_contains "${output}" 'overall=drift'

set +e
output="$(FAKE_BOARD_VERSION_SYNC=drifted run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'module version drift must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.module_version_sync=drifted'
assert_contains "${output}" 'board.state=drift'

set +e
output="$(FAKE_BENCHMARK_VERSION_SYNC=drifted run_harness status --strict 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'benchmark version drift must exit 2, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'board.benchmark_module_version_sync=drifted'
assert_contains "${output}" 'board.state=drift'

: > "${CALL_LOG}"
output="$(run_harness on --scope board)"
assert_contains "${output}" 'overall=optimized'
calls="$(<"${CALL_LOG}")"
assert_contains "${calls}" 'ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
assert_contains "${calls}" 'scp -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
assert_contains "${calls}" 'board on'
assert_contains "${calls}" '--defer-runtime'
assert_contains "${calls}" '--no-smoke'
assert_contains "${calls}" '--lock-token'
assert_contains "${calls}" '--optimized-ref HEAD'
assert_contains "${calls}" '--ssh-connect-timeout 10'
assert_contains "${calls}" '--ssh-alive-interval 15'
assert_contains "${calls}" '--ssh-alive-count 3'
[[ "${calls}" != *'ecommerce on'* ]] || { printf 'board scope called ecommerce transition\n' >&2; exit 1; }

: > "${CALL_LOG}"
run_harness status --ssh-connect-timeout 7 --ssh-alive-interval 20 --ssh-alive-count 2 >/dev/null
calls="$(<"${CALL_LOG}")"
assert_contains "${calls}" 'ssh -o BatchMode=yes -o ConnectTimeout=7 -o ServerAliveInterval=20 -o ServerAliveCountMax=2'
assert_contains "${calls}" '--ssh-connect-timeout 7'
assert_contains "${calls}" '--ssh-alive-interval 20'
assert_contains "${calls}" '--ssh-alive-count 2'

: > "${CALL_LOG}"
G7_PERF_SSH_CONNECT_TIMEOUT_SECONDS=8 \
G7_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS=25 \
G7_PERF_SSH_SERVER_ALIVE_COUNT_MAX=4 \
FAKE_CALL_LOG="${CALL_LOG}" PATH="${FAKE_BIN}:${PATH}" \
    "${BOARD_HARNESS}" status --host fake >/dev/null
assert_file_contains "${CALL_LOG}" \
    'ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=25 -o ServerAliveCountMax=4'

: > "${CALL_LOG}"
G7_PERF_SSH_CONNECT_TIMEOUT_SECONDS=9 \
G7_PERF_SSH_SERVER_ALIVE_INTERVAL_SECONDS=30 \
G7_PERF_SSH_SERVER_ALIVE_COUNT_MAX=5 \
FAKE_CALL_LOG="${CALL_LOG}" PATH="${FAKE_BIN}:${PATH}" \
    "${ECOMMERCE_HARNESS}" status --host fake >/dev/null
assert_file_contains "${CALL_LOG}" \
    'ssh -o BatchMode=yes -o ConnectTimeout=9 -o ServerAliveInterval=30 -o ServerAliveCountMax=5'

set +e
output="$(
    FAKE_COMMON_RUNTIME=baseline \
    FAKE_BOARD_RUNTIME=baseline \
    FAKE_BOARD_SCHEMA=baseline-invisible \
    FAKE_ECOMMERCE_RUNTIME=baseline \
    FAKE_ECOMMERCE_SCHEMA=baseline-invisible \
    run_harness on --scope all 2>&1
)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'on must reject a consistent baseline result, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'overall=baseline'

set +e
output="$(run_harness off --scope all 2>&1)"
result=$?
set -e
[[ "${result}" == 2 ]] || { printf 'off must reject a consistent optimized result, got %s\n' "${result}" >&2; exit 1; }
assert_contains "${output}" 'overall=optimized'

set +e
output="$(run_harness on --scope board --recover-fail-closed 2>&1)"
result=$?
set -e
[[ "${result}" != 0 ]] || { printf 'partial fail-closed recovery must fail\n' >&2; exit 1; }
assert_contains "${output}" 'requires --scope all'

set +e
output="$(run_harness status --parent-lock-token invalid 2>&1)"
result=$?
set -e
[[ "${result}" != 0 ]] || { printf 'invalid parent lock token must fail\n' >&2; exit 1; }
assert_contains "${output}" 'invalid parent performance lock token'

set +e
output="$(run_harness restore-original --scope all 2>&1)"
result=$?
set -e
[[ "${result}" != 0 ]] || { printf 'restore-original without --yes must fail\n' >&2; exit 1; }
assert_contains "${output}" 'requires --yes'

set +e
output="$(run_harness status --scope invalid 2>&1)"
result=$?
set -e
[[ "${result}" != 0 ]] || { printf 'unknown scope must fail\n' >&2; exit 1; }
assert_contains "${output}" 'unknown scope'

board_runtime_block="$(awk '
    /^clear_runtime\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
' "${BOARD_HARNESS}")"
ecommerce_runtime_block="$(awk '
    /^clear_runtime\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
' "${ECOMMERCE_HARNESS}")"
board_restore_block="$(awk '
    /^    restore-original\)/ { capture = 1 }
    capture { print }
    capture && /^    status\)/ { exit }
' "${BOARD_HARNESS}")"
ecommerce_restore_block="$(awk '
    /^    restore-original\)/ { capture = 1 }
    capture { print }
    capture && /^    status\)/ { exit }
' "${ECOMMERCE_HARNESS}")"

assert_contains "${board_runtime_block}" 'artisan queue:restart'
assert_contains "${board_runtime_block}" 'artisan horizon:terminate'
assert_contains "${board_runtime_block}" 'artisan reverb:restart'
assert_contains "${board_runtime_block}" 'DEFER_RUNTIME'
assert_contains "${board_runtime_block}" "[[ \"\${DEFER_RUNTIME}\" == \"0\" ]] || return 0"
assert_text_order "${board_runtime_block}" 'capture_runtime_generation' 'artisan queue:restart'
assert_text_order "${board_runtime_block}" 'systemctl reload php8.5-fpm' 'wait_for_runtime_generation'
assert_contains "${ecommerce_runtime_block}" 'artisan queue:restart'
assert_contains "${ecommerce_runtime_block}" 'artisan horizon:terminate'
assert_contains "${ecommerce_runtime_block}" 'artisan reverb:restart'
assert_contains "${ecommerce_runtime_block}" 'DEFER_RUNTIME'
assert_contains "${ecommerce_runtime_block}" "[[ \"\${DEFER_RUNTIME}\" == \"0\" ]] || return 0"
assert_text_order "${ecommerce_runtime_block}" 'capture_runtime_generation' 'artisan queue:restart'
assert_text_order "${ecommerce_runtime_block}" 'systemctl reload php8.5-fpm' 'wait_for_runtime_generation'

assert_text_order "${board_restore_block}" 'apply_source_archive baseline' 'drop_indexes_and_migration'
assert_text_order "${ecommerce_restore_block}" 'apply_archive baseline' 'drop_indexes'

mutation_flow="$(sed -n '/^MUTATION_STARTED=1/,$p' "${HARNESS}")"
assert_text_order "${mutation_flow}" 'quiesce_runtime' 'SOURCE_MUTATION_STARTED=1'
assert_text_order "${mutation_flow}" 'SOURCE_MUTATION_STARTED=1' "run_board \"\${ACTION}\""
assert_text_order "${mutation_flow}" "run_ecommerce \"\${ACTION}\"" 'finalize_runtime'
assert_text_order "${mutation_flow}" 'finalize_runtime' 'show_unified_status 1'
assert_text_order "${mutation_flow}" 'show_unified_status 1' 'release_maintenance_and_smoke'
assert_text_order "${mutation_flow}" 'release_maintenance_and_smoke' 'FINALIZED=1'
post_release_flow="$(sed -n '/^release_maintenance_and_smoke /,$p' "${HARNESS}")"
assert_text_order "${post_release_flow}" 'release_maintenance_and_smoke' 'show_unified_status 1'
assert_text_order "${post_release_flow}" 'show_unified_status 1' 'complete_transition'
assert_text_order "${post_release_flow}" 'complete_transition' 'FINALIZED=1'
assert_text_order "${post_release_flow}" 'FINALIZED=1' 'remove_transition_snapshot'
pre_mutation_flow="$(sed -n '/^acquire_remote_lock$/,/^MUTATION_STARTED=1/p' "${HARNESS}")"
assert_text_order "${pre_mutation_flow}" 'prepare_component_archives' 'verify_remote_archives'
assert_text_order "${pre_mutation_flow}" 'verify_remote_archives' 'preflight_transition_snapshot'
assert_text_order "${pre_mutation_flow}" 'preflight_transition_snapshot' 'MUTATION_STARTED=1'
assert_file_contains "${HARNESS}" 'artisan down --retry=60'
assert_file_contains "${HARNESS}" 'runtime_artisan_pids'
assert_file_contains "${HARNESS}" 'systemctl stop --no-block php8.5-fpm'
# shellcheck disable=SC2016
assert_file_contains "${HARNESS}" 'SMOKE_BOARD_SLUG="${G7_PERF_BOARD_SLUG:-freebd}"'
# shellcheck disable=SC2016
assert_file_contains "${HARNESS}" '/boards/${board_slug}/posts?page=1&per_page=20'
assert_file_contains "${HARNESS}" "status IN ('running','stopping')"
assert_file_contains "${HARNESS}" 'cron.service'
assert_file_contains "${HARNESS}" 'phase=runtime-ready'
assert_file_contains "${HARNESS}" 'phase=complete'
assert_file_contains "${HARNESS}" 'g7-performance-runtime-before.env'
assert_file_contains "${HARNESS}" 'Restart=no'
assert_file_contains "${HARNESS}" 'TimeoutStopSec='
assert_file_contains "${HARNESS}" 'quiesce did not complete; preserving maintenance and stopped runtimes'
assert_file_contains "${HARNESS}" 'tac "'
assert_file_contains "${HARNESS}" 'phase=smoke-passed'
assert_file_contains "${BOARD_HARNESS}" '--prepare-archive PATH'
assert_file_contains "${BOARD_HARNESS}" '--remote-archive PATH'
assert_file_contains "${ECOMMERCE_HARNESS}" '--prepare-archive PATH'
assert_file_contains "${ECOMMERCE_HARNESS}" '--remote-archive PATH'

quiesce_block="$(sed -n '/^quiesce_runtime() {/,/^REMOTE$/p' "${HARNESS}")"
assert_text_order "${quiesce_block}" 'artisan queue:restart' 'systemctl stop --no-block'
assert_text_order "${quiesce_block}" 'artisan reverb:restart' 'systemctl stop --no-block'
# shellcheck disable=SC2016
assert_text_order "${quiesce_block}" 'snapshot_present=0' 'rm -f "${units_file}" "${before_file}" "${quiesced_file}" "${maintenance_marker}"'
assert_contains "${quiesce_block}" 'recoverable fail-closed snapshot disappeared before drain'
# shellcheck disable=SC2016
assert_contains "${quiesce_block}" 'grep -Fxq -- "${unit}" "${units_file}"'
# shellcheck disable=SC2016
assert_file_contains "${HARNESS}" 'show_unified_status 1 "${EXPECTED_STATE}"'
assert_file_contains "${HARNESS}" 'parent performance lock owner mismatch'
assert_file_contains "${HARNESS}" 'captured runtime unit is not active at commit point'
# shellcheck disable=SC2016
assert_file_contains "${HARNESS}" '[[ ! -f "${app_root}/storage/framework/down" ]]'

assert_file_contains "${BOARD_HARNESS}" "total_columns=\"\$(mysql_scalar"
assert_file_contains "${BOARD_HARNESS}" "\"\${total_columns}\" == \"2\""
assert_file_contains "${BOARD_HARNESS}" "ps -u \"\${APP_USER}\" -o pid=,args="
assert_file_contains "${BOARD_HARNESS}" "[[ \"\${pid}\" =~ ^[0-9]+\$"
assert_file_contains "${BOARD_HARNESS}" "[[ \"\${entry}\" =~ ^([0-9]+):([0-9]+)\$"
assert_file_contains "${BOARD_HARNESS}" "stat -c '%u'"
assert_file_contains "${BOARD_HARNESS}" "deadline=\$((SECONDS + 60))"
assert_file_contains "${BOARD_HARNESS}" 'baseline runtime activation timed out'
assert_file_contains "${BOARD_HARNESS}" 'G7_BOARD_PERF_BENCHMARK_BASELINE_REF'
assert_file_contains "${BOARD_HARNESS}" 'search.source_ref='
assert_file_contains "${BOARD_HARNESS}" 'search.config='
assert_file_contains "${BOARD_HARNESS}" 'search.schema='
assert_file_contains "${BOARD_HARNESS}" 'ft_board_posts_title_content'
assert_file_contains "${BOARD_HARNESS}" 'WITH PARSER.*ngram'
assert_file_contains "${BOARD_HARNESS}" 'idx_board_posts_board_author'
assert_file_contains "${BOARD_HARNESS}" "SEQ_IN_INDEX=1 AND COLUMN_NAME='user_id'"
# 하네스 배열 확장문 자체가 들어있는지 검사합니다.
# shellcheck disable=SC2016
assert_file_contains "${BOARD_HARNESS}" 'for path in "${BENCHMARK_PATHS[@]}"'
assert_file_contains "${BOARD_HARNESS}" '^modules/_bundled/sirsoft-(board|benchmark)/'
assert_file_contains "${BOARD_HARNESS}" 'GROUP_CONCAT(SEQ_IN_INDEX'
assert_file_contains "${BOARD_HARNESS}" "GROUP_CONCAT(COALESCE(COLLATION, 'NULL')"
assert_file_contains "${BOARD_HARNESS}" 'board benchmark indexes are not visible after activation'
assert_file_not_contains "${BOARD_HARNESS}" "WHERE p.DB='\${DB_NAME}'"
assert_file_contains "${ECOMMERCE_HARNESS}" 'information_schema.INNODB_TRX'
assert_file_contains "${ECOMMERCE_HARNESS}" 'SET SESSION lock_wait_timeout=15; SET SESSION innodb_lock_wait_timeout=15;'
assert_file_contains "${ECOMMERCE_HARNESS}" 'mysql_ddl "ALTER TABLE'
assert_file_contains "${ECOMMERCE_HARNESS}" "ps -u \"\${APP_USER}\" -o pid=,args="
assert_file_contains "${ECOMMERCE_HARNESS}" "[[ \"\${pid}\" =~ ^[0-9]+\$"
assert_file_contains "${ECOMMERCE_HARNESS}" "[[ \"\${entry}\" =~ ^([0-9]+):([0-9]+)\$"
assert_file_contains "${ECOMMERCE_HARNESS}" "stat -c '%u'"
assert_file_contains "${ECOMMERCE_HARNESS}" "deadline=\$((SECONDS + 60))"
assert_file_contains "${ECOMMERCE_HARNESS}" 'baseline runtime activation timed out'
assert_file_contains "${ECOMMERCE_HARNESS}" 'GROUP_CONCAT(SEQ_IN_INDEX'
assert_file_contains "${ECOMMERCE_HARNESS}" "GROUP_CONCAT(COALESCE(COLLATION, 'NULL')"
assert_file_contains "${ECOMMERCE_HARNESS}" 'ecommerce benchmark indexes are not visible after activation'
assert_file_not_contains "${ECOMMERCE_HARNESS}" "mysql \"\${DB_NAME}\" -e \"ALTER TABLE"
assert_file_not_contains "${ECOMMERCE_HARNESS}" "WHERE p.DB='\${DB_NAME}'"

board_index_shape_block="$(awk '
    /^index_shape\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
' "${BOARD_HARNESS}")"
# shellcheck disable=SC2329
mysql_scalar() { printf '%s' "${INDEX_METADATA}"; }
# shellcheck disable=SC2034
POSTS_TABLE=g7_board_posts
# shellcheck disable=SC2034
DB_NAME=g7_testing
# 고정된 하네스 함수 본문을 fixture metadata로 직접 실행합니다.
# shellcheck disable=SC2294
eval "${board_index_shape_block}"

INDEX_METADATA='5|1,2,3,4,5|board_id,is_notice,parent_id,deleted_at,id|A,A,A,A,A|1|1|BTREE|BTREE|0|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" verified
INDEX_METADATA='5|1,2,3,4,5|board_id,is_notice,parent_id,deleted_at,id|A,A,A,D,A|1|1|BTREE|BTREE|0|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" drifted
INDEX_METADATA='5|1,2,3,4,5|board_id,parent_id,is_notice,deleted_at,id|A,A,A,A,A|1|1|BTREE|BTREE|0|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" drifted
INDEX_METADATA='5|1,2,3,4,5|board_id,is_notice,parent_id,deleted_at,id|A,A,A,A,A|0|0|BTREE|BTREE|0|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" drifted
INDEX_METADATA='5|1,2,3,4,5|board_id,is_notice,parent_id,deleted_at,id|A,A,A,A,A|1|1|BTREE|BTREE|1|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" drifted
INDEX_METADATA='0||||||||0|0'
assert_equals "$(index_shape idx_board_posts_list_id 'board_id,is_notice,parent_id,deleted_at,id' 5)" missing
unset -f index_shape mysql_scalar

set +e
output="$(PATH="${FAKE_BIN}:${PATH}" FAKE_CALL_LOG="${CALL_LOG}" "${BOARD_HARNESS}" on --host fake 2>&1)"
result=$?
set -e
[[ "${result}" != 0 ]] || { printf 'direct board mutation must fail\n' >&2; exit 1; }
assert_contains "${output}" 'must run through scripts/benchmark/g7-performance-toggle.sh --scope board'

baseline_archive="${TMP_ROOT}/board-baseline.tar.gz"
FAKE_CALL_LOG="${CALL_LOG}" FAKE_ARCHIVE_CAPTURE="${baseline_archive}" PATH="${FAKE_BIN}:${PATH}" \
    "${BOARD_HARNESS}" restore-original --yes --no-smoke --host fake --lock-token fake >/dev/null
baseline_extract="${TMP_ROOT}/board-baseline"
mkdir -p "${baseline_extract}"
tar -xzf "${baseline_archive}" -C "${baseline_extract}"
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-benchmark/module.json'
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-board/src/Listeners/SearchPostsListener.php'
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'app/Http/Requests/Public/SearchRequest.php'
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'app/Search/Engines/DatabaseFulltextEngine.php'
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'routes/api.php'
assert_file_contains "${baseline_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-board/src/routes/api.php'
assert_file_not_contains "${baseline_extract}/.harness/source.sha256" 'SearchRequestThrottle.php'
[[ "$(<"${baseline_extract}/.harness/source-ref")" =~ ^[0-9a-f]{40}$ ]] \
    || fail 'baseline archive source ref is invalid'
assert_file_contains "${baseline_extract}/modules/_bundled/sirsoft-benchmark/module.json" '"version": "0.2.4"'
assert_file_not_contains "${baseline_extract}/modules/_bundled/sirsoft-benchmark/src/Services/Support/BoardCounterSyncService.php" 'syncAuthorTermsForBoard'

optimized_archive="${TMP_ROOT}/board-optimized.tar.gz"
optimized_ref="$(git -C "$(cd -- "${SCRIPT_DIR}/../../.." && pwd)" write-tree)"
FAKE_CALL_LOG="${CALL_LOG}" FAKE_ARCHIVE_CAPTURE="${optimized_archive}" PATH="${FAKE_BIN}:${PATH}" \
    "${BOARD_HARNESS}" on --no-smoke --host fake --lock-token fake \
    --optimized-ref "${optimized_ref}" >/dev/null
optimized_extract="${TMP_ROOT}/board-optimized"
mkdir -p "${optimized_extract}"
tar -xzf "${optimized_archive}" -C "${optimized_extract}"
assert_file_contains "${optimized_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-benchmark/src/Services/Support/BoardCounterSyncService.php'
[[ "$(<"${optimized_extract}/.harness/source-ref")" =~ ^[0-9a-f]{40}$ ]] \
    || fail 'optimized archive source ref is invalid'
assert_file_contains "${optimized_extract}/modules/_bundled/sirsoft-board/module.json" '"version": "1.1.3"'
assert_file_contains "${optimized_extract}/modules/_bundled/sirsoft-benchmark/module.json" '"version": "0.2.6"'
assert_file_contains "${optimized_extract}/modules/_bundled/sirsoft-board/src/Observers/PostAuthorTermObserver.php" 'class PostAuthorTermObserver'
assert_file_contains "${optimized_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-board/src/routes/api.php'
assert_file_contains "${optimized_extract}/.harness/source.sha256" 'modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php'
assert_file_contains "${optimized_extract}/modules/_bundled/sirsoft-board/src/Http/Middleware/SearchRequestThrottle.php" 'class SearchRequestThrottle'

printf 'g7-performance-toggle tests: PASS\n'
