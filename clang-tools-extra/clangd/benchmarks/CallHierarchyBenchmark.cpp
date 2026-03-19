//===--- CallHierarchyBenchmark.cpp - Clangd call hierarchy benchmarks ----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Benchmarks for callHierarchy/incomingCalls and callHierarchy/outgoingCalls.
// Both operations work purely on the symbol index (no AST required).
//
// Usage:
//   CallHierarchyBenchmark <index.dex> <function_name> [BENCHMARK_OPTIONS...]
//
// Example:
//   # 1. Generate synthetic code:
//   python3 gen_callhierarchy_code.py --topology hub --callers 1000 \
//       -o /tmp/bench_hub.cpp
//
//   # 2. Build the index:
//   clangd-indexer /tmp/bench_hub.cpp -- > /tmp/bench.dex
//
//   # 3. Run the benchmark:
//   CallHierarchyBenchmark /tmp/bench.dex hub_function \
//       --benchmark_min_time=0.1s --benchmark_filter='incomingCalls'
//
//===----------------------------------------------------------------------===//

#include "../FindSymbols.h"
#include "../Protocol.h"
#include "../XRefs.h"
#include "../index/Serialization.h"
#include "../index/dex/Dex.h"
#include "benchmark/benchmark.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <string>

// Command-line positional arguments (set in main, read by benchmarks).
static const char *IndexFilename;
static const char *TargetFunction;

namespace clang {
namespace clangd {
namespace {

// ─── Index loading ────────────────────────────────────────────────────────────

std::unique_ptr<SymbolIndex> buildDexIndex() {
  return loadIndex(IndexFilename, SymbolOrigin::Static,
                   /*UseDex=*/true, /*SupportContainedRefs=*/true);
}

// ─── Helper: find a CallHierarchyItem by function name ───────────────────────

// Looks up `Name` in the index via FuzzyFind and returns a fully populated
// CallHierarchyItem.  Returns nullopt when the symbol is not found.
std::optional<CallHierarchyItem>
findCallHierarchyItem(const SymbolIndex *Index, llvm::StringRef Name) {
  FuzzyFindRequest Req;
  Req.Query = Name.str();
  Req.AnyScope = true;
  Req.Limit = 1;

  std::optional<CallHierarchyItem> Result;
  Index->fuzzyFind(Req, [&](const Symbol &S) {
    if (Result)
      return; // take only the first match

    // Build a minimal URI from the canonical declaration so that range
    // filtering in incomingCalls/outgoingCalls can work correctly.
    auto Loc = symbolToLocation(S, /*TUPath=*/"");
    if (!Loc) {
      llvm::consumeError(Loc.takeError());
      return;
    }

    CallHierarchyItem CHI;
    CHI.name = std::string(S.Name);
    CHI.detail = (S.Scope + S.Name).str();
    CHI.kind = indexSymbolKindToSymbolKind(S.SymInfo);
    CHI.data = S.ID.str(); // hex SymbolID – the only field actually required
    CHI.uri = Loc->uri;
    CHI.range = Loc->range;
    CHI.selectionRange = Loc->range;
    Result = std::move(CHI);
  });
  return Result;
}

// ─── Benchmark: incomingCalls ─────────────────────────────────────────────────
// Measures the time to resolve all callers of a given function.
// The index is loaded once before the timed loop.

static void BM_incomingCalls(benchmark::State &State) {
  const auto Index = buildDexIndex();
  if (!Index) {
    State.SkipWithError("Failed to load index");
    return;
  }
  const auto Item = findCallHierarchyItem(Index.get(), TargetFunction);
  if (!Item) {
    State.SkipWithError("Symbol not found in index");
    return;
  }

  // Report number of incoming calls as a custom counter.
  auto Results = incomingCalls(*Item, Index.get());
  State.counters["callers"] = static_cast<double>(Results.size());

  for (auto _ : State)
    benchmark::DoNotOptimize(incomingCalls(*Item, Index.get()));
}
BENCHMARK(BM_incomingCalls);

// ─── Benchmark: outgoingCalls ─────────────────────────────────────────────────
// Measures the time to resolve all callees of a given function.

static void BM_outgoingCalls(benchmark::State &State) {
  const auto Index = buildDexIndex();
  if (!Index) {
    State.SkipWithError("Failed to load index");
    return;
  }
  const auto Item = findCallHierarchyItem(Index.get(), TargetFunction);
  if (!Item) {
    State.SkipWithError("Symbol not found in index");
    return;
  }

  auto Results = outgoingCalls(*Item, Index.get());
  State.counters["callees"] = static_cast<double>(Results.size());

  for (auto _ : State)
    benchmark::DoNotOptimize(outgoingCalls(*Item, Index.get()));
}
BENCHMARK(BM_outgoingCalls);

// ─── Benchmark: indexBuild ────────────────────────────────────────────────────
// Measures how long loading and building the Dex index takes.
// Useful to separate index-build cost from query cost.

static void BM_indexBuild(benchmark::State &State) {
  for (auto _ : State)
    benchmark::DoNotOptimize(buildDexIndex());
}
BENCHMARK(BM_indexBuild);

} // namespace
} // namespace clangd
} // namespace clang

int main(int argc, char *argv[]) {
  if (argc < 3) {
    llvm::errs()
        << "Usage: " << argv[0]
        << " global-symbol-index.dex function_name BENCHMARK_OPTIONS...\n\n"
           "function_name   Name of the function to use as root for call "
           "hierarchy queries.\n\n"
           "Steps to prepare an index:\n"
           "  python3 gen_callhierarchy_code.py --topology hub "
           "--callers 500 -o /tmp/bench.cpp\n"
           "  clangd-indexer /tmp/bench.cpp -- > /tmp/bench.dex\n\n"
           "Example run:\n"
           "  CallHierarchyBenchmark /tmp/bench.dex hub_function "
           "--benchmark_min_time=0.1s\n";
    return -1;
  }

  IndexFilename = argv[1];
  TargetFunction = argv[2];

  // Strip the two custom arguments so Google Benchmark sees only its own args.
  argv[2] = argv[0];
  argv += 2;
  argc -= 2;

  ::benchmark::Initialize(&argc, argv);
  ::benchmark::RunSpecifiedBenchmarks();
  return 0;
}
