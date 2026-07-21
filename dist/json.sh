#!/usr/bin/env bash
# shell-json — single-file bundle
# Version: 0.1.0
# Generated: 2026-07-21

# --- error.sh ---
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

# --- ast.sh ---
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

# --- string.sh ---
# shell-json: string.sh — JSON string encoding/decoding
#
# Handles:
#   - \", \\, \/, \b, \f, \n, \r, \t escape sequences
#   - \uXXXX 4-hex-digit Unicode escapes
#   - Surrogate pairs (\uD800-\uDFFF -> supplementary planes)
#   - Reverse: encode raw string to JSON with proper escaping
#
# Part of shell-json (https://github.com/quintin/shell-json)

_UNICODE_SURROGATE=-1

# ── Decoding ─────────────────────────────────────────────────────────

# Decode a JSON-escaped string (without surrounding quotes) to raw text
# Usage: string_decode <escaped_string>
# Output: raw string on stdout
string_decode() {
    local s=$1 result="" i=0 c
    local len=${#s}

    _UNICODE_SURROGATE=-1

    while (( i < len )); do
        c="${s:$i:1}"
        if [[ "$c" == '\' && $((i + 1)) -lt len ]]; then
            local next="${s:$((i+1)):1}"
            case "$next" in
                '"')  result+='"';  i=$((i+2)) ;;
                '\') result+='\';  i=$((i+2)) ;;
                '/')  result+='/';  i=$((i+2)) ;;
                'b')  result+=$'\b'; i=$((i+2)) ;;
                'f')  result+=$'\f'; i=$((i+2)) ;;
                'n')  result+=$'\n'; i=$((i+2)) ;;
                'r')  result+=$'\r'; i=$((i+2)) ;;
                't')  result+=$'\t'; i=$((i+2)) ;;
                'u')
                    local hex="${s:$((i+2)):4}"
                    if [[ ${#hex} -lt 4 ]]; then
                        error_set "$_JSON_ERR_LEXER" "Truncated \\uXXXX escape"
                        return 1
                    fi
                    _decode_unicode_append "$hex" result
                    i=$((i+6))
                    ;;
                *)
                    error_set "$_JSON_ERR_LEXER" "Invalid escape sequence: \\$next"
                    return 1
                    ;;
            esac
        else
            result+="$c"
            i=$((i+1))
        fi
    done

    printf '%s' "$result"
}

# Append a decoded Unicode codepoint (from \uXXXX) to an accumulator
_decode_unicode_append() {
    local hex=$1
    local -n acc=$2
    local cp

    cp=$(printf '%d' "0x$hex")

    # High surrogate (U+D800..U+DBFF) — store and wait for low surrogate
    if (( cp >= 0xD800 && cp <= 0xDBFF )); then
        _UNICODE_SURROGATE=$cp
        return 0
    fi

    # Low surrogate (U+DC00..U+DFFF) — combine with stored high surrogate
    if (( cp >= 0xDC00 && cp <= 0xDFFF )); then
        if (( _UNICODE_SURROGATE >= 0xD800 && _UNICODE_SURROGATE <= 0xDBFF )); then
            local high=$_UNICODE_SURROGATE
            _UNICODE_SURROGATE=-1
            cp=$(( 0x10000 + ((high - 0xD800) << 10) + (cp - 0xDC00) ))
        else
            error_set "$_JSON_ERR_LEXER" "Lone low surrogate \\u$hex"
            return 1
        fi
    else
        _UNICODE_SURROGATE=-1
    fi

    # Encode codepoint as UTF-8 and append to accumulator
    _utf8_append "$cp" "$2"
    return 0
}

# Encode a Unicode codepoint as UTF-8 bytes and append to accumulator
_utf8_append() {
    local cp=$1
    local -n acc=$2
    local hex_bytes

    if (( cp < 0x80 )); then
        printf -v hex_bytes '\\x%02x' "$cp"
    elif (( cp < 0x800 )); then
        printf -v hex_bytes '\\x%02x\\x%02x' \
            $(( 0xC0 | (cp >> 6) )) \
            $(( 0x80 | (cp & 0x3F) ))
    elif (( cp < 0x10000 )); then
        printf -v hex_bytes '\\x%02x\\x%02x\\x%02x' \
            $(( 0xE0 | (cp >> 12) )) \
            $(( 0x80 | ((cp >> 6) & 0x3F) )) \
            $(( 0x80 | (cp & 0x3F) ))
    else
        printf -v hex_bytes '\\x%02x\\x%02x\\x%02x\\x%02x' \
            $(( 0xF0 | (cp >> 18) )) \
            $(( 0x80 | ((cp >> 12) & 0x3F) )) \
            $(( 0x80 | ((cp >> 6) & 0x3F) )) \
            $(( 0x80 | (cp & 0x3F) ))
    fi

    acc+=$(printf '%b' "$hex_bytes")
}

# ── Encoding ─────────────────────────────────────────────────────────

# Encode a raw string to a JSON string (including surrounding quotes)
# Usage: string_encode <raw_string>
# Output: JSON-escaped string on stdout
string_encode() {
    local s=$1 result='"' i=0 c
    local len=${#s}

    while (( i < len )); do
        c="${s:$i:1}"
        case "$c" in
            '"')  result+='\"' ;;
            '\') result+='\\' ;;
            $'\b') result+='\b' ;;
            $'\f') result+='\f' ;;
            $'\n') result+='\n' ;;
            $'\r') result+='\r' ;;
            $'\t') result+='\t' ;;
            # Other control characters (U+0000-U+001F) use \uXXXX
            [[:cntrl:]])
                printf -v result '%s\\u%04x' "$result" "'$c"
                ;;
            *)
                result+="$c"
                ;;
        esac
        i=$((i+1))
    done

    result+='"'
    printf '%s' "$result"
}

# --- number.sh ---
# shell-json: number.sh — JSON number validation and comparison
#
# Handles full JSON number grammar:
#   int: 0 | [1-9][0-9]*
#   frac: . [0-9]+
#   exp:  (e|E) (+|-)? [0-9]+
#   number: -? int (frac)? (exp)?
#
# Numbers are kept as strings — no conversion to bash integers
# (would lose precision beyond 63 bits).
#
# Part of shell-json (https://github.com/quintin/shell-json)

