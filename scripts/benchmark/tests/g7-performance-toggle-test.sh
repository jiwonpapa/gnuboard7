#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd -- "${SCRIPT_DIR}/.." && pwd)/g7-performance-toggle.sh"
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
EOF

cat > "${FAKE_BIN}/board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'board %s\n' "$*" >> "${FAKE_CALL_LOG}"
[[ "${1:-}" == status ]] || exit 0
cat <<STATUS
source=optimized-capable
source_integrity=${FAKE_BOARD_INTEGRITY:-verified}
runtime=${FAKE_BOARD_RUNTIME:-optimized}
schema=${FAKE_BOARD_SCHEMA:-optimized}
active_module_sync=verified
module_version_sync=${FAKE_BOARD_VERSION_SYNC:-verified}
module=sirsoft-board 1.1.1 active
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
module=sirsoft-ecommerce 1.0.3 active
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

output="$(run_harness status --strict)"
assert_contains "${output}" 'common.state=optimized'
assert_contains "${output}" 'board.state=optimized'
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

: > "${CALL_LOG}"
output="$(run_harness on --scope board --no-smoke)"
assert_contains "${output}" 'overall=optimized'
calls="$(<"${CALL_LOG}")"
assert_contains "${calls}" 'board on'
assert_contains "${calls}" '--defer-runtime'
assert_contains "${calls}" '--lock-token'
assert_contains "${calls}" '--optimized-ref HEAD'
[[ "${calls}" != *'ecommerce on'* ]] || { printf 'board scope called ecommerce transition\n' >&2; exit 1; }

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

printf 'g7-performance-toggle tests: PASS\n'
