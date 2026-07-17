#!/usr/bin/env bash
# Tests for lexer.sh
#
# Part of shell-json (https://github.com/quintin/shell-json)

source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/test_helper.sh"

test_lex() {
    lexer_init "$1"
    lexer_advance
    printf '%s|%s' "$_LEXER_CUR_TOKEN" "$_LEXER_CUR_VALUE"
}

# ── Single tokens ────────────────────────────────────────────────────

test_start "lexer: empty object"
result=$(test_lex '{}')
assert_eq "$result" 'LBRACE|' "first token {"

test_start "lexer: object braces"
lexer_init '{}'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "LBRACE" "first {"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "RBRACE" "then }"

test_start "lexer: array brackets"
lexer_init '[]'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "LBRACKET" "["
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "RBRACKET" "]"

test_start "lexer: colon and comma"
lexer_init ':,'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "COLON" ":"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "COMMA" ","

test_start "lexer: true"
lexer_init 'true'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "TRUE" "true"

test_start "lexer: false"
lexer_init 'false'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "FALSE" "false"

test_start "lexer: null"
lexer_init 'null'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "NULL" "null"

# ── String tokens ────────────────────────────────────────────────────

test_start "lexer: string"
lexer_init '"hello"'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "STRING" "string token"
assert_eq "$_LEXER_CUR_VALUE" "hello" "string value"

test_start "lexer: string with escape"
lexer_init '"say \"hello\""'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "STRING" "escaped string token"
assert_eq "$_LEXER_CUR_VALUE" 'say "hello"' "escaped string value"

test_start "lexer: string with unicode"
lexer_init '"A\u0041"'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "STRING" "unicode string token"
assert_eq "$_LEXER_CUR_VALUE" "AA" "unicode string value"

# ── Number tokens ────────────────────────────────────────────────────

test_start "lexer: integer"
lexer_init '42'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "NUMBER" "integer token"
assert_eq "$_LEXER_CUR_VALUE" "42" "integer value"

test_start "lexer: negative"
lexer_init '-3.14'
lexer_advance
assert_eq "$_LEXER_CUR_VALUE" "-3.14" "negative decimal"

test_start "lexer: scientific"
lexer_init '1.5e10'
lexer_advance
assert_eq "$_LEXER_CUR_VALUE" "1.5e10" "sci notation"

test_start "lexer: whitespace"
lexer_init '  {  "a"  :  1  }  '
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "LBRACE" "ws: {"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "STRING" "ws: string"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "COLON"  "ws: :"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "NUMBER"  "ws: number"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "RBRACE"  "ws: }"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "EOF"     "ws: eof"

test_start "lexer: newline in whitespace"
lexer_init $'{\n"a": 1\n}'
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "LBRACE" "nl: {"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "STRING" "nl: string"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "COLON"  "nl: :"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "NUMBER"  "nl: number"
lexer_advance; assert_eq "$_LEXER_CUR_TOKEN" "RBRACE"  "nl: }"

# ── Peek ─────────────────────────────────────────────────────────────

test_start "lexer: peek after advance"
lexer_init '123'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "NUMBER" "advance sets token"
assert_eq "$_LEXER_CUR_VALUE" "123" "advance sets value"
# peek reads current token without scanning (read-only)
lexer_peek
assert_eq "$_LEXER_CUR_TOKEN" "NUMBER" "peek after advance"

# ── Error cases ──────────────────────────────────────────────────────

test_start "lexer: unexpected char"
lexer_init '!'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "ERROR" "unexpected char"

test_start "lexer: unterminated string"
lexer_init '"hello'
lexer_advance
assert_eq "$_LEXER_CUR_TOKEN" "ERROR" "unterminated"

# ── Summary ──────────────────────────────────────────────────────────

test_summary