# Validate a JSON number string
# Usage: number_validate <str>
# Returns: 0 if valid, 1 if invalid
number_validate() {
    local s=$1

    # Empty string is invalid
    [[ -z "$s" ]] && return 1

    # Regex: optional -, then 0 or [1-9][0-9]*, optional frac, optional exp
    if [[ "$s" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
        return 0
    fi

    return 1
}

# Compare two JSON numbers
# Usage: number_compare <a> <b>
# Output: -1, 0, or 1
#
# Uses bc for floating-point comparison if available;
# falls back to integer comparison otherwise.
number_compare() {
    local a=$1 b=$2

    # If both look like integers, use bash arithmetic
    if [[ "$a" =~ ^-?[0-9]+$ && "$b" =~ ^-?[0-9]+$ ]]; then
        if (( a < b )); then
            printf '%s\n' "-1"
        elif (( a > b )); then
            printf '%s\n' "1"
        else
            printf '%s\n' "0"
        fi
        return
    fi

    # Try bc for floating-point
    if command -v bc &>/dev/null; then
        local result
        result=$(printf '%s\n' "if ($a < $b) print -1; if ($a > $b) print 1; if ($a == $b) print 0" | bc -l 2>/dev/null)
        if [[ -n "$result" ]]; then
            printf '%s\n' "$result"
            return
        fi
    fi

    # Fallback: numeric comparison using awk
    if command -v awk &>/dev/null; then
        local result
        result=$(awk -v a="$a" -v b="$b" 'BEGIN {
            if (a < b) print -1;
            else if (a > b) print 1;
            else print 0
        }' 2>/dev/null)
        if [[ -n "$result" ]]; then
            printf '%s\n' "$result"
            return
        fi
    fi

    # Last resort: string-based numeric comparison
    # Simple sign check + integer part comparison
    # This is approximate for floating point
    local a_sign="" b_sign=""
    [[ "$a" == -* ]] && a_sign="-" && a="${a#-}"
    [[ "$b" == -* ]] && b_sign="-" && b="${b#-}"

    # Different signs
    if [[ "$a_sign" != "$b_sign" ]]; then
        if [[ -z "$a_sign" && -n "$b_sign" ]]; then
            printf '%s\n' "1"; return
        elif [[ -n "$a_sign" && -z "$b_sign" ]]; then
            printf '%s\n' "-1"; return
        fi
    fi

    # Strip leading zeros for integer part comparison
    local a_int="${a%%.*}" b_int="${b%%.*}"
    a_int="${a_int##0}"
    b_int="${b_int##0}"
    a_int="${a_int:-0}"
    b_int="${b_int:-0}"

    if (( ${#a_int} < ${#b_int} )); then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "1" || echo "-1")"
        return
    elif (( ${#a_int} > ${#b_int} )); then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "-1" || echo "1")"
        return
    fi

    if [[ "$a_int" < "$b_int" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "1" || echo "-1")"
        return
    elif [[ "$a_int" > "$b_int" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "-1" || echo "1")"
        return
    fi

    # Integer parts equal, compare fractional parts
    local a_frac="${a#*.}" b_frac="${b#*.}"
    if [[ "$a_frac" == "$a" ]]; then a_frac=""; fi
    if [[ "$b_frac" == "$b" ]]; then b_frac=""; fi

    if [[ -z "$a_frac" && -z "$b_frac" ]]; then
        printf '%s\n' "0"
    elif [[ -z "$a_frac" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "1" || echo "-1")"
    elif [[ -z "$b_frac" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "-1" || echo "1")"
    elif [[ "$a_frac" < "$b_frac" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "1" || echo "-1")"
    elif [[ "$a_frac" > "$b_frac" ]]; then
        printf '%s\n' "$([[ -n "$a_sign" ]] && echo "-1" || echo "1")"
    else
        printf '%s\n' "0"
    fi
}

# --- lexer.sh ---
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

# --- parser.sh ---
# shell-json: parser.sh — Recursive descent JSON parser
#
# Consumes tokens from the lexer and builds a file-backed AST via ast.sh.
# Grammar (single-token lookahead via lexer_peek):
#
#   value   = object | array | string | number | TRUE | FALSE | NULL
#   object  = '{' ( string ':' value (',' string ':' value)* )? '}'
#   array   = '[' ( value (',' value)* )? ']'
#
# All parse_* functions set _PARSE_RESULT with the node ID.
# No subshells are used for value dispatch.
#
# Lexer contract:
#   lexer_advance() — reads next token, sets _LEXER_CUR_TOKEN/_LEXER_CUR_VALUE
#   lexer_peek() — returns current token type (no scanning)
#
# Part of shell-json (https://github.com/quintin/shell-json)

_PARSE_RESULT=""

# Parse the full token stream into an AST.
# Prints the AST root node ID on stdout.
parser_parse() {
    lexer_advance
    parse_value
    local root_id=$_PARSE_RESULT

    if [[ -n "$root_id" ]]; then
        if [[ "$_LEXER_CUR_TOKEN" != "EOF" && "$_LEXER_CUR_TOKEN" != "ERROR" ]]; then
            error_set "$_JSON_ERR_PARSER" "Unexpected token after root value at $(_helper_pos)"
            return 1
        fi
    fi

    printf '%s\n' "$root_id"
}

# ── Value dispatch ───────────────────────────────────────────────────

parse_value() {
    case "$_LEXER_CUR_TOKEN" in
        "LBRACE")   parse_object ;;
        "LBRACKET") parse_array ;;
        "STRING")   parse_string ;;
        "NUMBER")   parse_number ;;
        "TRUE")     parse_true ;;
        "FALSE")    parse_false ;;
        "NULL")     parse_null ;;
        "EOF")
            error_set "$_JSON_ERR_PARSER" "Unexpected end of input"
            return 1 ;;
        *)
            error_set "$_JSON_ERR_PARSER" "Unexpected token '$_LEXER_CUR_TOKEN' at $(_helper_pos)"
            return 1 ;;
    esac
}

# ── Object ───────────────────────────────────────────────────────────

parse_object() {
    lexer_advance  # consume '{'
    local obj_id
    obj_id=$(ast_create $_AST_T_OBJECT)
    local first=1

    while [[ "$_LEXER_CUR_TOKEN" != "RBRACE" ]]; do
        if (( !first )); then
            if [[ "$_LEXER_CUR_TOKEN" != "COMMA" ]]; then
                error_set "$_JSON_ERR_PARSER" "Expected ',' or '}' in object at $(_helper_pos)"
                return 1
            fi
            lexer_advance  # consume ','
        fi
        first=0

        if [[ "$_LEXER_CUR_TOKEN" != "STRING" ]]; then
            error_set "$_JSON_ERR_PARSER" "Expected string key in object at $(_helper_pos)"
            return 1
        fi
        local key=$_LEXER_CUR_VALUE
        lexer_advance  # consume key

        if [[ "$_LEXER_CUR_TOKEN" != "COLON" ]]; then
            error_set "$_JSON_ERR_PARSER" "Expected ':' after object key at $(_helper_pos)"
            return 1
        fi
        lexer_advance  # consume ':'

        parse_value
        local val_id=$_PARSE_RESULT
        [[ -z "$val_id" ]] && return 1

        ast_set_child_with_key "$obj_id" "$val_id" "$key"
    done

    lexer_advance  # consume '}'
    _PARSE_RESULT=$obj_id
}

# ── Array ────────────────────────────────────────────────────────────

parse_array() {
    lexer_advance  # consume '['
    local arr_id
    arr_id=$(ast_create $_AST_T_ARRAY)
    local first=1

    while [[ "$_LEXER_CUR_TOKEN" != "RBRACKET" ]]; do
        if (( !first )); then
            if [[ "$_LEXER_CUR_TOKEN" != "COMMA" ]]; then
                error_set "$_JSON_ERR_PARSER" "Expected ',' or ']' in array at $(_helper_pos)"
                return 1
            fi
            lexer_advance  # consume ','
        fi
        first=0

        parse_value
        local val_id=$_PARSE_RESULT
        [[ -z "$val_id" ]] && return 1

        ast_set_child "$arr_id" "$val_id"
    done

    lexer_advance  # consume ']'
    _PARSE_RESULT=$arr_id
}

# ── Primitives ───────────────────────────────────────────────────────

parse_string() {
    local value=$_LEXER_CUR_VALUE
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_STRING "$value")
}

parse_number() {
    local value=$_LEXER_CUR_VALUE
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_NUMBER "$value")
}

parse_true() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_BOOL "true")
}

