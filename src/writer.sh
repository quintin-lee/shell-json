#!/usr/bin/env bash
# shell-json: writer.sh — JSON AST serialization
#
# Walks a file-backed AST and produces compact or indented JSON on stdout.
#
# Part of shell-json (https://github.com/quintin/shell-json)

# Serialize an AST node to JSON text
# Usage: writer_write <node_id> [indent] [depth]
#   indent: 0 for compact (default), 2 for 2-space indent
#   depth: internal use (recursion depth)
writer_write() {
    local node_id=$1 indent=${2:-0} depth=${3:-0}
    local type indent_str

    type=$(ast_get_type "$node_id")

    case "$type" in
        "$_AST_T_STRING")  writer_write_string "$node_id" ;;
        "$_AST_T_NUMBER")  writer_write_number "$node_id" ;;
        "$_AST_T_BOOL")    writer_write_bool "$node_id" ;;
        "$_AST_T_NULL")    printf 'null' ;;
        "$_AST_T_OBJECT")  writer_write_object "$node_id" "$indent" "$depth" ;;
        "$_AST_T_ARRAY")   writer_write_array "$node_id" "$indent" "$depth" ;;
        *)
            error_set "$_JSON_ERR_GENERAL" "Unknown AST node type: $type"
            return 1 ;;
    esac
}

# ── Primitives ───────────────────────────────────────────────────────

writer_write_string() {
    local value
    value=$(ast_get_value "$1")
    string_encode "$value"
}

writer_write_number() {
    local value
    value=$(ast_get_value "$1")
    printf '%s' "$value"
}

writer_write_bool() {
    local value
    value=$(ast_get_value "$1")
    printf '%s' "$value"
}

# ── Object ───────────────────────────────────────────────────────────

writer_write_object() {
    local node_id=$1 indent=$2 depth=$3
    local child_count

    child_count=$(ast_get_child_count "$node_id")
    local inner_indent outer_indent

    printf '{'

    if (( indent > 0 && child_count > 0 )); then
        printf '\n'
        inner_indent=$(printf '%*s' $(( (depth + 1) * indent )) '')
        outer_indent=$(printf '%*s' $((depth * indent)) '')
    fi

    local i child_id key
    for (( i = 0; i < child_count; i++ )); do
        (( indent > 0 )) && printf '%s' "$inner_indent"

        key=$(ast_get_key_at "$node_id" "$i")
        string_encode "$key"
        printf ':'
        (( indent > 0 )) && printf ' '

        child_id=$(ast_child_by_index "$node_id" "$i")
        writer_write "$child_id" "$indent" $((depth + 1))

        if (( i < child_count - 1 )); then
            printf ','
            (( indent > 0 )) && printf '\n'
        fi
    done

    if (( indent > 0 && child_count > 0 )); then
        printf '\n%s' "$outer_indent"
    fi

    printf '}'
}

# ── Array ────────────────────────────────────────────────────────────

writer_write_array() {
    local node_id=$1 indent=$2 depth=$3
    local child_count

    child_count=$(ast_get_child_count "$node_id")
    local inner_indent outer_indent

    printf '['

    if (( indent > 0 && child_count > 0 )); then
        printf '\n'
        inner_indent=$(printf '%*s' $(( (depth + 1) * indent )) '')
        outer_indent=$(printf '%*s' $((depth * indent)) '')
    fi

    local i child_id
    for (( i = 0; i < child_count; i++ )); do
        (( indent > 0 )) && printf '%s' "$inner_indent"

        child_id=$(ast_child_by_index "$node_id" "$i")
        writer_write "$child_id" "$indent" $((depth + 1))

        if (( i < child_count - 1 )); then
            printf ','
            (( indent > 0 )) && printf '\n'
        fi
    done

    if (( indent > 0 && child_count > 0 )); then
        printf '\n%s' "$outer_indent"
    fi

    printf ']'
}
