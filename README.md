# shell-json

A fully-featured JSON parsing and querying library implemented entirely in pure Bash. No external dependencies — no `jq`, no `python`, no `grep`/`sed` hacks.

## Architecture

Compiler-style pipeline: **lexer → parser → file-backed AST → query/writer**

```
┌──────────┐   tokens    ┌─────────┐   AST nodes   ┌───────────────┐
│ lexer.sh │ ──────────► │parser.sh│ ────────────► │  ast.sh       │
│ (stream) │             │(rec-des)│               │(file-backed)  │
└──────────┘             └─────────┘               └──┬────────────┘
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

## Features

- **Full JSON parsing** — strings (with Unicode/surrogate pairs), numbers (arbitrary precision as strings), booleans, null, objects, arrays
- **File-backed AST** — node store in `/tmp`, auto-cleaned via `json.free`
- **JSONPath queries** — full RFC 9535 subset: `$`, `@`, dot/bracket notation, `[0]`, `[*]`, `$..key`, slice `[1:3]`, union `[0,1]`, filter `[?(@.price<10)]`
- **Compact & pretty serialization** — `json.write "$root"` or `json.write "$root" 2`
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
    echo "$(json.write "$node")"
done

# Serialize to pretty JSON
pretty=$(json.write "$root" 2)
echo "$pretty"

# Free resources
json.free "$root"
```

### Parse from string

```bash
root=$(json.parse_string '{"name":"test","value":42}')
echo "$(json.write "$root")"
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

| Module | Description |
|--------|-------------|
| `error.sh` | Error handling framework with codes and positions |
| `ast.sh` | File-backed AST node store (base64-encoded values) |
| `string.sh` | JSON string encode/decode with Unicode support |
| `number.sh` | Number validation and comparison (no precision loss) |
| `lexer.sh` | Character-level JSON tokenizer |
| `parser.sh` | Recursive descent parser |
| `object.sh` | Object helper functions (get, keys, has, length) |
| `array.sh` | Array helper functions (get, length) |
| `writer.sh` | AST → JSON serializer (compact + pretty) |
| `query.sh` | JSONPath engine (RFC 9535) |
| `json.sh` | Public API entry point — source only this file |

## Testing

```bash
# Run all tests
bash tests/run_tests.sh

# Run specific test suite
bash tests/run_tests.sh lexer
bash tests/run_tests.sh parser
bash tests/run_tests.sh query
bash tests/run_tests.sh string
bash tests/run_tests.sh number
```

All 136 tests pass.

## Limitations

- **No streaming/SAX** — entire JSON must be parsed before querying
- **No mutation** — read-only query interface
- **No JSON Schema**
- **Single-threaded** — one invocation per shell session (temp dir per call)

## License

MIT
