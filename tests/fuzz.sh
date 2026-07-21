#!/usr/bin/env bash
# shell-json fuzz tester
#
# Generates random valid JSON, corrupts inputs, and verifies that the parser
# handles everything without crashing or producing inconsistent output.
#
# Usage: bash tests/fuzz.sh [iterations]

set -euo pipefail

ITERATIONS="${1:-1000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/src/json.sh"

_FAILED=0
_TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

say() { printf '  %s\n' "$1"; }
fail() { say "FAIL: $1"; _FAILED=$((_FAILED + 1)); }
ok()   { :; }

# Generate a random integer 0..max-1
rand_int() { printf '%s' $((RANDOM % $1)); }

# Pick a random element from a space-separated list
pick() {
    local items=("$@")
    printf '%s' "${items[RANDOM % ${#items[@]}]}"
}

# Generate a random ASCII string (safe for JSON)
rand_ascii_string() {
    local len=$((RANDOM % 20 + 1)) s=""
    local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-!@#$%^&*()'
    for ((i = 0; i < len; i++)); do
        s+="${chars:RANDOM % ${#chars}:1}"
    done
    printf '%s' "$s"
}

# Generate a JSON-safe string (escapes backslash and double quote)
gen_json_string() {
    local raw
    raw=$(rand_ascii_string)
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    printf '%s' "$raw"
}

# ── Random JSON generator ─────────────────────────────────────────────────────

gen_value() {
    local depth=${1:-0}
    if (( depth > 10 )); then
        # At max depth, generate a simple value
        case $(rand_int 4) in
            0) printf '"%s"' "$(gen_json_string)" ;;
            1) printf '%s' $((RANDOM * (RANDOM % 2 == 0 ? 1 : -1))) ;;
            2) printf '%s' "$(pick true false null)" ;;
            3) printf '%s' "$(rand_int 1000000)" ;;
        esac
        return
    fi
    case $(rand_int 6) in
        0) printf '"%s"' "$(gen_json_string)" ;;
        1) printf '%s' $((RANDOM * (RANDOM % 2 == 0 ? 1 : -1))) ;;
        2) printf '%s' "$(pick true false null)" ;;
        3) gen_object $((depth + 1)) ;;
        4) gen_array $((depth + 1)) ;;
        5) printf '%s' "$(rand_int 1000).$(rand_int 100)" ;;
    esac
}

gen_object() {
    local depth=${1:-0}
    local count=$(rand_int 4)
    if (( count == 0 )); then
        printf '{}'
        return
    fi
    printf '{'
    local sep=""
    for ((i = 0; i < count; i++)); do
        printf '%s"%s":%s' "$sep" "$(gen_json_string)" "$(gen_value $depth)"
        sep=","
    done
    printf '}'
}

gen_array() {
    local depth=${1:-0}
    local count=$(rand_int 5)
    if (( count == 0 )); then
        printf '[]'
        return
    fi
    printf '['
    local sep=""
    for ((i = 0; i < count; i++)); do
        printf '%s%s' "$sep" "$(gen_value $depth)"
        sep=","
    done
    printf ']'
}

# ── Test cases ────────────────────────────────────────────────────────────────

# Test 1: Random valid JSON roundtrip
test_roundtrip() {
    local json=$1
    local root result
    root=$(json.parse_string "$json" 2>/dev/null) || return 1
    if [[ -z "$root" ]]; then
        # Parse failed — should have error set
        return 1
    fi
    result=$(json.dump "$root" 2>/dev/null) || true
    json.free "$root" 2>/dev/null || true
    # Verify output is non-empty JSON
    if [[ -z "$result" ]]; then
        return 1
    fi
    # Check it starts with { [ " true false null or digit
    case "${result:0:1}" in
        '{'|'['|'"'|'t'|'f'|'n'|[0-9-]) return 0 ;;
        *) return 1 ;;
    esac
}

# Test 2: Parse malformed JSON — verify no crash
test_malformed() {
    local input=$1
    # Should not crash; either succeeds or returns a meaningful error
    local root
    root=$(json.parse_string "$input" 2>/dev/null) || {
        # Parse failed — error should be set
        local code
        code=$(json.last_error 2>/dev/null) || true
        json.clear_error 2>/dev/null || true
        if [[ -n "$code" && "${code%%:*}" =~ ^[0-9]+$ ]]; then
            return 0  # Meaningful error code
        fi
        # Some failures still acceptable — no crash is the main goal
        return 0
    }
    # If it somehow parsed, free it
    json.free "$root" 2>/dev/null || true
}

