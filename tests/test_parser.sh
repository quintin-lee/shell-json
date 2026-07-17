#!/usr/bin/env bash
# Tests for parser + writer (round-trip)
#
# Part of shell-json (https://github.com/quintin/shell-json)

source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/test_helper.sh"

SIMPLE_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/fixtures"

# Helper: parse a JSON string, write it compact, return result
roundtrip() {
    local input="$1"
    local root

    error_clear
    ast_init
    lexer_init "$input"
    root=$(parser_parse) || { ast_destroy; return 1; }
    writer_write "$root" 0
    ast_destroy
}

pretty_roundtrip() {
    local input="$1"
    local root

    error_clear
    ast_init
    lexer_init "$input"
    root=$(parser_parse) || { ast_destroy; return 1; }
    writer_write "$root" 2
    ast_destroy
}

# ── Basic values ─────────────────────────────────────────────────────

test_start "parse: null"
result=$(roundtrip 'null')
assert_eq "$result" "null" "null"

test_start "parse: true"
result=$(roundtrip 'true')
assert_eq "$result" "true" "true"

test_start "parse: false"
result=$(roundtrip 'false')
assert_eq "$result" "false" "false"

test_start "parse: number integer"
result=$(roundtrip '42')
assert_eq "$result" "42" "int"

test_start "parse: number negative"
result=$(roundtrip '-42')
assert_eq "$result" "-42" "negative"

test_start "parse: number decimal"
result=$(roundtrip '3.14')
assert_eq "$result" "3.14" "decimal"

test_start "parse: number sci"
result=$(roundtrip '1e10')
assert_eq "$result" "1e10" "sci"

test_start "parse: string"
result=$(roundtrip '"hello"')
assert_eq "$result" '"hello"' "string"

test_start "parse: string with escapes"
result=$(roundtrip '"hello\nworld"')
assert_eq "$result" '"hello\nworld"' "escaped string"

# ── Array ────────────────────────────────────────────────────────────

test_start "parse: empty array"
result=$(roundtrip '[]')
assert_eq "$result" "[]" "empty array"

test_start "parse: array of numbers"
result=$(roundtrip '[1,2,3]')
assert_eq "$result" "[1,2,3]" "number array"

test_start "parse: array of strings"
result=$(roundtrip '["a","b","c"]')
assert_eq "$result" '["a","b","c"]' "string array"

test_start "parse: nested array"
result=$(roundtrip '[[1,2],[3,4]]')
assert_eq "$result" "[[1,2],[3,4]]" "nested array"

# ── Object ───────────────────────────────────────────────────────────

test_start "parse: empty object"
result=$(roundtrip '{}')
assert_eq "$result" "{}" "empty object"

test_start "parse: simple object"
result=$(roundtrip '{"a":1}')
assert_eq "$result" '{"a":1}' "simple object"

test_start "parse: object with multiple keys"
result=$(roundtrip '{"a":1,"b":2}')
assert_eq "$result" '{"a":1,"b":2}' "multi key object"

test_start "parse: nested object"
result=$(roundtrip '{"a":{"b":2}}')
assert_eq "$result" '{"a":{"b":2}}' "nested object"

# ── Complex ──────────────────────────────────────────────────────────

test_start "parse: object with array"
result=$(roundtrip '{"menu":{"items":[1,2,3]}}')
assert_eq "$result" '{"menu":{"items":[1,2,3]}}' "obj with array"

test_start "parse: mixed types"
result=$(roundtrip '{"str":"hello","num":42,"arr":[1,2],"obj":{"x":1},"flag":true,"nothing":null}')
assert_eq "$result" '{"str":"hello","num":42,"arr":[1,2],"obj":{"x":1},"flag":true,"nothing":null}' "mixed types"

# ── Pretty-print ─────────────────────────────────────────────────────

test_start "pretty: simple object"
result=$(pretty_roundtrip '{"a":1}')
assert_eq "$result" $'{\n  "a": 1\n}' "pretty object"

test_start "pretty: array"
result=$(pretty_roundtrip '[1,2]')
assert_eq "$result" $'[\n  1,\n  2\n]' "pretty array"

# ── File input ───────────────────────────────────────────────────────

test_start "parse: from file"
error_clear
ast_init
lexer_init_file "$SIMPLE_DIR/complex.json"
root=$(parser_parse)
result=$(writer_write "$root" 0)
ast_destroy
assert_ok "complex.json parsed" test -n "$root"

# ── Error handling ───────────────────────────────────────────────────

test_start "parse: invalid JSON"
error_clear
ast_init
lexer_init '{invalid}'
result=$(parser_parse 2>/dev/null)
assert_eq "$result" "" "invalid json returns empty"
ast_destroy

# ── Summary ──────────────────────────────────────────────────────────

test_summary
