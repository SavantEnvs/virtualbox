#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN upstream OpenSSL's own TAP test recipes (built by mayhem/build.sh in mayhem/build/openssl-test with
# the project's normal flags). The selected recipes are known-answer / golden-output suites: BN arithmetic
# (test/recipes/10-test_bn_data), SHA/HMAC/CMAC vectors, the EVP known-answer files (30-test_evp_data),
# ASN.1 and X.509 parsing against reference dumps, PEM/CRL/conf/punycode parsing. A program that exits 0
# without producing TAP output (a no-op patch) leaves them without a plan, so they fail.
TESTS="test_bn test_sha test_hmac test_cmac test_evp test_asn1_parse test_asn1_encode test_asn1_decode test_conf test_punycode test_x509 test_pem_reading test_dgst test_crl test_hexstring test_kdf"
TEST_TREE="$SRC/mayhem/build/openssl-test"
if [ ! -f "$TEST_TREE/Makefile" ] || [ ! -x "$TEST_TREE/test/evp_test" ]; then
  echo "OpenSSL test programs missing: mayhem/build.sh did not build them" >&2
  emit_ctrf "openssl-tap" 0 1 0
  exit 1
fi
cd "$TEST_TREE"

LOG="$(mktemp)"
HARNESS_JOBS="$MAYHEM_JOBS" make run_tests TESTS="$TESTS" >"$LOG" 2>&1
cat "$LOG"

# The last "Files=F, Tests=T" line is the summary for the selected recipes.
total="$(sed -n 's/^Files=[0-9]*, Tests=\([0-9]*\).*/\1/p' "$LOG" | tail -1)"
if [ -z "$total" ] || [ "$total" -eq 0 ]; then
  echo "no TAP output from the OpenSSL test programs" >&2
  emit_ctrf "openssl-tap" 0 1 0
  exit 1
fi
failed=0
while read -r n; do failed=$(( failed + n )); done < <(sed -n 's/.*Tests: [0-9]* *Failed: \([0-9]*\)).*/\1/p' "$LOG")
skipped="$(grep -c 'skipped:' "$LOG" || true)"
if grep -q '^Result: FAIL' "$LOG" && [ "$failed" -eq 0 ]; then failed=1; fi
emit_ctrf "openssl-tap" $(( total - failed )) "$failed" "$skipped"
