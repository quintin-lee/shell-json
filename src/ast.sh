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

# Sync AST namespace from PID file so new node allocations go into the
# same tree as an existing AST. Safe to call even when no AST has been
# initialized yet (no-op).
ast_sync() {
    local pid_file="/tmp/.shell-json-ast-dir.$$"
    if [[ -f "$pid_file" ]]; then
        _AST_DIR=$(cat "$pid_file")
        _AST_COUNTER_FILE="$_AST_DIR/counter"
        _AST_TMPFILE="$_AST_DIR/.tmp_read"
    fi
}

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

# ── Bulk node reader ─────────────────────────────────────────────────

# Read all 4 lines of a node file in one file open.
# Sets _AST_R_T (type), _AST_R_V (value-encoded), _AST_R_C (children),
# _AST_R_K (keys) variables with their prefix headers.
# Returns 0 on success, 1 if node file does not exist.
_ast_read_node() {
    local id=$1 padded file
    printf -v padded "%07d" "$id"
    local pid_file="/tmp/.shell-json-ast-dir.$$"
    if [[ -f "$pid_file" ]]; then
        _AST_DIR=$(cat "$pid_file")
    fi
    file="$_AST_DIR/nodes/$padded"
    [[ -f "$file" ]] || return 1
    { read -r _AST_R_T && read -r _AST_R_V && read -r _AST_R_C && read -r _AST_R_K; } < "$file"
}

# Write all 4 lines back to a node file (after _ast_read_node + modifications)
_ast_write_node() {
    local id=$1 padded file
    printf -v padded "%07d" "$id"
    local pid_file="/tmp/.shell-json-ast-dir.$$"
    if [[ -f "$pid_file" ]]; then
        _AST_DIR=$(cat "$pid_file")
    fi
    file="$_AST_DIR/nodes/$padded"
    {
        printf '%s\n' "$_AST_R_T"
        printf '%s\n' "$_AST_R_V"
        printf '%s\n' "$_AST_R_C"
        printf '%s\n' "$_AST_R_K"
    } > "$file"
}

# ── Read accessors ──────────────────────────────────────────────────

# Get the type code of a node (prints integer)
ast_get_type() {
    _ast_read_node "$1" || return 1
    printf '%s' "${_AST_R_T#t|}"
}

# Get the decoded value of a node (prints to stdout)
ast_get_value() {
    _ast_read_node "$1" || return 1
    local fragment="${_AST_R_V#v|}"
    [[ -n "$fragment" ]] && _ast_decode_b64 "$fragment"
}

# Get space-separated children IDs
ast_get_children() {
    _ast_read_node "$1" || return 1
    printf '%s' "${_AST_R_C#c|}"
}

