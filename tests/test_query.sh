#!/usr/bin/env bash
# Tests for query.sh (JSONPath)
#
# Part of shell-json (https://github.com/quintin/shell-json)

source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/test_helper.sh"

# Global for query test AST
_QT_ROOT=""

# Build a store-like AST and store root in _QT_ROOT
build_store_ast() {
    ast_init
    local store obj book1 book2 books title1 title2 price1 price2 author1

    book1=$(ast_create $_AST_T_OBJECT)
    title1=$(ast_create $_AST_T_STRING "Sayings of the Century")
    price1=$(ast_create $_AST_T_NUMBER "8.95")
    ast_set_child_with_key "$book1" "$title1" "title"
    ast_set_child_with_key "$book1" "$price1" "price"

    book2=$(ast_create $_AST_T_OBJECT)
    title2=$(ast_create $_AST_T_STRING "Sword of Honour")
    price2=$(ast_create $_AST_T_NUMBER "12.99")
    author1=$(ast_create $_AST_T_STRING "Evelyn Waugh")
    ast_set_child_with_key "$book2" "$title2" "title"
    ast_set_child_with_key "$book2" "$price2" "price"
    ast_set_child_with_key "$book2" "$author1" "author"

    books=$(ast_create $_AST_T_ARRAY)
    ast_set_child "$books" "$book1"
    ast_set_child "$books" "$book2"

    obj=$(ast_create $_AST_T_OBJECT)
    ast_set_child_with_key "$obj" "$books" "books"

    store=$(ast_create $_AST_T_OBJECT)
    ast_set_child_with_key "$store" "$obj" "store"

    _QT_ROOT=$store
}

# ── Path tokenizer tests ────────────────────────────────────────────

test_start "query path: root token"
_q_tokenize_path "\$"
assert_eq "${_Q_TT[0]}" "ROOT" "root token"

test_start "query path: dot access"
_q_tokenize_path "\$.store"
assert_eq "${_Q_TT[0]}" "ROOT" "root"
assert_eq "${_Q_TT[1]}" "DOT" "dot"
assert_eq "${_Q_TT[2]}" "IDENT" "ident"
assert_eq "${_Q_TV[2]}" "store" "name"

test_start "query path: bracket access"
_q_tokenize_path "\$['key']"
assert_eq "${_Q_TT[1]}" "LBRACKET" "lb"
assert_eq "${_Q_TT[2]}" "STRING" "string"
assert_eq "${_Q_TV[2]}" "key" "string val"

test_start "query path: recursive descent"
_q_tokenize_path "\$..author"
assert_eq "${_Q_TT[1]}" "DOTDOT" "dotdot"
assert_eq "${_Q_TT[2]}" "IDENT" "ident"
assert_eq "${_Q_TV[2]}" "author" "author"

test_start "query path: number index"
_q_tokenize_path "\$[0]"
assert_eq "${_Q_TT[1]}" "LBRACKET"
assert_eq "${_Q_TT[2]}" "NUMBER"
assert_eq "${_Q_TV[2]}" "0"

test_start "query path: wildcard"
_q_tokenize_path "\$[*]"
assert_eq "${_Q_TT[1]}" "LBRACKET"
assert_eq "${_Q_TT[2]}" "STAR"

test_start "query path: slice tokens"
_q_tokenize_path "\$[1:3]"
assert_eq "${_Q_TT[1]}" "LBRACKET"
assert_eq "${_Q_TT[2]}" "NUMBER"
assert_eq "${_Q_TV[2]}" "1"
assert_eq "${_Q_TT[3]}" "COLON"
assert_eq "${_Q_TT[4]}" "NUMBER"
assert_eq "${_Q_TV[4]}" "3"

# ── Segment parsing tests ───────────────────────────────────────────

test_start "parse segments: simple path"
_q_parse_path "\$.store.book"
found_store=0 found_book=0
for seg in "${_Q_SEGMENTS[@]}"; do
    [[ "$seg" == "key:store" ]] && found_store=1
    [[ "$seg" == "key:book" ]] && found_book=1
done
assert_eq "$found_store" "1" "store segment"
assert_eq "$found_book" "1" "book segment"

test_start "parse segments: bracket path"
_q_parse_path "\$['store']['book']"
found_store=0
for seg in "${_Q_SEGMENTS[@]}"; do
    [[ "$seg" == "key:store" ]] && found_store=1
done
assert_eq "$found_store" "1" "bracket store"

test_start "parse segments: wildcard"
_q_parse_path "\$[*]"
found_wild=0
for seg in "${_Q_SEGMENTS[@]}"; do
    [[ "$seg" == "wild:" ]] && found_wild=1
done
assert_eq "$found_wild" "1" "wildcard segment"

test_start "parse segments: recursive descent"
_q_parse_path "\$..author"
found_deep=0
for seg in "${_Q_SEGMENTS[@]}"; do
    [[ "$seg" == "deep:author" ]] && found_deep=1
done
assert_eq "$found_deep" "1" "deep segment"

test_start "parse segments: slice"
_q_parse_path "\$[1:3]"
found_slice=0
for seg in "${_Q_SEGMENTS[@]}"; do
    [[ "$seg" == "slice:1:3:1" ]] && found_slice=1
done
assert_eq "$found_slice" "1" "slice segment"

# ── Query execution tests ──────────────────────────────────────────

build_store_ast

test_start "query exec: root node"
result=$(query_execute "$_QT_ROOT" "\$")
assert_ok "root returns something" test -n "$result"

test_start "query exec: simple key"
result=$(query_execute "$_QT_ROOT" "\$.store")
assert_ok "store key exists" test -n "$result"

test_start "query exec: nested key"
result=$(query_execute "$_QT_ROOT" "\$.store.books")
assert_ok "books array exists" test -n "$result"

test_start "query exec: wildcard on array"
result=$(query_execute "$_QT_ROOT" "\$.store.books[*]")
lines=$(printf '%s' "$result" | grep -c .)
assert_eq "$lines" "2" "wildcard on 2-book array"

test_start "query exec: recursive descent"
result=$(query_execute "$_QT_ROOT" "\$..title")
lines=$(printf '%s' "$result" | grep -c .)
assert_eq "$lines" "2" "deep finds 2 titles"

test_start "query exec: index access"
result=$(query_execute "$_QT_ROOT" "\$.store.books[0]")
assert_ok "first book exists" test -n "$result"

test_start "query exec: bracket notation"
result=$(query_execute "$_QT_ROOT" "\$['store']['books']")
assert_ok "bracket access works" test -n "$result"

# Clean up this AST
ast_destroy

# ── Query on parsed JSON ───────────────────────────────────────────

test_start "query exec: from parsed json"
ast_init
lexer_init '{"x":{"y":[1,2,3]}}'
root=$(parser_parse)
result=$(query_execute "$root" "\$.x.y[2]")
val=$(ast_get_value "$result")
assert_eq "$val" "3" "value at path is 3"
ast_destroy

# ── Summary ─────────────────────────────────────────────────────────

test_summary
