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
    _Q_ROOT_NODE=$root_id
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
_Q_MUTATION_PARENTS=()

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
_Q_ROOT_NODE=""
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

# Parse filter expression [?(@.price<10)] or [?@.price<10] into a segment
# Collects tokens until matching RPAREN (paren form) or RBRACKET/COMMA (bare form)
# Stores as pipe-delimited string
_q_parse_filter() {
    local expr_tokens=""

    # Check if filter is parenthesized: ?(...) or bare: ?expr
    if (( _Q_TPOS < ${#_Q_TT[@]} )) && [[ "${_Q_TT[$_Q_TPOS]}" == "LPAREN" ]]; then
        # Parenthesized form — skip LPAREN, collect until matching RPAREN
        _Q_TPOS=$((_Q_TPOS+1))
        local depth=1
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
    else
        # Bare form [?expr] — collect until RBRACKET or COMMA (don't consume)
        while (( _Q_TPOS < ${#_Q_TT[@]} )) && \
              [[ "${_Q_TT[$_Q_TPOS]}" != "RBRACKET" && "${_Q_TT[$_Q_TPOS]}" != "COMMA" ]]; do
            local t="${_Q_TT[$_Q_TPOS]}"
            local v="${_Q_TV[$_Q_TPOS]}"
            if [[ -n "$expr_tokens" ]]; then
                expr_tokens+="|"
            fi
            expr_tokens+="$t:$v"
            _Q_TPOS=$((_Q_TPOS+1))
        done
    fi

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
                # Single or double-quoted string (with escape support)
                local quote="${s:$i:1}"
                local start=$((i+1))
                local j=$start
                while (( j < len )); do
                    local ch="${s:$j:1}"
                    if [[ "$ch" == '\' ]] && (( j + 1 < len )); then
                        # Skip escaped character (including escaped quote)
                        j=$((j+2))
                        continue
                    fi
                    [[ "$ch" == "$quote" ]] && break
                    j=$((j+1))
                done
                _Q_TT+=("STRING")
                # Store raw text with escape sequences preserved
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
            '-')
                if (( i+1 < len )) && [[ "${s:$((i+1)):1}" =~ [0-9] ]]; then
                    # Negative number (e.g. $[-1])
                    local ns=$((i+1))
                    local ni=$ns
                    while (( ni < len )) && [[ "${s:$ni:1}" =~ [0-9] ]]; do ni=$((ni+1)); done
                    if (( ni < len )) && [[ "${s:$ni:1}" == "." ]]; then
                        ni=$((ni+1))
                        while (( ni < len )) && [[ "${s:$ni:1}" =~ [0-9] ]]; do ni=$((ni+1)); done
                    fi
                    _Q_TT+=("NUMBER")
                    _Q_TV+=("-${s:$ns:$((ni-ns))}")
                    i=$ni
                else
                    _Q_TT+=("MINUS"); _Q_TV+=(""); i=$((i+1))
                fi
                ;;
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
                        '.'|'['|']'|'*'|':'|','|'?'|'('|')'|' '|$'\t'|$'\r'|$'\n'|"'"|'$'|'@'|'<'|'>'|'='|'!'|'&'|'|') break ;;
                    esac
                    ki=$((ki+1))
                done
                if (( ki > ks )); then
                    local kw="${s:$ks:$((ki-ks))}"
                    case "$kw" in
                        "true")  _Q_TT+=("TRUE");  _Q_TV+=("") ;;
                        "false") _Q_TT+=("FALSE"); _Q_TV+=("") ;;
                        "null")  _Q_TT+=("NULL");  _Q_TV+=("") ;;
                        *)       _Q_TT+=("IDENT"); _Q_TV+=("$kw") ;;
                    esac
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
    mapfile -t nodes <<< "$lines"

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
    local type child_count
    type=$(ast_get_type "$node_id")
    if [[ "$type" == "$_AST_T_ARRAY" ]]; then
        # Handle negative indexing
        if (( idx < 0 )); then
            child_count=$(ast_get_child_count "$node_id")
            idx=$((child_count + idx))
        fi
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
    set -f; read -ra parts <<< "$values"; set +f
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
    local left_type=$_Q_EXPR_TOK_TYPE

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
            local right_type=$_Q_EXPR_TOK_TYPE

            _q_expr_compare "$op" "$left_val" "$right_val" "$left_type" "$right_type"
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

            # Consume chained .key / .length access or bracket [n] / ['key'] access
            while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                  { [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]] || \
                    [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "LBRACKET" ]]; }; do
                if [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]]; then
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    local prop="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))

                    if [[ "$prop" == "length" ]]; then
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
                else
                    # Bracket access: [n] or ['key'] or ["key"]
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    local bt="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
                    local bv="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"

                    # Check for nested filter [?(...)] — evaluate inner filter
                    if [[ "$bt" == "QMARK" ]]; then
                        # Position is at LPAREN after QMARK
                        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                        # Collect inner filter expression tokens up to matching RPAREN
                        local inner_depth=0
                        local inner_tokens=""
                        while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && (( inner_depth >= 0 )); do
                            local it="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
                            local iv="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                            if [[ "$it" == "LPAREN" ]]; then
                                inner_depth=$((inner_depth+1))
                            elif [[ "$it" == "RPAREN" ]]; then
                                inner_depth=$((inner_depth-1))
                                if (( inner_depth <= 0 )); then
                                    break
                                fi
                            fi
                            if [[ -n "$inner_tokens" ]]; then
                                inner_tokens+="|"
                            fi
                            inner_tokens+="$it:$iv"
                            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                        done
                        # Skip RPAREN and RBRACKET closing ?(...) bracket selector
                        if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                           [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RPAREN" ]]; then
                            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                        fi
                        if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                           [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RBRACKET" ]]; then
                            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                        fi

                        # Evaluate inner filter against current node's children
                        local nt
                        nt=$(ast_get_type "$current")
                        local found_child=""
                        if [[ "$nt" == "$_AST_T_ARRAY" ]]; then
                            local children
                            children=$(ast_get_children "$current")
                            # Save outer expression state
                            local saved_expr_pos=$_Q_EXPR_POS
                            local -a saved_expr_toks=("${_Q_EXPR_TOKS[@]}")
                            local -a saved_expr_vals=("${_Q_EXPR_VALS[@]}")
                            local saved_filter_node=$_Q_FILTER_NODE

                            local ch
                            for ch in $children; do
                                if _q_eval_filter_expr "$ch" "$inner_tokens"; then
                                    found_child=$ch
                                    break
                                fi
                            done

                            # Restore outer expression state
                            _Q_EXPR_POS=$saved_expr_pos
                            _Q_EXPR_TOKS=("${saved_expr_toks[@]}")
                            _Q_EXPR_VALS=("${saved_expr_vals[@]}")
                            _Q_FILTER_NODE=$saved_filter_node
                        fi

                        if [[ -n "$found_child" ]]; then
                            current=$found_child
                            continue
                        else
                            _Q_EXPR_VAL="null"
                            _Q_EXPR_TOK_TYPE="NULL"
                            return 1
                        fi
                    fi

                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    # Skip RBRACKET
                    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                       [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RBRACKET" ]]; then
                        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    fi

                    local child=""
                    if [[ "$bt" == "NUMBER" ]]; then
                        child=$(ast_child_by_index "$current" "$bv")
                    elif [[ "$bt" == "STRING" ]]; then
                        child=$(ast_child_by_key "$current" "$bv")
                    fi
                    if [[ -n "$child" ]]; then
                        current=$child
                    else
                        _Q_EXPR_VAL="null"
                        _Q_EXPR_TOK_TYPE="NULL"
                        return 1
                    fi
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

            # Bare @ — the node itself, resolve to its value
            local cur_type cur_val
            cur_type=$(ast_get_type "$cur_node")
            cur_val=$(ast_get_value "$cur_node")
            _Q_EXPR_VAL="$cur_val"
            case "$cur_type" in
                "$_AST_T_STRING") _Q_EXPR_TOK_TYPE="STR"; return 0 ;;
                "$_AST_T_NUMBER") _Q_EXPR_TOK_TYPE="NUM"; return 0 ;;
                "$_AST_T_BOOL")   _Q_EXPR_TOK_TYPE="BOOL";
                                  if [[ "$cur_val" == "true" ]]; then return 0; else return 1; fi ;;
                "$_AST_T_NULL")   _Q_EXPR_VAL="null"; _Q_EXPR_TOK_TYPE="NULL"; return 1 ;;
                *)                _Q_EXPR_TOK_TYPE="REF"; return 0 ;;
            esac
            ;;
        "ROOT")
            # $ — root node reference in filter expression, followed by optional chained path
            _Q_EXPR_POS=$((_Q_EXPR_POS+1))
            local current=$_Q_ROOT_NODE

            # Consume chained .key / .length access or bracket [n] / ['key'] access
            while (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                  { [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]] || \
                    [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "LBRACKET" ]]; }; do
                if [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "DOT" ]]; then
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    local prop="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    if [[ "$prop" == "length" ]]; then
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
                else
                    # Bracket access: [n] or ['key'] or ["key"]
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    local bt="${_Q_EXPR_TOKS[$_Q_EXPR_POS]}"
                    local bv="${_Q_EXPR_VALS[$_Q_EXPR_POS]}"
                    _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    local child=""
                    if [[ "$bt" == "NUMBER" ]]; then
                        child=$(ast_child_by_index "$current" "$bv")
                    elif [[ "$bt" == "STRING" ]]; then
                        child=$(ast_child_by_key "$current" "$bv")
                    fi
                    if [[ -n "$child" ]]; then
                        current=$child
                    else
                        _Q_EXPR_VAL="null"
                        _Q_EXPR_TOK_TYPE="NULL"
                        return 1
                    fi
                    # Skip RBRACKET
                    if (( _Q_EXPR_POS < ${#_Q_EXPR_TOKS[@]} )) && \
                       [[ "${_Q_EXPR_TOKS[$_Q_EXPR_POS]}" == "RBRACKET" ]]; then
                        _Q_EXPR_POS=$((_Q_EXPR_POS+1))
                    fi
                fi
            done

            # Return final node value
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
            ;;
        "IDENT")
            # Function call: contains(), type(), has(), length(), match(), search(), count(), value()
            if [[ "$tv" == "contains" || "$tv" == "type" || "$tv" == "has" || "$tv" == "length" || "$tv" == "match" || "$tv" == "search" || "$tv" == "count" || "$tv" == "value" ]]; then
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
                        "count")
                            # count(@.key) — returns 1 if node exists, 0 otherwise
                            if [[ "$_Q_EXPR_TOK_TYPE" == "REF" ]]; then
                                _Q_EXPR_VAL="1"
                            elif [[ -n "$arg1" ]] && [[ "$arg1" != "null" ]]; then
                                _Q_EXPR_VAL="1"
                            else
                                _Q_EXPR_VAL="0"
                            fi
                            _Q_EXPR_TOK_TYPE="NUM"
                            return 0
                            ;;
                        "value")
                            # value(@.key) — extract value from singleton nodelist
                            # In our implementation, values are already scalar, so this is identity
                            _Q_EXPR_VAL="$arg1"
                            _Q_EXPR_TOK_TYPE="${_Q_EXPR_TOK_TYPE:-STR}"
                            return 0
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