parse_false() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_BOOL "false")
}

parse_null() {
    lexer_advance
    _PARSE_RESULT=$(ast_create $_AST_T_NULL "")
}

# ── Helper ───────────────────────────────────────────────────────────

_helper_pos() {
    lexer_get_position
}

# --- object.sh ---
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

# --- array.sh ---
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

# --- writer.sh ---
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
    local type

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

# --- query.sh ---
# shell-json: query.sh — JSONPath (RFC 9535) query engine
#
# Supported path features:
#   $            Root
#   @            Current node (filter context)
#   .key         Dot child access
#   ['key']      Bracket child access
#   [n]          Array index
#   [*]          Wildcard (all children)
#   ..key        Recursive descent
#   [a:b:c]      Slice (start:end:step)
#   [?(expr)]    Filter expression (with arithmetic, functions)
#
# Filter expressions support:
#   Comparisons: == != < > <= >=
#   Arithmetic:  + - * /  (e.g., @.price + 1 > 10)
#   Logical:     && || !
#   Parentheses for grouping
#   String literals: '...'
#   Number literals (including negatives)
#   @.key / @.length
#   true / false / null literals
#   Functions: contains(@.key, 'str'), type(@.key), has(@.key),
#             length(@), length(@.key), match(@.key, 'regex'), search(@.key, 'regex')
#
# Part of shell-json (https://github.com/quintin/shell-json)

# ── Public API ───────────────────────────────────────────────────────

# Execute a JSONPath query against an AST
# Usage: query_execute <root_node_id> <path_expression>
# Output: matching node IDs, one per line
query_execute() {
    # zsh compatibility: 0-indexed arrays + word splitting (like bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local root_id=$1 path_expr=$2
    local segments_count

    # Parse the path into segments
    _q_parse_path "$path_expr"
    segments_count=${#_Q_SEGMENTS[@]}

    if (( segments_count == 0 )); then
        # Root only
        printf '%s\n' "$root_id"
        return
    fi

    # Evaluate
    _Q_RESULT="$root_id"$'\n'
    local seg_idx
    for (( seg_idx = 0; seg_idx < segments_count; seg_idx++ )); do
        local seg="${_Q_SEGMENTS[$seg_idx]}"
        _Q_NEXT_RESULT=""
        _q_eval_segment "$seg"
        _Q_RESULT="$_Q_NEXT_RESULT"
    done

    printf '%s' "$_Q_RESULT" | sed '/^$/d'
}

# ── Internal state ──────────────────────────────────────────────────

_Q_SEGMENTS=()
_Q_RESULT=""
_Q_NEXT_RESULT=""

# ── Path lexer tokens ───────────────────────────────────────────────

# Token types:
#   DOT       .
#   DOTDOT    ..
#   LBRACKET  [
#   RBRACKET  ]
#   STAR      *
#   COLON     :
#   COMMA     ,
#   QMARK     ?
#   LPAREN    (
#   RPAREN    )
#   IDENT     identifier (key name)
#   NUMBER    integer
#   STRING    single-quoted string
#   ROOT      $
#   CUR       @
#   AND       &&
#   OR        ||
#   BANG      !
#   EQ        ==
#   NE        !=
#   LTE       <=
#   GTE       >=
#   LT        <
#   GT        >
#   EOF       end of expression

_Q_TT=()
_Q_TV=()
_Q_TPOS=0

# Filter expression evaluation state
_Q_FILTER_NODE=""
_Q_EXPR_POS=0
_Q_EXPR_TOKS=()
_Q_EXPR_VALS=()
_Q_EXPR_VAL=""
_Q_EXPR_TOK_TYPE=""

# ── Path parsing ─────────────────────────────────────────────────────

# Parse a JSONPath string into the _Q_SEGMENTS array
# Each segment is: <type>:<args>
# Types: key, idx, wild, deep, slice, filter
_q_parse_path() {
    local path=$1
    _Q_SEGMENTS=()
    _q_tokenize_path "$path"
    _Q_TPOS=0

    # Skip leading $
    if [[ "${_Q_TT[0]}" == "ROOT" ]]; then
        _Q_TPOS=1
    fi

    while (( _Q_TPOS < ${#_Q_TT[@]} )); do
        local tok="${_Q_TT[$_Q_TPOS]}"

        case "$tok" in
            "DOT")
                _Q_TPOS=$((_Q_TPOS+1))
                _q_parse_dot_access
                ;;
            "DOTDOT")
                _Q_TPOS=$((_Q_TPOS+1))
                _q_parse_deep_access
                ;;
            "LBRACKET")
                _Q_TPOS=$((_Q_TPOS+1))
                _q_parse_bracket
                ;;
            *)
                # Treat as dot access without dot
                if [[ "$tok" == "IDENT" ]]; then
                    _Q_SEGMENTS+=("key:${_Q_TV[$_Q_TPOS]}")
                    _Q_TPOS=$((_Q_TPOS+1))
                else
                    break
                fi
                ;;
        esac
    done
}

