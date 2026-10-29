#!/usr/bin/env bash
#
# mayhem/build.sh — build the ChaiScript fuzz harness (+ standalone reproducer) with the sanitizers,
# and the project's own test suite with its normal flags. Runs in the commit image as `mayhem` in /mayhem.
# Re-runnable and network-free: ChaiScript is header-only and has no fetched dependencies.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_DIR="$SRC/build/fuzz"
mkdir -p "$FUZZ_DIR"

# 1) Fuzz harness: the whole interpreter is header-only, so it is compiled (sanitized, DWARF 3) into the
#    harness translation unit. Built twice: with libFuzzer, and against the run-once standalone driver.
CXXSTD="-std=c++20 -O1 -pthread -I$SRC/include"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD $LIB_FUZZING_ENGINE -c "$SRC/mayhem/fuzz_eval.cpp" -o "$FUZZ_DIR/fuzz_eval.o" &
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD -c "$SRC/mayhem/fuzz_eval.cpp" -o "$FUZZ_DIR/fuzz_eval_standalone.o" &
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o" &
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o" &
wait

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -pthread $LIB_FUZZING_ENGINE "$FUZZ_DIR/fuzz_eval.o" "$FUZZ_DIR/lsan_off.o" -ldl -o /mayhem/fuzz_eval
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -pthread "$FUZZ_DIR/fuzz_eval_standalone.o" "$FUZZ_DIR/standalone_main.o" "$FUZZ_DIR/lsan_off.o" -ldl -o /mayhem/fuzz_eval-standalone

# 2) Test suite with the project's NORMAL flags (clean, independent of the sanitized build above).
#    test.sh only runs what lands in build/tests.
cmake -S "$SRC" -B "$SRC/build/tests" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$SRC/build/tests" -j"$MAYHEM_JOBS"
