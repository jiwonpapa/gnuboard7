#!/usr/bin/env bash

# shellcheck disable=SC2016,SC2154

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/benchmark/g7-operational-load.sh"
K6_SCRIPT="${REPO_ROOT}/modules/_bundled/sirsoft-benchmark/tests/k6/g7-operational-load.js"
REAL_JQ="$(command -v jq)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/g7-operational-test.XXXXXX")"
FAKE_BIN="${WORK_DIR}/bin"
mkdir -p "${FAKE_BIN}"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
    printf 'g7-operational-load test failed: %s\n' "$*" >&2
    exit 1
}

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
    *sirsoft-board/boards/freebd/posts/123)
        printf '%s\n' '{"success":true,"data":{"id":123,"title":"fixture post"}}'
        ;;
    *sirsoft-board/boards/freebd/posts*)
        printf '%s\n' '{"success":true,"data":{"data":[{"id":123,"status":"published","is_secret":false}],"pagination":{"current_page":1}}}'
        ;;
    *sirsoft-ecommerce/products/456)
        printf '%s\n' '{"success":true,"data":{"id":456,"name":"fixture product"}}'
        ;;
    *sirsoft-ecommerce/products*)
        printf '%s\n' '{"success":true,"data":{"data":[{"id":456}],"pagination":{"current_page":1}}}'
        ;;
    *) exit 22 ;;
esac
EOF

cat > "${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
action='commit'
for arg in "${args[@]}"; do
    case "${arg}" in sample|stop) action="${arg}"; break ;; esac
done
case "${action}" in
    commit)
        printf '%040d\n' 7
        ;;
    stop)
        exit 0
        ;;
    sample)
        printf 'sample,elapsed_seconds,timestamp,cpu_count,host_busy_pct,php_fpm_cpu_pct,php_fpm_rss_mib,mysql_cpu_pct,mysql_rss_mib,searchd_cpu_pct,searchd_rss_mib,load1,mem_available_mib,mem_total_mib,swap_used_mib,abort_reason\n'
        if [[ "${FAKE_SAMPLER_ABORT:-0}" == 1 ]]; then
            printf '1,1,2026-07-21T10:00:01+09:00,4,80,20,180,40,900,5,100,3.0,399,8192,0,\n'
            printf '2,2,2026-07-21T10:00:02+09:00,4,82,21,185,41,905,6,101,3.1,398,8192,0,\n'
            printf '3,3,2026-07-21T10:00:03+09:00,4,84,22,190,42,910,7,102,3.2,397,8192,0,mem_available_below_limit_consecutive\n'
            exit 86
        fi
        if [[ "${FAKE_LOW_SLO:-0}" == 1 ]]; then
            printf '1,1,2026-07-21T10:00:01+09:00,4,40,10,180,20,900,2,100,1.0,1500,8192,0,\n'
            sleep 1
            printf '2,2,2026-07-21T10:00:02+09:00,4,50,12,190,22,910,3,105,1.2,1400,8192,0,\n'
            exit 0
        fi
        printf '1,1,2026-07-21T10:00:01+09:00,4,40,10,180,20,900,2,100,1.0,4096,8192,0,\n'
        sleep 1
        printf '2,2,2026-07-21T10:00:02+09:00,4,50,12,190,22,910,3,105,1.2,4000,8192,0,\n'
        ;;
esac
EOF

cat > "${FAKE_BIN}/k6" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
summary=''
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --summary-export ]]; then shift; summary="$1"; fi
    shift
done
[[ -n "${summary}" ]]
case "${DURATION}" in
    *s) seconds="${DURATION%s}" ;;
    *m) seconds=$((${DURATION%m} * 60)) ;;
    *h) seconds=$((${DURATION%h} * 3600)) ;;
esac
planned=$((TARGET_RPS * seconds))
dropped="${FAKE_DROPPED:-0}"
count=$((planned - dropped))
cycles=$((count / 10)); remainder=$((count % 10))
shop_extra=$((remainder < 5 ? remainder : 5))
board_extra=$((remainder > 5 ? remainder - 5 : 0)); ((board_extra <= 3)) || board_extra=3
home_extra=0; ((remainder >= 9)) && home_extra=1 || true
shop=$((cycles * 5 + shop_extra)); board=$((cycles * 3 + board_extra))
home=$((cycles + home_extra)); write_like=${cycles}
semantic="${FAKE_SEMANTIC_RATE:-1}"
http_failure="${FAKE_HTTP_FAILURE_RATE:-0}"
sleep "${FAKE_K6_DELAY:-0.2}"
"${REAL_JQ_BIN}" -n \
    --argjson count "${count}" --argjson dropped "${dropped}" \
    --argjson shop "${shop}" --argjson board "${board}" --argjson home "${home}" \
    --argjson write_like "${write_like}" --argjson semantic "${semantic}" \
    --argjson http_failure "${http_failure}" '
    def trend: {avg:40,min:5,med:30,"p(90)":70,"p(95)":80,"p(99)":95,max:120};
    def rate($value): {value:$value,passes:(if $value == 1 then $count else 0 end),fails:(if $value == 1 then 0 else $count end)};
    def counter($value): {count:$value,rate:2};
    {metrics:{
      http_reqs:counter($count), iterations:counter($count), dropped_iterations:counter($dropped),
      http_req_failed:rate($http_failure),
      g7_operational_http_valid:rate((if $http_failure == 0 then 1 else 0 end)),
      g7_operational_valid:rate($semantic), g7_operational_duration:trend,
      g7_workload_shop_requests:counter($shop), g7_workload_shop_valid:rate($semantic), g7_workload_shop_duration:trend,
      g7_workload_board_requests:counter($board), g7_workload_board_valid:rate($semantic), g7_workload_board_duration:trend,
      g7_workload_home_requests:counter($home), g7_workload_home_valid:rate($semantic), g7_workload_home_duration:trend,
      g7_workload_write_like_requests:counter($write_like), g7_workload_write_like_valid:rate($semantic), g7_workload_write_like_duration:trend
    }}
