#!/usr/bin/env bash
# shell-json: error.sh — Error handling framework
# Provides global last-error state with code + message.
#
# Part of shell-json (https://github.com/quintin/shell-json)

_JSON_ERR_CODE=0
_JSON_ERR_MSG=""

# Error codes
readonly _JSON_ERR_GENERAL=1
readonly _JSON_ERR_LEXER=2
readonly _JSON_ERR_PARSER=3
readonly _JSON_ERR_TYPE=4
readonly _JSON_ERR_KEY_NOT_FOUND=5
readonly _JSON_ERR_INDEX_OOB=6
readonly _JSON_ERR_PATH_SYNTAX=7
readonly _JSON_ERR_IO=8

# Set the error state
# Usage: error_set <code> <message>
error_set() {
    _JSON_ERR_CODE=$1
    _JSON_ERR_MSG=$2
}

# Get the current error as "code: message"
error_get() {
    echo "$_JSON_ERR_CODE: $_JSON_ERR_MSG"
}

# Clear the error state
error_clear() {
    _JSON_ERR_CODE=0
    _JSON_ERR_MSG=""
}

# Get the error code
error_code() {
    echo "$_JSON_ERR_CODE"
}

# Get the error message
error_msg() {
    echo "$_JSON_ERR_MSG"
}
