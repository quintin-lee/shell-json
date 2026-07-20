#!/usr/bin/env bash
# shell-json: lexer.sh — Character-level JSON tokenizer
#
# Reads JSON text and emits a sequence of tokens.  The lexer maintains
# position, line/col counters, and a single-token lookahead for peek.
#
# Token types produced (stored in _LEXER_CUR_TOKEN):
#   STRING  NUMBER  TRUE  FALSE  NULL
#   LBRACE  RBRACE  LBRACKET  RBRACKET  COLON  COMMA
#   EOF  ERROR
#
# Token value (when applicable) is stored in _LEXER_CUR_VALUE.
#
# Part of shell-json (https://github.com/quintin/shell-json)

# ── State ────────────────────────────────────────────────────────────

_LEXER_INPUT=""
_LEXER_POS=0
_LEXER_LEN=0
_LEXER_LINE=1
_LEXER_COL=1
_LEXER_CUR_TOKEN=""
_LEXER_CUR_VALUE=""

# ── Initialisation ───────────────────────────────────────────────────

# Initialise the lexer with a JSON string
# Usage: lexer_init <string>
lexer_init() {
    _LEXER_INPUT="$1"
    _LEXER_POS=0
    _LEXER_LEN=${#1}
    _LEXER_LINE=1
    _LEXER_COL=1
    _LEXER_CUR_TOKEN=""
    _LEXER_CUR_VALUE=""
}

# Initialise from a file
# Usage: lexer_init_file <path>
lexer_init_file() {
    local content
    content=$(< "$1") || {
        error_set "$_JSON_ERR_IO" "Cannot read file: $1"
        return 1
    }
    lexer_init "$content"
}

# ── Token access ─────────────────────────────────────────────────────

# Advance to the next token from the input.
# Sets _LEXER_CUR_TOKEN and _LEXER_CUR_VALUE.
lexer_advance() {
    _lexer_scan
}

# Return the current token type (set by last lexer_advance) without consuming.
# This just reads _LEXER_CUR_TOKEN — no actual scanning happens.
lexer_peek() {
    printf '%s' "$_LEXER_CUR_TOKEN"
}

# ── Position ─────────────────────────────────────────────────────────

lexer_get_position() {
    printf '%d:%d' "$_LEXER_LINE" "$_LEXER_COL"
}

# ── Internal scan ────────────────────────────────────────────────────

_lexer_skip_whitespace() {
    local c
    while (( _LEXER_POS < _LEXER_LEN )); do
        c="${_LEXER_INPUT:$_LEXER_POS:1}"
        case "$c" in
            $' ')
                _LEXER_POS=$((_LEXER_POS+1))
                _LEXER_COL=$((_LEXER_COL+1)) ;;
            $'\t')
                _LEXER_POS=$((_LEXER_POS+1))
                _LEXER_COL=$((_LEXER_COL+1)) ;;
            $'\n')
                _LEXER_POS=$((_LEXER_POS+1))
                _LEXER_LINE=$((_LEXER_LINE+1))
                _LEXER_COL=1 ;;
            $'\r')
                _LEXER_POS=$((_LEXER_POS+1))
                _LEXER_COL=1 ;;
            *) break ;;
        esac
    done
}

_lexer_scan() {
    _lexer_skip_whitespace

    if (( _LEXER_POS >= _LEXER_LEN )); then
        _LEXER_CUR_TOKEN="EOF"
        _LEXER_CUR_VALUE=""
        return
    fi

    local c="${_LEXER_INPUT:$_LEXER_POS:1}"

    case "$c" in
        '{') _LEXER_CUR_TOKEN="LBRACE";  _LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        '}') _LEXER_CUR_TOKEN="RBRACE";  _LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        '[') _LEXER_CUR_TOKEN="LBRACKET";_LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        ']') _LEXER_CUR_TOKEN="RBRACKET";_LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        ':') _LEXER_CUR_TOKEN="COLON";   _LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        ',') _LEXER_CUR_TOKEN="COMMA";   _LEXER_CUR_VALUE=""; _LEXER_POS=$((_LEXER_POS+1)); _LEXER_COL=$((_LEXER_COL+1)) ;;
        '"') _lexer_scan_string ;;
        '-'|[0-9]) _lexer_scan_number ;;
        't') _lexer_scan_literal "true" "TRUE" ;;
        'f') _lexer_scan_literal "false" "FALSE" ;;
        'n') _lexer_scan_literal "null" "NULL" ;;
        *)
            error_set "$_JSON_ERR_LEXER" "Unexpected character '$c' at $(_lexer_get_position)"
            _LEXER_CUR_TOKEN="ERROR"
            _LEXER_CUR_VALUE="Unexpected character '$c'"
            _LEXER_POS=$((_LEXER_POS+1))
            ;;
    esac
}