' > "${summary}"
if [[ "${dropped}" != 0 || "${semantic}" != 1 || "${http_failure}" != 0 ]]; then exit 99; fi
EOF

chmod +x "${FAKE_BIN}/curl" "${FAKE_BIN}/ssh" "${FAKE_BIN}/k6"

run_harness() {
    local output="$1"
    shift
    G7_OP_CURL_BIN="${FAKE_BIN}/curl" \
    G7_OP_SSH_BIN="${FAKE_BIN}/ssh" \
    G7_OP_K6_BIN="${FAKE_BIN}/k6" \
    G7_OP_JQ_BIN="${REAL_JQ}" \
    REAL_JQ_BIN="${REAL_JQ}" \
        "${HARNESS}" --rate 2 --duration 30s --host fixture --base-url http://fixture \
        --output-dir "${output}" "$@"
}

[[ "$("${HARNESS}" --profile spike --plan | "${REAL_JQ}" -r '.board_requests_per_minute')" == 594 ]] \
    || fail 'spike plan must stay below the board throttle'
if "${HARNESS}" --rate 34 --duration 1m --plan >"${WORK_DIR}/unsafe.out" 2>"${WORK_DIR}/unsafe.err"; then
    fail '34 RPS plan must be refused by the board throttle preflight'
fi
grep -q '612 board requests/minute' "${WORK_DIR}/unsafe.err" \
    || fail 'unsafe plan did not explain the board throttle calculation'

normal="${WORK_DIR}/normal"
run_harness "${normal}"
"${REAL_JQ}" -e '
  .validation.passed == true
  and .metadata.read_only == true
  and .metadata.tuning_transition_performed == false
  and .schedule.actual_requests == 60
  and .schedule.iterations == 60
  and .schedule.dropped_iterations == 0
  and ([.workloads[].requests] == [30,18,6,6])
  and .resources.php_fpm_rss_max_mib == 190
  and .resources.mysql_rss_max_mib == 910
  and .resources.searchd_rss_max_mib == 105
  and .resources.mem_total_mib == 8192
  and .resources.mem_available_min_pct > 48
' "${normal}/summary.json" >/dev/null || fail 'normal fixture report is invalid'
[[ -s "${normal}/summary.csv" && -s "${normal}/report.md" && -s "${normal}/resources.csv" ]] \
    || fail 'normal fixture did not produce JSON/CSV/Markdown/resource artifacts'

dropped="${WORK_DIR}/dropped"
if FAKE_DROPPED=1 run_harness "${dropped}" >"${WORK_DIR}/dropped.out" 2>"${WORK_DIR}/dropped.err"; then
    fail 'dropped iteration fixture must fail'
fi
"${REAL_JQ}" -e '.validation.passed == false and (.validation.errors | index("dropped_iterations") != null)' \
    "${dropped}/summary.json" >/dev/null || fail 'drop failure was not preserved in JSON'

semantic="${WORK_DIR}/semantic"
if FAKE_SEMANTIC_RATE=0 run_harness "${semantic}" >"${WORK_DIR}/semantic.out" 2>"${WORK_DIR}/semantic.err"; then
    fail 'semantic failure fixture must fail'
fi
"${REAL_JQ}" -e '.validation.passed == false and (.validation.errors | index("semantic_validation") != null)' \
    "${semantic}/summary.json" >/dev/null || fail 'semantic failure was not preserved in JSON'

low_slo="${WORK_DIR}/low-slo"
if FAKE_LOW_SLO=1 run_harness "${low_slo}" >"${WORK_DIR}/low-slo.out" 2>"${WORK_DIR}/low-slo.err"; then
    fail 'memory below the 25% pass threshold must fail'
fi
"${REAL_JQ}" -e '.validation.passed == false and (.validation.errors | index("memory_available_below_25pct") != null)' \
    "${low_slo}/summary.json" >/dev/null || fail 'memory percentage failure was not preserved in JSON'

abort="${WORK_DIR}/abort"
if FAKE_SAMPLER_ABORT=1 FAKE_K6_DELAY=3 run_harness "${abort}" >"${WORK_DIR}/abort.out" 2>"${WORK_DIR}/abort.err"; then
    fail 'three consecutive low-memory samples must abort the load'
fi
grep -q 'mem_available_below_limit_consecutive' "${WORK_DIR}/abort.err" \
    || fail 'memory safety abort reason was not reported'

bash -n "${HARNESS}" "$0"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${HARNESS}" "$0"
fi
if command -v k6 >/dev/null 2>&1; then
    k6 inspect "${K6_SCRIPT}" >/dev/null
fi

printf 'g7-operational-load tests passed\n'
