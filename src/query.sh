#!/usr/bin/env bash
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
#   [?(expr)]    Filter expression
#
# Filter expressions support:
#   Comparisons: == != < > <= >=
#   Logical: && || !
#   Parentheses for grouping
#   String literals: '...'
#   Number literals
#   @.key / @.length
#   true / false / null literals
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
            # Could be index or slice start — check next token
            if (( _Q_TPOS + 1 < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$((_Q_TPOS + 1))]}" == "COLON" ]]; then
                _q_parse_slice
            else
                _Q_SEGMENTS+=("idx:${_Q_TV[$_Q_TPOS]}")
                _Q_TPOS=$((_Q_TPOS+1))
            fi
            ;;
        "STRING")
            _Q_SEGMENTS+=("key:${_Q_TV[$_Q_TPOS]}")
            _Q_TPOS=$((_Q_TPOS+1))
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
            "'")
                # Single-quoted string
                local start=$((i+1))
                local j=$start
                while (( j < len )); do
                    [[ "${s:$j:1}" == "'" ]] && break
                    j=$((j+1))
                done
                _Q_TT+=("STRING")
                _Q_TV+=("${s:$start:$((j-start))}")
                i=$((j+1))
                ;;
            '-'|[0-9])
                # Number
                local ns=$i
                local ni=$i
                while (( ni < len )); do
                    local nc="${s:$ni:1}"
                    [[ "$nc" != '-' && "$nc" != '+' && "$nc" != [0-9] ]] && break
                    ni=$((ni+1))
                done
                _Q_TT+=("NUMBER")
                _Q_TV+=("${s:$ns:$((ni-ns))}")
                i=$ni
                ;;
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
#   add_expr = primary (for future extensions)
#   primary  = '(' or_expr ')' | NUMBER | STRING | 'true' | 'false' | 'null' | '@' path

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
    _q_expr_parse_primary
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
            _q_expr_parse_primary
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

# Parse a primary expression: NUMBER, STRING, BOOL, NULL, @node, or (sub-expr)
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
            # @ — current node, followed by path
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            local cur_node=$_Q_FILTER_NODE
            local cur_type
            cur_type=$(ast_get_type "$cur_node")

            # Check for .key or .length access
            if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
               [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]]; then
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                local prop="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                if [[ "$prop" == "length" ]]; then
                    local length
                    length=$(ast_get_child_count "$cur_node")
                    _Q_EXPR_VAL="$length"
                    _Q_EXPR_TOK_TYPE="NUM"
                    return 0
                else
                    # Access child by key
                    local child
                    child=$(ast_child_by_key "$cur_node" "$prop")
                    if [[ -n "$child" ]]; then
                        local child_type child_val
                        child_type=$(ast_get_type "$child")
                        child_val=$(ast_get_value "$child")
                        _Q_EXPR_VAL="$child_val"
                        case "$child_type" in
                            "$_AST_T_STRING") _Q_EXPR_TOK_TYPE="STR"; return 0 ;;
                            "$_AST_T_NUMBER") _Q_EXPR_TOK_TYPE="NUM"; return 0 ;;
                            "$_AST_T_BOOL")   _Q_EXPR_TOK_TYPE="BOOL";
                                              if [[ "$child_val" == "true" ]]; then return 0; else return 1; fi ;;
                            *) _Q_EXPR_TOK_TYPE="REF"; return 0 ;;
                        esac
                    else
                        # Property not found — null value
                        _Q_EXPR_VAL="null"
                        _Q_EXPR_TOK_TYPE="NULL"
                        return 1
                    fi
                fi
            else
                # Bare @ — the node itself
                _Q_EXPR_VAL=""
                _Q_EXPR_TOK_TYPE="NODE"
                # Object/array nodes are truthy
                if [[ "$cur_type" == "$_AST_T_NULL" ]]; then
                    return 1
                fi
                return 0
            fi
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