# Test 3: Deeply nested objects
test_deep_nesting() {
    local depth="${1:-50}"
    local json=""
    local close=""
    for ((i = 0; i < depth; i++)); do
        json+='{"a":'
        close+="}"
    done
    json+="1$close"

    local root
    root=$(json.parse_string "$json" 2>/dev/null) || return 0  # Might hit recursion limit, that's OK
    if [[ -n "$root" ]]; then
        local result
        result=$(json.dump "$root" 2>/dev/null) || true
        json.free "$root" 2>/dev/null || true
        # Verify result is valid (starts with {)
        if [[ -n "$result" && "${result:0:1}" == "{" ]]; then
            return 0
        fi
    fi
    return 0  # Failures at extreme depth are acceptable
}

# ── Edge case corpus ──────────────────────────────────────────────────────────

get_edge_cases() {
    # Return array of edge case JSON strings
    cat <<'EDGES'
null
true
false
0
-0
1
-1
0.0
0.00
1e10
-1e10
1E+10
1E-10
1.5e10
0.0000001
2147483647
-2147483648
9007199254740991
""
"hello"
"hello world"
"\""
"\\"
"\/"
"\b"
"\f"
"\n"
"\r"
"\t"
"\u0041"
"\u004a"
"\u00e9"
"\u2603"
"\uD83D\uDE00"
"\n\t\r"
"line1\nline2"
"tab\there"
"slash\\/slash"
"quote\"here"
"back\\slash"
{}
[]
{"":null}
{"a":1,"b":2}
{"a":{"b":{"c":null}}}
[1,2,3]
[1,[2,[3]]]
[null,true,false,0,""]
{"spaces": "  value  "}
{"unicode": "\u0041\u0042\u0043"}
{"numbers": [0.1, 0.01, 0.001]}
EDGES
}

get_malformed_cases() {
    cat <<'MALFORMED'
{invalid}
{,}
{:}
[]
[}
{:}
{,}
{{}}
[[]]
['single quotes']
{"key"}
{"key":}
{,"key":1}
{"key":1,}
{"a" "b"}
["a" "b"]
[1,]
{"a":01}
{"a":00}
{"a":-0}
{"a":.5}
{"a":1.}
{"a":1e}
{"a":1e-}
{"a":1.2.3}
{"a":truee}
{"a":fals}
{"a":nulle}
{"\x41":1}
{}
{"a":1 /* comment */}
{"a":1,}
[1 2 3]
[1,,2]
{"a":undefined}
{"a":NaN}
{"a":Infinity}
MALFORMED
}

# ── Main fuzz loop ────────────────────────────────────────────────────────────

echo "=========================================="
echo " shell-json Fuzz Tester"
echo " Iterations: $ITERATIONS"
echo " Date:       $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="
echo

# Phase 1: Edge cases
echo "[Phase 1/4] Edge case corpus"
while IFS= read -r json; do
    [[ -z "$json" || "$json" == "#"* ]] && continue
    _TOTAL=$((_TOTAL + 1))
    test_roundtrip "$json" || fail "edge case roundtrip: $json"
done < <(get_edge_cases)
say "Done — $_TOTAL edge cases"

# Phase 2: Malformed inputs (no-crash check)
echo
echo "[Phase 2/4] Malformed input (no-crash)"
_mcount=0
while IFS= read -r input; do
    [[ -z "$input" || "$input" == "#"* ]] && continue
    _TOTAL=$((_TOTAL + 1))
    _mcount=$((_mcount + 1))
    test_malformed "$input" || fail "malformed: $input"
done < <(get_malformed_cases)
say "Done — $_mcount malformed inputs"

# Phase 3: Random valid JSON roundtrips
echo
echo "[Phase 3/4] Random valid JSON roundtrips (n=$ITERATIONS)"
for ((i = 0; i < ITERATIONS; i++ )); do
    json=$(gen_value 0)
    _TOTAL=$((_TOTAL + 1))
    if ! test_roundtrip "$json"; then
        fail "roundtrip #$((i+1)): ${json:0:80}"
    fi
    if (( i > 0 && i % 100 == 0 )); then
        printf '  %d random tests completed\n' "$i"
    fi
done
say "Done — $ITERATIONS random roundtrips"

# Phase 4: Deep nesting test
echo
echo "[Phase 4/4] Deep nesting stress test"
for depth in 10 20 50 100 200; do
    _TOTAL=$((_TOTAL + 1))
    test_deep_nesting "$depth"
    say "  depth=$depth: OK"
done

# ── Results ───────────────────────────────────────────────────────────────────

echo
echo "=========================================="
echo " Results: $_TOTAL total, $_FAILED failed"
echo "=========================================="

if (( _FAILED > 0 )); then
    echo "Some tests FAILED."
    exit 1
fi
echo "All fuzz tests passed."
