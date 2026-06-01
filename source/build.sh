#!/usr/bin/env bash
set -e
MH="minhook/src/buffer.c minhook/src/hook.c minhook/src/trampoline.c minhook/src/hde/hde32.c minhook/src/hde/hde64.c"
# RELEASE build (default): no perf counters compiled in -- zero hot-path cost.
# To build a developer instrumented binary instead, pass CNFIX_PERF=1 to this
# script, e.g.  CNFIX_PERF=1 bash build.sh  -- that defines -DCNFIX_PERF so the
# lightweight call/hit counters increment and dump to the debug log (only when
# the debug flag file is also present). NEVER ship a CNFIX_PERF build.
PERF_FLAG=""
if [ "${CNFIX_PERF:-0}" = "1" ]; then PERF_FLAG="-DCNFIX_PERF=1"; echo "(building with CNFIX_PERF instrumentation -- DO NOT SHIP)"; fi
i686-w64-mingw32-g++ -shared -O2 -std=c++17 -static $PERF_FLAG -I minhook/include -I src src/CNFixEnglish_source.cpp $MH -o CNFixEnglish.dll
echo "Built CNFixEnglish.dll (English meaning + Pinyin mode, configurable)"