# Compare two values with RFC 9535 semantics
# Types: NUM, STR, BOOL, NULL, REF/NODE (structured — object/array)
# Rules:
#   Same type: numeric, string, boolean, null comparison (boolean/structured < > => false)
#   Type mismatch (including both REF/NODE): == false, != true, < > <= >= false
_q_expr_compare() {
    local op=$1 a=$2 b=$3
    local left_type=$4 right_type=$5

    # Type mismatch: only == and != are valid (both false for ==, true for !=)
    if [[ "$left_type" != "$right_type" ]]; then
        case "$op" in
            "EQ") return 1 ;;
            "NE") return 0 ;;
            *)    return 1 ;;  # < > <= >= → false
        esac
    fi

    # Same type comparison
    case "$left_type" in
        "NUM")
            local cmp
            cmp=$(number_compare "$a" "$b")
            case "$op" in
                "EQ")  [[ "$cmp" == "0" ]]; return $? ;;
                "NE")  [[ "$cmp" != "0" ]]; return $? ;;
                "LT")  [[ "$cmp" == "-1" ]]; return $? ;;
                "GT")  [[ "$cmp" == "1" ]]; return $? ;;
                "LTE") [[ "$cmp" == "-1" || "$cmp" == "0" ]]; return $? ;;
                "GTE") [[ "$cmp" == "1" || "$cmp" == "0" ]]; return $? ;;
            esac
            ;;
        "STR")
            case "$op" in
                "EQ")  [[ "$a" == "$b" ]]; return $? ;;
                "NE")  [[ "$a" != "$b" ]]; return $? ;;
                "LT")  [[ "$a" < "$b" ]]; return $? ;;
                "GT")  [[ "$a" > "$b" ]]; return $? ;;
                "LTE") [[ "$a" < "$b" || "$a" == "$b" ]]; return $? ;;
                "GTE") [[ "$a" > "$b" || "$a" == "$b" ]]; return $? ;;
            esac
            ;;
        "BOOL")
            # No ordering for booleans per RFC 9535
            case "$op" in
                "EQ") [[ "$a" == "$b" ]]; return $? ;;
                "NE") [[ "$a" != "$b" ]]; return $? ;;
                *)    return 1 ;;  # < > <= ≥ → false
            esac
            ;;
        "NULL")
            # null == null → true, null != null → false, others → false
            case "$op" in
                "EQ") return 0 ;;
                "NE") return 1 ;;
                *)    return 1 ;;
            esac
            ;;
        "REF"|"NODE")
            # Structured types: ==/!= structural (empty string = the node ref), others false
            case "$op" in
                "EQ") [[ "$a" == "$b" ]]; return $? ;;
                "NE") [[ "$a" != "$b" ]]; return $? ;;
                *)    return 1 ;;  # < > <= ≥ → false
            esac
            ;;
        *)
            # Unknown types — fall back to string
            case "$op" in
                "EQ") [[ "$a" == "$b" ]]; return $? ;;
                "NE") [[ "$a" != "$b" ]]; return $? ;;
                "LT") [[ "$a" < "$b" ]]; return $? ;;
                "GT") [[ "$a" > "$b" ]]; return $? ;;
                "LTE") [[ "$a" < "$b" || "$a" == "$b" ]]; return $? ;;
                "GTE") [[ "$a" > "$b" || "$a" == "$b" ]]; return $? ;;
            esac
            ;;
    esac
}

