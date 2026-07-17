#!/usr/bin/env bash
# shell-json: object.sh — JSON object helper functions
#
# Part of shell-json (https://github.com/quintin/shell-json)

# Get the value of a key in an object (prints child node ID)
# Usage: object_get <node_id> <key>
# Returns: 0 on success, 1 if key not found
object_get() {
    local node_id=$1 key=$2
    local type

    type=$(ast_get_type "$node_id")
    if [[ "$type" != "$_AST_T_OBJECT" ]]; then
        error_set "$_JSON_ERR_TYPE" "Not an object node"
        return 1
    fi

    ast_child_by_key "$node_id" "$key" || {
        error_set "$_JSON_ERR_KEY_NOT_FOUND" "Key not found: $key"
        return 1
    }
}

# List all keys in an object (one per line on stdout)
# Usage: object_keys <node_id>
object_keys() {
    local node_id=$1

    ast_list_keys "$node_id"
}

# Check if a key exists in an object
# Usage: object_has <node_id> <key>
# Returns: 0 if found, 1 if not found or not an object
object_has() {
    local node_id=$1 key=$2
    local type

    type=$(ast_get_type "$node_id")
    [[ "$type" != "$_AST_T_OBJECT" ]] && return 1

    ast_child_by_key "$node_id" "$key" > /dev/null 2>&1
}

# Get the number of key-value pairs in an object
# Usage: object_length <node_id>
object_length() {
    local node_id=$1
    ast_get_child_count "$node_id"
}
