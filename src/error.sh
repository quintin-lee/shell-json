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
    # Persist for cross-subshell recovery — $$ is the original shell's PID
    # from any nested $(...) depth, so parent can read it back
    if [[ "$1" != "0" ]]; then
        printf '%d|%s\n' "$1" "$2" > "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
}

# Get the current error as "code: message"
error_get() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_CODE: $_JSON_ERR_MSG"
}

# Clear the error state
error_clear() {
    _JSON_ERR_CODE=0
    _JSON_ERR_MSG=""
    rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
}

# Get the error code
error_code() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r _JSON_ERR_CODE _JSON_ERR_MSG < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_CODE"
}

# Get the error message
error_msg() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_MSG"
}
