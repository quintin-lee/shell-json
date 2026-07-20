#!/usr/bin/env bash
# Tests for writer.sh — AST → JSON serialization
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
_TESTS_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
source "$_TESTS_DIR/test_helper.sh"

# ── Helpers ────────────────────────────────────────────────────────────

# Create a primitive AST node and serialize it
write_primitive() {
    local type=$1 value=$2
    error_clear
    ast_init
    local id
    id=$(ast_create "$type" "$value")
    writer_write "$id" 0
    ast_destroy
}

# Build an object with given keys/values and serialize it
# Usage: write_object <indent> <key1> <val1> [<key2> <val2> ...]
write_object() {
    local indent=$1; shift
    error_clear
    ast_init
    local obj_id kid
    obj_id=$(ast_create "$_AST_T_OBJECT" "")
    while (( $# >= 2 )); do
        kid=$(ast_create "$_AST_T_STRING" "$2")
        ast_set_child_with_key "$obj_id" "$kid" "$1"
        shift 2
    done
    writer_write "$obj_id" "$indent"
    ast_destroy
}

# Build an array with given child types/values
write_array() {
    local indent=$1; shift
    error_clear
    ast_init
    local arr_id kid
    arr_id=$(ast_create "$_AST_T_ARRAY" "")
    while (( $# >= 1 )); do
        kid=$(ast_create "$1" "$2")
        ast_set_child "$arr_id" "$kid"
        shift 2
    done
    writer_write "$arr_id" "$indent"
    ast_destroy
}

# ── Primitives ─────────────────────────────────────────────────────────

test_start "write: string simple"
result=$(write_primitive "$_AST_T_STRING" "hello")
assert_eq "$result" '"hello"' "simple string"

test_start "write: string empty"
result=$(write_primitive "$_AST_T_STRING" "")
assert_eq "$result" '""' "empty string"

test_start "write: number integer"
result=$(write_primitive "$_AST_T_NUMBER" "42")
assert_eq "$result" "42" "integer"

test_start "write: number negative"
result=$(write_primitive "$_AST_T_NUMBER" "-1")
assert_eq "$result" "-1" "negative"

test_start "write: number zero"
result=$(write_primitive "$_AST_T_NUMBER" "0")
assert_eq "$result" "0" "zero"

test_start "write: number decimal"
result=$(write_primitive "$_AST_T_NUMBER" "3.14")
assert_eq "$result" "3.14" "decimal"

test_start "write: number scientific"
result=$(write_primitive "$_AST_T_NUMBER" "1e10")
assert_eq "$result" "1e10" "scientific"

test_start "write: boolean true"
result=$(write_primitive "$_AST_T_BOOL" "true")
assert_eq "$result" "true" "true"

test_start "write: boolean false"
result=$(write_primitive "$_AST_T_BOOL" "false")
assert_eq "$result" "false" "false"

test_start "write: null"
result=$(write_primitive "$_AST_T_NULL" "")
assert_eq "$result" "null" "null"

# ── Object ─────────────────────────────────────────────────────────────

test_start "write: empty object"
result=$(write_object 0)
assert_eq "$result" "{}" "empty object"

test_start "write: object single key"
result=$(write_object 0 "a" "1")
assert_eq "$result" '{"a":"1"}' "single key"

test_start "write: object multiple keys"
result=$(write_object 0 "x" "10" "y" "20" "z" "30")
assert_eq "$result" '{"x":"10","y":"20","z":"30"}' "multiple keys"

# ── Array ──────────────────────────────────────────────────────────────

test_start "write: empty array"
result=$(write_array 0)
assert_eq "$result" "[]" "empty array"

test_start "write: array single element"
result=$(write_array 0 "$_AST_T_NUMBER" "1")
assert_eq "$result" "[1]" "single element"

test_start "write: array multiple elements"
result=$(write_array 0 "$_AST_T_NUMBER" "1" "$_AST_T_NUMBER" "2" "$_AST_T_NUMBER" "3")
assert_eq "$result" "[1,2,3]" "multiple elements"

test_start "write: array mixed types"
result=$(write_array 0 \
    "$_AST_T_STRING" "a" \
    "$_AST_T_NUMBER" "42" \
    "$_AST_T_BOOL" "true" \
    "$_AST_T_NULL" "")
assert_eq "$result" '["a",42,true,null]' "mixed types"

# ── Pretty-print ───────────────────────────────────────────────────────

test_start "write pretty: object single key"
result=$(write_object 2 "a" "1")
assert_eq "$result" $'{\n  "a": "1"\n}' "pretty object single"

test_start "write pretty: object multiple keys"
result=$(write_object 2 "a" "1" "b" "2")
assert_eq "$result" $'{\n  "a": "1",\n  "b": "2"\n}' "pretty object multi"

test_start "write pretty: empty object"
result=$(write_object 2)
assert_eq "$result" "{}" "pretty empty object"

test_start "write pretty: empty array"
result=$(write_array 2)
assert_eq "$result" "[]" "pretty empty array"

# ── Complex nested ─────────────────────────────────────────────────────

test_start "write: nested object in array"
error_clear
ast_init
arr=$(ast_create "$_AST_T_ARRAY" "")
arr=$(ast_create "$_AST_T_ARRAY" "")
obj=$(ast_create "$_AST_T_OBJECT" "")
kid_a=$(ast_create "$_AST_T_STRING" "hello")
kid_b=$(ast_create "$_AST_T_NUMBER" "42")
ast_set_child_with_key "$obj" "$kid_a" "msg"
ast_set_child_with_key "$obj" "$kid_b" "num"
ast_set_child "$arr" "$obj"
result=$(writer_write "$arr" 0)
ast_destroy
assert_eq "$result" '[{"msg":"hello","num":42}]' "nested object in array"

test_start "write pretty: nested"
error_clear
ast_init
arr=$(ast_create "$_AST_T_ARRAY" "")
arr=$(ast_create "$_AST_T_ARRAY" "")
obj=$(ast_create "$_AST_T_OBJECT" "")
kid_a=$(ast_create "$_AST_T_STRING" "hello")
kid_b=$(ast_create "$_AST_T_NUMBER" "42")
ast_set_child_with_key "$obj" "$kid_a" "msg"
ast_set_child_with_key "$obj" "$kid_b" "num"
ast_set_child "$arr" "$obj"
result=$(writer_write "$arr" 2)
ast_destroy
assert_eq "$result" $'[\n  {\n    "msg": "hello",\n    "num": 42\n  }\n]' "pretty nested"

# ── Summary ────────────────────────────────────────────────────────────

test_summary
