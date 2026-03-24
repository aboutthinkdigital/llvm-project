#!/usr/bin/env bash
# =============================================================================
# benchmark_callhierarchy.sh  –  End-to-end call hierarchy benchmark runner
#
# This script generates synthetic C++ code, builds a clangd index,
# and runs CallHierarchyBenchmark for each configured scenario.
#
# Usage:
#   ./benchmark_callhierarchy.sh [OPTIONS]
#
# Options:
#   -b <build-dir>   Build directory containing clangd-indexer and
#                    CallHierarchyBenchmark  (default: build-debug)
#   -o <work-dir>    Working directory for generated files  (default: /tmp/chbench)
#   -n <runs>        Number of benchmark repetitions per scenario (default: 10)
#   -t <time>        --benchmark_min_time per run, e.g. 0.1s  (default: 0.05s)
#   -f <filter>      --benchmark_filter regex  (default: all)
#   -s <scenarios>   Comma-separated list of scenarios to run
#                    Available: chain_small,chain_large,hub_small,hub_large,
#                               fanout_small,fanout_large,mixed,tree,multi_tu
#                    (default: all)
#   -h               Show this help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../../../build-debug"
WORK_DIR="/tmp/chbench"
RUNS=10
BENCH_MIN_TIME="0.05s"
BENCH_FILTER=""
SCENARIOS="chain_small,chain_large,hub_small,hub_large,fanout_small,fanout_large,mixed,tree"

# Aggregate statistics across scenarios.
declare -a INDEX_SIZE_BYTES_ALL=()
declare -a INDEX_SYMBOLS_ALL=()

while getopts "b:o:n:t:f:s:h" opt; do
  case $opt in
    b) BUILD_DIR="$OPTARG" ;;
    o) WORK_DIR="$OPTARG" ;;
    n) RUNS="$OPTARG" ;;
    t) BENCH_MIN_TIME="$OPTARG" ;;
    f) BENCH_FILTER="$OPTARG" ;;
    s) SCENARIOS="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

INDEXER="$BUILD_DIR/bin/clangd-indexer"
BENCH="$BUILD_DIR/tools/clang/tools/extra/clangd/benchmarks/CallHierarchyBenchmark"
GENSCRIPT="$SCRIPT_DIR/gen_callhierarchy_code.py"

for bin in "$INDEXER" "$BENCH"; do
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: not found or not executable: $bin" >&2
    echo "  Run: ninja -C $BUILD_DIR CallHierarchyBenchmark clangd-indexer" >&2
    exit 1
  fi
done

mkdir -p "$WORK_DIR"

# ─── scenario definitions ─────────────────────────────────────────────────────
# Format: "topology|extra-arg1|extra-arg2|...|--|target-function|label"
# Fields are pipe-separated; extra args end at the sentinel field "--"
declare -A SCENARIO_DEFS
SCENARIO_DEFS["chain_small"]="chain|--size|200|--|f100|Chain-200"
SCENARIO_DEFS["chain_large"]="chain|--size|5000|--|f2500|Chain-5000"
SCENARIO_DEFS["hub_small"]="hub|--callers|100|--|hub_function|Hub-100-callers"
SCENARIO_DEFS["hub_large"]="hub|--callers|2000|--|hub_function|Hub-2000-callers"
SCENARIO_DEFS["fanout_small"]="fanout|--callees|100|--|hub_function|Fanout-100-callees"
SCENARIO_DEFS["fanout_large"]="fanout|--callees|2000|--|hub_function|Fanout-2000-callees"
SCENARIO_DEFS["mixed"]="mixed|--callers|500|--callees|500|--|hub_function|Mixed-500x500"
SCENARIO_DEFS["tree"]="tree|--depth|10|--|node0|Tree-depth10"

# ─── statistics (python3) ─────────────────────────────────────────────────────
python3_stats() {
  python3 - "$@" <<'PYEOF'
import sys, statistics

label = sys.argv[1]
bench = sys.argv[2]
values = list(map(float, sys.argv[3:]))
if not values:
    print(f"  [{label}] {bench}: no data")
    sys.exit(0)
values.sort()
n = len(values)
median = statistics.median(values)
mean   = statistics.mean(values)
stdev  = statistics.stdev(values) if n > 1 else 0.0
p95    = values[min(int(0.95 * n), n - 1)]

def fmt(ns):
    if ns >= 1e9: return f"{ns/1e9:.3f}  s"
    if ns >= 1e6: return f"{ns/1e6:.3f} ms"
    if ns >= 1e3: return f"{ns/1e3:.3f} us"
    return f"{ns:.0f} ns"

print(f"  {label:30s}  {bench:20s}  "
      f"median={fmt(median):12s}  p95={fmt(p95):12s}  "
      f"mean={fmt(mean):12s}  stdev={fmt(stdev):10s}  n={n}")
PYEOF
}

python3_numeric_stats() {
  python3 - "$@" <<'PYEOF'
import sys, statistics

label = sys.argv[1]
unit = sys.argv[2]
values = list(map(float, sys.argv[3:]))
if not values:
    print(f"  {label}: no data")
    sys.exit(0)

values.sort()
n = len(values)
median = statistics.median(values)
mean = statistics.mean(values)
stdev = statistics.stdev(values) if n > 1 else 0.0

def fmt(v):
    if unit == "bytes":
        if v >= 1024 * 1024:
            return f"{int(v)} B ({v/(1024*1024):.2f} MiB)"
        if v >= 1024:
            return f"{int(v)} B ({v/1024:.2f} KiB)"
        return f"{int(v)} B"
    return f"{int(v)}"

print(f"  {label}: median={fmt(median)}  mean={fmt(mean)}  stdev={fmt(stdev)}  n={n}")
PYEOF
}

