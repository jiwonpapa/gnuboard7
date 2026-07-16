#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/benchmark/g7-ab-benchmark.sh"
K6_SCRIPT="${REPO_ROOT}/modules/_bundled/sirsoft-benchmark/tests/k6/g7-entry-routes.js"
REAL_JQ="$(command -v jq)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-ab-test.XXXXXX")"
FAKE_BIN="${WORK_DIR}/bin"
mkdir -p "${FAKE_BIN}"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
    printf 'g7-ab-benchmark test failed: %s\n' "$*" >&2
    exit 1
}

cat > "${FAKE_BIN}/toggle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-status}"
printf '%s\n' "$*" >> "${FAKE_TOGGLE_LOG}"
printf 'toggle %s %s\n' "${action}" "$*" >> "${FAKE_EVENT_LOG}"

token=''
recover=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent-lock-token) shift; token="${1:-}" ;;
        --recover-fail-closed) recover=1 ;;
    esac
    shift
done
[[ -n "${token}" && -f "${FAKE_REMOTE_LOCK_FILE}" ]]
[[ "$(<"${FAKE_REMOTE_LOCK_FILE}")" == "${token}" ]]

case "${action}" in
    off)
        printf 'baseline\n' > "${FAKE_STATE_FILE}"
        [[ "${FAKE_OFF_FAIL:-0}" != 1 ]] || exit 7
        ;;
    on)
        if [[ "${FAKE_ON_FAIL_WHILE_GUARD:-0}" == 1 \
            && -f "${FAKE_GUARD_STATE_FILE}" \
            && "$(<"${FAKE_GUARD_STATE_FILE}")" == active ]]; then
            exit 8
        fi
        if [[ "${FAKE_REQUIRE_RECOVER:-0}" == 1 && "${recover}" != 1 ]]; then
            exit 9
        fi
        printf 'optimized\n' > "${FAKE_STATE_FILE}"
        ;;
    status)
        state="$(<"${FAKE_STATE_FILE}")"
        printf 'common.state=%s\nboard.state=%s\necommerce.state=%s\noverall=%s\n' \
            "${state}" "${state}" "${state}" "${state}"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SSH_LOG}"

args=("$@")
action=''
action_index=-1
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
        ab-lock-acquire|ab-lock-assert|ab-lock-release|mysql-guard-install|mysql-guard-restore|mysql-idle-gate|xdebug-check|cpu-sample|cpu-stop)
            action="${args[i]}"
            action_index=${i}
            break
            ;;
    esac
done
printf 'ssh %s %s\n' "${action:-transport}" "$*" >> "${FAKE_EVENT_LOG}"

require_owner() {
    local token="$1"
    [[ -f "${FAKE_REMOTE_LOCK_FILE}" ]]
    [[ "$(<"${FAKE_REMOTE_LOCK_FILE}")" == "${token}" ]]
}

case "${action}" in
    '')
        exit 0
        ;;
    ab-lock-acquire)
        token="${args[action_index + 1]}"
        lock_dir="${args[action_index + 2]}"
        [[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d ]]
        [[ ! -e "${FAKE_REMOTE_LOCK_FILE}" ]] || exit 73
        printf '%s\n' "${token}" > "${FAKE_REMOTE_LOCK_FILE}"
        ;;
    ab-lock-assert)
        token="${args[action_index + 1]}"
        lock_dir="${args[action_index + 2]}"
        [[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d ]]
        require_owner "${token}"
        ;;
    ab-lock-release)
        token="${args[action_index + 1]}"
        lock_dir="${args[action_index + 2]}"
        [[ "${lock_dir}" == /var/lock/g7-performance-toggle.lock.d ]]
        require_owner "${token}"
        rm -f -- "${FAKE_REMOTE_LOCK_FILE}"
        ;;
    mysql-guard-install)
        token="${args[action_index + 4]}"
        require_owner "${token}"
        printf 'active\n' > "${FAKE_GUARD_STATE_FILE}"
        if [[ "${FAKE_GUARD_MALFORMED:-0}" == 1 ]]; then
            printf 'malformed\n'
        else
            printf 'max_execution_time\t0\n'
        fi
        ;;
    mysql-guard-restore)
        token="${args[action_index + 2]}"
        require_owner "${token}"
        printf 'inactive\n' > "${FAKE_GUARD_STATE_FILE}"
        ;;
    mysql-idle-gate)
        token="${args[action_index + 3]}"
        require_owner "${token}"
        ;;
    xdebug-check)
        token="${args[action_index + 3]}"
        require_owner "${token}"
        ;;
    cpu-sample)
        window="${args[action_index + 3]}"
        token="${args[action_index + 5]}"
        require_owner "${token}"
        printf 'sample,elapsed_seconds,timestamp,host_busy_pct,php_fpm_host_capacity_pct,mysql_host_capacity_pct\n'
        printf '1,1,2026-07-16T10:00:01+09:00,50.000,70.000,20.000\n'
        printf '2,%s,2026-07-16T10:01:20+09:00,60.000,80.000,30.000\n' "${window}"
        ;;
    cpu-stop)
        token="${args[action_index + 2]}"
        require_owner "${token}"
        ;;