# ── Mutation operations (set / delete / push) ────────────────────────

# Internal: resolve parent node(s) + last segment info from a JSONPath
_q_resolve_for_mutation() {
    local root_id=$1 path_expr=$2
    _q_parse_path "$path_expr"
    local seg_count=${#_Q_SEGMENTS[@]}
    (( seg_count > 0 )) || { _Q_MUTATION_PARENTS=(); return 1; }

    local last_seg="${_Q_SEGMENTS[$((seg_count - 1))]}"
    _Q_MUTATION_LAST_TYPE="${last_seg%%:*}"
    _Q_MUTATION_LAST_VALUE="${last_seg#*:}"

    if (( seg_count == 1 )); then
        _Q_MUTATION_PARENTS=("$root_id")
        return 0
    fi

    _Q_ROOT_NODE=$root_id
    _Q_RESULT="$root_id"$'\n'
    local seg_idx
    for (( seg_idx = 0; seg_idx < seg_count - 1; seg_idx++ )); do
        local seg="${_Q_SEGMENTS[$seg_idx]}"
        _Q_NEXT_RESULT=""
        _q_eval_segment "$seg"
        _Q_RESULT="$_Q_NEXT_RESULT"
    done

    _Q_MUTATION_PARENTS=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && _Q_MUTATION_PARENTS+=("$id")
    done <<< "$(printf '%s' "$_Q_RESULT" | sed '/^$/d')"
    return 0
}

# Set a value at a JSONPath location
# Usage: query_set <root_id> <path> <json_value_string>
# Parses json_value_string and attaches it at the path
query_set() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local root_id=$1 path_expr=$2 json_value=$3
    error_clear

    _q_resolve_for_mutation "$root_id" "$path_expr" || {
        error_setf "$_JSON_ERR_PATH_SYNTAX" "Invalid JSONPath '%s' in set operation" "$path_expr"
        return 1
    }

    local seg_type="$_Q_MUTATION_LAST_TYPE"
    local seg_val="$_Q_MUTATION_LAST_VALUE"
    [[ -n "$seg_type" ]] || {
        error_setf "$_JSON_ERR_PATH_SYNTAX" "Cannot set value at root '$path_expr'" "$path_expr"
        return 1
    }

    local matched=0 parent
    for parent in "${_Q_MUTATION_PARENTS[@]}"; do
        case "$seg_type" in
            "key")
                local existing
                existing=$(ast_child_by_key "$parent" "$seg_val")
                lexer_init "$json_value"
                local new_node
                new_node=$(parser_parse) || continue
                if [[ -n "$existing" ]]; then
                    ast_replace_child "$parent" "$existing" "$new_node"
                    ast_delete_recursive "$existing"
                else
                    ast_set_child_with_key "$parent" "$new_node" "$seg_val"
                fi
                matched=1
                ;;
            "idx")
                local existing
                existing=$(ast_child_by_index "$parent" "$seg_val")
                if [[ -n "$existing" ]]; then
                    lexer_init "$json_value"
                    local new_node
                    new_node=$(parser_parse) || continue
                    ast_replace_child "$parent" "$existing" "$new_node"
                    ast_delete_recursive "$existing"
                    matched=1
                fi
                ;;
            "wild")
                local children
                children=$(ast_get_children "$parent")
                local child
                for child in $children; do
                    lexer_init "$json_value"
                    local new_node
                    new_node=$(parser_parse) || continue
                    ast_replace_child "$parent" "$child" "$new_node"
                    ast_delete_recursive "$child"
                done
                matched=1
                ;;
        esac
    done

    if (( matched == 0 )); then
        error_setf "$_JSON_ERR_KEY_NOT_FOUND" "No matching location for path '%s' in set operation" "$path_expr"
        return 1
    fi
    return 0
}

