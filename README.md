# shell-json

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.3+-brightgreen)
[**中文文档**](README.zh.md)

A fully-featured JSON parsing and querying library implemented entirely in pure Bash. No external dependencies — no `jq`, no `python`, no `grep`/`sed` hacks.

## Architecture

Compiler-style pipeline: **lexer → parser → file-backed AST → query/writer**

```
                    ┌──────────────┐
                    │ json.sh      │ ← Public API (source this file)
                    │ entry point  │
                    └──────┬───────┘
                           │ sources all
                           ▼
              ┌────────────────────────┐
              │   Core Pipeline        │
              │                        │
  ┌───────────┤ lexer.sh  ─────────► parser.sh
  │           └───────────────────────┤
  │                                  ▼
  │                          ┌───────────────┐
  │                          │  ast.sh       │
  │                          │ (file-backed) │
  │                          └───────┬───────┘
  │                                  │
  │         ┌────────────────────────┼────────────────────────┐
  │         │                        │                        │
  │         ▼                        ▼                        ▼
  │  ┌──────────┐          ┌──────────────┐        ┌──────────────┐
  │  │query.sh  │          │ writer.sh    │        │ object.sh    │
  │  │(JSONPath)│          │(serialize)   │        │ array.sh     │
  │  └──────────┘          └──────────────┘        └──────────────┘
  │                                                  │
  │         ┌────────────────────────────────────────┤
  │         │                                        │
  │         ▼                                        │
  │  ┌──────────────┐  ┌──────────────┐             │
  │  │ string.sh    │  │ number.sh    │             │
  │  │(encode/decode)│ │(validate)    │             │
  │  └──────────────┘  └──────────────┘             │
  │                                                │
  │  ┌─────────────────────────────────────────────┤
  │  │                                             │
  │  ▼                                             │
  │  ┌──────────────┐                             │
  │  │ error.sh     │ ← All modules                │
  │  │(errors)      │   use this                   │
  │  └──────────────┘                             │
  └────────────────────────────────────────────────┘
```

## Features

- **Full JSON parsing** — strings (with Unicode/surrogate pairs), numbers (arbitrary precision as strings), booleans, null, objects, arrays
- **File-backed AST** — node store in `/tmp`, auto-cleaned via `json.free`
- **JSONPath queries** — full RFC 9535 subset: `$`, `@`, dot/bracket notation, `[0]`, `[*]`, `$..key`, slice `[1:3]`, union `[0,1]`, filter `[?(@.price<10)]`
- **Compact & pretty serialization** — `json.dump "$root"` or `json.dump "$root" 2`
- **Error handling** — structured errors with codes and line:column positions
- **Pure Bash** — works in any POSIX-compatible shell environment

## Quick Start

```bash
#!/usr/bin/env bash
source ./src/json.sh

# Parse a JSON file
root=$(json.parse "data.json") || { echo "Error: $(json.last_error)"; exit 1; }

# Query with JSONPath
results=$(json.query "$root" '$.store.book[*].title')
for node in $results; do
    echo "$(json.dump "$node")"
done

# Serialize to pretty JSON
pretty=$(json.dump "$root" 2)
echo "$pretty"

# Free resources
json.free "$root"
```

### Parse from string

```bash
root=$(json.parse_string '{"name":"test","value":42}')
echo "$(json.dump "$root")"
# {"name":"test","value":42}
json.free "$root"
```

### JSONPath examples

```bash
# Root
json.query "$root" '$'

# Dot notation
json.query "$root" '$.store.book'

# Bracket notation
json.query "$root" "$['store']['book']"

# Array index
json.query "$root" '$.store.book[0]'

# Wildcard
json.query "$root" '$.store.book[*].title'

# Recursive descent
json.query "$root" '$..author'

# Slice
json.query "$root" '$.store.book[0:2]'

# Union
json.query "$root" '$.store.book[0,2]'

# Filter
json.query "$root" '$.store.book[?(@.price < 10)]'
```

## Modules

