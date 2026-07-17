#!/usr/bin/env bash
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
