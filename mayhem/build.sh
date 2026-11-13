#!/usr/bin/env bash
#
# mayhem/build.sh — build the fuzz harnesses (sanitized) and the project's own test binaries
# (normal flags). Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The project's own test binaries (multimon-ng, gen-ng, unit tests) with its NORMAL flags,
#    where test.sh and upstream's test/run_tests.sh look for them (build/, gitignored upstream).
cmake -S . -B build \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
    -DX11_SUPPORT=OFF -DPULSE_AUDIO_SUPPORT=OFF -DSDL3_SCOPE=OFF
cmake --build build -j"$MAYHEM_JOBS"

# 2) The decoder library, sanitized + SanCov-instrumented, out of tree in build-fuzz/ (gitignored
#    upstream via build-*). Same sources and defines as the CMake multimon-ng target, minus the
#    UI/audio backends. Both harnesses link unixinput.c's I/O helpers; fuzz_demod #includes it.
OUT=build-fuzz
mkdir -p "$OUT"
CFLAGS_FUZZ="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -std=gnu11 \
 -DCHARSET_UTF8 -DDUMMY_AUDIO -DNO_X11 -DNO_SDL3 -DHAVE_TIMESPEC_GET -DMAX_VERBOSE_LEVEL=3 -I$SRC"

LIB_SRCS="uart.c pocsag.c selcall.c hdlc.c demod_zvei1.c demod_zvei2.c demod_zvei3.c demod_pzvei.c
 demod_dzvei.c demod_ccir.c demod_eia.c demod_eea.c demod_ufsk12.c demod_poc24.c demod_poc12.c
 demod_poc5.c demod_hapn48.c demod_fsk96.c demod_dtmf.c demod_dualtone.c demod_clipfsk.c
 demod_fmsfsk.c demod_afsk24.c demod_afsk24_3.c demod_afsk24_2.c demod_afsk12.c demod_flex.c
 demod_flex_next.c demod_gsc.c costabi.c costabf.c clip.c fms.c demod_eas.c demod_morse.c
 demod_dumpcsv.c demod_x10.c cJSON.c bch.c"
objs=()
for f in $LIB_SRCS; do
    o="$OUT/${f%.c}.o"
    $CC $CFLAGS_FUZZ -c "$f" -o "$o" &
    objs+=("$o")
    while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
done
wait

# unixinput.c: main() renamed so it can be linked/included next to a fuzzer entry point.
$CC $CFLAGS_FUZZ -Dmain=multimon_cli_main -c unixinput.c -o "$OUT/unixinput.o"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OUT/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"

# 3) Harnesses: libFuzzer binary + run-once standalone reproducer each.
$CC $CFLAGS_FUZZ -Dmain=multimon_cli_main -c mayhem/fuzz_demod.c -o "$OUT/fuzz_demod.o"
$CC $CFLAGS_FUZZ -c mayhem/fuzz_rxbit.c -o "$OUT/fuzz_rxbit.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OUT/fuzz_demod.o" "${objs[@]}" "$OUT/lsan_off.o" -lm -o /mayhem/fuzz_demod
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "$OUT/fuzz_demod.o" "${objs[@]}" "$OUT/lsan_off.o" -lm -o /mayhem/fuzz_demod-standalone
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OUT/fuzz_rxbit.o" "$OUT/unixinput.o" "${objs[@]}" "$OUT/lsan_off.o" -lm -o /mayhem/fuzz_rxbit
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "$OUT/fuzz_rxbit.o" "$OUT/unixinput.o" "${objs[@]}" "$OUT/lsan_off.o" -lm -o /mayhem/fuzz_rxbit-standalone
