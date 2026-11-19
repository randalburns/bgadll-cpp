#!/bin/sh
# Checks that this library returns exactly what the C# BGADLL returns: builds the C# library
# from the BGA submodule (extern/BGA, NativeAOT), builds this one and bench_bga, runs both on
# the same positions and compares every (tricks, weight) result.
#
# Needs the .NET SDK (8 or later) and Bo Haglund's DDS, which the C# library calls:
#   BGA_DDS_LIB=<ben>/bin/libdds.so ./check.sh            (macOS: libdds.dylib)
# This library uses ddfast when it can load it (BGA_DDFAST_LIB, DDFAST_TABLES), else the same
# DDS. POSITIONS=n sets the number of random positions (default 300), THREADS=n the threads
# (default: the number of CPUs).
set -eu
cd "$(dirname "$0")"
: "${BGA_DDS_LIB:?set BGA_DDS_LIB to Haglund DDS (libdds.so / libdds.dylib), e.g. <ben>/bin/libdds.so}"
N=${POSITIONS:-300}
T=${THREADS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
if ! command -v dotnet >/dev/null 2>&1 && [ -x "$HOME/.dotnet/dotnet" ]; then
  export PATH="$HOME/.dotnet:$PATH" DOTNET_ROOT="$HOME/.dotnet"
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# extern/BGA is not checked out by a recursive clone (update = none); fetch it here.
git submodule update --init --checkout extern/BGA

case "$(uname -s)" in
  Darwin) RID=osx-arm64 EXT=dylib CXX=${CXX:-clang++} ;;
  *)
    EXT=so CXX=${CXX:-g++}
    case "$(uname -m)" in x86_64) RID=linux-x64 ;; *) RID=linux-arm64 ;; esac ;;
esac

dotnet publish extern/BGA/BGADLL.Native/BGADLL.Native.csproj -c Release -r "$RID" \
  --self-contained true -o bin/csharp >/dev/null
# The C# library loads DDS as "dds", looked for beside the program that loads it: run it from
# bin/csharp with DDS there under that name. A preloaded copy is not enough on macOS, where
# BEN's libdds.2.9.0.dylib is known by its install name, @rpath/libdds.2.dylib.
cp "$BGA_DDS_LIB" "bin/csharp/libdds.$EXT"
./build.sh
$CXX -std=c++17 -O2 -o bin/bench_bga bench/bench_bga.cpp -ldl
cp bin/bench_bga bin/csharp/bench_bga

bin/csharp/bench_bga --lib "bin/csharp/BGADLL.$EXT" --preload "$BGA_DDS_LIB" --positions "$N" \
  --threads "$T" --iters 1 --dump bin/check-csharp.txt | grep -E '^lib=|random all'
bin/bench_bga --lib "bin/BGADLL.$EXT" --positions "$N" --threads "$T" --iters 1 --dump bin/check-cpp.txt \
  | grep -E '^lib=|random all'
if cmp -s bin/check-csharp.txt bin/check-cpp.txt; then
  echo "same results as the C# library ($(git -C extern/BGA describe --always --tags))"
else
  echo "RESULTS DIFFER: bin/check-csharp.txt bin/check-cpp.txt" >&2
  exit 1
fi