esac
EOF

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"

if [[ "${url}" == */ ]]; then
    count=0
    [[ ! -f "${FAKE_ROOT_COUNT_FILE}" ]] || count="$(<"${FAKE_ROOT_COUNT_FILE}")"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${FAKE_ROOT_COUNT_FILE}"
    if [[ "${FAKE_ROOT_FAIL_CALL:-0}" -eq "${count}" \
        || ("${FAKE_ROOT_FAIL_FROM:-0}" -gt 0 && "${count}" -ge "${FAKE_ROOT_FAIL_FROM}") ]]; then
        exit 22
    fi
    exit 0
fi

case "${url}" in
    */sirsoft-board/boards/freebd/posts/123)
        printf '%s\n' '{"success":true,"data":{"id":123,"title":"benchmark 887161 post"}}'
        ;;
    *sirsoft-board/boards/freebd/posts*)
        page=1
        if [[ "${url}" == *'?page=2&'* || "${url}" == *'&page=2&'* ]]; then page=2; fi
        if [[ "${url}" == *'?page=59999&'* || "${url}" == *'&page=59999&'* ]]; then page=59999; fi
        printf '{"success":true,"data":{"data":[{"id":123,"title":"benchmark 887161 post","status":"published","is_secret":false}],"pagination":{"current_page":%s,"total":100}}}\n' "${page}"
        ;;
    */sirsoft-ecommerce/products/456)
        printf '%s\n' '{"success":true,"data":{"id":456,"name":"러닝화"}}'
        ;;
    */sirsoft-ecommerce/products/456/reviews*)
        printf '%s\n' '{"success":true,"data":{"reviews":{"data":[]}}}'
        ;;
    */sirsoft-ecommerce/products/456/inquiries*)
        printf '%s\n' '{"success":true,"data":{"items":[]}}'
        ;;
    */sirsoft-ecommerce/products/456/downloadable-coupons*)
        printf '%s\n' '{"success":true,"data":{"data":[]}}'
        ;;
    *sirsoft-ecommerce/products*)
        page=1
        if [[ "${url}" == *'?page=2&'* || "${url}" == *'&page=2&'* ]]; then page=2; fi
        printf '{"success":true,"data":{"data":[{"id":456,"name":"러닝화"}],"pagination":{"current_page":%s,"total":100}}}\n' "${page}"
        ;;
    *)
        printf '%s\n' '{"success":true,"data":[]}'
        ;;
esac
EOF

cat > "${FAKE_BIN}/k6" <<EOF
#!/usr/bin/env bash
set -euo pipefail
summary=''
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == --summary-export ]]; then
        shift
        summary="\$1"
    fi
    shift
done
[[ -n "\${summary}" ]]
if [[ "\${FAKE_K6_SKIP_BASELINE:-0}" == 1 && "\${summary}" == *baseline-1* ]]; then
    exit 2
fi
case "\${summary}" in
    *baseline*) duration=100 ;;
    *) duration=50 ;;