| Module | Description | Key Functions |
|--------|-------------|---------------|
| `error.sh` | Error handling framework with codes and positions | `error_set`, `error_get`, `error_clear`, `error_code`, `error_msg` |
| `ast.sh` | File-backed AST node store (base64-encoded values) | `ast_create`, `ast_get_type`, `ast_get_value`, `ast_set_child`, `ast_set_child_with_key`, `ast_destroy` |
| `string.sh` | JSON string encode/decode with Unicode support | `string_encode`, `string_decode` |
| `number.sh` | Number validation and comparison (no precision loss) | `number_validate`, `number_compare` |
| `lexer.sh` | Character-level JSON tokenizer | `lexer_init`, `lexer_advance`, `lexer_peek`, `lexer_get_position` |
| `parser.sh` | Recursive descent parser | `parser_parse` |
| `object.sh` | Object helper functions (get, keys, has, length) | `object_get`, `object_keys`, `object_has`, `object_length` |
| `array.sh` | Array helper functions (get, length) | `array_get`, `array_length` |
| `writer.sh` | AST → JSON serializer (compact + pretty) | `writer_write` |
| `query.sh` | JSONPath engine (RFC 9535) | `query_execute` |
| `json.sh` | Public API entry point — source only this file | `json.parse`, `json.parse_string`, `json.query`, `json.dump`, `json.free`, `json.last_error`, `json.clear_error` |

## API Reference

### `json.parse <filepath>`

Parses a JSON file and returns the AST root node ID.

```bash
root=$(json.parse "data.json")
root=$(json.parse "data.json") || { echo "parse failed"; exit 1; }
```

### `json.parse_string <string>`

Parses a JSON string and returns the AST root node ID.

```bash
root=$(json.parse_string '{"key": "value"}')
root=$(json.parse_string "$json_str") || { echo "parse failed"; exit 1; }
```

### `json.query <root_id> <path>`

Executes a JSONPath query against the AST. Outputs matching node IDs, one per line.