# Delete nodes matching a JSONPath
# Usage: query_delete <root_id> <path>
query_delete() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local root_id=$1 path_expr=$2
    error_clear

    _q_resolve_for_mutation "$root_id" "$path_expr" || {
        error_setf "$_JSON_ERR_PATH_SYNTAX" "Invalid JSONPath '%s' in delete operation" "$path_expr"
        return 1
    }

    local seg_type="$_Q_MUTATION_LAST_TYPE"
    local seg_val="$_Q_MUTATION_LAST_VALUE"
    [[ -n "$seg_type" ]] || {
        error_setf "$_JSON_ERR_PATH_SYNTAX" "Cannot delete root '$path_expr'" "$path_expr"
        return 1
    }

    local parent
    for parent in "${_Q_MUTATION_PARENTS[@]}"; do
        case "$seg_type" in
            "key")
                local existing
                existing=$(ast_child_by_key "$parent" "$seg_val")
                if [[ -n "$existing" ]]; then
                    ast_remove_child "$parent" "$existing"
                    ast_delete_recursive "$existing"
                fi
                ;;
            "idx")
                local existing
                existing=$(ast_child_by_index "$parent" "$seg_val")
                if [[ -n "$existing" ]]; then
                    ast_remove_child "$parent" "$existing"
                    ast_delete_recursive "$existing"
                fi
                ;;
            "wild")
                local children
                children=$(ast_get_children "$parent")
                local child
                for child in $children; do
                    ast_remove_child "$parent" "$child"
                    ast_delete_recursive "$child"
                done
                ;;
        esac
    done
    return 0
}

