#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${SCRIPT_DIR}/../octane-ab-harness.sh"
LOAD_SCRIPT="${SCRIPT_DIR}/../octane-load.js"
RELOAD_PROBE_SCRIPT="${SCRIPT_DIR}/../octane-reload-probe.php"

bash -n "${HARNESS}"
test -f "${LOAD_SCRIPT}"
php -l "${RELOAD_PROBE_SCRIPT}" >/dev/null

help_output="$(bash "${HARNESS}" help)"
grep -q '^  doctor' <<< "${help_output}"
grep -q '^  run' <<< "${help_output}"
grep -q '^  restore' <<< "${help_output}"
grep -q -- '--baseline-url URL' <<< "${help_output}"
grep -q -- '--request-host HOST' <<< "${help_output}"
grep -q -- '--no-performance-gate' <<< "${help_output}"
grep -q -- '--reload-probe' <<< "${help_output}"

if bash "${HARNESS}" run --probe invalid >/dev/null 2>&1; then
    printf 'invalid probe unexpectedly succeeded\n' >&2
    exit 1
fi

if bash "${HARNESS}" doctor --request-host 'bad/host' >/dev/null 2>&1; then
    printf 'invalid request host unexpectedly succeeded\n' >&2
    exit 1
fi

grep -q 'REQUEST_HOST' "${LOAD_SCRIPT}"
grep -q "http_reqs: \['count>0'\]" "${LOAD_SCRIPT}"
grep -q "http_req_failed: \['rate==0'\]" "${LOAD_SCRIPT}"
grep -q 'extension:update-autoload' "${HARNESS}"

printf 'octane A/B harness contract: PASS\n'
