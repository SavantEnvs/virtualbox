#!/usr/bin/env bash
#
# mayhem/build.sh — builds the OpenSSL libFuzzer harnesses that ship in-tree with VirtualBox's
# vendored OpenSSL (src/libs/openssl-3.5.8/fuzz), plus the OpenSSL test suite for mayhem/test.sh.
#
# Runs inside the commit image as `mayhem` in /mayhem. Everything is built in COPIES of the vendored
# tree under mayhem/build/ (gitignored), so no upstream file is touched. VirtualBox patches the
# vendored OpenSSL for its own kBuild (symbol mangling header, iprt-based bn_conf.h/dso_conf.h); the
# copies are un-patched back to stock OpenSSL layout before Configure.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

OSSL_SRC="$SRC/src/libs/openssl-3.5.8"
BUILD="$SRC/mayhem/build"
FUZZ_TREE="$BUILD/openssl-fuzz"
TEST_TREE="$BUILD/openssl-test"
BIN="$BUILD/bin"
mkdir -p "$BIN"

# Harness name (fuzz/<name>.c) -> binary name. All harnesses in fuzz/build.info that build here.
HARNESSES="acert asn1 asn1parse bignum bndiv client cmp cms conf crl ct decoder dtlsclient dtlsserver
 hashtable ml-dsa ml-kem pem provider punycode quic-client quic-lcidm quic-rcidm quic-server quic-srtm
 server slh-dsa smime v3name x509"

# Copy the vendored tree (newer-only, so source edits propagate on a re-run) and, on first use,
# strip VirtualBox's kBuild-specific bits so stock Configure works.
prep_tree() {
  local dest="$1"
  mkdir -p "$dest"
  cp -au "$OSSL_SRC/." "$dest/"
  if [ ! -f "$dest/Makefile" ]; then
    rm -f "$dest/configdata.pm" "$dest/include/crypto/bn_conf.h" "$dest/include/crypto/dso_conf.h"
    : > "$dest/openssl-mangling.h"
  fi
}

# 1) Sanitized OpenSSL libs + libFuzzer harnesses. -fsanitize=fuzzer-no-link instruments the library
#    itself for coverage; ASan+UBSan (halting) come from $SANITIZER_FLAGS. Only two UBSan checks are
#    relaxed: `alignment` (OpenSSL's own fuzzing docs do the same; bignum/hash code does benign
#    unaligned loads) and `function` (OpenSSL's STACK_OF/LHASH APIs call typed callbacks through
#    void* function pointers by design, which trips it on the first input of every harness).
prep_tree "$FUZZ_TREE"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

cd "$FUZZ_TREE"
if [ ! -f Makefile ]; then
  # shellcheck disable=SC2086
  CC="$CC" ./Configure linux-x86_64-clang enable-fuzz-libfuzzer no-shared no-asm \
    -DPEDANTIC -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -I"$FUZZ_TREE" \
    enable-ec_nistp_64_gcc_128 enable-weak-ssl-ciphers enable-rc5 enable-md2 \
    enable-ssl3 enable-ssl3-method enable-nextprotoneg \
    -O1 $SANITIZER_FLAGS -fno-sanitize=alignment,function -fsanitize=fuzzer-no-link $DEBUG_FLAGS >/dev/null
fi
make -j"$MAYHEM_JOBS" build_generated build_libs >/dev/null

for h in $HARNESSES; do
  n="${h//-/_}"
  # shellcheck disable=SC2086
  make -j"$MAYHEM_JOBS" "fuzz/$h" LDCMD="$CC $LIB_FUZZING_ENGINE $BUILD/lsan_off.o" >/dev/null
  mv -f "fuzz/$h" "$BIN/$n"
  objs=(fuzz/"$h"-bin-*.o)
  if [ "$h" = provider ]; then
    # fuzz/provider.c returns 1 on success, which libFuzzer treats as an unwanted input: new coverage
    # is never kept and the run stalls at ~14 edges. Rename its entry point in a copy of the object and
    # put mayhem/provider_adapter.c (maps 1 -> 0, 0 -> -1) in front of it; the fuzzed code is untouched.
    # shellcheck disable=SC2086
    $CC $SANITIZER_FLAGS -fno-sanitize=alignment,function -fsanitize=fuzzer-no-link $DEBUG_FLAGS \
      -c "$SRC/mayhem/provider_adapter.c" -o "$BUILD/provider_adapter.o"
    objcopy --redefine-sym FuzzerTestOneInput=provider_upstream_test_one_input \
      fuzz/provider-bin-provider.o "$BUILD/provider_upstream.o"
    objs=(fuzz/provider-bin-driver.o "$BUILD/provider_upstream.o" "$BUILD/provider_adapter.o")
    # shellcheck disable=SC2086
    $CC $SANITIZER_FLAGS -fno-sanitize=alignment,function $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${objs[@]}" \
      "$BUILD/lsan_off.o" -L. -lcrypto -ldl -pthread -o "$BIN/$n"
  fi
  # Standalone run-once reproducer: same harness objects, STANDALONE_FUZZ_MAIN instead of libFuzzer.
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${objs[@]}" "$BUILD/standalone_main.o" "$BUILD/lsan_off.o" \
    -L. -lssl -lcrypto -ldl -pthread -o "$BIN/${n}-standalone"
done

# 2) The test suite with the project's NORMAL flags (clean build, no sanitizers, no fuzzing).
prep_tree "$TEST_TREE"
cd "$TEST_TREE"
if [ ! -f Makefile ]; then
  # shellcheck disable=SC2086
  CC="$CC" ./Configure linux-x86_64-clang no-engine -I"$TEST_TREE" $COVERAGE_FLAGS >/dev/null
fi
make -j"$MAYHEM_JOBS" build_generated build_libs_nodep build_programs_nodep build_modules_nodep link-utils >/dev/null