# Parse .key or .* dot access into a segment
_q_parse_dot_access() {
    if (( _Q_TPOS >= ${#_Q_TT[@]} )); then
        return
    fi
    local tok="${_Q_TT[$_Q_TPOS]}"
    if [[ "$tok" == "STAR" ]]; then
        _Q_SEGMENTS+=("wild:")
        _Q_TPOS=$((_Q_TPOS+1))
    elif [[ "$tok" == "IDENT" ]]; then
        _Q_SEGMENTS+=("key:${_Q_TV[$_Q_TPOS]}")
        _Q_TPOS=$((_Q_TPOS+1))
    fi
}

# Parse ..key or ..* recursive descent into a segment
_q_parse_deep_access() {
    if (( _Q_TPOS >= ${#_Q_TT[@]} )); then
        _Q_SEGMENTS+=("deep:*")
        return
    fi
    local tok="${_Q_TT[$_Q_TPOS]}"
    if [[ "$tok" == "STAR" ]]; then
        _Q_SEGMENTS+=("deep:*")
        _Q_TPOS=$((_Q_TPOS+1))
    elif [[ "$tok" == "IDENT" ]]; then
        _Q_SEGMENTS+=("deep:${_Q_TV[$_Q_TPOS]}")
        _Q_TPOS=$((_Q_TPOS+1))
    else
        _Q_SEGMENTS+=("deep:*")
    fi
}

# Parse bracket [...] access: index, slice, key, wildcard, or filter
_q_parse_bracket() {
    local tok="${_Q_TT[$_Q_TPOS]}"

    case "$tok" in
        "STAR")
            _Q_SEGMENTS+=("wild:")
            _Q_TPOS=$((_Q_TPOS+1))
            ;;
        "NUMBER")
            # Could be index, slice, or union start
            if (( _Q_TPOS + 1 < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$((_Q_TPOS + 1))]}" == "COLON" ]]; then
                _q_parse_slice
            elif (( _Q_TPOS + 1 < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$((_Q_TPOS + 1))]}" == "COMMA" ]]; then
                _q_parse_union "idx"
            else
                _Q_SEGMENTS+=("idx:${_Q_TV[$_Q_TPOS]}")
                _Q_TPOS=$((_Q_TPOS+1))
            fi
            ;;
        "STRING")
            # Could be key or union start
            if (( _Q_TPOS + 1 < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$((_Q_TPOS + 1))]}" == "COMMA" ]]; then
                _q_parse_union "key"
            else
                _Q_SEGMENTS+=("key:${_Q_TV[$_Q_TPOS]}")
                _Q_TPOS=$((_Q_TPOS+1))
            fi
            ;;
        "QMARK")
            # Filter: [?(expr)]
            _Q_TPOS=$((_Q_TPOS+1))
            _q_parse_filter
            ;;
        *)
            # Could be slice or union
            local slice_seen=0
            if [[ "$tok" == "COLON" ]] || [[ "$tok" == "NUMBER" ]]; then
                slice_seen=1
            fi
            if (( slice_seen )); then
                _q_parse_slice
            fi
            ;;
    esac

    # Consume RBRACKET if present
    if (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "RBRACKET" ]]; then
        _Q_TPOS=$((_Q_TPOS+1))
    fi
}

# Parse slice [start:end:step] notation into a segment
_q_parse_slice() {
    local start="" end="" step=""
    local tok="${_Q_TT[$_Q_TPOS]}"

    if [[ "$tok" == "NUMBER" ]]; then
        start="${_Q_TV[$_Q_TPOS]}"
        _Q_TPOS=$((_Q_TPOS+1))
    fi

    if (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "COLON" ]]; then
        _Q_TPOS=$((_Q_TPOS+1))
    else
        # Single number only — it's an index
        _Q_SEGMENTS+=("idx:$start")
        return
    fi

    tok="${_Q_TT[$_Q_TPOS]}"
    if [[ "$tok" == "NUMBER" ]]; then
        end="${_Q_TV[$_Q_TPOS]}"
        _Q_TPOS=$((_Q_TPOS+1))
    fi

    if (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "COLON" ]]; then
        _Q_TPOS=$((_Q_TPOS+1))
        tok="${_Q_TT[$_Q_TPOS]}"
        if [[ "$tok" == "NUMBER" ]]; then
            step="${_Q_TV[$_Q_TPOS]}"
            _Q_TPOS=$((_Q_TPOS+1))
        fi
    fi

    _Q_SEGMENTS+=("slice:${start:-}:${end:-}:${step:-1}")
}

# Parse union [0,1,2] or ['a','b'] into a segment
# Stores as "union:mode:value1|value2|..."
_q_parse_union() {
    local mode=$1  # "idx" or "key"
    local values="${_Q_TV[$_Q_TPOS]}"
    _Q_TPOS=$((_Q_TPOS+1))

    while (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "COMMA" ]]; do
        _Q_TPOS=$((_Q_TPOS+1))
        values+="|${_Q_TV[$_Q_TPOS]}"
        _Q_TPOS=$((_Q_TPOS+1))
    done

    _Q_SEGMENTS+=("union:${mode}:${values}")
}

