#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS known-answer checks over the vendored zlib: mayhem/zlib_kat.c and upstream's minigzip, built by
# mayhem/build.sh with the project's normal flags. Every check compares output against a known value.
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
if [ ! -x "$BIN/zlib_kat" ] || [ ! -x "$BIN/minigzip" ]; then
  echo "zlib test programs missing: mayhem/build.sh did not build them" >&2
  emit_ctrf "zlib-kat" 0 1 0
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
kat() { grep "^$1=" kat.out | head -1 | cut -d= -f2-; }

# zlib_kat: known answers for the checksums, deflate output bytes, inflate, and a rejected stream; it
# also writes a gzip file (gzopen/gzputs/gzprintf/gzclose) that gzip(1) must decode.
"$BIN/zlib_kat" kat.gz > kat.out 2> kat.err
check "zlib_kat exit status" 0 "$?"
check "crc32 of 123456789" "cbf43926" "$(kat crc32)"
check "adler32 of 123456789" "091e01de" "$(kat adler32)"
check "compress level 6" "789ccb48cdc9c9d751c800518a0021700496" "$(kat compress6)"
check "compress level 9" "78dacb48cdc9c9d751c800518a0021700496" "$(kat compress9)"
check "uncompress" "hello, hello!" "$(kat uncompress)"
check "inflate fixed stream" "hello, hello!" "$(kat inflate_fixed)"
check "inflate rejects bad adler32 (Z_DATA_ERROR)" "-3" "$(kat inflate_bad_adler)"
check "gz file written by zlib" "hello, gz!" "$(gzip -dc kat.gz 2>/dev/null)"

# minigzip: compress a fixed input; gzip(1) must restore the exact bytes.
seq 1 5000 > input.txt
want_md5="$(md5sum < input.txt | cut -d' ' -f1)"
"$BIN/minigzip" < input.txt > input.gz
check "minigzip magic" "1f8b08" "$(head -c3 input.gz | od -An -tx1 | tr -d ' \n')"
check "minigzip compresses" "yes" "$([ "$(stat -c%s input.gz)" -lt "$(stat -c%s input.txt)" ] && echo yes || echo no)"
check "minigzip stream decodes to the input" "$want_md5" "$(gzip -dc input.gz 2>/dev/null | md5sum | cut -d' ' -f1)"

emit_ctrf "zlib-kat" "$passed" "$failed" 0