# Push a value to the end of an array
# Usage: query_push <root_id> <array_path> <json_value_string>
# The full path resolves to the target array (unlike set/delete which split
# on the last segment to find the parent).
query_push() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt localoptions KSH_ARRAYS SH_WORD_SPLIT
    fi
    local root_id=$1 path_expr=$2 json_value=$3
    error_clear

    _q_parse_path "$path_expr"
    local seg_count=${#_Q_SEGMENTS[@]}

    # Resolve ALL segments — the matched nodes ARE the arrays
    _Q_ROOT_NODE=$root_id
    _Q_RESULT="$root_id"$'\n'
    local seg_idx
    for (( seg_idx = 0; seg_idx < seg_count; seg_idx++ )); do
        local seg="${_Q_SEGMENTS[$seg_idx]}"
        _Q_NEXT_RESULT=""
        _q_eval_segment "$seg"
        _Q_RESULT="$_Q_NEXT_RESULT"
    done

    local matched=0
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        local parent_type
        parent_type=$(ast_get_type "$id")
        if [[ "$parent_type" == "$_AST_T_ARRAY" ]]; then
            lexer_init "$json_value"
            local new_node
            new_node=$(parser_parse) || continue
            ast_set_child "$id" "$new_node"
            matched=1
        fi
    done <<< "$(printf '%s' "$_Q_RESULT" | sed '/^$/d')"

    if (( matched == 0 )); then
        error_setf "$_JSON_ERR_TYPE" "Path '%s' does not resolve to an array" "$path_expr"
        return 1
    fi
    return 0
}

# ── Path-level tokenizer helpers (used also in filter tokenization) ──

# Token types for expression tokenization:
# (These are the same as path token types — they share the same enum)
