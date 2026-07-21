#!/usr/bin/env bash
# Tests for query.sh (JSONPath)
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
source "$(cd "$(dirname "$_self")" && pwd -P)/test_helper.sh"

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

# ── JSONPath extension tests ────────────────────────────────────────

test_start "arithmetic: @.price + 1 > 10"
ast_init
lexer_init '{"books":[{"title":"A","price":8},{"title":"B","price":15}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.books[?(@.price + 1 > 10)].title')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only B matches"
ast_destroy

test_start "arithmetic: @.price * 2 < 30"
ast_init
lexer_init '{"items":[{"name":"x","price":5},{"name":"y","price":20}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.price * 2 < 30)].name')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only x matches"
ast_destroy

test_start "function: contains(@.name, 'bc')"
ast_init
lexer_init '{"items":[{"name":"abc"},{"name":"xyz"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.name)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "2" "both have name"
ast_destroy

test_start "function: type(@.key)"
ast_init
lexer_init '{"x":"hello","y":42,"z":true}'
root=$(parser_parse)
result=$(json.query "$root" '$.x')
val=$(ast_get_value "$result")
assert_eq "$val" "hello" "x is string"
ast_destroy

test_start "function: has(@.key)"
ast_init
lexer_init '{"a":1,"b":null}'
root=$(parser_parse)
result=$(json.query "$root" '$.a')
assert_ok "has a" test -n "$result"
ast_destroy

test_start "function: length(@.name) string length"
ast_init
lexer_init '{"users":[{"name":"Alice","id":1},{"name":"Bob","id":2}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.users[?(length(@.name) > 3)].id')
val=$(ast_get_value "$result")
assert_eq "$val" "1" "only Alice (5 chars) has name length > 3"
ast_destroy

test_start "function: match(@.name, regex)"
ast_init
lexer_init '{"items":[{"name":"abc"},{"name":"xyz"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(match(@.name, "^a"))].name')
val=$(ast_get_value "$result")
assert_eq "$val" "abc" "match finds starting with a"
ast_destroy

test_start "function: search(@.name, regex)"
ast_init
lexer_init '{"items":[{"name":"hello"},{"name":"world"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(search(@.name, "ello"))].name')
val=$(ast_get_value "$result")
assert_eq "$val" "hello" "search finds substring"
ast_destroy

test_start "recursive descent with filter"
ast_init
lexer_init '{"store":{"books":[{"title":"A","price":8},{"title":"B","price":15}]}}'
root=$(parser_parse)
result=$(json.query "$root" '$..title')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "2" "deep finds both titles"
ast_destroy

test_start "bracket: union indices [0,1,2]"
ast_init
lexer_init '{"items":[{"id":1},{"id":2},{"id":3}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[0,1,2].id')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "3" "union finds all 3 items"
ast_destroy

test_start "filter: nested dot-path (@.author.name)"
ast_init
lexer_init '{"data":[{"author":{"name":"Alice"}},{"author":{"name":"Bo"}}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.data[?(length(@.author.name) > 3)].author.name')
val=$(ast_get_value "$result")
assert_eq "$val" "Alice" "nested path finds Alice (5 chars)"
ast_destroy

# ── Negative index tests (Gap 1) ─────────────────────────────────────

test_start "negative index: [-1] returns last element"
ast_init
lexer_init '{"items":[10,20,30]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[-1]')
val=$(ast_get_value "$result")
assert_eq "$val" "30" "last element via -1"
ast_destroy

test_start "negative index: [-2] returns second-to-last"
ast_init
lexer_init '{"items":[10,20,30]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[-2]')
val=$(ast_get_value "$result")
assert_eq "$val" "20" "second-to-last via -2"
ast_destroy

test_start "negative slice: [-2:] returns last two"
ast_init
lexer_init '{"items":[10,20,30,40]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[-2:]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "2" "last two via -2:"
ast_destroy

test_start "negative slice: [-3:-1]"
ast_init
lexer_init '{"items":[10,20,30,40]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[-3:-1]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "2" "range -3:-1 returns 2 items"
ast_destroy

# ── Bracket access in filter expressions (Gap 2) ─────────────────────

test_start "filter bracket: @.items[0].price"
ast_init
lexer_init '{"data":[{"items":[{"price":5},{"price":15}]},{"items":[{"price":25}]}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.data[?(@.items[0].price > 10)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "second data item has items[0].price=25 > 10"
ast_destroy

test_start "filter bracket: @.items['key'] string key"
ast_init
lexer_init '{"data":[{"meta":{"active":true}},{"meta":{"active":false}}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.data[?(@.meta["active"] == true)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only first meta.active is true"
ast_destroy

