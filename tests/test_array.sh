#!/usr/bin/env bash
# Tests for array.sh module
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
_TEST_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
source "$_TEST_DIR/test_helper.sh"

test_start "array: get element by index"
error_clear
ast_init
lexer_init '[10,20,30]'
root=$(parser_parse)
child=$(array_get "$root" "1")
assert_ok "index 1 exists" test -n "$child"
val=$(ast_get_value "$child")
assert_eq "$val" "20" "value at index 1 is 20"
ast_destroy

test_end

test_start "array: get negative index"
error_clear
ast_init
lexer_init '[10,20,30]'
root=$(parser_parse)
child=$(array_get "$root" "-1")
assert_ok "negative index works" test -n "$child"
val=$(ast_get_value "$child")
assert_eq "$val" "30" "last value is 30"
ast_destroy

test_end

test_start "array: out of bounds returns error"
error_clear
ast_init
lexer_init '[1,2,3]'
root=$(parser_parse)
result=$(array_get "$root" "99" 2>/dev/null)
assert_fail "OOB returns failure" array_get "$root" "99"
msg=$(error_msg)
[[ "$msg" == *"out of bounds"* ]] && assert_ok "error mentions out of bounds" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: expected OOB error, got: [%s]\n' "$msg"
}
ast_destroy

test_end

test_start "array: not an array node"
error_clear
ast_init
lexer_init '{"a":1}'
root=$(parser_parse)
result=$(array_get "$root" "0" 2>/dev/null)
assert_fail "non-array returns failure" array_get "$root" "0"
msg=$(error_msg)
[[ "$msg" == *"Not an array"* ]] && assert_ok "error mentions not array" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: expected Not an array error, got: [%s]\n' "$msg"
}
ast_destroy

test_end

test_start "array: length of empty array"
error_clear
ast_init
lexer_init '[]'
root=$(parser_parse)
len=$(array_length "$root")
assert_eq "$len" "0" "empty array length"
ast_destroy

test_end

test_start "array: length of populated array"
error_clear
ast_init
lexer_init '[1,2,3,4,5]'
root=$(parser_parse)
len=$(array_length "$root")
assert_eq "$len" "5" "length is 5"
ast_destroy

test_end

# ── Summary ──────────────────────────────────────────────────────────

test_summary
