#!/usr/bin/env bash
# shell-json: json.sh — Public API for shell-json library
#
# Sources all modules and provides a clean public interface.
# Usage:
#   source json.sh
#   root=$(json.parse "file.json")
#   json.query "$root" "$.store.book[0].title"
#   json.dump "$root"
#   json.free "$root"
#
# Part of shell-json (https://github.com/quintin/shell-json)

# Double-sourcing guard — skip only if all modules were actually loaded
if [[ -n "$_JSON_LOADED" ]] && type error_clear &>/dev/null && type ast_init &>/dev/null; then
    return
fi

# Source all modules — robust path resolution
# Supports bash (BASH_SOURCE) and zsh (%x prompt expansion)
_self="${BASH_SOURCE[0]:-${(%):-%x}}"
SELF_DIR="$(cd "$(dirname "$_self")" && pwd -P 2>/dev/null)" || SELF_DIR=""
if [[ -z "$SELF_DIR" || ! -f "$SELF_DIR/error.sh" ]]; then
    SELF_DIR="$PWD/src"
    [[ -f "$SELF_DIR/error.sh" ]] || SELF_DIR="$PWD"
fi

source "$SELF_DIR/error.sh"
source "$SELF_DIR/ast.sh"
source "$SELF_DIR/string.sh"
source "$SELF_DIR/number.sh"
source "$SELF_DIR/lexer.sh"
source "$SELF_DIR/parser.sh"
source "$SELF_DIR/object.sh"
source "$SELF_DIR/array.sh"
source "$SELF_DIR/writer.sh"
source "$SELF_DIR/query.sh"

_JSON_LOADED=1

# ── Public API ───────────────────────────────────────────────────────

# Parse a JSON file and return the AST root node ID
# Usage: json.parse <filepath>
json.parse() {
    error_clear
    ast_init

    lexer_init_file "$1" || {
        local rc=$?
        ast_destroy
        return $rc
    }

    local root_id
    root_id=$(parser_parse) || {
        local rc=$?
        ast_destroy
        return $rc
    }

    printf '%s\n' "$root_id"
}

# Parse a JSON string and return the AST root node ID
# Usage: json.parse_string <string>
json.parse_string() {
    error_clear
    ast_init

    lexer_init "$1"

    local root_id
    root_id=$(parser_parse) || {
        local rc=$?
        ast_destroy
        return $rc
    }

    printf '%s\n' "$root_id"
}

# Execute a JSONPath query against an AST
# Usage: json.query <root_id> <path>
# Output: matching node IDs, one per line
json.query() {
    query_execute "$1" "$2"
}

# Serialize an AST node to JSON text
# Usage: json.write <node_id> [indent]
#   indent: 0 (compact, default) or 2 (pretty)
json.write() {
    writer_write "$1" "${2:-0}"
}

# Free an AST and all its resources
# Usage: json.free <root_id>
json.free() {
    ast_destroy
    error_clear
}

# Get the last error message
# Usage: json.last_error
json.last_error() {
    error_get
}

# Clear the error state
# Usage: json.clear_error
json.clear_error() {
    error_clear
}
