#!/usr/bin/env bash
# shell-json: parser.sh — Recursive descent JSON parser
#
# Consumes tokens from the lexer and builds a file-backed AST via ast.sh.
# Grammar (single-token lookahead via lexer_peek):
#
#   value   = object | array | string | number | TRUE | FALSE | NULL
#   object  = '{' ( string ':' value (',' string ':' value)* )? '}'
#   array   = '[' ( value (',' value)* )? ']'
#
# All parse_* functions set _PARSE_RESULT with the node ID.
# No subshells are used for value dispatch.
#
# Lexer contract:
#   lexer_advance() — reads next token, sets _LEXER_CUR_TOKEN/_LEXER_CUR_VALUE
#   lexer_peek() — returns current token type (no scanning)
#
# Part of shell-json (https://github.com/quintin/shell-json)

_PARSE_RESULT=""

# Parse the full token stream into an AST.
# Prints the AST root node ID on stdout.
parser_parse() {
    lexer_advance
    parse_value
    local root_id=$_PARSE_RESULT

    if [[ -n "$root_id" ]]; then
        if [[ "$_LEXER_CUR_TOKEN" != "EOF" && "$_LEXER_CUR_TOKEN" != "ERROR" ]]; then
            error_setf "$_JSON_ERR_PARSER" "Unexpected token after root value at %s" "$(_helper_pos)"
            return 1
        fi
    fi

    printf '%s\n' "$root_id"
}

# ── Value dispatch ───────────────────────────────────────────────────

parse_value() {
    case "$_LEXER_CUR_TOKEN" in
        "LBRACE")   parse_object ;;
        "LBRACKET") parse_array ;;
        "STRING")   parse_string ;;
        "NUMBER")   parse_number ;;
        "TRUE")     parse_true ;;
        "FALSE")    parse_false ;;
        "NULL")     parse_null ;;
        "EOF")
            error_setf "$_JSON_ERR_PARSER" "Unexpected end of input at %s" "$(_helper_pos)"
            return 1 ;;
        *)
            error_setf "$_JSON_ERR_PARSER" "Unexpected token '%s' at %s" "$_LEXER_CUR_TOKEN" "$(_helper_pos)"
            return 1 ;;
    esac
}

# ── Object ───────────────────────────────────────────────────────────

parse_object() {
    lexer_advance  # consume '{'
    local obj_id
    obj_id=$(ast_create "$_AST_T_OBJECT")
    local first=1

    while [[ "$_LEXER_CUR_TOKEN" != "RBRACE" ]]; do
        if (( !first )); then
            if [[ "$_LEXER_CUR_TOKEN" != "COMMA" ]]; then
                error_setf "$_JSON_ERR_PARSER" "Expected ',' or '}' in object at %s" "$(_helper_pos)"
                return 1
            fi
            lexer_advance  # consume ','
        fi
        first=0

        if [[ "$_LEXER_CUR_TOKEN" != "STRING" ]]; then
            error_setf "$_JSON_ERR_PARSER" "Expected string key in object at %s" "$(_helper_pos)"
            return 1
        fi
        local key=$_LEXER_CUR_VALUE
        lexer_advance  # consume key

        if [[ "$_LEXER_CUR_TOKEN" != "COLON" ]]; then
            error_setf "$_JSON_ERR_PARSER" "Expected ':' after object key at %s" "$(_helper_pos)"
            return 1
        fi
        lexer_advance  # consume ':'

        parse_value
        local val_id=$_PARSE_RESULT
        [[ -z "$val_id" ]] && return 1

        ast_set_child_with_key "$obj_id" "$val_id" "$key"
    done

    lexer_advance  # consume '}'
    _PARSE_RESULT=$obj_id
}

# ── Array ────────────────────────────────────────────────────────────

parse_array() {
    lexer_advance  # consume '['
    local arr_id
    arr_id=$(ast_create $_AST_T_ARRAY)
    local first=1

    while [[ "$_LEXER_CUR_TOKEN" != "RBRACKET" ]]; do
        if (( !first )); then
            if [[ "$_LEXER_CUR_TOKEN" != "COMMA" ]]; then
                error_setf "$_JSON_ERR_PARSER" "Expected ',' or ']' in array at %s" "$(_helper_pos)"
                return 1
            fi
            lexer_advance  # consume ','
        fi
        first=0

        parse_value
        local val_id=$_PARSE_RESULT
        [[ -z "$val_id" ]] && return 1

        ast_set_child "$arr_id" "$val_id"
    done

    lexer_advance  # consume ']'
    _PARSE_RESULT=$arr_id
}

# ── Primitives ───────────────────────────────────────────────────────

parse_string() {
    local value=$_LEXER_CUR_VALUE
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_STRING "$value")
}

parse_number() {
    local value=$_LEXER_CUR_VALUE
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_NUMBER "$value")
}

parse_true() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_BOOL "true")
}

parse_false() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_BOOL "false")
}

parse_null() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_NULL "")
}

# ── Helper ───────────────────────────────────────────────────────────

_helper_pos() {
    lexer_get_position
}
