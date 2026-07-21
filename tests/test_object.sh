#!/usr/bin/env bash
# Tests for object.sh module
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
_TEST_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
source "$_TEST_DIR/test_helper.sh"

# ── Basic object operations ─────────────────────────────────────────

test_start "object: get child by key"
error_clear
ast_init
lexer_init '{"name":"Alice","age":30}'
root=$(parser_parse)
child=$(ast_child_by_key "$root" "name")
assert_ok "key exists" test -n "$child"
val=$(ast_get_value "$child")
assert_eq "$val" "Alice" "value is Alice"
ast_destroy

test_end

test_start "object: get non-existent key"
error_clear
ast_init
lexer_init '{"name":"Bob"}'
root=$(parser_parse)
child=$(ast_child_by_key "$root" "missing")
assert_eq "$child" "" "non-existent key returns empty"
ast_destroy

test_end

test_start "object: set child with key"
error_clear
ast_init
lexer_init '{"a":1}'
root=$(parser_parse)
lexer_init '"hello"'
new_node=$(parser_parse)
ast_set_child_with_key "$root" "$new_node" "b"
child=$(ast_child_by_key "$root" "b")
assert_ok "set key works" test -n "$child"
val=$(ast_get_value "$child")
assert_eq "$val" "hello" "value is hello"
ast_destroy

test_end

test_start "object: remove child"
error_clear
ast_init
lexer_init '{"a":1,"b":2}'
root=$(parser_parse)
child=$(ast_child_by_key "$root" "a")
ast_remove_child "$root" "$child"
result=$(query_execute "$root" "\$.a" 2>/dev/null)
assert_eq "$result" "" "removed key no longer accessible"
ast_destroy

test_end

test_start "object: replace child"
error_clear
ast_init
lexer_init '{"a":1}'
root=$(parser_parse)
lexer_init '"replaced"'
new_node=$(parser_parse)
old=$(ast_child_by_key "$root" "a")
ast_replace_child "$root" "$old" "$new_node"
val=$(ast_get_value "$(ast_child_by_key "$root" "a")")
assert_eq "$val" "replaced" "replaced value"
ast_destroy

test_end

test_start "object: get children"
error_clear
ast_init
lexer_init '{"a":1,"b":2,"c":3}'
root=$(parser_parse)
children=$(ast_get_children "$root")
count=$(printf '%s\n' $children | wc -l)
assert_eq "$count" "3" "three children"
ast_destroy

test_end

test_start "object: get child count"
error_clear
ast_init
lexer_init '[]'
root=$(parser_parse)
count=$(ast_get_child_count "$root")
assert_eq "$count" "0" "empty array has 0 children"
ast_destroy

test_end

test_start "object: not an object type"
error_clear
ast_init
lexer_init '42'
root=$(parser_parse)
type=$(ast_get_type "$root")
assert_eq "$type" "$_AST_T_NUMBER" "number type"
ast_destroy

test_end

# ── Summary ──────────────────────────────────────────────────────────

test_summary
