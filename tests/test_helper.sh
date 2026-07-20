#!/usr/bin/env bash
# Test helper framework for shell-json
#
# Part of shell-json (https://github.com/quintin/shell-json)

_TOTAL=0
_PASSED=0
_FAILED=0
_SKIPPED=0
_CURRENT_TEST=""

# Source the library — supports bash (BASH_SOURCE) and zsh (%x expansion)
_self="${BASH_SOURCE[0]:-${(%):-%x}}"
SELF_DIR="$(cd "$(dirname "$_self")/.." && pwd -P 2>/dev/null)" || SELF_DIR=""
if [[ -z "$SELF_DIR" || ! -f "$SELF_DIR/src/json.sh" ]]; then
    SELF_DIR="$PWD"
fi
source "$SELF_DIR/src/json.sh"

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    _TOTAL=$((_TOTAL+1))
    if [[ "$actual" == "$expected" ]]; then
        _PASSED=$((_PASSED+1))
    else
        _FAILED=$((_FAILED+1))
        printf '  FAIL: %s\n' "$_CURRENT_TEST"
        printf '    expected: [%s]\n' "$expected"
        printf '    actual:   [%s]\n' "$actual"
        if [[ -n "$msg" ]]; then
            printf '    message:  %s\n' "$msg"
        fi
    fi
}

assert_ok() {
    local desc="$1"
    shift
    _TOTAL=$((_TOTAL+1))
    if "$@" 2>/dev/null; then
        _PASSED=$((_PASSED+1))
    else
        _FAILED=$((_FAILED+1))
        printf '  FAIL: %s\n' "$_CURRENT_TEST"
        printf '    command failed: %s\n' "$*"
        printf '    description: %s\n' "$desc"
    fi
}

assert_fail() {
    local desc="$1"
    shift
    _TOTAL=$((_TOTAL+1))
    if ! "$@" 2>/dev/null; then
        _PASSED=$((_PASSED+1))
    else
        _FAILED=$((_FAILED+1))
        printf '  FAIL: %s\n' "$_CURRENT_TEST"
        printf '    command unexpectedly succeeded: %s\n' "$*"
        printf '    description: %s\n' "$desc"
    fi
}

test_start() {
    _CURRENT_TEST="$1"
}

test_end() {
    :
}

test_summary() {
    printf '\n--- Results ---\n'
    printf 'Total:  %d\n' "$_TOTAL"
    printf 'Passed: %d\n' "$_PASSED"
    printf 'Failed: %d\n' "$_FAILED"
    printf 'Skipped:%d\n' "$_SKIPPED"
    if (( _FAILED > 0 )); then
        return 1
    fi
    return 0
}
