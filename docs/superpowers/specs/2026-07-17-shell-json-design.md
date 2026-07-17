# shell-json: A Compiler-Style JSON Library in Pure Bash

## Overview

A fully-featured JSON parsing and querying library implemented entirely in
POSIX-compatible Bash, designed with a compiler architecture:
**lexer → parser → AST → query/writer**.  No external dependencies — no jq,
no Python, no grep/sed hacks.  Every JSON construct and every RFC 9535
JSONPath feature is handled through a proper pipeline.

## Architecture

```
┌─────────┐   tokens    ┌──────────┐   AST nodes   ┌─────────────────┐
│ lexer.sh │ ──────────► │ parser.sh│ ────────────► │  ast.sh         │
│ (stream) │             │ (rec-des)│               │ (file-backed)   │
└─────────┘             └──────────┘               └──┬──────────────┘
                                                      │
                    ┌─────────────────────────────────┼──────────────┐
                    │               │                 │              │
               ┌────▼────┐   ┌─────▼─────┐   ┌───────▼──────┐  ┌───▼────┐
               │query.sh │   │ writer.sh │   │ object.sh    │  │array.sh│
               │(JSONPath│   │(serialize)│   │array.sh      │  │string  │
               │ RFC9535)│   │           │   │string.sh     │  │number  │
               └─────────┘   └───────────┘   │number.sh     │  │        │
                                             └──────────────┘  └────────┘
```

### Lexer (`lexer.sh`)

Character-level state machine that consumes JSON text and emits tokens.

**Token types** (emitted as lines of text):

| Token        | Text representation |
|--------------|---------------------|
| STRING       | `TOKEN_STRING <value>` |
| NUMBER       | `TOKEN_NUMBER <raw>`   |
| TRUE         | `TOKEN_TRUE`           |
| FALSE        | `TOKEN_FALSE`          |
| NULL         | `TOKEN_NULL`           |
| LBRACE       | `TOKEN_LBRACE`         |
| RBRACE       | `TOKEN_RBRACE`         |
| LBRACKET     | `TOKEN_LBRACKET`       |
| RBRACKET     | `TOKEN_RBRACKET`       |
| COLON        | `TOKEN_COLON`          |
| COMMA        | `TOKEN_COMMA`          |
| EOF          | `TOKEN_EOF`            |
| ERROR        | `TOKEN_ERROR <msg>`    |

**Whitespace**: skip `0x20` (space), `0x09` (tab), `0x0A` (LF), `0x0D` (CR).

**String scanning**:
- Collect characters until unescaped `"`.
- Handle escape sequences: `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`.
- Handle `\uXXXX` — decode 4 hex digits into UTF-8 bytes using the
  surrogate-pair rules from RFC 8259 §9.
- Error on: unterminated strings, invalid escapes, lone surrogates.

**Number scanning**:
- Optional `-`.
- Integer part: one or more digits (`0` or `[1-9][0-9]*`).
- Optional fraction: `.` followed by one or more digits.
- Optional exponent: `e`/`E`, optional `+`/`-`, one or more digits.
- Numbers are stored as their raw text — no conversion to bash integers
  (which would lose precision beyond 63 bits).

**Interface**:
```bash
# Initialise: point lexer at a JSON string or file
lexer_init <string_or_file>

# Return the next token (text representation above)
lexer_next

# Return the next token without consuming it
lexer_peek

# Current position (for error messages)
lexer_get_position  # prints "line:col"
```

The lexer reads from a temporary file descriptor (or a pipe) and advances
an internal position counter stored in a variable.

### Parser (`parser.sh`)

Recursive-descent parser operating over the lexer token stream.  It
consumes tokens and calls `ast_create()` to build the AST.

**Grammar** (single token lookahead):