esac
dropped="\${FAKE_K6_DROPPED:-0}"
hot_duration="\${HOT_DURATION%s}"
iterations=\$((HOT_ARRIVAL_RATE * hot_duration + 1 - dropped))
invalid="\${FAKE_K6_INVALID_ROUTE:-}"
"${REAL_JQ}" -n \
    --argjson duration "\${duration}" \
    --argjson dropped "\${dropped}" \
    --argjson iterations "\${iterations}" \
    --arg invalid "\${invalid}" '
    [
      "home", "home_stats", "home_recent", "home_popular_boards", "home_boards",
      "board_list_p1", "board_list_p2", "board_deep", "board_detail", "board_navigation",
      "board_search", "global_search", "shop_home_categories", "shop_list_p1", "shop_list_p2",
      "shop_home_recent", "shop_home_popular", "shop_home_new", "shop_detail",
      "shop_detail_reviews", "shop_detail_inquiries", "shop_detail_coupons",
      "shop_search_p1", "shop_search_p2"
    ] as \$keys
    | reduce \$keys[] as \$key (
        {metrics: {
          http_req_failed: {values: {rate: 0}},
          http_reqs: {values: {count: 126, rate: 25.2}},
          iterations: {values: {count: \$iterations}},
          dropped_iterations: {values: {count: \$dropped, rate: 0}}
        }};
        .metrics["g7_route_" + \$key + "_duration"] = {
          values: {avg: \$duration, med: \$duration, "p(95)": \$duration, "p(99)": \$duration, max: \$duration}
        }
        | .metrics["g7_route_" + \$key + "_valid"] = {
          values: (if \$key == \$invalid
            then {rate: 0, passes: 0, fails: 1}
            else {rate: 1, passes: 6, fails: 0}
          end)
        }
      )
' > "\${summary}"
if [[ "\${FAKE_K6_FORCE_ZERO:-0}" != 1 && ("\${dropped}" != 0 || -n "\${invalid}") ]]; then
    exit 99
fi
EOF

chmod +x "${FAKE_BIN}/toggle" "${FAKE_BIN}/ssh" "${FAKE_BIN}/curl" "${FAKE_BIN}/k6"

run_harness() {
    local output_dir="$1" state_file="$2" toggle_log="$3" ssh_log="$4"
    local guard_state="${state_file}.guard" lock_file="${state_file}.remote-lock"
    local event_log="${state_file}.events" root_count="${state_file}.root-count"
    shift 4
    printf 'optimized\n' > "${state_file}"
    printf 'inactive\n' > "${guard_state}"
    : > "${toggle_log}"
    : > "${ssh_log}"
    : > "${event_log}"
    rm -f -- "${root_count}"
    FAKE_STATE_FILE="${state_file}" \
    FAKE_TOGGLE_LOG="${toggle_log}" \
    FAKE_SSH_LOG="${ssh_log}" \
    FAKE_EVENT_LOG="${event_log}" \
    FAKE_REMOTE_LOCK_FILE="${lock_file}" \
    FAKE_GUARD_STATE_FILE="${guard_state}" \
    FAKE_ROOT_COUNT_FILE="${root_count}" \
    G7_AB_TOGGLE_SCRIPT="${FAKE_BIN}/toggle" \
    G7_AB_SSH_BIN="${FAKE_BIN}/ssh" \
    G7_AB_CURL_BIN="${FAKE_BIN}/curl" \
    G7_AB_K6_BIN="${FAKE_BIN}/k6" \
    G7_AB_OUTPUT_DIR="${output_dir}" \
        "${HARNESS}" \
        --repeats 1 \
        --hot-vus 1 \
        --hot-rate 1 \
        --hot-duration 5 \
        --measurement-window 80 \
        --idle-timeout 15 \
        --cpu-max-seconds 80 \
        "$@"
}

assert_released() {
    local state_file="$1"
    [[ ! -e "${state_file}.remote-lock" ]] || fail "remote lock was not released: ${state_file}"
    [[ "$(<"${state_file}.guard")" == inactive ]] || fail "MySQL guard remained active: ${state_file}"
}

SUCCESS_DIR="${WORK_DIR}/success"
SUCCESS_STATE="${WORK_DIR}/success-state"
SUCCESS_TOGGLE_LOG="${WORK_DIR}/success-toggle.log"
SUCCESS_SSH_LOG="${WORK_DIR}/success-ssh.log"
run_harness "${SUCCESS_DIR}" "${SUCCESS_STATE}" "${SUCCESS_TOGGLE_LOG}" "${SUCCESS_SSH_LOG}" >/dev/null 2>&1

