#!/usr/bin/env bash
# Integration tests — end-to-end through public API
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
_TESTS_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
source "$_TESTS_DIR/test_helper.sh"

SIMPLE_DIR="$_TESTS_DIR/fixtures"

# ── Public API round-trip ──────────────────────────────────────────────

test_start "api: parse_string + dump roundtrip"
root=$(json.parse_string '{"a":1,"b":2}')
result=$(json.dump "$root")
json.free "$root"
assert_eq "$result" '{"a":1,"b":2}' "simple object roundtrip"

test_start "api: parse_string array"
root=$(json.parse_string '[1,2,3]')
result=$(json.dump "$root")
json.free "$root"
assert_eq "$result" '[1,2,3]' "array roundtrip"

test_start "api: parse_string nested"
root=$(json.parse_string '{"a":{"b":["c","d"]}}')
result=$(json.dump "$root")
json.free "$root"
assert_eq "$result" '{"a":{"b":["c","d"]}}' "nested roundtrip"

test_start "api: parse_string pretty"
root=$(json.parse_string '{"a":1,"b":2}')
result=$(json.dump "$root" 2)
json.free "$root"
assert_eq "$result" $'{\n  "a": 1,\n  "b": 2\n}' "pretty print"

test_start "api: parse_string empty object"
root=$(json.parse_string '{}')
result=$(json.dump "$root")
json.free "$root"
assert_eq "$result" '{}' "empty object"

test_start "api: parse_string empty array"
root=$(json.parse_string '[]')
result=$(json.dump "$root")
json.free "$root"
assert_eq "$result" '[]' "empty array"

# ── Query ──────────────────────────────────────────────────────────────

test_start "api: query root"
root=$(json.parse_string '{"x":1}')
result=$(json.query "$root" '$')
json.free "$root"
assert_ok "root query returns non-empty" test -n "$result"

test_start "api: query child"
root=$(json.parse_string '{"x":{"y":42}}')
child=$(json.query "$root" '$.x')
result=$(json.dump "$child")
json.free "$root"
assert_eq "$result" '{"y":42}' "query child then dump"

test_start "api: query array index"
root=$(json.parse_string '{"items":[10,20,30]}')
child=$(json.query "$root" '$.items[1]')
result=$(json.dump "$child")
json.free "$root"
assert_eq "$result" "20" "array index query"

test_start "api: query and dump chain"
root=$(json.parse_string '{"users":[{"name":"alice"},{"name":"bob"}]}')
children=$(json.query "$root" '$.users[*].name')
names=""
for node in $children; do
    names="$names$(json.dump "$node") "
done
json.free "$root"
assert_eq "$names" '"alice" "bob" ' "query wildcard then dump each"

# ── Parse file ─────────────────────────────────────────────────────────

test_start "api: parse file"
root=$(json.parse "$SIMPLE_DIR/simple.json")
result=$(json.dump "$root")
json.free "$root"
assert_ok "file parsed and dumped" test -n "$result"

# ── Error handling ─────────────────────────────────────────────────────

test_start "api: last_error on invalid JSON"
root=$(json.parse_string '{invalid}' 2>/dev/null)
code=$(json.last_error)
json.clear_error
# json.last_error returns "code: message" format; extract numeric code
assert_ok "parse failure returns error code" test "${code%%:*}" -gt 0

test_start "api: clear_error resets state"
json.parse_string '{invalid}' 2>/dev/null
code_before=$(json.last_error)
json.clear_error
code_after=$(json.last_error)
# json.last_error returns "code: message" format; extract numeric code
assert_ok "parser error code" test "${code_before%%:*}" -eq 3
assert_eq "$code_after" "0: " "cleared to default"

test_start "api: multiple sequential parse sessions"
root1=$(json.parse_string '{"a":1}')
r1=$(json.dump "$root1")
json.free "$root1"
root2=$(json.parse_string '{"b":2}')
r2=$(json.dump "$root2")
json.free "$root2"
assert_eq "$r1" '{"a":1}' "first parse"
assert_eq "$r2" '{"b":2}' "second parse"

# ── Summary ────────────────────────────────────────────────────────────

test_summary
