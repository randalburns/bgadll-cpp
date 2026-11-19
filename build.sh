#!/bin/sh
# Builds the C++ BGADLL with the C ABI of BGADLL.Native, a drop-in for BEN's
#   Linux:  bin/BGADLL.so     (BEN: bin/BGA/linux/x64/BGADLL.so)
#   macOS:  bin/BGADLL.dylib  (BEN: bin/BGA/macos/arm64/BGADLL.dylib)
# No link-time dependencies beyond libc/libstdc++: the solver (libddfast / libdds) is opened at
# run time (see src/dds.hpp).
#   CXX=...    compiler (default g++ on Linux, clang++ on macOS)
#   ARCH=...   target flags (default -march=x86-64-v3 on x86-64, -mcpu=native on Arm; the
#              solver libraries carry their own)
#   OUT=...    output directory (default bin)
# `./build.sh test` builds and runs the unit tests (tests/test_model.cpp) with the same flags.
#   HWY=...    directory holding hwy/highway.h (Google Highway, header-only use). Used where
#              the target has no AVX2 (Apple silicon: NEON). Unset, it is looked for with
#              pkg-config, in Homebrew's include directory and beside a ddfast checkout;
#              HWY=none builds without it.
set -eu
cd "$(dirname "$0")"
OUT=${OUT:-bin}
mkdir -p "$OUT"
SRC="src/model.cpp src/dds.cpp src/pimc.cpp src/ffi.cpp"

find_highway() {
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libhwy 2>/dev/null; then
    pkg-config --variable=includedir libhwy; return
  fi
  for d in /opt/homebrew/include /usr/local/include ../ddfast/build/highway ../../ddfast/build/highway \
           /usr/include; do
    if [ -f "$d/hwy/highway.h" ]; then echo "$d"; return; fi
  done
}
case "${HWY:-}" in
  none) HWY_FLAGS="-DBGA_NO_HIGHWAY" ;;
  "") d=$(find_highway); HWY_FLAGS=${d:+-I$d} ;;
  *)
    if [ ! -f "$HWY/hwy/highway.h" ]; then echo "HWY=$HWY: no hwy/highway.h there" >&2; exit 1; fi
    HWY_FLAGS="-I$HWY" ;;
esac

if [ "${1:-}" = test ]; then
  if [ "$(uname -s)" = Darwin ]; then CXX=${CXX:-clang++}; ARCH=${ARCH:--mcpu=native}; else
    CXX=${CXX:-g++}
    case "$(uname -m)" in x86_64) ARCH=${ARCH:--march=x86-64-v3} ;; *) ARCH=${ARCH:--mcpu=native} ;; esac
  fi
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O2 -Wall -Wextra $ARCH $HWY_FLAGS -Isrc -o "$OUT/test_model" tests/test_model.cpp src/model.cpp
  exec "$OUT/test_model"
fi
if [ "$(uname -s)" = Darwin ]; then
  CXX=${CXX:-clang++}
  ARCH=${ARCH:--mcpu=native}
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O2 -g -fPIC -fvisibility=hidden -Wall -Wextra $ARCH $HWY_FLAGS \
    -dynamiclib -install_name @rpath/BGADLL.dylib -o "$OUT/BGADLL.dylib" $SRC -pthread
  echo "built $OUT/BGADLL.dylib"
else
  CXX=${CXX:-g++}
  case "$(uname -m)" in
    x86_64) ARCH=${ARCH:--march=x86-64-v3} ;;
    *) ARCH=${ARCH:--mcpu=native} ;;
  esac
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O2 -g -fPIC -fvisibility=hidden -Wall -Wextra $ARCH $HWY_FLAGS \
    -shared -o "$OUT/BGADLL.so" $SRC -static-libstdc++ -static-libgcc -pthread -ldl
  echo "built $OUT/BGADLL.so"
fi
# Which vector code model.cpp got, as the compiler sees it.
# shellcheck disable=SC2086
if echo | $CXX $ARCH -dM -E - 2>/dev/null | grep -q '__AVX2__'; then
  echo "vector code: AVX2"
elif [ "${HWY:-}" != none ] && echo '#include <hwy/highway.h>' | $CXX -std=c++17 $ARCH $HWY_FLAGS -x c++ -fsyntax-only - 2>/dev/null; then
  echo "vector code: Highway ${HWY_FLAGS#-I}"
else
  echo "vector code: none (no AVX2, no Highway; set HWY=<dir with hwy/highway.h>)"
fi