# ─── run one scenario ─────────────────────────────────────────────────────────
run_scenario() {
  local name="$1"
  local def="${SCENARIO_DEFS[$name]}"

  # Parse pipe-separated definition: topology|arg...|--|target|label
  IFS='|' read -ra FIELDS <<< "$def"
  local topology="${FIELDS[0]}"
  local extra_args=()
  local target=""
  local label=""
  local sentinel_seen=false
  local field_idx=0
  for field in "${FIELDS[@]:1}"; do
    if [[ "$field" == "--" ]]; then
      sentinel_seen=true
      field_idx=0
    elif ! $sentinel_seen; then
      extra_args+=("$field")
    else
      case $field_idx in
        0) target="$field" ;;
        1) label="$field" ;;
      esac
      field_idx=$((field_idx + 1))
    fi
  done

  local src="$WORK_DIR/${name}.cpp"
  local idx="$WORK_DIR/${name}.dex"
  local raw_dir="$WORK_DIR/runs_${name}"
  mkdir -p "$raw_dir"

  echo ""
  echo "── Scenario: $label ─────────────────────────────"

  # 1. Generate C++ code
  echo "   Generating code (topology=$topology) ..."
  python3 "$GENSCRIPT" --topology "$topology" "${extra_args[@]}" --output "$src" > /dev/null

  # 2. Build index
  echo "   Indexing $src ..."
  "$INDEXER" "$src" -- > "$idx" 2>/dev/null

  # Build YAML sidecar once to extract stable counters (symbols/refs/relations).
  local idx_yaml="$raw_dir/index.yaml"
  "$INDEXER" --format=yaml "$src" -- > "$idx_yaml" 2>/dev/null

  local idx_bytes symbol_count ref_bundle_count relation_count
  idx_bytes=$(stat -c '%s' "$idx")
  symbol_count=$(grep -c '^--- !Symbol$' "$idx_yaml" || true)
  ref_bundle_count=$(grep -c '^--- !Refs$' "$idx_yaml" || true)
  relation_count=$(grep -c '^--- !Relation$' "$idx_yaml" || true)

  INDEX_SIZE_BYTES_ALL+=("$idx_bytes")
  INDEX_SYMBOLS_ALL+=("$symbol_count")

  echo "   Index stats: size=${idx_bytes} B, symbols=${symbol_count}, ref-bundles=${ref_bundle_count}, relations=${relation_count}"

  # 3. Run benchmark N times
  echo "   Running $RUNS benchmark run(s) ..."
  local filter_arg=""
  [[ -n "$BENCH_FILTER" ]] && filter_arg="--benchmark_filter=$BENCH_FILTER"

  declare -A BENCH_TIMES
  for i in $(seq 1 "$RUNS"); do
    out="$raw_dir/run_${i}.txt"
    "$BENCH" "$idx" "$target" \
      --benchmark_min_time="$BENCH_MIN_TIME" \
      ${filter_arg:+"$filter_arg"} \
      --benchmark_color=false \
      2>/dev/null \
      | grep -E '^BM_' > "$out" || true
    printf "     run %2d/%d\r" "$i" "$RUNS"
  done
  echo ""

  # 4. Collect benchmark names from first run
  local bench_names
  bench_names=$(awk '{print $1}' "$raw_dir/run_1.txt" 2>/dev/null | sort -u || true)

  # 5. Print stats per benchmark
  for bname in $bench_names; do
    local ns_vals=()
    for i in $(seq 1 "$RUNS"); do
      val=$(grep "^$bname " "$raw_dir/run_${i}.txt" 2>/dev/null | awk '{print $2}' || true)
      [[ -n "$val" ]] && ns_vals+=("$val")
    done
    python3_stats "$label" "$bname" "${ns_vals[@]}"
  done
}

# ─── header ───────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  clangd CallHierarchy Benchmark"
echo "  build-dir : $BUILD_DIR"
echo "  work-dir  : $WORK_DIR"
echo "  runs/scenario : $RUNS"
echo "  min-time  : $BENCH_MIN_TIME"
echo "============================================================"
echo ""
echo "  $(printf '%-30s  %-20s  %-12s  %-12s  %-12s  %-10s  %s' \
    Scenario Benchmark Median P95 Mean Stdev N)"
echo "  $(printf '%0.s-' {1..110})"

# ─── run requested scenarios ─────────────────────────────────────────────────
IFS=',' read -ra SCEN_LIST <<< "$SCENARIOS"
for scen in "${SCEN_LIST[@]}"; do
  scen="${scen// /}"   # trim spaces
  if [[ -z "${SCENARIO_DEFS[$scen]+x}" ]]; then
    echo "WARNING: Unknown scenario '$scen' – skipping" >&2
  else
    run_scenario "$scen"
  fi
done

echo ""
echo "Index summary over executed scenarios:"
python3_numeric_stats "Index size" "bytes" "${INDEX_SIZE_BYTES_ALL[@]}"
python3_numeric_stats "Symbol count" "count" "${INDEX_SYMBOLS_ALL[@]}"

echo ""
echo "Done.  Raw data in $WORK_DIR/"
