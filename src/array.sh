#!/usr/bin/env bash
# shell-json: array.sh — JSON array helper functions
#
# Part of shell-json (https://github.com/quintin/shell-json)

# Get the element at an index in an array (prints child node ID)
# Usage: array_get <node_id> <index>
# Returns: 0 on success, 1 if index out of bounds
array_get() {
    local node_id=$1 idx=$2
    local type

    type=$(ast_get_type "$node_id")
    if [[ "$type" != "$_AST_T_ARRAY" ]]; then
        error_set "$_JSON_ERR_TYPE" "Not an array node"
        return 1
    fi

    ast_child_by_index "$node_id" "$idx" || {
        error_set "$_JSON_ERR_INDEX_OOB" "Index out of bounds: $idx"
        return 1
    }
}

# Get the number of elements in an array
# Usage: array_length <node_id>
array_length() {
    local node_id=$1
    ast_get_child_count "$node_id"
}
