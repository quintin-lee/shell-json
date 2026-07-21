#!/usr/bin/env bash
# Tests for error handling framework
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
_TEST_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
source "$_TEST_DIR/test_helper.sh"

# ── error_set / error_get ────────────────────────────────────────────

test_start "error: basic error_set and error_get"
error_clear
error_set "$_JSON_ERR_TYPE" "type mismatch"
assert_eq "$_JSON_ERR_CODE" "$_JSON_ERR_TYPE" "code set"
assert_eq "$_JSON_ERR_MSG" "type mismatch" "message set"

result=$(error_get)
assert_eq "$result" "${_JSON_ERR_TYPE}: type mismatch" "error_get output"

test_end

# ── error_setf ───────────────────────────────────────────────────────

test_start "error: error_setf formats message"
error_clear
error_setf "$_JSON_ERR_PARSER" "Expected '%s' at %s" "}" "line 1 col 5"
assert_eq "$_JSON_ERR_CODE" "$_JSON_ERR_PARSER" "error_setf code"
assert_eq "$_JSON_ERR_MSG" "Expected '}' at line 1 col 5" "error_setf message"

test_end

# ── error_location ───────────────────────────────────────────────────

test_start "error: error_location sets location"
error_clear
error_set "$_JSON_ERR_LEXER" "bad token"
error_location "file.json:42:10"
assert_eq "$_JSON_ERR_LOC" "file.json:42:10" "location set"

result=$(error_loc)
assert_eq "$result" "file.json:42:10" "error_loc output"

test_end

# ── error_chain ──────────────────────────────────────────────────────

test_start "error: error_chain appends chain"
error_clear
error_set "$_JSON_ERR_PARSER" "parse failed"
error_chain "lexer error"
chain=$(error_chain_get)
assert_eq "$chain" "lexer error" "single chain entry"

error_chain "context: root object"
chain=$(error_chain_get)
assert_eq "$chain" "lexer error -> context: root object" "two chain entries"

test_end

# ── error_get_json ───────────────────────────────────────────────────

test_start "error: error_get_json returns valid JSON structure"
error_clear
error_setf "$_JSON_ERR_PARSER" "Unexpected token '%s' at %s" "EOF" "line 3 col 1"
error_location "input.json:3:1"
error_chain "outer call"

json=$(error_get_json)
assert_eq "$json" '{"code":3,"message":"Unexpected token '\''EOF'\'' at line 3 col 1","location":"input.json:3:1","chain":"outer call"}' "JSON output"

test_end

# ── error_clear ──────────────────────────────────────────────────────

test_start "error: error_clear resets state"
error_set "$_JSON_ERR_IO" "read failed"
error_location "test.txt:1:1"
error_chain "step1"
error_clear
assert_eq "$_JSON_ERR_CODE" "0" "code cleared"
assert_eq "$_JSON_ERR_MSG" "" "message cleared"
assert_eq "$_JSON_ERR_LOC" "" "loc cleared"
assert_eq "$_JSON_ERR_CHAIN" "" "chain cleared"

test_end

# ── Parser errors include position ──────────────────────────────────

test_start "parser: error includes location on unexpected token"
error_clear
ast_init
lexer_init '{invalid'
root=$(parser_parse 2>/dev/null)
assert_eq "$root" "" "invalid parse fails"
msg=$(error_msg)
# Should mention position info
[[ "$msg" == *"at"* ]] && assert_ok "error has location" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: parser error should include position\n'
    printf '    actual message: [%s]\n' "$msg"
}
ast_destroy

test_end

test_start "parser: error includes location on EOF"
error_clear
ast_init
lexer_init ''
root=$(parser_parse 2>/dev/null)
assert_eq "$root" "" "empty input fails"
msg=$(error_msg)
[[ "$msg" == *"Unexpected end"* ]] && assert_ok "correct EOF message" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: expected EOF error message, got: [%s]\n' "$msg"
}
ast_destroy

test_end

# ── Mutation errors include path ─────────────────────────────────────

test_start "mutation: set error includes path in message"
error_clear
ast_init
lexer_init '{"a":1}'
root=$(parser_parse)
path_expr='$'
query_set "$root" "$path_expr" '"val"' 2>/dev/null
assert_fail "set fails on root path" query_set "$root" "$path_expr" '"val"'
msg=$(error_msg)
[[ "$msg" == *"$path_expr"* ]] && assert_ok "error contains path" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: mutation error should contain path, got: [%s]\n' "$msg"
}
ast_destroy

test_end

test_start "mutation: push error includes path in message"
error_clear
ast_init
lexer_init '{"a":1}'
root=$(parser_parse)
path_expr='$.a'
query_push "$root" "$path_expr" '"val"' 2>/dev/null
assert_fail "push fails on non-array" query_push "$root" "$path_expr" '"val"'
msg=$(error_msg)
[[ "$msg" == *"$path_expr"* ]] && assert_ok "push error contains path" true || {
    _FAILED=$((_FAILED+1))
    printf '  FAIL: push error should contain path, got: [%s]\n' "$msg"
}
ast_destroy

test_end

# ── Summary ──────────────────────────────────────────────────────────

test_summary
