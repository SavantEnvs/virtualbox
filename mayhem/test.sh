#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS zlib's own functional programs (example, minigzip), built by mayhem/build.sh with
# the project's normal flags. Every check compares output against a known value: example's printed
# round-trip results, and minigzip's compress -> decompress of a fixed input back to its exact bytes.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
SRC="${SRC:-/mayhem}"
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

BIN="$SRC/mayhem/build/bin"
if [ ! -x "$BIN/example" ] || [ ! -x "$BIN/minigzip" ]; then
  echo "zlib test programs missing: mayhem/build.sh did not build them" >&2
  emit_ctrf "zlib-example" 0 1 0
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

passed=0
failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1: expected '$2', got '$3'" >&2; fi
}

# example: deflate/inflate round trips, gz file write/read/seek, dictionary, inflateSync.
"$BIN/example" > example.out 2> example.err
rc=$?
check "example exit status" 0 "$rc"
check "example uncompress" "uncompress(): hello, hello!" "$(grep '^uncompress()' example.out)"
check "example gzread" "gzread(): hello, hello!" "$(grep '^gzread()' example.out)"
check "example gzgets after gzseek" "gzgets() after gzseek: hello!" "$(grep '^gzgets()' example.out)"
check "example inflate" "inflate(): hello, hello!" "$(grep '^inflate()' example.out)"
check "example large_inflate" "large_inflate(): OK" "$(grep '^large_inflate()' example.out)"
check "example inflateSync" "after inflateSync(): hello, hello!" "$(grep '^after inflateSync()' example.out)"
check "example dictionary" "inflate with dictionary: hello, hello!" "$(grep '^inflate with dictionary' example.out)"

# minigzip: compress a fixed file, check the gzip magic and that decompression restores the exact bytes.
seq 1 5000 > input.txt
want_md5="$(md5sum < input.txt | cut -d' ' -f1)"
"$BIN/minigzip" < input.txt > input.gz
check "minigzip magic" "1f8b08" "$(head -c3 input.gz | od -An -tx1 | tr -d ' \n')"
check "minigzip compresses" "yes" "$([ "$(stat -c%s input.gz)" -lt "$(stat -c%s input.txt)" ] && echo yes || echo no)"
"$BIN/minigzip" -d < input.gz > output.txt
check "minigzip round trip" "$want_md5" "$(md5sum < output.txt | cut -d' ' -f1)"
check "minigzip round trip size" "$(stat -c%s input.txt)" "$(stat -c%s output.txt)"

# a system gzip stream decodes to the known text
printf 'hello, hello!\n' | gzip -c > sys.gz
check "minigzip reads gzip(1) output" "hello, hello!" "$("$BIN/minigzip" -d < sys.gz)"

emit_ctrf "zlib-example" "$passed" "$failed" 0