| Argument | Description |
|----------|-------------|
| `root_id` | AST root node ID (from `json.parse` / `json.parse_string`) |
| `path` | JSONPath expression (see [JSONPath Reference](#jsonpath-reference)) |

```bash
results=$(json.query "$root" '$.store.book[*].title')
for node in $results; do
    json.dump "$node"
done
```

### `json.dump <node_id> [indent]`

Serializes an AST node back to JSON text.

| Argument | Description |
|----------|-------------|
| `node_id` | AST node ID to serialize |
| `indent` | *(optional)* `0` = compact (default), `2` = pretty-print |

```bash
json.dump "$root"        # compact: {"a":1}
json.dump "$root" 2      # pretty: {\n  "a": 1\n}
```

### `json.free <root_id>`

Frees all AST resources (temp directory). Always call after you're done.

```bash
json.free "$root"
```

### `json.last_error`

Returns the last error message (empty string if no error).

```bash
json.parse "bad.json" || {
    echo "Error: $(json.last_error)" >&2
    exit 1
}
```

### `json.clear_error`

Clears the error state. Call before retrying after a failure.

```bash
json.clear_error
```

## Error Codes

| Code | Constant | Meaning |
|------|----------|---------|
| 1 | `_JSON_ERR_GENERAL` | General parse error |
| 2 | `_JSON_ERR_LEXER` | Lexer error (unexpected char, unterminated string) |
| 3 | `_JSON_ERR_PARSER` | Parser error (unexpected token) |
| 4 | `_JSON_ERR_TYPE` | Type error (e.g., index on string) |
| 5 | `_JSON_ERR_KEY_NOT_FOUND` | Key not found in object |
| 6 | `_JSON_ERR_INDEX_OOB` | Index out of bounds |
| 7 | `_JSON_ERR_PATH_SYNTAX` | Invalid JSONPath syntax |
| 8 | `_JSON_ERR_IO` | Internal / I/O error |

## JSONPath Reference

| Syntax | Example | Description |
|--------|---------|-------------|
| Root | `$` | The root object/array |
| Current | `@` | Current node (filter context) |
| Dot child | `$.store.book` | Object dot notation |
| Bracket child | `$['store']['book']` | Object bracket notation |
| Array index | `$[0]` | Integer array index |
| Wildcard | `$[*]`, `$.*` | All children |
| Recursive descent | `$..author` | Deep scan for key |
| Slice | `$[1:3]`, `$[0:-1]`, `$[::2]` | Array slicing |
| Union | `$[0,1]`, `$['a','b']` | Multiple selectors |
| Filter | `$[?(@.price<10)]` | Predicate filter |

**Filter expressions** support:
- Comparisons: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical: `&&`, `||`
- Unary: `!`
- Grouping: `( ... )`
- Literals: `'...'` (strings), numbers, `true`, `false`, `null`
- Property access: `@.key`, `@.length`

## How It Works

The library follows a compiler-style pipeline:

```
JSON text ─► Lexer ─► Tokens ─► Parser ─► AST nodes ─► Query/Writer
```

1. **Lexer** (`lexer.sh`) — Reads JSON character by character, emits tokens
   (STRING, NUMBER, TRUE, FALSE, NULL, LBRACE, RBRACKET, etc.)
2. **Parser** (`parser.sh`) — Recursive descent parser that consumes tokens
   and builds an AST using `ast_create()` calls.
3. **AST** (`ast.sh`) — File-backed node store in `/tmp`. Each node is a
   small file containing type, value (base64-encoded), children IDs, and keys.
4. **Query** (`query.sh`) — Evaluates JSONPath expressions against the AST,
   returning matching node IDs.
5. **Writer** (`writer.sh`) — Recursively walks the AST and serializes it
   back to JSON text (compact or pretty-printed).

### Why no external dependencies?

Most JSON libraries rely on `jq`, Python, or `grep`/`sed` hacks. shell-json
is written entirely in Bash builtins and standard POSIX tools (`mktemp`,
`base64`, `sed`). This makes it portable to any environment where Bash
runs — containers, embedded systems, CI pipelines — without installing
anything extra.

### AST storage details

Each invocation creates a temp directory like `/tmp/shell-json.XXXXXX/`:

```
/tmp/shell-json.XXXXXX/
  counter       ← incrementing node ID counter
  nodes/
    0000001     ← node file (4 lines: type|value|children|keys)
    0000002
    ...
```

Values are base64-encoded to safely handle arbitrary strings including
newlines, Unicode, and binary data. Call `json.free` to clean up.

## Project Structure

```
shell-json/
├── src/                    # Core library modules
│   ├── json.sh             # Public API (source this file)
│   ├── error.sh            # Error handling framework
│   ├── ast.sh              # File-backed AST node store
│   ├── lexer.sh            # Character-level tokenizer
│   ├── parser.sh           # Recursive descent parser
│   ├── string.sh           # String encode/decode
│   ├── number.sh           # Number validation/comparison
│   ├── object.sh           # Object helper functions
│   ├── array.sh            # Array helper functions
│   ├── writer.sh           # AST → JSON serializer
│   └── query.sh            # JSONPath engine
├── tests/                  # Test suite
│   ├── run_tests.sh        # Test runner
│   ├── test_helper.sh      # Test framework
│   ├── test_lexer.sh       # Lexer unit tests
│   ├── test_number.sh      # Number validation tests
│   ├── test_parser.sh      # Parser round-trip tests
│   ├── test_query.sh       # JSONPath tests
│   ├── test_string.sh      # String encode/decode tests
│   └── fixtures/           # Sample JSON files
├── docs/                   # Design documentation
├── README.md               # This file
├── CHANGELOG.md            # Version history
├── LICENSE                 # MIT License
└── .gitignore
```

## Testing

```bash
# Run all tests
bash tests/run_tests.sh

# Run specific test suite
bash tests/run_tests.sh lexer
bash tests/run_tests.sh number
bash tests/run_tests.sh parser
bash tests/run_tests.sh query
bash tests/run_tests.sh string
```

All 136 tests pass.

## Limitations

- **No streaming/SAX** — entire JSON must be parsed before querying
- **No mutation** — read-only query interface
- **No JSON Schema**
- **Single-threaded** — one invocation per shell session (temp dir per call)

## Design Documentation

For a deep dive into the library's internals — lexer token types, parser grammar,
AST file format, and JSONPath evaluation algorithm — see the
[design specification](docs/superpowers/specs/2026-07-17-shell-json-design.md).

## License

MIT

## Compatibility

### Requirements

| Requirement | Details |
|-------------|---------|
| **Bash** | 4.3+ (uses `local -n` namerefs for Unicode decoding) |
| **External tools** | `mktemp`, `base64`, `sed` (standard on Linux/macOS) |
| **Encoding** | UTF-8 locale recommended for correct Unicode handling |
| **Not supported** | `sh`, `dash`; Bash < 4.3 |

### Portability notes

- The library uses Bash-specific features: `[[ ]]` conditionals, `$(( ))` arithmetic, `local -n` namerefs, `printf -v`, and ANSI-C quoting (`$'\n'`).
- On macOS, the default Bash is 3.2. Upgrade via Homebrew (`brew install bash`) or use a container with Bash 4.3+.
- `base64` flags differ between GNU and BSD implementations — the code handles both via fallback logic.

## Error Handling

Use `json.last_error` to inspect errors after a failed operation:

```bash
source ./src/json.sh

# Parse with error recovery
root=$(json.parse "data.json") || {
    echo "Parse failed: $(json.last_error)" >&2
    json.clear_error          # clear error state before retry/exit
    exit 1
}

# Query may return no results (not an error)
results=$(json.query "$root" '$.nonexistent.key')
if [[ -z "$results" ]]; then
    echo "No matches found"
fi

# Write with error checking
output=$(json.dump "$root") || {
    echo "Serialization failed: $(json.last_error)" >&2
    exit 1
}

# Always clean up resources
json.free "$root"
```