[[ "$(<"${SUCCESS_STATE}")" == optimized ]] || fail 'successful run did not finish optimized'
assert_released "${SUCCESS_STATE}"
[[ -s "${SUCCESS_DIR}/comparison.md" ]] || fail 'Markdown report missing'
[[ -s "${SUCCESS_DIR}/comparison.csv" ]] || fail 'CSV report missing'
[[ -s "${SUCCESS_DIR}/cpu-comparison.csv" ]] || fail 'CPU CSV report missing'
"${REAL_JQ}" -e '
    .metadata.complete == true
    and .metadata.final_state == "optimized"
    and .metadata.hot_arrival_rate_per_second == 1
    and .metadata.cpu_measurement_window_seconds == 80
    and .metadata.process_cpu_basis == "percentage of total host CPU capacity"
    and (.routes | length == 24)
    and ([.routes[].baseline.valid, .routes[].optimized.valid] | all)
    and ([.routes[].p95_change_pct] | all(. == -50))
    and ([.cpu[].schedule_valid] | all)
    and ([.cpu[].samples_min] | all(. == 2))
    and ([.cpu[].actual_elapsed_seconds_min] | all(. == 80))
    and (.cpu[0].host_busy_avg_pct == 55)
    and (.cpu[0].php_fpm_cpu_avg_pct == 75)
' "${SUCCESS_DIR}/comparison.json" >/dev/null || fail 'comparison JSON is invalid'
grep -q '^off .*--parent-lock-token g7-ab-' "${SUCCESS_TOGGLE_LOG}" || fail 'OFF did not borrow the A/B lock token'
grep -q '^on .*--parent-lock-token g7-ab-' "${SUCCESS_TOGGLE_LOG}" || fail 'ON did not borrow the A/B lock token'
grep -q -- '--board-slug freebd' "${SUCCESS_TOGGLE_LOG}" || fail 'A/B board slug was not passed to toggle smoke'
grep -q 'ab-lock-acquire.*g7-performance-toggle.lock.d' "${SUCCESS_SSH_LOG}" || fail 'global lock was not acquired'
grep -q 'ab-lock-release.*g7-performance-toggle.lock.d' "${SUCCESS_SSH_LOG}" || fail 'global lock was not owner-released'
grep -q 'mysql-guard-restore' "${SUCCESS_SSH_LOG}" || fail 'MySQL timeout was not restored'

FAILURE_DIR="${WORK_DIR}/failure"
FAILURE_STATE="${WORK_DIR}/failure-state"
FAILURE_TOGGLE_LOG="${WORK_DIR}/failure-toggle.log"
FAILURE_SSH_LOG="${WORK_DIR}/failure-ssh.log"
set +e
FAKE_OFF_FAIL=1 run_harness \
    "${FAILURE_DIR}" "${FAILURE_STATE}" "${FAILURE_TOGGLE_LOG}" "${FAILURE_SSH_LOG}" \
    >/dev/null 2>&1
failure_exit=$?
set -e
[[ "${failure_exit}" != 0 ]] || fail 'injected OFF failure unexpectedly succeeded'
[[ "$(<"${FAILURE_STATE}")" == optimized ]] || fail 'failure cleanup did not restore optimized state'
assert_released "${FAILURE_STATE}"
[[ "$(grep -c '^on ' "${FAILURE_TOGGLE_LOG}")" -ge 1 ]] || fail 'failure cleanup did not retry ON'

PREFLIGHT_DIR="${WORK_DIR}/preflight"
PREFLIGHT_STATE="${WORK_DIR}/preflight-state"
PREFLIGHT_TOGGLE_LOG="${WORK_DIR}/preflight-toggle.log"
PREFLIGHT_SSH_LOG="${WORK_DIR}/preflight-ssh.log"
set +e
FAKE_GUARD_MALFORMED=1 run_harness \
    "${PREFLIGHT_DIR}" "${PREFLIGHT_STATE}" "${PREFLIGHT_TOGGLE_LOG}" "${PREFLIGHT_SSH_LOG}" \
    >/dev/null 2>&1
preflight_exit=$?
set -e
[[ "${preflight_exit}" != 0 ]] || fail 'malformed guard response unexpectedly succeeded'
[[ "$(<"${PREFLIGHT_STATE}")" == optimized ]] || fail 'pre-mutation failure changed state'
assert_released "${PREFLIGHT_STATE}"
! grep -Eq '^(on|off) ' "${PREFLIGHT_TOGGLE_LOG}" || fail 'pre-mutation failure invoked a tuning mutation'
grep -q 'mysql-guard-restore' "${PREFLIGHT_SSH_LOG}" || fail 'durable MySQL guard snapshot was not restored'