# Parse filter expression [?(@.price<10)] into a segment
# Collects tokens until matching RPAREN, stores as pipe-delimited string
_q_parse_filter() {
    # Expect LPAREN
    if (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "LPAREN" ]]; then
        _Q_TPOS=$((_Q_TPOS+1))
    fi

    # Collect filter expression tokens until matching RPAREN
    local depth=1
    local expr_tokens=""
    while (( _Q_TPOS < ${#_Q_TT[@]} )) && (( depth > 0 )); do
        local t="${_Q_TT[$_Q_TPOS]}"
        local v="${_Q_TV[$_Q_TPOS]}"
        if [[ "$t" == "RPAREN" ]]; then
            depth=$((depth-1))
            if (( depth == 0 )); then
                _Q_TPOS=$((_Q_TPOS+1))
                break
            fi
        fi
        if [[ "$t" == "LPAREN" ]]; then
            depth=$((depth+1))
        fi
        if [[ -n "$expr_tokens" ]]; then
            expr_tokens+="|"
        fi
        expr_tokens+="$t:$v"
        _Q_TPOS=$((_Q_TPOS+1))
    done

    _Q_SEGMENTS+=("filter:$expr_tokens")
}

# Parse ..key or ..* recursive descent into a segment
_q_parse_deep_access() {
    if (( _Q_TPOS >= ${#_Q_TT[@]} )); then
        _Q_SEGMENTS+=("deep:*")
        return
    fi
    local tok="${_Q_TT[$_Q_TPOS]}"
    if [[ "$tok" == "STAR" ]]; then
        _Q_SEGMENTS+=("deep:*")
        _Q_TPOS=$((_Q_TPOS+1))
    elif [[ "$tok" == "IDENT" ]]; then
        _Q_SEGMENTS+=("deep:${_Q_TV[$_Q_TPOS]}")
        _Q_TPOS=$((_Q_TPOS+1))
    else
        _Q_SEGMENTS+=("deep:*")
    fi
}

# ── Path tokenizer ───────────────────────────────────────────────────

# Tokenize a JSONPath expression into _Q_TT (types) and _Q_TV (values)
# Handles: $ @ . .. [ ] * : , ? ( ) 'strings' -numbers identifiers
_q_tokenize_path() {
    local s=$1 i=0 len=${#1}
    _Q_TT=()
    _Q_TV=()

    while (( i < len )); do
        local c="${s:$i:1}"
        case "$c" in
            '$') _Q_TT+=("ROOT");  _Q_TV+=(""); i=$((i+1)) ;;
            '@') _Q_TT+=("CUR");   _Q_TV+=(""); i=$((i+1)) ;;
            '.')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == '.' ]]; then
                    _Q_TT+=("DOTDOT"); _Q_TV+=(""); i=$((i+2))
                else
                    _Q_TT+=("DOT"); _Q_TV+=(""); i=$((i+1))
                fi
                ;;
            '[') _Q_TT+=("LBRACKET"); _Q_TV+=(""); i=$((i+1)) ;;
            ']') _Q_TT+=("RBRACKET"); _Q_TV+=(""); i=$((i+1)) ;;
            '*') _Q_TT+=("STAR"); _Q_TV+=(""); i=$((i+1)) ;;
            ':') _Q_TT+=("COLON"); _Q_TV+=(""); i=$((i+1)) ;;
            ',') _Q_TT+=("COMMA"); _Q_TV+=(""); i=$((i+1)) ;;
            '?') _Q_TT+=("QMARK"); _Q_TV+=(""); i=$((i+1)) ;;
            '(') _Q_TT+=("LPAREN"); _Q_TV+=(""); i=$((i+1)) ;;
            ')') _Q_TT+=("RPAREN"); _Q_TV+=(""); i=$((i+1)) ;;
            '=')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "=" ]]; then
                    _Q_TT+=("EQ"); _Q_TV+=(""); i=$((i+2))
                else
                    # Single = not valid, skip
                    i=$((i+1))
                fi
                ;;
            '!')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "=" ]]; then
                    _Q_TT+=("NE"); _Q_TV+=(""); i=$((i+2))
                else
                    _Q_TT+=("BANG"); _Q_TV+=(""); i=$((i+1))
                fi
                ;;
            '<')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "=" ]]; then
                    _Q_TT+=("LTE"); _Q_TV+=(""); i=$((i+2))
                else
                    _Q_TT+=("LT"); _Q_TV+=(""); i=$((i+1))
                fi
                ;;
            '>')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "=" ]]; then
                    _Q_TT+=("GTE"); _Q_TV+=(""); i=$((i+2))
                else
                    _Q_TT+=("GT"); _Q_TV+=(""); i=$((i+1))
                fi
                ;;
            '&')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "&" ]]; then
                    _Q_TT+=("AND"); _Q_TV+=(""); i=$((i+2))
                else
                    i=$((i+1))
                fi
                ;;
            '|')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" == "|" ]]; then
                    _Q_TT+=("OR"); _Q_TV+=(""); i=$((i+2))
                else
                    i=$((i+1))
                fi
                ;;
            "'"|'"')
                # Single or double-quoted string
                local quote="${s:$i:1}"
                local start=$((i+1))
                local j=$start
                while (( j < len )); do
                    [[ "${s:$j:1}" == "$quote" ]] && break
                    j=$((j+1))
                done
                _Q_TT+=("STRING")
                _Q_TV+=("${s:$start:$((j-start))}")
                i=$((j+1))
                ;;
            [0-9])
                # Number (digits and optional decimal point)
                local ns=$i
                local ni=$i
                while (( ni < len )) && [[ "${s:$ni:1}" == [0-9] ]]; do
                    ni=$((ni+1))
                done
                if (( ni < len )) && [[ "${s:$ni:1}" == "." ]]; then
                    ni=$((ni+1))
                    while (( ni < len )) && [[ "${s:$ni:1}" == [0-9] ]]; do
                        ni=$((ni+1))
                    done
                fi
                _Q_TT+=("NUMBER")
                _Q_TV+=("${s:$ns:$((ni-ns))}")
                i=$ni
                ;;
            '+') _Q_TT+=("PLUS"); _Q_TV+=(""); i=$((i+1)) ;;
            '-') _Q_TT+=("MINUS"); _Q_TV+=(""); i=$((i+1)) ;;
            '/') _Q_TT+=("DIV"); _Q_TV+=(""); i=$((i+1)) ;;
            ' '|$'\t'|$'\r'|$'\n')
                i=$((i+1))  # skip whitespace
                ;;
            *)
                # Identifier (key name)
                local ks=$i
                local ki=$i
                while (( ki < len )); do
                    local kc="${s:$ki:1}"
                    case "$kc" in
                        '.'|'['|']'|'*'|':'|','|'?'|'('|')'|' '|$'\t'|$'\r'|$'\n'|"'"|'$'|'@') break ;;
                    esac
                    ki=$((ki+1))
                done
                if (( ki > ks )); then
                    _Q_TT+=("IDENT")
                    _Q_TV+=("${s:$ks:$((ki-ks))}")
                fi
                i=$ki
                ;;
        esac
    done

    _Q_TT+=("EOF")
    _Q_TV+=("")
}

# ── Segment evaluation ───────────────────────────────────────────────

# Apply a single segment to all nodes in _Q_RESULT
_q_eval_segment() {
    local seg=$1
    local type="${seg%%:*}"
    local args="${seg#*:}"

    local lines
    lines=$(printf '%s' "$_Q_RESULT" | sed '/^$/d')
    local old_ifs=$IFS
    IFS=$'\n'
    set -f; nodes=($lines); set +f
    IFS=$old_ifs

    local node
    for node in "${nodes[@]}"; do
        [[ -z "$node" ]] && continue
        case "$type" in
            "key")  _q_eval_key "$node" "$args" ;;
            "idx")  _q_eval_idx "$node" "$args" ;;
            "wild") _q_eval_wild "$node" ;;
            "deep") _q_eval_deep "$node" "$args" ;;
            "slice") _q_eval_slice "$node" "$args" ;;
            "filter") _q_eval_filter "$node" "$args" ;;
            "union") _q_eval_union "$node" "$args" ;;
        esac
    done
}

# Evaluate a key access segment against a single node
_q_eval_key() {
    local node_id=$1 key=$2
    local type
    type=$(ast_get_type "$node_id")
    if [[ "$type" == "$_AST_T_OBJECT" ]]; then
        local child
        child=$(ast_child_by_key "$node_id" "$key") && {
            _Q_NEXT_RESULT+="${child}"$'\n'
        }
    fi
}

# Evaluate an index access segment against a single node
_q_eval_idx() {
    local node_id=$1 idx=$2
    local type
    type=$(ast_get_type "$node_id")
    if [[ "$type" == "$_AST_T_ARRAY" ]]; then
        local child
        child=$(ast_child_by_index "$node_id" "$idx") && {
            _Q_NEXT_RESULT+="${child}"$'\n'
        }
    fi
}

# Evaluate a wildcard segment — returns all children of object/array
_q_eval_wild() {
    local node_id=$1
    local type children
    type=$(ast_get_type "$node_id")
    if [[ "$type" == "$_AST_T_OBJECT" || "$type" == "$_AST_T_ARRAY" ]]; then
        children=$(ast_get_children "$node_id")
        local ch
        for ch in $children; do
            _Q_NEXT_RESULT+="${ch}"$'\n'
        done
    fi
}

# Evaluate a recursive descent segment — delegate to _q_deep_collect
_q_eval_deep() {
    local node_id=$1 target=$2
    _q_deep_collect "$node_id" "$target"
}

# Recursively collect nodes matching target key (or all nodes if target=*)
_q_deep_collect() {
    local node_id=$1 target=$2
    local type
    type=$(ast_get_type "$node_id")

    # If searching for a specific key in objects
    if [[ "$target" != "*" && "$type" == "$_AST_T_OBJECT" ]]; then
        local child
        child=$(ast_child_by_key "$node_id" "$target") && {
            _Q_NEXT_RESULT+="${child}"$'\n'
        }
    fi

    # Recursively collect from children
    local children
    children=$(ast_get_children "$node_id")
    [[ -z "$children" ]] && return

    local ch
    for ch in $children; do
        _q_deep_collect "$ch" "$target"
    done
}