# Get count of children
ast_get_child_count() {
    _ast_read_node "$1" || return 1
    local children="${_AST_R_C#c|}"
    if [[ -n "$children" ]]; then
        local __c=0
        # shellcheck disable=SC2086
        for _ in $children; do __c=$((__c+1)); done
        printf '%s' "$__c"
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
    local search_encoded
    search_encoded=$(_ast_encode_b64 "$search_key")
    _ast_read_node "$parent_id" || return 1
    local keys="${_AST_R_K#k|}"
    local children="${_AST_R_C#c|}"
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
    _ast_read_node "$parent_id" || return 1
    local children="${_AST_R_C#c|}"
    [[ -z "$children" ]] && return 1
    read -ra arr <<< "$children"
    # Normalize negative index
    if (( idx < 0 )); then
        idx=$(( ${#arr[@]} + idx ))
    fi
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
    _ast_read_node "$1" || return 1
    local keys="${_AST_R_K#k|}"
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
    _ast_read_node "$parent_id" || return 1
    local keys="${_AST_R_K#k|}"
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

# ── Write accessors ─────────────────────────────────────────────────

# Set / append a child to a node
ast_set_child() {
    local parent_id=$1 child_id=$2
    _ast_read_node "$parent_id" || return 1
    local existing="${_AST_R_C#c|}"
    if [[ -n "$existing" ]]; then
        _AST_R_C="c|${existing} ${child_id}"
    else
        _AST_R_C="c|${child_id}"
    fi
    _ast_write_node "$parent_id"
}

    # Append a child with a key (for object members)
ast_set_child_with_key() {
    local parent_id=$1 child_id=$2 key=$3
    local encoded_key
    _ast_read_node "$parent_id" || return 1

    # Modify children line
    local existing="${_AST_R_C#c|}"
    if [[ -n "$existing" ]]; then
        _AST_R_C="c|${existing} ${child_id}"
    else
        _AST_R_C="c|${child_id}"
    fi

    # Modify keys line
    encoded_key=$(_ast_encode_b64 "$key")
    local existing_keys="${_AST_R_K#k|}"
    if [[ -n "$existing_keys" ]]; then
        _AST_R_K="k|${existing_keys}|${encoded_key}"
    else
        _AST_R_K="k|${encoded_key}"
    fi

    _ast_write_node "$parent_id"
}

# ── Mutation primitives ──────────────────────────────────────────────

# Set the value of a node (updates the value line in node file)
# Usage: ast_set_value <node_id> <new_value>
ast_set_value() {
    local id=$1 new_value=$2
    _ast_read_node "$id" || return 1
    local encoded
    if [[ -n "$new_value" ]]; then
        encoded=$(_ast_encode_b64 "$new_value")
        _AST_R_V="v|${encoded}"
    else
        _AST_R_V="v|"
    fi
    _ast_write_node "$id"
}

# Replace a child in the parent's children list (preserving position)
# Usage: ast_replace_child <parent_id> <old_child_id> <new_child_id>
ast_replace_child() {
    local parent_id=$1 old_id=$2 new_id=$3
    _ast_read_node "$parent_id" || return 1
    local children="${_AST_R_C#c|}"
    local new_children=""
    local found=0
    local child
    for child in $children; do
        if [[ "$child" == "$old_id" ]]; then
            if [[ -n "$new_children" ]]; then
                new_children="$new_children $new_id"
            else
                new_children="$new_id"
            fi
            found=1
        else
            if [[ -n "$new_children" ]]; then
                new_children="$new_children $child"
            else
                new_children="$child"
            fi
        fi
    done
    if (( found )); then
        _AST_R_C="c|${new_children}"
        _ast_write_node "$parent_id"
        return 0
    fi
    return 1
}

# Remove a child from a parent (removes from children and keys lists)
# Usage: ast_remove_child <parent_id> <child_id>
ast_remove_child() {
    local parent_id=$1 target_id=$2
    _ast_read_node "$parent_id" || return 1
    local children="${_AST_R_C#c|}"
    local keys="${_AST_R_K#k|}"
    local new_children=""
    local new_keys=""
    local found=0

    read -ra child_arr <<< "$children"
    local IFS='|'
    read -ra key_arr <<< "$keys"
    unset IFS

    local i
    for (( i = 0; i < ${#child_arr[@]}; i++ )); do
        if [[ "${child_arr[$i]}" == "$target_id" ]]; then
            found=1
        else
            if [[ -n "$new_children" ]]; then
                new_children="$new_children ${child_arr[$i]}"
            else
                new_children="${child_arr[$i]}"
            fi
            if (( i < ${#key_arr[@]} )) && [[ -n "${key_arr[$i]}" ]]; then
                if [[ -n "$new_keys" ]]; then
                    new_keys="$new_keys|${key_arr[$i]}"
                else
                    new_keys="${key_arr[$i]}"
                fi
            fi
        fi
    done

    if (( found )); then
        _AST_R_C="c|${new_children}"
        _AST_R_K="k|${new_keys}"
        _ast_write_node "$parent_id"
        return 0
    fi
    return 1
}

# Recursively delete a node and all its descendants
# Usage: ast_delete_recursive <node_id>
ast_delete_recursive() {
    local id=$1 padded
    local children
    children=$(ast_get_children "$id")
    local child
    for child in $children; do
        ast_delete_recursive "$child"
    done
    printf -v padded "%07d" "$id"
    rm -f "$_AST_DIR/nodes/$padded"
}

# Allocate and return the next node ID
# Usage: ast_next_id
ast_next_id() {
    local id
    read -r id < "$_AST_COUNTER_FILE"
    id=$((id + 1))
    printf '%s\n' "$id" > "$_AST_COUNTER_FILE"
    printf '%s\n' "$id"
}