INCOMPLETE_DIR="${WORK_DIR}/incomplete"
INCOMPLETE_STATE="${WORK_DIR}/incomplete-state"
INCOMPLETE_TOGGLE_LOG="${WORK_DIR}/incomplete-toggle.log"
INCOMPLETE_SSH_LOG="${WORK_DIR}/incomplete-ssh.log"
set +e
FAKE_K6_SKIP_BASELINE=1 run_harness \
    "${INCOMPLETE_DIR}" "${INCOMPLETE_STATE}" "${INCOMPLETE_TOGGLE_LOG}" "${INCOMPLETE_SSH_LOG}" \
    >/dev/null 2>&1
incomplete_exit=$?
set -e
[[ "${incomplete_exit}" != 0 ]] || fail 'incomplete phase unexpectedly succeeded'
[[ "$(<"${INCOMPLETE_STATE}")" == optimized ]] || fail 'incomplete phase did not finish optimized'
assert_released "${INCOMPLETE_STATE}"
[[ ! -e "${INCOMPLETE_DIR}/comparison.json" ]] || fail 'incomplete phase produced a misleading comparison report'

STALE_DIR="${WORK_DIR}/stale"
STALE_STATE="${WORK_DIR}/stale-state"
STALE_TOGGLE_LOG="${WORK_DIR}/stale-toggle.log"
STALE_SSH_LOG="${WORK_DIR}/stale-ssh.log"
printf 'foreign-owner\n' > "${STALE_STATE}.remote-lock"
set +e
run_harness "${STALE_DIR}" "${STALE_STATE}" "${STALE_TOGGLE_LOG}" "${STALE_SSH_LOG}" >/dev/null 2>&1
stale_exit=$?
set -e
[[ "${stale_exit}" != 0 ]] || fail 'foreign global lock owner was ignored'
[[ "$(<"${STALE_STATE}.remote-lock")" == foreign-owner ]] || fail 'foreign lock was removed by a non-owner'
! grep -q 'mysql-guard-install' "${STALE_SSH_LOG}" || fail 'guard was installed without global-lock ownership'
! grep -Eq '^(on|off) ' "${STALE_TOGGLE_LOG}" || fail 'tuning mutated without global-lock ownership'

CAP_DIR="${WORK_DIR}/cap-retry"
CAP_STATE="${WORK_DIR}/cap-retry-state"
CAP_TOGGLE_LOG="${WORK_DIR}/cap-retry-toggle.log"
CAP_SSH_LOG="${WORK_DIR}/cap-retry-ssh.log"
set +e
FAKE_ON_FAIL_WHILE_GUARD=1 run_harness \
    "${CAP_DIR}" "${CAP_STATE}" "${CAP_TOGGLE_LOG}" "${CAP_SSH_LOG}" \
    >/dev/null 2>&1
cap_exit=$?
set -e
[[ "${cap_exit}" != 0 ]] || fail 'cap-blocked main transition unexpectedly completed the benchmark'
[[ "$(<"${CAP_STATE}")" == optimized ]] || fail 'ON was not retried after cap restoration'
assert_released "${CAP_STATE}"
restore_line="$(grep -n 'ssh mysql-guard-restore' "${CAP_STATE}.events" | tail -1 | cut -d: -f1)"
last_on_line="$(grep -n 'toggle on ' "${CAP_STATE}.events" | tail -1 | cut -d: -f1)"
[[ "${restore_line}" -lt "${last_on_line}" ]] || fail 'final ON retry did not occur after cap restoration'

DROPPED_DIR="${WORK_DIR}/dropped"
DROPPED_STATE="${WORK_DIR}/dropped-state"
DROPPED_TOGGLE_LOG="${WORK_DIR}/dropped-toggle.log"
DROPPED_SSH_LOG="${WORK_DIR}/dropped-ssh.log"
set +e
FAKE_K6_DROPPED=1 run_harness \
    "${DROPPED_DIR}" "${DROPPED_STATE}" "${DROPPED_TOGGLE_LOG}" "${DROPPED_SSH_LOG}" \
    >/dev/null 2>&1
