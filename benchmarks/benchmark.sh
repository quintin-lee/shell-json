#!/usr/bin/env bash
# shell-json benchmark suite
#
# Compares shell-json vs jq across parse, query, and serialize operations
# at multiple data scales.
#
# Usage: bash benchmarks/benchmark.sh [iterations]
#   iterations: number of runs per benchmark (default: 3)

set -uo pipefail

ITERATIONS="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/src/json.sh"

DATA_SMALL="$SCRIPT_DIR/small.json"
DATA_MEDIUM="$SCRIPT_DIR/medium.json"
DATA_LARGE="$SCRIPT_DIR/large.json"

# ── Timing helper ──────────────────────────────────────────────────────────

# Run a command N times, report min and mean wall-clock time in ms
benchmark_n() {
    local name=$1 cmd=$2
    local i total=0 min=9999999 val
    for ((i = 0; i < ITERATIONS; i++)); do
        val=$( { time -p bash -c "$cmd" >/dev/null 2>&1; } 2>&1 | grep real | awk '{print $2 * 1000}')
        if [[ -n "$val" ]]; then
            total=$(awk "BEGIN {print $total + $val}")
            if awk "BEGIN {exit ($val < $min ? 0 : 1)}" 2>/dev/null; then
                min=$val
            fi
        fi
    done
    local mean
    mean=$(awk "BEGIN {printf \"%.1f\", $total / $ITERATIONS}")
    printf '  %-48s  min=%6.1fms  mean=%6.1fms\n' "$name" "$min" "$mean"
}

# ── Test files ──────────────────────────────────────────────────────────────

run_file() {
    local label=$1 file=$2
    local size
    size=$(stat --format='%s' "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)

    echo
    echo "==== $label ($size bytes) ===="

    # Parse + dump roundtrip
    echo "  [Parse + Serialize]"
    benchmark_n "shell-json parse + dump" \
        "source src/json.sh; root=\$(json.parse \"$file\"); json.dump \"\$root\"; json.free \"\$root\""
    benchmark_n "jq             parse + dump" \
        "jq -c '.' \"$file\""

    # Pretty-print
    echo "  [Pretty-print]"
    benchmark_n "shell-json pretty-print" \
        "source src/json.sh; root=\$(json.parse \"$file\"); json.dump \"\$root\" 2; json.free \"\$root\""
    benchmark_n "jq             pretty-print" \
        "jq '.' \"$file\" > /dev/null"
}

# ── Main ────────────────────────────────────────────────────────────────────

echo "=========================================="
echo " shell-json Benchmark Suite"
echo " Iterations: $ITERATIONS"
echo " Bash:       ${BASH_VERSION}"
echo " jq:         $(jq --version 2>&1)"
echo "=========================================="

run_file "small" "$DATA_SMALL"
run_file "medium" "$DATA_MEDIUM"
run_file "large"  "$DATA_LARGE"

echo
echo "==== Done ===="