_lexer_get_position() {
    printf '%d:%d' "$_LEXER_LINE" "$_LEXER_COL"
}

# ── String scanning ──────────────────────────────────────────────────

_lexer_scan_string() {
    local start=$((_LEXER_POS + 1))
    local i=$start
    local escaped=0
    local ch

    while (( i < _LEXER_LEN )); do
        ch="${_LEXER_INPUT:$i:1}"
        if (( escaped )); then
            escaped=0
        elif [[ "$ch" == '\' ]]; then
            escaped=1
        elif [[ "$ch" == '"' ]]; then
            local raw="${_LEXER_INPUT:$start:$((i - start))}"
            _LEXER_CUR_VALUE=$(string_decode "$raw") || {
                _LEXER_CUR_TOKEN="ERROR"
                return 1
            }
            _LEXER_CUR_TOKEN="STRING"
            _LEXER_POS=$((i + 1))
            _LEXER_COL=$((_LEXER_COL + (i - start) + 2))
            return
        fi
        i=$((i+1))
    done

    error_set "$_JSON_ERR_LEXER" "Unterminated string"
    _LEXER_CUR_TOKEN="ERROR"
    _LEXER_CUR_VALUE="Unterminated string"
}

# ── Number scanning ─────────────────────────────────────────────────

_lexer_scan_number() {
    local start=$_LEXER_POS
    local i=$start
    local ch
    local seen_dot=0 seen_exp=0

    # Allow leading minus sign
    if (( i < _LEXER_LEN )) && [[ "${_LEXER_INPUT:$i:1}" == '-' ]]; then
        i=$((i+1))
    fi

    while (( i < _LEXER_LEN )); do
        ch="${_LEXER_INPUT:$i:1}"
        if [[ "$ch" == '.' ]]; then
            (( seen_dot )) && break
            seen_dot=1
        elif [[ "$ch" == 'e' || "$ch" == 'E' ]]; then
            (( seen_exp )) && break
            seen_exp=1
            local next_idx=$((i+1))
            if (( next_idx < _LEXER_LEN )); then
                local next_ch="${_LEXER_INPUT:$next_idx:1}"
                if [[ "$next_ch" == '+' || "$next_ch" == '-' ]]; then
                    i=$((i+1))
                fi
            fi
        elif [[ "$ch" != [0-9] ]]; then
            break
        fi
        i=$((i+1))
    done

    _LEXER_CUR_VALUE="${_LEXER_INPUT:$start:$((i - start))}"
    _LEXER_CUR_TOKEN="NUMBER"
    _LEXER_POS=$i
    _LEXER_COL=$((_LEXER_COL + (i - start)))
}

# ── Literal scanning (true / false / null) ──────────────────────────

_lexer_scan_literal() {
    local expected=$1 token=$2
    local elen=${#expected}
    local actual="${_LEXER_INPUT:$_LEXER_POS:$elen}"

    if [[ "$actual" == "$expected" ]]; then
        _LEXER_CUR_TOKEN="$token"
        _LEXER_CUR_VALUE=""
        _LEXER_POS=$((_LEXER_POS + elen))
        _LEXER_COL=$((_LEXER_COL + elen))
    else
        error_set "$_JSON_ERR_LEXER" "Unexpected token at $(_lexer_get_position): expected '$expected', got '${actual}'"
        _LEXER_CUR_TOKEN="ERROR"
        _LEXER_CUR_VALUE="Unexpected token"
    fi
}