dropped_exit=$?
set -e
[[ "${dropped_exit}" != 0 ]] || fail 'dropped fixed-arrival iterations were accepted'
assert_released "${DROPPED_STATE}"
"${REAL_JQ}" -e '
    ([.cpu[].schedule_valid] | all(. == false))
    and ([.routes[].baseline.p95_ms, .routes[].optimized.p95_ms, .routes[].p95_change_pct] | all(. == null))
' "${DROPPED_DIR}/comparison.json" >/dev/null || fail 'dropped iterations were interpreted as valid timings'

INVALID_DIR="${WORK_DIR}/invalid"
INVALID_STATE="${WORK_DIR}/invalid-state"
INVALID_TOGGLE_LOG="${WORK_DIR}/invalid-toggle.log"
INVALID_SSH_LOG="${WORK_DIR}/invalid-ssh.log"
set +e
FAKE_K6_INVALID_ROUTE=board_list_p2 FAKE_K6_FORCE_ZERO=1 run_harness \
    "${INVALID_DIR}" "${INVALID_STATE}" "${INVALID_TOGGLE_LOG}" "${INVALID_SSH_LOG}" \
    >/dev/null 2>&1
invalid_exit=$?
set -e
[[ "${invalid_exit}" != 0 ]] || fail 'semantic route failure was accepted'
assert_released "${INVALID_STATE}"
"${REAL_JQ}" -e '
    .routes[] | select(.key == "board_list_p2")
    | .baseline.valid == false
      and .optimized.valid == false
      and .baseline.p95_ms == null
      and .optimized.p95_ms == null
      and .p95_change_pct == null
' "${INVALID_DIR}/comparison.json" >/dev/null || fail 'invalid semantic durations were reported as timings'

LIVE_RETRY_DIR="${WORK_DIR}/live-retry"
LIVE_RETRY_STATE="${WORK_DIR}/live-retry-state"
LIVE_RETRY_TOGGLE_LOG="${WORK_DIR}/live-retry-toggle.log"
LIVE_RETRY_SSH_LOG="${WORK_DIR}/live-retry-ssh.log"
FAKE_ROOT_FAIL_CALL=2 run_harness \
    "${LIVE_RETRY_DIR}" "${LIVE_RETRY_STATE}" "${LIVE_RETRY_TOGGLE_LOG}" "${LIVE_RETRY_SSH_LOG}" \
    >/dev/null 2>&1
assert_released "${LIVE_RETRY_STATE}"
[[ "$(grep -c '^on ' "${LIVE_RETRY_TOGGLE_LOG}")" -ge 2 ]] \
    || fail 'final live health failure did not trigger an ON retry'

LIVE_FATAL_DIR="${WORK_DIR}/live-fatal"
LIVE_FATAL_STATE="${WORK_DIR}/live-fatal-state"
LIVE_FATAL_TOGGLE_LOG="${WORK_DIR}/live-fatal-toggle.log"
LIVE_FATAL_SSH_LOG="${WORK_DIR}/live-fatal-ssh.log"
set +e
FAKE_ROOT_FAIL_FROM=2 run_harness \
    "${LIVE_FATAL_DIR}" "${LIVE_FATAL_STATE}" "${LIVE_FATAL_TOGGLE_LOG}" "${LIVE_FATAL_SSH_LOG}" \
    >/dev/null 2>&1
live_fatal_exit=$?
set -e
[[ "${live_fatal_exit}" != 0 ]] || fail 'permanent final live health failure was accepted'
assert_released "${LIVE_FATAL_STATE}"
grep -q -- '--recover-fail-closed' "${LIVE_FATAL_TOGGLE_LOG}" \
    || fail 'final live health failure did not attempt fail-closed recovery'
[[ ! -e "${LIVE_FATAL_DIR}/comparison.json" ]] \
    || fail 'fatal final health failure left a misleading comparison report'

if command -v k6 >/dev/null 2>&1; then
    threshold_count="$(k6 inspect "${K6_SCRIPT}" | "${REAL_JQ}" '.thresholds | length')"
    [[ "${threshold_count}" == 26 ]] || fail "unexpected k6 threshold count: ${threshold_count}"
fi
grep -Fq 'payload?.data?.reviews?.data' "${K6_SCRIPT}" \
    || fail 'review semantic validator does not follow the public API shape'
grep -Fq 'payload?.data?.items' "${K6_SCRIPT}" \
    || fail 'inquiry semantic validator does not follow the public API shape'

printf 'g7-ab-benchmark tests: PASS\n'
