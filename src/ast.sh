#!/usr/bin/env bash
# shell-json: ast.sh — File-backed AST node management
#
# Each node is stored as a file in a temp directory.
# Node file format (4 lines, single-line each):
#   t|<type_code>
#   v|<printf '%q'-escaped value or empty>
#   c|<space-separated child IDs or empty>
#   k|<pipe-separated printf '%q'-escaped keys or empty>
#
# Node types: 0=string, 1=number, 2=bool, 3=null, 4=object, 5=array
#
# Part of shell-json (https://github.com/quintin/shell-json)

_AST_DIR=""
_AST_COUNTER_FILE=""
_AST_TMPFILE=""

readonly _AST_T_STRING=0
readonly _AST_T_NUMBER=1
readonly _AST_T_BOOL=2
readonly _AST_T_NULL=3
readonly _AST_T_OBJECT=4
readonly _AST_T_ARRAY=5

# ── Lifecycle ────────────────────────────────────────────────────────

ast_init() {
    _AST_DIR=$(mktemp -d "/tmp/shell-json.XXXXXX")
    _AST_COUNTER_FILE="$_AST_DIR/counter"
    _AST_TMPFILE="$_AST_DIR/.tmp_read"
    mkdir -p "$_AST_DIR/nodes"
    printf '%s\n' "0" > "$_AST_COUNTER_FILE"
    # Save for subshell access: child processes inherit the file via PID
    printf '%s' "$_AST_DIR" > "/tmp/.shell-json-ast-dir.$$"
}

ast_destroy() {
    local pid_file="/tmp/.shell-json-ast-dir.$$"
    if [[ -f "$pid_file" ]]; then
        _AST_DIR=$(cat "$pid_file")
    elif [[ -z "$_AST_DIR" ]]; then
        return 0
    fi
    if [[ -n "$_AST_DIR" && -d "$_AST_DIR" ]]; then
        rm -rf "$_AST_DIR"
    fi
    rm -f "$pid_file"
    _AST_DIR=""
    _AST_COUNTER_FILE=""
    _AST_TMPFILE=""
}

# ── Helpers ──────────────────────────────────────────────────────────

# Get the file path for a node ID
_ast_file() {
    local id=$1 padded
    if [[ -z "$id" ]]; then
        error_set "$_JSON_ERR_IO" "Empty node ID"
        return 1
    fi
    # Guard against multi-line or non-numeric IDs (e.g. from _q_eval_path misuse)
    if [[ "$id" != *[!0-9]* ]]; then
        printf -v padded "%07d" "$id"
    else
        error_set "$_JSON_ERR_IO" "Invalid node ID: $id"
        return 1
    fi
    # Always recover from PID file when available — tracks the most recent
    # ast_init call and survives subshell boundaries. This prevents stale
    # _AST_DIR values inherited from parent scopes from routing to wrong nodes.
    local pid_file="/tmp/.shell-json-ast-dir.$$"
    if [[ -f "$pid_file" ]]; then
        _AST_DIR=$(cat "$pid_file")
    fi
    if [[ -z "$_AST_DIR" || ! -d "$_AST_DIR" ]]; then
        error_set "$_JSON_ERR_IO" "AST directory not found"
        return 1
    fi
    printf '%s' "$_AST_DIR/nodes/$padded"
}

# Base64-decode a string fragment and print it
_ast_decode_b64() {
    if [[ -n "$1" ]]; then
        printf '%s' "$1" | base64 -d 2>/dev/null || true
    fi
}

# Base64-encode a string
_ast_encode_b64() {
    printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64
}

# ── Node CRUD ────────────────────────────────────────────────────────

# Create a node, print its ID on stdout
# Usage: ast_create <type> [<value>]
ast_create() {
    local type=$1 value=${2:-}
    local id padded_id file

    read -r id < "$_AST_COUNTER_FILE"
    id=$((id + 1))
    printf '%s\n' "$id" > "$_AST_COUNTER_FILE"
    printf -v padded_id "%07d" "$id"
    file="$_AST_DIR/nodes/$padded_id"

    {
        printf '%s\n' "t|${type}"
        if [[ -n "$value" ]]; then
            local encoded
            encoded=$(_ast_encode_b64 "$value")
            printf '%s\n' "v|${encoded}"
        else
            printf '%s\n' "v|"
        fi
        printf '%s\n' "c|"
        printf '%s\n' "k|"
    } > "$file"

    printf '%s\n' "$id"
}

# Get the type code of a node (prints integer)
ast_get_type() {
    local file
    file=$(_ast_file "$1")
    local line
    IFS= read -r line < "$file"
    printf '%s' "${line#t|}"
}