# Evaluate a slice segment — select children by start:end:step range
_q_eval_slice() {
    local node_id=$1 args=$2
    local type
    type=$(ast_get_type "$node_id")
    if [[ "$type" != "$_AST_T_ARRAY" ]]; then
        return
    fi

    # Parse start:end:step
    local start end step
    start=$(echo "$args" | cut -d: -f1)
    end=$(echo "$args" | cut -d: -f2)
    step=$(echo "$args" | cut -d: -f3)
    step="${step:-1}"

    local child_count
    child_count=$(ast_get_child_count "$node_id")

    # Normalise indices
    # start defaults to 0 if step>0, end if step<0
    if [[ -z "$start" ]]; then
        if (( step >= 0 )); then start=0
        else start=$((child_count - 1))
        fi
    else
        # Handle negative indexing
        if (( start < 0 )); then
            start=$((child_count + start))
            (( start < 0 )) && start=0
        fi
    fi

    if [[ -z "$end" ]]; then
        if (( step >= 0 )); then end=$child_count
        else end=-1
        fi
    else
        if (( end < 0 )); then
            end=$((child_count + end))
            (( end < 0 )) && end=0
        fi
    fi

    # Clamp
    (( start < 0 )) && start=0
    (( start >= child_count )) && return
    (( end > child_count )) && end=$child_count

    local i
    if (( step > 0 )); then
        for (( i = start; i < end; i += step )); do
            local child
            child=$(ast_child_by_index "$node_id" "$i")
            [[ -n "$child" ]] && _Q_NEXT_RESULT+="${child}"$'\n'
        done
    elif (( step < 0 )); then
        for (( i = start; i > end; i += step )); do
            local child
            child=$(ast_child_by_index "$node_id" "$i")
            [[ -n "$child" ]] && _Q_NEXT_RESULT+="${child}"$'\n'
        done
    fi
}

# Evaluate a union selector — collect children matching multiple indices/keys
_q_eval_union() {
    local node_id=$1 args=$2
    local mode="${args%%:*}" values="${args#*:}"
    local old_ifs=$IFS
    IFS='|'
    set -f; local parts=($values); set +f
    IFS=$old_ifs
    local part
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        local child
        if [[ "$mode" == "idx" ]]; then
            child=$(ast_child_by_index "$node_id" "$part")
        elif [[ "$mode" == "key" ]]; then
            child=$(ast_child_by_key "$node_id" "$part")
        fi
        [[ -n "$child" ]] && _Q_NEXT_RESULT+="${child}"$'\n'
    done
}

# Evaluate a simple path expression (.key or .length) against a node
# Returns the node ID or empty string if not found
_q_eval_path() {
    local node_id=$1 path=$2
    [[ -z "$path" ]] && return
    
    # Split path into segments: .key.subkey.length
    local clean_path="${path#.}"
    local current_node=$node_id
    
    IFS='.' read -ra parts <<< "$clean_path"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        if [[ "$part" == "length" ]]; then
            # length returns a number, not a node — can't chain further
            ast_get_child_count "$current_node"
            return
        fi
        local child
        child=$(ast_child_by_key "$current_node" "$part")
        if [[ -n "$child" ]]; then
            current_node=$child
        else
            return
        fi
    done
    printf '%s' "$current_node"
}

# ── Filter evaluation ────────────────────────────────────────────────

# Evaluate a filter segment — test each child against the filter expression
_q_eval_filter() {
    local node_id=$1 expr_tokens=$2
    local type
    type=$(ast_get_type "$node_id")
    if [[ "$type" != "$_AST_T_ARRAY" ]]; then
        # Filter on non-array: apply to each child that matches
        # Actually, according to RFC 9535, filter is a selector on arrays
        # Apply to current node if it's an object
        if _q_eval_filter_expr "$node_id" "$expr_tokens"; then
            _Q_NEXT_RESULT+="${node_id}"$'\n'
        fi
        return
    fi

    local children
    children=$(ast_get_children "$node_id")
    local ch
    for ch in $children; do
        if _q_eval_filter_expr "$ch" "$expr_tokens"; then
            _Q_NEXT_RESULT+="${ch}"$'\n'
        fi
    done
}

# Evaluate filter expression against a single node
# Expression format: "t1:v1|t2:v2|..."
_q_eval_filter_expr() {
    local node_id=$1 expr=$2

    # Tokenize the filter expression pipe format
    local old_ifs=$IFS
    IFS='|'
    read -ra tokens <<< "$expr"
    IFS=$old_ifs

    # Parse and evaluate using precedence climbing
    _Q_EXPR_POS=0
    _Q_EXPR_TOKS=()
    _Q_EXPR_VALS=()
    local tok
    for tok in "${tokens[@]}"; do
        local tt="${tok%%:*}"
        local tv="${tok#*:}"
        _Q_EXPR_TOKS+=("$tt")
        _Q_EXPR_VALS+=("$tv")
    done
    _Q_EXPR_TOKS+=("EOF")
    _Q_EXPR_VALS+=("")

    _Q_FILTER_NODE=$node_id
    _q_expr_parse_or
    local result=$?
    return $result
}

# Expression parser (precedence climbing):
#   or_expr  = and_expr ('||' and_expr)*
#   and_expr = not_expr ('&&' not_expr)*
#   not_expr = '!' not_expr | cmp_expr
#   cmp_expr = add_expr (('=='|'!='|'<'|'>'|'<='|'>=') add_expr)?
#   add_expr = mul_expr (('+'|'-') mul_expr)*
#   mul_expr = unary_expr (('*'|'/') unary_expr)*
#   unary_expr = ('-') unary_expr | primary
#   primary  = '(' or_expr ')' | NUMBER | STRING | 'true' | 'false' | 'null' | '@' path | contains() | type() | has()

_q_expr_parse_or() {
    _q_expr_parse_and
    local left_result=$?
    while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
          [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "OR" ]]; do
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_and
        local right_result=$?
        if (( left_result == 0 || right_result == 0 )); then
            left_result=0
        else
            left_result=1
        fi
    done
    return $left_result
}

_q_expr_parse_and() {
    _q_expr_parse_not
    local left_result=$?
    while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
          [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "AND" ]]; do
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_not
        local right_result=$?
        if (( left_result == 0 && right_result == 0 )); then
            left_result=0
        else
            left_result=1
        fi
    done
    return $left_result
}

_q_expr_parse_not() {
    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "BANG" ]]; then
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_not
        local result=$?
        if (( result == 0 )); then return 1; else return 0; fi
    fi
    _q_expr_parse_cmp
    return $?
}