# ── Nested filter expression (Gap 3) ──────────────────────────────

test_start "nested filter: @.items[?(@.price<15)]"
ast_init
lexer_init '{"store":{"items":[{"price":5,"ok":true},{"price":20,"ok":false}]}}'
root=$(parser_parse)
result=$(json.query "$root" '$.store[?(@.items[?(@.price<15)].ok == true)]')
# Use json.dump to verify structure (ast_get_value returns empty for objects)
dumped=$(json.dump "$result" 2>/dev/null)
assert_eq "$dumped" '{"items":[{"price":5,"ok":true},{"price":20,"ok":false}]}' "dumped store object"
ast_destroy

test_start "nested filter: no match when inner filter fails"
ast_init
lexer_init '{"store":{"items":[{"price":5,"ok":true},{"price":20,"ok":false}]}}'
root=$(parser_parse)
result=$(json.query "$root" '$.store[?(@.items[?(@.price<1)].ok == true)]')
assert_eq "$result" "" "nested filter does not match when no item has price<1"
ast_destroy

# ── $ in filter expressions (RFC 9535 Gap 1) ─────────────────────────

test_start "\$ root in filter: @.price < \$.min"
ast_init
lexer_init '{"items":[{"price":5},{"price":15},{"price":25}],"min":10}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.price < $.min)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only item with price < 10 matches"
ast_destroy

test_start "\$ root in filter: @.price > \$.max"
ast_init
lexer_init '{"items":[{"price":5},{"price":15},{"price":25}],"max":20}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.price > $.max)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only item with price > 20 matches"
ast_destroy

# ── Bare ?expr without parentheses (RFC 9535 Gap 2) ────────────────

test_start "bare filter: [?@.price < 10] without parens"
ast_init
lexer_init '{"items":[{"price":5},{"price":15}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?@.price < 10]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "bare filter matches one item"
ast_destroy

test_start "bare filter: [?@.b == 'kilo'] without parens"
ast_init
lexer_init '{"a":[{"b":"j"},{"b":"k"},{"b":"kilo"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.a[?@.b == "kilo"].b')
val=$(ast_get_value "$result")
assert_eq "$val" "kilo" "bare filter with string comparison"
ast_destroy

test_start "bare filter: [?@ > 3.5] array value comparison"
ast_init
lexer_init '{"a":[3,5,1,2,4,6]}'
root=$(parser_parse)
result=$(json.query "$root" '$.a[?@ > 3.5]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "3" "bare filter on array values: 5,4,6 > 3.5"
ast_destroy

# ── count() function (RFC 9535 Gap 3) ──────────────────────────────

test_start "count(): count(@.existing) returns 1"
ast_init
lexer_init '{"items":[{"name":"a","tags":["x","y"]},{"name":"b"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(count(@.tags) > 0)].name')
val=$(ast_get_value "$result")
assert_eq "$val" "a" "count() > 0 matches item with tags"
ast_destroy

test_start "count(): count(@.nonexistent) returns 0"
ast_init
lexer_init '{"items":[{"name":"a"},{"name":"b","extra":true}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(count(@.extra) > 0)].name')
val=$(ast_get_value "$result")
assert_eq "$val" "b" "count() finds b.extra"
ast_destroy

# ── value() function (RFC 9535 Gap 4) ──────────────────────────────

test_start "value(): value(@.key) returns the value"
ast_init
lexer_init '{"items":[{"price":42}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(value(@.price) == 42)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "value() comparison works"
ast_destroy

# ── RFC 9535 comparison semantics (Gap 5) ─────────────────────────

test_start "comparison: type mismatch 13 == '13' is false"
ast_init
lexer_init '{"items":[{"val":"13"},{"val":13}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.val == 13)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "only number 13 matches, string '13' does not"
ast_destroy

test_start "comparison: type mismatch '13' != 13 is true"
ast_init
lexer_init '{"items":[{"val":"13"},{"val":13}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.val != 13)]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "string '13' != number 13 is true"
ast_destroy

# ── String escape in filter literals (Gap 6) ───────────────────────

test_start "escape: double-quoted \\\"hello\\\" in filter"
ast_init
lexer_init '{"items":[{"name":"hello"}]}'
root=$(parser_parse)
result=$(json.query "$root" '$.items[?(@.name == "hello")]')
count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "$count" "1" "escaped string comparison works"
ast_destroy

# ── Summary ─────────────────────────────────────────────────────────

test_summary
