# shell-json Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete, compiler-style JSON parsing and querying library in pure bash with lexer, parser, file-backed AST, RFC 9535 JSONPath, and round-trip serialization.

**Architecture:** Compiler pipeline model — `lexer.sh` (character-level tokenizer) → `parser.sh` (recursive descent) → `ast.sh` (file-backed node store) → `query.sh`/`writer.sh`. Each module is a bash script with prefix-named functions and no external deps beyond standard POSIX tools.

**Tech Stack:** Pure bash (>= v4 for associative arrays), POSIX userland (mkdir, mktemp, rm, etc.). No jq, Python, or any non-standard tooling. `bc` optional for float comparison in JSONPath filters.

---

## Chunk 1: Foundation (error.sh, ast.sh)

### Task 1: error.sh — Error handling framework

**Files:**
- Create: `error.sh`

- [ ] **Write error.sh**

```bash
# Error handling framework for shell-json.
# Provides global last-error state with code + message.

_JSON_ERR_CODE=0
_JSON_ERR_MSG=""

# Error codes
_JSON_ERR_GENERAL=1
_JSON_ERR_LEXER=2
_JSON_ERR_PARSER=3
_JSON_ERR_TYPE=4
_JSON_ERR_KEY_NOT_FOUND=5
_JSON_ERR_INDEX_OOB=6
_JSON_ERR_PATH_SYNTAX=7
_JSON_ERR_IO=8

error_set()   { _JSON_ERR_CODE=$1; _JSON_ERR_MSG=$2; }
error_get()   { echo "$_JSON_ERR_CODE: $_JSON_ERR_MSG"; }
error_clear() { _JSON_ERR_CODE=0; _JSON_ERR_MSG=""; }
error_code()  { echo "$_JSON_ERR_CODE"; }
error_msg()   { echo "$_JSON_ERR_MSG"; }
```

- [ ] **Test error.sh manually**

```bash
source error.sh
error_clear
error_set 42 "test error"
echo "Code: $(error_code), Msg: $(error_msg)"
error_get
```

### Task 2: ast.sh — File-backed AST node store

**Files:**
- Create: `ast.sh`

Manages a temp directory with one file per node and a sequential counter.

```bash
# AST node types
_AST_STRING=0
_AST_NUMBER=1
_AST_BOOL=2
_AST_NULL=3
_AST_OBJECT=4
_AST_ARRAY=5

_AST_DIR=""
_AST_COUNTER_FILE=""

ast_init() {
    _AST_DIR=$(mktemp -d "/tmp/shell-json.XXXXXX")
    _AST_COUNTER_FILE="$_AST_DIR/counter"
    echo 0 > "$_AST_COUNTER_FILE"
}

# Create a node and return its ID
ast_create() {
    local type=$1 value=$2
    local id
    read -r id < "$_AST_COUNTER_FILE"
    id=$((id + 1))
    echo "$id" > "$_AST_COUNTER_FILE"
    
    # Pad ID to 7 digits for sorted directory listing
    local padded_id
    printf -v padded_id "%07d" "$id"
    
    # Write node file as JSON
    if [ -n "$value" ]; then
        echo "{\"t\":$type,\"v\":\"$value\"}" > "$_AST_DIR/nodes/$padded_id"
    else
        echo "{\"t\":$type}" > "$_AST_DIR/nodes/$padded_id"
    fi
    
    echo "$id"
}

ast_get_type() {
    local padded_id
    printf -v padded_id "%07d" "$1"
    sed -n 's/.*"t":\([0-9]\+\).*/\1/p' "$_AST_DIR/nodes/$padded_id"
}

ast_get_value() {
    local padded_id
    printf -v padded_id "%07d" "$1"
    sed -n 's/.*"v":"\([^"]*\)".*/\1/p' "$_AST_DIR/nodes/$padded_id"
}

ast_set_child() {
    local parent_id=$1 child_id=$2
    local padded_id
    printf -v padded_id "%07d" "$parent_id"
    local file="$padded_id"
    # ... (full file manipulation logic)
}

# ... etc
```

---

## Chunk 2: Lexer + String + Number

### Task 3: string.sh — String encode/decode

**Files:**
- Create: `string.sh`

Handles `\uXXXX` → UTF-8 conversion, all JSON escape sequences, and reverse.

### Task 4: number.sh — Number validation

**Files:**
- Create: `number.sh`

Validates JSON number syntax via regex, no conversion.

### Task 5: lexer.sh — Tokenizer

**Files:**
- Create: `lexer.sh`

Character-level state machine. Reads JSON text, emits token lines.

---

## Chunk 3: Parser + Object/Array wrappers

### Task 6: parser.sh — Recursive descent parser

**Files:**
- Create: `parser.sh`

Consumes lexer token stream, builds AST via ast.sh functions.

### Task 7: object.sh + array.sh — Convenience wrappers

**Files:**
- Create: `object.sh`, `array.sh`

High-level operations on AST object/array nodes.

---

## Chunk 4: Writer + Query

### Task 8: writer.sh — JSON serializer

**Files:**
- Create: `writer.sh`

Recursive AST walk → indented or compact JSON string.

### Task 9: query.sh — JSONPath engine

**Files:**
- Create: `query.sh`

Full RFC 9535 JSONPath with mini-lexer, expression evaluator for filters.

---

## Chunk 5: Public API + Tests

### Task 10: json.sh — Public API

**Files:**
- Create: `json.sh`

Sources all modules, exposes clean public interface with `json.XXX` functions.

### Task 11: tests/ — Test suite

**Files:**
- Create: `tests/run_tests.sh`
- Create: `tests/test_lexer.sh`
- Create: `tests/test_parser.sh`
- Create: `tests/test_writer.sh`
- Create: `tests/test_query.sh`
- Create: `tests/test_string.sh`
- Create: `tests/test_number.sh`
- Create: `tests/test_ast.sh`
- Create: `tests/fixtures/simple.json`
- Create: `tests/fixtures/complex.json`
