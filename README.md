# bgadll-cpp

A C++ port of the BGADLL engine of [BGA](https://github.com/ThorvaldAagaard/BGA) (`PIMC`, `PIMCDef` and the classes they use) with the same C
ABI as `BGADLL.Native` (the 61 `bga_*` functions of [BGAFFI.cs](https://github.com/ThorvaldAagaard/BGA/blob/main/BGADLL.Native/BGAFFI.cs)).
It is a drop-in for BEN's `bin/BGA/linux/x64/BGADLL.so` (and `bin/BGA/macos/arm64/BGADLL.dylib`):
BEN's ctypes bindings (`src/pimc/BGADLL_Native.py`) load it unchanged.

Its double-dummy solver is [ddfast](https://github.com/randalburns/ddfast)
(`ddfast::card_results`), with Bo Haglund's DDS as a fallback. Without ddfast it runs on DDS
alone, with the same results as the C# library and no .NET build.

Linux x86-64 and macOS (Apple silicon), both tested; Arm Linux builds (`-mcpu=native`) but is untested.

## Build

```sh
./build.sh          # Linux: bin/BGADLL.so; macOS: bin/BGADLL.dylib
```

C++17, no other dependencies: g++ on Linux (libstdc++ linked statically, `-march=x86-64-v3` by
default on x86-64; `ARCH` overrides), clang++ on macOS. The solver library is opened at run
time with `dlopen`.

One loop in the sampler is vectorised. On x86-64 it is AVX2. Elsewhere (Apple silicon) it uses
[Highway](https://github.com/google/highway) if its headers are found, else plain C++.
`build.sh` looks for Highway with pkg-config, in Homebrew's include directory
(`brew install highway`) and beside a ddfast checkout; `HWY=<dir>` names the directory holding
`hwy/highway.h`, `HWY=none` builds without it. It prints the choice (`vector code: ...`), and
`bga_simd()` (not in `BGAFFI.cs`) reports it at run time. All three give the same results.

## Use with BEN

BEN has this library as a submodule. `bash build_native.sh` in BEN builds it, or run
`./build.sh` here; BEN then loads `bin/BGADLL.so` (macOS: `bin/BGADLL.dylib`) from
this directory in place of the C# library under `<ben>/bin/BGA`, which stays there for
`BEN_BGADLL=csharp`. Do not copy this library over the C# one. BEN's `src/preflight.py`
reports the engine and solver in use.

The solver is chosen once per process:

| | |
|---|---|
| `BGA_DDS_BACKEND=ddfast` / `haglund` | force a backend; unset, ddfast if it can be loaded, else Haglund |
| `BGA_DDFAST_LIB` / `BGA_DDS_LIB` | path of `libddfast` / `libdds` (`.so`, or `.dylib` on macOS) |
| `DDFAST_TABLES` | ddfast's table directory (as for BEN's own ddfast use) |

A library already in the process is used first, then `BGA_DDFAST_LIB` / `BGA_DDS_LIB`, then
one beside `BGADLL.so`, then the loader's path. BEN's DDSolver has already loaded ddfast's
`libddfast` (its Python module links it), so BGADLL uses that copy and both share one set of
tables; BEN also sets `BGA_DDFAST_LIB` to it, and `BGA_DDS_LIB` to its vendored DDS library for
the Haglund backend (`BEN_PIMC_DDS=haglund`, or when ddfast is not built). ddfast's
`libdds` (DDS's C interface) is for the C# library and is not used here. `bga_dds_backend()`
reports `ddfast`, `haglund` or `none`. With no solver, `bga_pimc_setup` and
`bga_pimcdef_setup` return -1.

## Same results as the C# library

Given the same inputs, the port makes the same samples in the same order:
- the same seed (SHA-256 of the two known hands);
- the same SplitMix32 Fisher-Yates order of the opponents' splits (computed only as far as
  it is read: see below);
- the same constraint handling and the same weights.

So it returns the same `(tricks, weight)` lists. `bench/bench_bga.cpp` checks this. It drives
any `BGADLL.so` through the C ABI, as BEN does, and dumps every result. On the 3 fixed
positions and 300 random positions at every stage of play, every combination below gave
byte-identical dumps:
- C# NativeAOT on Haglund DDS;
- C++ on Haglund DDS;
- C++ on ddfast;
- C# on ddfast's `libdds` shim.

`check.sh` runs this check. It builds the C# library from the BGA submodule (`extern/BGA`,
with NativeAOT; it needs the .NET SDK), builds this library, runs both through `bench_bga` and
compares the dumps:

```sh
BGA_DDS_LIB=<ben>/bin/libdds.so ./check.sh    # Haglund DDS, which the C# library calls
```

This library uses ddfast when it can load it (`BGA_DDFAST_LIB`, `DDFAST_TABLES`), else the
same DDS.

`./build.sh test` runs the unit tests, which check the sampler's fast paths against the code
they replace (`tests/test_model.cpp`). CI (`.github/workflows/ci.yml`) runs on every pull
request to `main`, on Linux x86-64 and macOS (Apple silicon):
- the build;
- the unit tests for each vector path: AVX2, Highway and scalar on Linux; Highway (NEON) and
  scalar on macOS;
- `check.sh` on Haglund DDS (BEN's binaries, pinned by commit and SHA-256). The macOS job
  compares against the C# results from the Linux job (`REFERENCE=`), which works because
  `bench_bga` deals the same positions on every platform. The C# library itself isn't run on
  macOS: on runners with fewer than 8 cores, DDS rejects some of the 8 thread indexes it uses,
  and it scores those solves as 0 tricks. This library retires a rejected index and retries.

`main` takes changes only through pull requests that pass both jobs.

## Performance

Milliseconds per evaluation (`bench_bga`, 12 threads, Linux x86-64, Ryzen AI 9 HX 370). Each
figure is the median of 3 runs, with the builds interleaved, and all 24 runs gave the same
results.
- **All positions**: the mean over the 300 random positions.
- **Own work**: the part of that mean spent in BGADLL itself (setup and sampling), not in the
  solver.
- **First trick**: the fixed declarer position at trick 1 (C(26,13) = 10.4M opponent splits),
  where the sampling costs the most.

These were measured before `bench_bga` switched to a portable shuffle, so its 300 random
positions are now a different set. Each row adds one change to the row above:

| | Solver | All positions | Own work | First trick | Speedup (all) |
|---|---|---:|---:|---:|---:|
| C# library (NativeAOT) | DDS | 128.1 | 14.4 | 351 | 1.0x |
| C++ port | DDS | 96.3 | 6.5 | 265 | 1.3x |
| C++ port | ddfast | 24.1 | 6.3 | 95 | 5.3x |
| + faster sampling, plain C++ | ddfast | 20.5 | 2.4 | 53 | 6.2x |
| + AVX2 | ddfast | **19.6** | **1.5** | **46** | **6.5x** |

What each change contributes:
- **C++ (1.3x).** The C# library spends 14 ms of each evaluation on its own work and makes
  slower solver calls (113 ms against 89 ms on the same DDS). On defence it is 25x slower
  (1,069 ms against 42 ms).
- **ddfast (4.0x on top).** The solver goes from 89 ms to 17 ms per evaluation.
- **Faster sampling (1.2x).** Only the part of the shuffle that is read is computed, and the
  sample search runs in parallel (see below). Own work drops from 6.3 ms to 2.4 ms, and the
  first trick from 95 ms to 53 ms.
- **AVX2 (1.05x overall, 1.16x on the first trick).** AVX2 vectorises the shuffle loop, the
  only vector code. Own work drops from 2.4 ms to 1.5 ms.

The solver time varies by about 5% from run to run, so the own-work column is the precise
comparison between builds: every build makes exactly the same solver calls. On DDS, the
sampling and AVX2 changes save the same few milliseconds (96.0 and 96.8 ms against 96.3 ms,
within noise), against much longer solves.

For reference, the C# library on ddfast's `libdds` shim takes 55.0 ms (18.9 ms own work, 168 ms
on the first trick). On ddfast, perf puts 96% of the C++ library's time in ddfast's search and
about 1% in BGADLL.

macOS (Apple M5, 10 threads), measured before the faster sampling: C# on DDS 133.6, C++ on DDS
124.7, C# on ddfast 31.0, C++ on ddfast 21.5.

## Differences from the C# library

The sampling is the same as in C#, done in less time:
- Utils.Shuffle orders all C(n, n/2) splits, 10.4 million on the first trick, and FindSamples
  usually reads a few hundred. SplitMix32's i-th draw depends only on the seed and i, so the
  entries read are worked out on their own (`shuffle_prefix`, `src/model.cpp`), exactly as
  the full shuffle would leave them. Below 512K splits the whole shuffle is done.
- After the first 8192 splits, FindSamples checks the rest on all threads and merges them in
  order, so the samples, `Examined` and `Playouts` are as in C#.

- `version()` is `1.0.0.0`.
- Samples are 64-bit card masks rather than lists of `Card` objects and strings.
- Worker threads come from one persistent pool instead of new threads per `Evaluate`, because
  ddfast keeps its search state per OS thread.
- `AwaitEvaluation` wakes on a condition variable instead of polling every 10 ms.
- On ddfast, a sample can have a revoke in the current trick: a hidden hand that discarded
  while still holding the suit led. DDS accepts that position and ddfast does not, so the trick
  is played out card by card, as ddfast's own DDS layer does. The fusion strategy's "x" command
  plays the lowest of the best cards, where DDS plays whichever best card it finds first. BEN's
  configs have fusion off.
- Behaviour that is a quirk in C# is kept, so results match:
  - `PIMCDef` records the trick count as the weight.
  - `Clear()` leaves the shown hands.
  - Results are read back in descending order after `SortResults`.

## Repository

`extern/BGA` is [BGA](https://github.com/ThorvaldAagaard/BGA) as a submodule, pinned to the
version this port reproduces (0.9.9.3). Its `BGADLL` and `BGADLL.Native` are the C# library
ported here and the reference `check.sh` builds. A recursive clone skips it (`update = none`
in `.gitmodules`), so projects that include this repository as a submodule, such as BEN, don't
fetch BGA. `check.sh` fetches it; by hand, run
`git submodule update --init --checkout extern/BGA`.

When BGA changes BGADLL, port the change, move the submodule to the new version, and run
`check.sh`.

## License

Licensed under either of
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)), as is ddfast, or
- MIT License ([LICENSE-MIT](LICENSE-MIT)), as is BGA,

at your option. The code is a port of BGA's `BGADLL`, Copyright (c) 2024 Ark223, under the MIT
License; see [NOTICE](NOTICE).

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in
this work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without
any additional terms or conditions.