_q_expr_parse_cmp() {
    _q_expr_parse_add
    local left_result=$?
    local left_val=$_Q_EXPR_VAL

    if (( _Q_EXPR_POS >= ${#_Q_EXPR_TOKS[@]} )); then
        # If primary returned a truthy value, return 0
        # For non-boolean results, non-empty/non-zero = truthy
        if [[ "$_Q_EXPR_TOK_TYPE" == "NUM" ]] || [[ "$_Q_EXPR_TOK_TYPE" == "STR" ]]; then
            return $left_result
        fi
        return $left_result
    fi

    local op="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
    case "$op" in
        "EQ"|"NE"|"LT"|"GT"|"LTE"|"GTE")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _q_expr_parse_add
            local right_result=$?
            local right_val=$_Q_EXPR_VAL

            _q_expr_compare "$op" "$left_val" "$right_val"
            return $?
            ;;
        *)
            # No comparison operator — the value itself is the boolean
            return $left_result
            ;;
    esac
}

_q_expr_parse_add() {
    _q_expr_parse_mul
    local left_result=$?
    local left_val=$_Q_EXPR_VAL
    local left_type=$_Q_EXPR_TOK_TYPE

    while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
          [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "PLUS" || "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "MINUS" ]]; do
        local op="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_mul
        local right_val=$_Q_EXPR_VAL
        local right_type=$_Q_EXPR_TOK_TYPE

        if [[ "$left_type" == "NUM" ]] && [[ "$right_type" == "NUM" ]]; then
            if [[ "$op" == "PLUS" ]]; then
                left_val=$(awk "BEGIN {printf \"%.6g\", $left_val + $right_val}")
            elif [[ "$op" == "MINUS" ]]; then
                left_val=$(awk "BEGIN {printf \"%.6g\", $left_val - $right_val}")
            fi
            left_type="NUM"
        elif [[ "$left_type" == "STR" ]] && [[ "$op" == "PLUS" ]]; then
            left_val="${left_val}${right_val}"
            left_type="STR"
        else
            left_val=""
            left_type=""
            return 1
        fi
    done

    _Q_EXPR_VAL="$left_val"
    _Q_EXPR_TOK_TYPE="$left_type"
    return $left_result
}

_q_expr_parse_mul() {
    _q_expr_parse_unary
    local left_result=$?
    local left_val=$_Q_EXPR_VAL
    local left_type=$_Q_EXPR_TOK_TYPE

    while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
          [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "STAR" || "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DIV" ]]; do
        local op="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_unary
        local right_val=$_Q_EXPR_VAL
        local right_type=$_Q_EXPR_TOK_TYPE

        if [[ "$left_type" == "NUM" ]] && [[ "$right_type" == "NUM" ]]; then
            if [[ "$op" == "STAR" ]]; then
                left_val=$(awk "BEGIN {printf \"%.6g\", $left_val * $right_val}")
            elif [[ "$op" == "DIV" ]]; then
                if [[ "$right_val" == "0" ]]; then
                    left_val=""
                    left_type=""
                    return 1
                fi
                left_val=$(awk "BEGIN {printf \"%.6g\", $left_val / $right_val}")
            fi
            left_type="NUM"
        else
            left_val=""
            left_type=""
            return 1
        fi
    done

    _Q_EXPR_VAL="$left_val"
    _Q_EXPR_TOK_TYPE="$left_type"
    return $left_result
}

_q_expr_parse_unary() {
    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "MINUS" ]]; then
        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
        _q_expr_parse_unary
        local val=$_Q_EXPR_VAL
        if [[ "$_Q_EXPR_TOK_TYPE" == "NUM" ]]; then
            _Q_EXPR_VAL=$(awk "BEGIN {printf \"%.6g\", -$val}")
            return $?
        else
            _Q_EXPR_VAL=""
            _Q_EXPR_TOK_TYPE=""
            return 1
        fi
    fi
    _q_expr_parse_primary
    return $?
}

