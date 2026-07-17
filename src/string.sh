#!/usr/bin/env bash
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
