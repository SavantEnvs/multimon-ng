#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's own functional suite (test/run_tests.sh) against the binaries
# build.sh produced in build/. Every case decodes a known sample (or gen-ng output) and greps the
# decoder's stdout for the exact expected message, so a neutered multimon-ng fails it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

for bin in build/multimon-ng build/gen-ng; do
  [ -x "$bin" ] || { echo "missing $bin — mayhem/build.sh should have built it" >&2; emit_ctrf run_tests.sh 0 1; exit 1; }
done
command -v sox >/dev/null || { echo "sox missing from the image" >&2; emit_ctrf run_tests.sh 0 1; exit 1; }

out="$(MULTIMON="$SRC/build/multimon-ng" GEN_NG="$SRC/build/gen-ng" bash test/run_tests.sh 2>&1)"
rc=$?
printf '%s\n' "$out"

# Final line is "Tests: <passed>/<run> passed" (test/run_tests.sh).
summary="$(printf '%s\n' "$out" | sed -n 's/^Tests: \([0-9][0-9]*\)\/\([0-9][0-9]*\) passed.*/\1 \2/p' | tail -n1)"
if [ -z "$summary" ]; then
  echo "no 'Tests: P/T passed' summary from test/run_tests.sh" >&2
  emit_ctrf run_tests.sh 0 1
  exit 1
fi
read -r passed total <<<"$summary"
failed=$(( total - passed ))
[ "$total" -ge 40 ] || { echo "suspiciously few tests ran ($total)" >&2; failed=$(( failed + 1 )); }
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf run_tests.sh "$passed" "$failed"