# Get the decoded value of a node (prints to stdout)
ast_get_value() {
    local file
    file=$(_ast_file "$1") || return $?
    local line fragment
    {
        IFS= read -r line
        IFS= read -r line
    } < "$file"
    fragment="${line#v|}"
    [[ -n "$fragment" ]] && _ast_decode_b64 "$fragment"
}

# Set / append a child to a node
ast_set_child() {
    local parent_id=$1 child_id=$2
    local file
    file=$(_ast_file "$parent_id")
    local existing
    existing=$(sed -n '3s/^c|//p' "$file")
    if [[ -n "$existing" ]]; then
        sed -i "3s/^c|.*/c|${existing} ${child_id}/" "$file"
    else
        sed -i "3s/^c|.*/c|${child_id}/" "$file"
    fi
}

# Append a child with a key (for object members)
ast_set_child_with_key() {
    local parent_id=$1 child_id=$2 key=$3
    local file
    file=$(_ast_file "$parent_id") || return $?
    local encoded_key

    ast_set_child "$parent_id" "$child_id"

    encoded_key=$(_ast_encode_b64 "$key")
    local existing_keys
    existing_keys=$(sed -n '4s/^k|//p' "$file")
    if [[ -n "$existing_keys" ]]; then
        sed -i "4s/^k|.*/k|${existing_keys}|${encoded_key}/" "$file"
    else
        sed -i "4s/^k|.*/k|${encoded_key}/" "$file"
    fi
}

# Get space-separated children IDs
ast_get_children() {
    local file
    file=$(_ast_file "$1")
    sed -n '3s/^c|//p' "$file"
}

# Get count of children
ast_get_child_count() {
    local children
    children=$(ast_get_children "$1")
    if [[ -n "$children" ]]; then
        printf '%s' "$children" | wc -w | tr -d ' '
    else
        printf '%s' "0"
    fi
}

# Look up a child by key (for objects), prints child ID or empty
ast_child_by_key() {
    # zsh compatibility: 0-indexed arrays + word splitting (like bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local parent_id=$1 search_key=$2
    local file
    file=$(_ast_file "$parent_id") || return $?
    local search_encoded

    search_encoded=$(_ast_encode_b64 "$search_key")

    local keys_line children_line
    keys_line=$(sed -n '4p' "$file")
    children_line=$(sed -n '3p' "$file")

    local keys="${keys_line#k|}"
    local children="${children_line#c|}"

    [[ -z "$keys" ]] && return 1

    local IFS='|'
    read -ra key_arr <<< "$keys"
    unset IFS

    read -ra child_arr <<< "$children"
    local i
    for (( i = 0; i < ${#key_arr[@]}; i++ )); do
        if [[ "${key_arr[$i]}" == "$search_encoded" ]]; then
            printf '%s' "${child_arr[$i]}"
            return 0
        fi
    done

    return 1
}

# Get child by index (for arrays), prints child ID or empty
ast_child_by_index() {
    # zsh compatibility: 0-indexed arrays + word splitting (like bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local parent_id=$1 idx=$2
    local children
    children=$(ast_get_children "$1")
    [[ -z "$children" ]] && return 1
    read -ra arr <<< "$children"
    if (( idx >= 0 && idx < ${#arr[@]} )); then
        printf '%s' "${arr[$idx]}"
        return 0
    fi
    return 1
}

# List all keys (one per line on stdout, decoded)
ast_list_keys() {
    # zsh compatibility: word splitting (like bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions SH_WORD_SPLIT
    fi
    local file
    file=$(_ast_file "$1") || return $?
    local keys_line
    keys_line=$(sed -n '4p' "$file")
    local keys="${keys_line#k|}"
    [[ -z "$keys" ]] && return

    local IFS='|'
    read -ra key_arr <<< "$keys"
    unset IFS

    local key
    for key in "${key_arr[@]}"; do
        [[ -n "$key" ]] && _ast_decode_b64 "$key"
        printf '\n'
    done
}

# Get key at a specific index
ast_get_key_at() {
    # zsh compatibility: 0-indexed arrays + word splitting (like bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local parent_id=$1 idx=$2
    local file
    file=$(_ast_file "$parent_id") || return $?
    local keys_line
    keys_line=$(sed -n '4p' "$file")
    local keys="${keys_line#k|}"
    [[ -z "$keys" ]] && return 1

    local IFS='|'
    read -ra key_arr <<< "$keys"
    unset IFS

    if (( idx >= 0 && idx < ${#key_arr[@]} )); then
        _ast_decode_b64 "${key_arr[$idx]}"
        return 0
    fi
    return 1
}
