#!/usr/bin/env bash
# Tests for string.sh
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
source "$(cd "$(dirname "$_self")" && pwd -P)/test_helper.sh"

# ── string_encode ────────────────────────────────────────────────────

test_start "string_encode: basic string"
result=$(string_encode "hello")
assert_eq "$result" '"hello"' "basic string"

test_start "string_encode: with quotes"
result=$(string_encode 'say "hello"')
assert_eq "$result" '"say \"hello\""' "quoted string"

test_start "string_encode: with backslash"
result=$(string_encode 'a\b')
assert_eq "$result" '"a\\b"' "backslash"

test_start "string_encode: with newline"
result=$(string_encode $'hello\nworld')
assert_eq "$result" '"hello\nworld"' "newline"

test_start "string_encode: with tab"
result=$(string_encode $'hello\tworld')
assert_eq "$result" '"hello\tworld"' "tab"

test_start "string_encode: control char (SOH)"
result=$(string_encode $'a\x01b')
assert_eq "$result" '"a\u0001b"' "SOH"

test_start "string_encode: empty string"
result=$(string_encode "")
assert_eq "$result" '""' "empty"

test_start "string_encode: unicode"
result=$(string_encode $'\u00e9')
assert_eq "$result" '"é"' "e-acute"

# ── string_decode ────────────────────────────────────────────────────

test_start "string_decode: basic"
result=$(string_decode "hello")
assert_eq "$result" "hello" "basic"

test_start "string_decode: quotes"
result=$(string_decode 'say \"hello\"')
assert_eq "$result" 'say "hello"' "unescaped quotes"

test_start "string_decode: backslash"
result=$(string_decode 'a\\b')
assert_eq "$result" 'a\b' "unescaped backslash"

test_start "string_decode: newline"
result=$(string_decode 'hello\nworld')
assert_eq "$result" $'hello\nworld' "unescaped newline"

test_start "string_decode: tab"
result=$(string_decode 'hello\tworld')
assert_eq "$result" $'hello\tworld' "unescaped tab"

test_start "string_decode: slash"
result=$(string_decode 'hello\/world')
assert_eq "$result" 'hello/world' "unescaped slash"

test_start "string_decode: unicode \\u0041"
result=$(string_decode '\u0041')
assert_eq "$result" 'A' "unicode A"

test_start "string_decode: unicode \\u00e9"
result=$(string_decode '\u00e9')
# This produces UTF-8 for é (U+00E9) which is \xC3\xA9
assert_eq "$result" $'\u00e9' "unicode e-acute"

test_start "string_decode: empty"
result=$(string_decode "")
assert_eq "$result" "" "empty"

test_start "string_decode: no escapes"
result=$(string_decode "simple text")
assert_eq "$result" "simple text" "plain"

# ── Round-trip ───────────────────────────────────────────────────────

test_start "string round-trip: basic"
original="hello world"
encoded=$(string_encode "$original")
decoded=$(string_decode "${encoded:1:-1}")
assert_eq "$decoded" "$original" "round-trip basic"

test_start "string round-trip: special chars"
original=$'hello\n\t"world"\\'
encoded=$(string_encode "$original")
decoded=$(string_decode "${encoded:1:-1}")
assert_eq "$decoded" "$original" "round-trip special"

# ── Summary ──────────────────────────────────────────────────────────

test_summary
