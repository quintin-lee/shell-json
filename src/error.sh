#!/usr/bin/env bash
# shell-json: error.sh — Error handling framework
# Provides global last-error state with code + message, optional location,
# and chain support for nested operations.
#
# Part of shell-json (https://github.com/quintin/shell-json)

_JSON_ERR_CODE=0
_JSON_ERR_MSG=""
_JSON_ERR_LOC=""
_JSON_ERR_CHAIN=""

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
        printf '%d|%s|%s|%s\n' "$1" "$2" "${_JSON_ERR_LOC:-}" "${_JSON_ERR_CHAIN:-}" > "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
}

# Set the error state with a formatted message (printf-style)
# Usage: error_setf <code> <format_string> [args...]
error_setf() {
    local code=$1
    shift
    error_set "$code" "$(printf "$1" "${@:2}")"
}

# Set location info on the current error
# Usage: error_location <file>:<line> or <description>
error_location() {
    _JSON_ERR_LOC="$1"
    if [[ -n "$_JSON_ERR_MSG" ]]; then
        error_set "$_JSON_ERR_CODE" "$_JSON_ERR_MSG"
    fi
}

# Append to the error chain
# Usage: error_chain <message>
error_chain() {
    if [[ -n "$_JSON_ERR_CHAIN" ]]; then
        _JSON_ERR_CHAIN="${_JSON_ERR_CHAIN} -> $1"
    else
        _JSON_ERR_CHAIN="$1"
    fi
    if [[ -n "$_JSON_ERR_MSG" ]]; then
        error_set "$_JSON_ERR_CODE" "$_JSON_ERR_MSG"
    fi
}

# Get the current error as "code: message"
error_get() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_CODE: $_JSON_ERR_MSG"
}

# Clear the error state
error_clear() {
    _JSON_ERR_CODE=0
    _JSON_ERR_MSG=""
    _JSON_ERR_LOC=""
    _JSON_ERR_CHAIN=""
    rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
}

# Get the error code
error_code() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r _JSON_ERR_CODE _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_CODE"
}

# Get the error message
error_msg() {
    # Recover error from PID file if lost across subshell boundary
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_MSG"
}

# Get the error location
error_loc() {
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_LOC"
}

# Get the error chain
error_chain_get() {
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r saved _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        _JSON_ERR_CODE=$saved
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    echo "$_JSON_ERR_CHAIN"
}

# Get the full error as JSON
error_get_json() {
    if [[ "$_JSON_ERR_CODE" -eq 0 ]] && [[ -f "/tmp/.shell-json-err.$$" ]]; then
        local saved
        IFS='|' read -r _JSON_ERR_CODE _JSON_ERR_MSG _JSON_ERR_LOC _JSON_ERR_CHAIN < "/tmp/.shell-json-err.$$" 2>/dev/null || true
        rm -f "/tmp/.shell-json-err.$$" 2>/dev/null || true
    fi
    # Escape special characters for JSON
    local msg="${_JSON_ERR_MSG//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    msg="${msg//$'\n'/\\n}"
    msg="${msg//$'\t'/\\t}"
    local loc="${_JSON_ERR_LOC//\\/\\\\}"
    loc="${loc//\"/\\\"}"
    local chain="${_JSON_ERR_CHAIN//\\/\\\\}"
    chain="${chain//\"/\\\"}"
    printf '{"code":%d,"message":"%s","location":"%s","chain":"%s"}' \
        "$_JSON_ERR_CODE" "$msg" "$loc" "$chain"
}
