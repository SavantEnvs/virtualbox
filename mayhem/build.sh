#!/usr/bin/env bash
#
# mayhem/build.sh — builds the vendored zlib (src/libs/zlib-1.3.2) three ways: sanitized + coverage
# instrumented for the gzread libFuzzer harness (and its -standalone reproducer), and plain (the
# project's normal flags) for the known-answer program (mayhem/zlib_kat.c) and upstream's minigzip that mayhem/test.sh runs.
#
# Runs inside the commit image as `mayhem` in /mayhem. Objects land in mayhem/build/ (gitignored);
# no upstream file is touched.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

ZLIB="$SRC/src/libs/zlib-1.3.2"
BUILD="$SRC/mayhem/build"
BIN="$BUILD/bin"
mkdir -p "$BIN" "$BUILD/fuzz" "$BUILD/plain"

LIB_SRCS="adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil"
COMMON_DEFS="-D_LARGEFILE64_SOURCE=1 -DHAVE_HIDDEN -DZ_HAVE_UNISTD_H"

# 1) Sanitized zlib (ASan+UBSan halting from $SANITIZER_FLAGS; -fsanitize=fuzzer-no-link so the library
#    itself is covered) + the gzread harness.
FUZZ_OBJS=()
for s in $LIB_SRCS; do
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link $COMMON_DEFS -I"$ZLIB" \
    -c "$ZLIB/$s.c" -o "$BUILD/fuzz/$s.o" &
  FUZZ_OBJS+=("$BUILD/fuzz/$s.o")
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
done
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link $COMMON_DEFS -I"$ZLIB" \
  -c "$SRC/mayhem/gzread_harness.c" -o "$BUILD/fuzz/gzread_harness.o" &
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/fuzz/lsan_off.o" &
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/fuzz/standalone_main.o" &
wait

# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/fuzz/gzread_harness.o" "${FUZZ_OBJS[@]}" \
  "$BUILD/fuzz/lsan_off.o" -o "$BIN/gzread"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/fuzz/gzread_harness.o" "${FUZZ_OBJS[@]}" \
  "$BUILD/fuzz/standalone_main.o" "$BUILD/fuzz/lsan_off.o" -o "$BIN/gzread-standalone"

# 2) The upstream test programs with the project's NORMAL flags (no sanitizers, no fuzzing).
PLAIN_OBJS=()
for s in $LIB_SRCS; do
  $CC -O2 $COMMON_DEFS -I"$ZLIB" -c "$ZLIB/$s.c" -o "$BUILD/plain/$s.o" &
  PLAIN_OBJS+=("$BUILD/plain/$s.o")
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
done
wait
$CC -O2 $COMMON_DEFS -I"$ZLIB" "$SRC/mayhem/zlib_kat.c" "${PLAIN_OBJS[@]}" -o "$BIN/zlib_kat"
$CC -O2 $COMMON_DEFS -I"$ZLIB" "$ZLIB/test/minigzip.c" "${PLAIN_OBJS[@]}" -o "$BIN/minigzip"