```
value     = object | array | string | number | true | false | null
object    = '{' ( string ':' value (',' string ':' value)* )? '}'
array     = '[' ( value (',' value)* )? ']'
string    = TOKEN_STRING
number    = TOKEN_NUMBER
true      = TOKEN_TRUE
false     = TOKEN_FALSE
null      = TOKEN_NULL
```

**Error handling**: on unexpected token, emit the error via `error.sh`
with position, then abort.  Parse errors are always fatal for that
invocation.

**Interface**:
```bash
# Parse the full token stream; returns the AST root node ID
parser_parse <lexer_state_var>   # writes node ID to stdout
```

### AST (`ast.sh`)

File-backed node store.  Each invocation creates a dedicated temp
directory (`/tmp/shell-json.XXXXXX/`) that is auto-cleaned on `json.free`.

**Directory layout**:
```
/tmp/shell-json.XXXXXX/
  counter       ← integer, incremented for each new node
  nodes/
    0000001     ← one file per node
    0000002
    ...
```

**Node file format** (JSON on a single line):

```json
{"t":<type>,"v":<value>,"c":[<child_id>,...],"k":[<key>,...]}

# where type is:
#   0 = string,  1 = number,  2 = boolean,  3 = null
#   4 = object,  5 = array
```

- **Primitive** (string, number, boolean, null): `v` holds the value.
  `c` and `k` are absent.
- **Array**: `c` holds the ordered list of child node IDs.
- **Object**: `c` holds child node IDs, `k` holds the corresponding keys
  (same index order).

The node files are intentionally tiny — one short JSON line.

**Interface**:
```bash
ast_create <type> [<value>]                    # → node ID
ast_set_child <node_id> <child_id>             # append child
ast_set_key <node_id> <key>                    # set key for last child
ast_get_type   <node_id>                       # → type integer
ast_get_value  <node_id>                       # → value string
ast_get_children <node_id>                     # → space-separated IDs
ast_get_keys     <node_id>                     # → space-separated keys
ast_free_all                                    # remove temp dir
```

### Object Functions (`object.sh`)

```bash
object_get   <node_id> <key>      # → child node ID or error
object_keys  <node_id>            # → newline-separated keys
object_has   <node_id> <key>      # → 0 (found) / 1 (not found)
object_length <node_id>           # → key count
```

### Array Functions (`array.sh`)

```bash
array_get    <node_id> <index>    # → child node ID or error
array_length <node_id>            # → element count
```

### String Functions (`string.sh`)

```bash
string_encode <raw_string>        # → JSON-escaped (with quotes)
string_decode <json_string>       # → raw string (without quotes)
```

Handles `\uXXXX` to UTF-8 conversion, all standard escape sequences,
surrogate pair detection.

### Number Functions (`number.sh`)

```bash
number_validate <raw>             # → 0 (valid JSON number) / 1 (invalid)
number_compare <raw_a> <raw_b>    # → -1, 0, or 1 (for JSONPath filters)
```

Numbers are kept as strings. `number_compare` uses bash's `bc` or
double-arithmetic for comparison — but only if `bc` is available,
otherwise falls back to integer comparison.  Validation is done via
regex — JSON number grammar.

### Writer (`writer.sh`)

Recursive AST walk that serialises the node tree back to a JSON string.

```bash
writer_write <node_id> [indent]   # → JSON text on stdout
```

- `indent` argument controls pretty-printing (0 = compact, 2 = 2-space indent).
- All strings are re-escaped via `string_encode`.
- No trailing newline (caller decides).

### Query / JSONPath (`query.sh`)

Full RFC 9535 JSONPath implementation.

```bash
query_execute <root_node_id> <path_expr>   # → matching node IDs (one per line)
```

**Supported path features**:

| Syntax | Example | Description |
|--------|---------|-------------|
| Root | `$` | The root object/array |
| Current | `@` | Current node (filter context) |
| Dot child | `$.store.book` | Object dot notation |
| Bracket child | `$['store']['book']` | Object bracket notation |
| Array index | `$[0]` | Integer array index |
| Wildcard | `$[*]`, `$.*` | All children |
| Recursive descent | `$..author` | Deep scan |
| Slice | `$[1:3]`, `$[0:-1]`, `$[::2]` | Array slicing |
| Union | `$[0,1]`, `$['a','b']` | Multiple selectors |
| Filter | `$[?(@.price<10)]` | Predicate filter |

**Filter expressions** support:
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical: `&&`, `||`
- Unary: `!`
- Grouping: `( ... )`
- String literals: `'...'` (single quotes)
- Number literals
- `@.key` for current node property access
- `@.length` for array length
- `true`, `false`, `null` literals

The query engine:
1. **Tokenises** the path expression (separate mini-lexer for JSONPath syntax).
2. **Parses** into a segment tree (selectors with optional filters).
3. **Evaluates** by walking the AST and collecting matching node IDs.
4. Filters run an **expression evaluator** that resolves `@.key` against
   the current candidate node.

### Error Handling (`error.sh`)

Global last-error state.

```bash
error_set    <code> <message>
error_get                  # prints "<code>: <message>"
error_clear
```

Error codes:

| Code | Meaning |
|------|---------|
| 1 | General parse error |
| 2 | Lexer error (unexpected char, unterminated string) |
| 3 | Parser error (unexpected token) |
| 4 | Type error (e.g., index on string) |
| 5 | Key not found |
| 6 | Index out of bounds |
| 7 | Invalid JSONPath syntax |
| 8 | Internal / I/O error |

### Public API (`json.sh`)

```bash
# Parse JSON from a file
json.parse <file>
# Parse JSON from a string
json.parse_string <str>
# Query with JSONPath
json.query <root_id> <path>
# Serialize to JSON
json.write <root_id>
# Free all resources
json.free <root_id>
```

`json.sh` sources every module, sets up signal traps for cleanup,
and is the only file library users need to source.

### Testing (`tests/`)

```
tests/
  run_tests.sh       ← test runner
  test_lexer.sh      ← tokenizer unit tests
  test_parser.sh     ← parser unit tests
  test_ast.sh        ← AST management tests
  test_object.sh     ← object helper tests
  test_array.sh      ← array helper tests
  test_string.sh     ← string encode/decode tests
  test_number.sh     ← number validation tests
  test_writer.sh     ← round-trip tests
  test_query.sh      ← JSONPath tests
  fixtures/          ← sample JSON files
```

Test framework helpers (sourced by each test file):
- `assert_eq <actual> <expected> [msg]`
- `assert_ok <cmd> [msg]`
- `assert_fail <cmd> [msg]`
- `test_start <name>` / `test_end` for test grouping.

Runner auto-discovers `test_*.sh` files and executes them, summarising
pass/fail/skip counts.

### Limitations (deliberate)

- **No streaming/SAX.**  The entire JSON text must be lexed/parsed into
  AST before any query can run.
- **No mutation.**  The query interface is read-only.  To build new JSON
  you always go through the parser or manually construct AST nodes.
- **No JSON Schema.**
- **Single-threaded.**  The temp directory and counter assume one
  invocation at a time.  Not safe for concurrent use in the same shell
  without separate temp directories (which already happens per-call).

## Implementation Order

1. `error.sh` — foundational, no dependencies
2. `ast.sh` — file-backed node store
3. `lexer.sh` — tokeniser (depends on error.sh, uses ast.sh types)
4. `string.sh` — string encoding/decoding (used by lexer + writer)
5. `number.sh` — number validation (used by lexer + query)
6. `parser.sh` — builds AST from token stream (depends on lexer, ast, error)
7. `object.sh`, `array.sh` — convenience wrappers around AST
8. `writer.sh` — AST → JSON (depends on ast, string)
9. `query.sh` — JSONPath (depends on ast, object, array)
10. `json.sh` — public API that ties it all together
11. `tests/` — test suite
