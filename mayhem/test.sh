#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ChaiScript's own functional suite (built by mayhem/build.sh into build/tests).
#
#  1. every unittests/*.chai script runs under `chai` (as ctest does) and must print the completion marker
#     from mayhem/unit_done.chai (two scripts end in an explicit exit(0) and are checked by exit status
#     only), so a neutered interpreter that exits 0 without evaluating fails;
#  2. the Catch2 `compiled_tests` binary must report "All tests passed" with its assertion counts;
#  3. the remaining ctest tests (C++ API tests, version/help checks) must pass;
#  4. a known-answer script (mayhem/oracle.chai) must produce exactly mayhem/oracle.expected.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

BT="$SRC/build/tests"
CHAI="$BT/chai"
for f in "$CHAI" "$BT/compiled_tests" "$BT/CTestTestfile.cmake"; do
  [ -e "$f" ] || { echo "test.sh: missing $f — mayhem/build.sh must build the test suite" >&2; exit 2; }
done

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

export CHAI_USE_PATH="$SRC/unittests/" CHAI_MODULE_PATH="$BT/"
passed=0; failed=0

# 1) unit scripts
run_unit() {
  local f="$1" out rc
  out="$("$CHAI" "$SRC/unittests/unit_test.inc" "$f" "$SRC/mayhem/unit_done.chai" 2>&1)"; rc=$?
  # A script that ends its success path with an explicit exit(0) can never reach the marker.
  if [ $rc -eq 0 ] && { [[ "$out" == *CHAI_UNIT_DONE ]] || grep -q 'exit(0)' "$f"; }; then
    echo "PASS $f"
  else
    echo "FAIL $f"; printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
  fi
}
export -f run_unit; export CHAI SRC
unit_log="$(ls "$SRC"/unittests/*.chai | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'run_unit {}')"
p=$(printf '%s\n' "$unit_log" | grep -c '^PASS ')
f=$(printf '%s\n' "$unit_log" | grep -c '^FAIL ')
printf '%s\n' "$unit_log" | grep -A5 '^FAIL ' || true
echo "unit scripts: $p passed, $f failed"
passed=$((passed + p)); failed=$((failed + f))

# 2) Catch2 suite
catch_out="$("$BT/compiled_tests" 2>&1)"; catch_rc=$?
if [ $catch_rc -eq 0 ] && cases=$(printf '%s\n' "$catch_out" | sed -n 's/^All tests passed (.* assertions\? in \([0-9]*\) test cases\?)$/\1/p') && [ -n "$cases" ]; then
  echo "compiled_tests: $cases test cases passed"
  passed=$((passed + cases))
else
  printf '%s\n' "$catch_out" | tail -15
  echo "compiled_tests: FAILED"
  failed=$((failed + 1))
fi

# 3) remaining ctest tests (the unit scripts and Catch cases are covered above)
ctest_out="$(cd "$BT" && ctest -j"$MAYHEM_JOBS" -E '^(unit\.|compiled\.)' 2>&1)"
printf '%s\n' "$ctest_out" | tail -8
if line=$(printf '%s\n' "$ctest_out" | sed -n 's/^.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\)$/\1 \2/p') && [ -n "$line" ]; then
  set -- $line; ct_failed=$1; ct_total=$2
  passed=$((passed + ct_total - ct_failed)); failed=$((failed + ct_failed))
else
  echo "ctest: no summary"; failed=$((failed + 1))
fi

# 4) known-answer script
oracle_out="$("$CHAI" "$SRC/mayhem/oracle.chai" 2>&1)"
if [ "$oracle_out" = "$(cat "$SRC/mayhem/oracle.expected")" ]; then
  echo "oracle: ok"; passed=$((passed + 1))
else
  echo "oracle: MISMATCH"; diff <(printf '%s\n' "$oracle_out") "$SRC/mayhem/oracle.expected" | head -20
  failed=$((failed + 1))
fi

emit_ctrf "chaiscript-chai+catch2+ctest" "$passed" "$failed" 0