# Parse a primary expression: NUMBER, STRING, BOOL, NULL, @node, function, or (sub-expr)
_q_expr_parse_primary() {
    if (( _Q_EXPR_POS >= ${#_Q_EXPR_TOKS[@]} )); then
        _Q_EXPR_VAL=""
        _Q_EXPR_TOK_TYPE=""
        return 1
    fi

    local tt="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
    local tv="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"

    case "$tt" in
        "LPAREN")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _q_expr_parse_or
            local result=$?
            # Skip RPAREN
            if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
               [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RPAREN" ]]; then
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            fi
            _Q_EXPR_VAL=""
            return $result
            ;;
        "NUMBER")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL="$tv"
            _Q_EXPR_TOK_TYPE="NUM"
            # Non-zero is truthy
            if [[ "$tv" == "0" ]]; then return 1; else return 0; fi
            ;;
        "STRING")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL="$tv"
            _Q_EXPR_TOK_TYPE="STR"
            # Non-empty string is truthy
            if [[ -n "$tv" ]]; then return 0; else return 1; fi
            ;;
        "TRUE")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL="true"
            _Q_EXPR_TOK_TYPE="BOOL"
            return 0
            ;;
        "FALSE")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL="false"
            _Q_EXPR_TOK_TYPE="BOOL"
            return 1
            ;;
        "NULL")
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL="null"
            _Q_EXPR_TOK_TYPE="NULL"
            return 1
            ;;
        "CUR")
            # @ — current node, followed by optional chained path
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            local cur_node=$_Q_FILTER_NODE
            local current=$cur_node

            # Consume chained .key / .length access
            while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                  [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]]; do
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                local prop="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))

                if [[ "$prop" == "length" ]]; then
                    # .length at any level — child count / string length
                    local child_type
                    child_type=$(ast_get_type "$current")
                    if [[ "$child_type" == "$_AST_T_STRING" ]]; then
                        local str_val
                        str_val=$(ast_get_value "$current")
                        _Q_EXPR_VAL="${#str_val}"
                    else
                        _Q_EXPR_VAL=$(ast_get_child_count "$current")
                    fi
                    _Q_EXPR_TOK_TYPE="NUM"
                    return 0
                fi

                local child
                child=$(ast_child_by_key "$current" "$prop")
                if [[ -n "$child" ]]; then
                    current=$child
                else
                    _Q_EXPR_VAL="null"
                    _Q_EXPR_TOK_TYPE="NULL"
                    return 1
                fi
            done

            # If we consumed at least one DOT, return final node's value
            if [[ "$current" != "$cur_node" ]]; then
                local final_type final_val
                final_type=$(ast_get_type "$current")
                final_val=$(ast_get_value "$current")
                _Q_EXPR_VAL="$final_val"
                case "$final_type" in
                    "$_AST_T_STRING") _Q_EXPR_TOK_TYPE="STR"; return 0 ;;
                    "$_AST_T_NUMBER") _Q_EXPR_TOK_TYPE="NUM"; return 0 ;;
                    "$_AST_T_BOOL")   _Q_EXPR_TOK_TYPE="BOOL";
                                      if [[ "$final_val" == "true" ]]; then return 0; else return 1; fi ;;
                    "$_AST_T_NULL")   _Q_EXPR_VAL="null"; _Q_EXPR_TOK_TYPE="NULL"; return 1 ;;
                    *)                _Q_EXPR_TOK_TYPE="REF"; return 0 ;;
                esac
            fi

            # Bare @ — the node itself
            local cur_type
            cur_type=$(ast_get_type "$cur_node")
            _Q_EXPR_VAL=""
            _Q_EXPR_TOK_TYPE="NODE"
            if [[ "$cur_type" == "$_AST_T_NULL" ]]; then
                return 1
            fi
            return 0
            ;;
        "IDENT")
            # Function call: contains(), type(), has(), length(), match(), search()
            if [[ "$tv" == "contains" || "$tv" == "type" || "$tv" == "has" || "$tv" == "length" || "$tv" == "match" || "$tv" == "search" ]]; then
                local func_name=$tv
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                # Expect LPAREN
                if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                   [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "LPAREN" ]]; then
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    # Evaluate arguments
                    local arg1="" arg2=""
                    _q_expr_parse_or
                    arg1=$_Q_EXPR_VAL
                    # Skip COMMA
                    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                       [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "COMMA" ]]; then
                        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                        _q_expr_parse_or
                        arg2=$_Q_EXPR_VAL
                    fi
                    # Skip RPAREN
                    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                       [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RPAREN" ]]; then
                        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    fi

                    case "$func_name" in
                        "contains")
                            # contains(@.key, 'str') — check if string contains substring
                            _Q_EXPR_VAL="$arg1"
                            _Q_EXPR_TOK_TYPE="STR"
                            if [[ -n "$arg2" ]] && [[ "$arg1" == *"$arg2"* ]]; then
                                return 0
                            else
                                return 1
                            fi
                            ;;
                        "type")
                            # type(@.key) — returns 'string', 'number', 'boolean', 'null', 'object', 'array'
                            local type_node_id
                            type_node_id=$(_q_eval_path "$cur_node" "$arg1")
                            if [[ -n "$type_node_id" ]]; then
                                local t
                                t=$(ast_get_type "$type_node_id")
                                case "$t" in
                                    "$_AST_T_STRING") _Q_EXPR_VAL="string" ;;
                                    "$_AST_T_NUMBER") _Q_EXPR_VAL="number" ;;
                                    "$_AST_T_BOOL")   _Q_EXPR_VAL="boolean" ;;
                                    "$_AST_T_NULL")   _Q_EXPR_VAL="null" ;;
                                    "$_AST_T_OBJECT") _Q_EXPR_VAL="object" ;;
                                    "$_AST_T_ARRAY")  _Q_EXPR_VAL="array" ;;
                                    *)                _Q_EXPR_VAL="unknown" ;;
                                esac
                                _Q_EXPR_TOK_TYPE="STR"
                                return 0
                            else
                                _Q_EXPR_VAL="null"
                                _Q_EXPR_TOK_TYPE="NULL"
                                return 1
                            fi
                            ;;
                        "has")
                            # has(@.key) — check if object has property
                            local has_node_id
                            has_node_id=$(_q_eval_path "$cur_node" "$arg1")
                            if [[ -n "$has_node_id" ]]; then
                                _Q_EXPR_VAL="true"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 0
                            else
                                _Q_EXPR_VAL="false"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 1
                            fi
                            ;;
                        "length")
                            # length(@) or length(@.key) — child count / string length
                            # arg1 is the evaluated argument value, not a path
                            if [[ -z "$arg1" ]]; then
                                # length(@) — child count of current filter node
                                _Q_EXPR_VAL=$(ast_get_child_count "$_Q_FILTER_NODE")
                            else
                                # length(@.key) — string length of the value
                                _Q_EXPR_VAL="${#arg1}"
                            fi
                            _Q_EXPR_TOK_TYPE="NUM"
                            return 0
                            ;;
                        "match")
                            # match(@.key, 'pattern') — regex match (bash =~)
                            if [[ -n "$arg2" ]] && [[ "$arg1" =~ $arg2 ]]; then
                                _Q_EXPR_VAL="true"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 0
                            else
                                _Q_EXPR_VAL="false"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 1
                            fi
                            ;;
                        "search")
                            # search(@.key, 'pattern') — regex search (same as match)
                            if [[ -n "$arg2" ]] && [[ "$arg1" =~ $arg2 ]]; then
                                _Q_EXPR_VAL="true"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 0
                            else
                                _Q_EXPR_VAL="false"
                                _Q_EXPR_TOK_TYPE="BOOL"
                                return 1
                            fi
                            ;;
                    esac
                fi
            fi
            # Unknown identifier — skip
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL=""
            _Q_EXPR_TOK_TYPE=""
            return 1
            ;;
        *)
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            _Q_EXPR_VAL=""
            return 1
            ;;
    esac
}

# Compare two values
_q_expr_compare() {
    local op=$1 a=$2 b=$3

    # Try numeric comparison first
    if [[ "$a" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ && \
          "$b" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
        local cmp
        cmp=$(number_compare "$a" "$b")
        case "$op" in
            "EQ") [[ "$cmp" == "0" ]]; return $? ;;
            "NE") [[ "$cmp" != "0" ]]; return $? ;;
            "LT") [[ "$cmp" == "-1" ]]; return $? ;;
            "GT") [[ "$cmp" == "1" ]]; return $? ;;
            "LTE") [[ "$cmp" == "-1" || "$cmp" == "0" ]]; return $? ;;
            "GTE") [[ "$cmp" == "1" || "$cmp" == "0" ]]; return $? ;;
        esac
    fi

    # String comparison fallback
    case "$op" in
        "EQ") [[ "$a" == "$b" ]]; return $? ;;
        "NE") [[ "$a" != "$b" ]]; return $? ;;
        "LT") [[ "$a" < "$b" ]]; return $? ;;
        "GT") [[ "$a" > "$b" ]]; return $? ;;
        "LTE") [[ "$a" < "$b" || "$a" == "$b" ]]; return $? ;;
        "GTE") [[ "$a" > "$b" || "$a" == "$b" ]]; return $? ;;
    esac

    return 1
}

# ── Path-level tokenizer helpers (used also in filter tokenization) ──

# Token types for expression tokenization:
# (These are the same as path token types — they share the same enum)

# --- json.sh ---
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
if [[ -n "${_JSON_LOADED:-}" ]] && type error_clear &>/dev/null && type ast_init &>/dev/null; then
    return
fi

# Source all modules — robust path resolution
# Supports bash (BASH_SOURCE) and zsh (%x prompt expansion)
# shellcheck disable=SC2296
_self="${BASH_SOURCE[0]:-${(%):-%x}}"
SELF_DIR="$(cd "$(dirname "$_self")" && pwd -P 2>/dev/null)" || SELF_DIR=""
if [[ -z "$SELF_DIR" || ! -f "$SELF_DIR/error.sh" ]]; then
    SELF_DIR="$PWD/src"
    [[ -f "$SELF_DIR/error.sh" ]] || SELF_DIR="$PWD"
fi


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
# Usage: json.dump <node_id> [indent]
#   indent: 0 (compact, default) or 2 (pretty)
json.dump() {
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

