# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub Actions release workflow
- CONTRIBUTING.md, issue/PR templates, SECURITY.md

## [0.1.0] - 2026-07-20

### Fixed
- **zsh compatibility**: Replace `${BASH_SOURCE[0]%/*}` with `${(%):-%x}` fallback for self-directory detection — `source src/json.sh` now works in zsh
- **zsh array indexing**: Add `KSH_ARRAYS` option in `query_execute()` and AST functions — JSONPath queries on indexed arrays/lists work in zsh
- **Subshell AST persistence**: `ast_init` saves `_AST_DIR` to a PID-based file; `_ast_file()` reads it back when called from a different shell scope — `json.parse_string` + `json.dump` pattern now works correctly across subshell boundaries
- **Error state cross-subshell loss**: Error code/message persisted to PID file, recovered by `error_get`/`error_code`/`error_msg`
- **Query wildcard multi-line bug**: `_q_eval_segment` used `read -ra` which reads only first line of `_Q_RESULT` — replaced with `readarray -t`
- **Stale AST_DIR across subshells**: `_ast_file` always prefers PID file over inherited `_AST_DIR`, preventing stale directory routing
- **set -u compatibility**: `ZSH_VERSION`, `_JSON_LOADED`, `ast_create $2`, `_ast_file` empty ID — all unbound variable references fixed
- **Match/search return propagation**: `local var=$other` in `_q_expr_parse_mul`/`add` overwrote `$?` — saved result code before local assignments

### Changed
- **json.write → json.dump**: Renamed public API for clarity — `json.write` is now `json.dump` (old name removed)
- **Performance optimization**: Replaced all `sed`/`wc`/`tr` subprocess calls in AST accessors with `_ast_read_node()` — single file read per node (1.5x speedup on small, 1.4x on medium)

### Added
- Initial release of shell-json
- Full JSON parsing pipeline (lexer → parser → AST)
- File-backed AST with base64-encoded values
- JSONPath query engine (RFC 9535 subset): key, wildcard, recursive descent, filter, slice, index, union
- JSONPath filter extensions: arithmetic (`+`, `-`, `*`, `/`), functions (`contains()`, `type()`, `has()`, `length()`, `match()`, `search()`)
- Compact and pretty-print serialization
- Structured error handling with codes and positions
- Test suite: 199 tests across 7 suites (lexer, number, parser, query, string, writer, integration)
- Style consistency: `.editorconfig`, ShellCheck zero warnings
- Continuous integration: GitHub Actions matrix across bash 4.3–5.2 (Docker-based)
- Comprehensive documentation: README (EN/ZH), API reference, inline doc comments, known limitations, benchmarks, design spec, implementation plan
- Examples directory: 5 runnable example scripts (parse, query, error handling, CI check)

### Modules
- `error.sh` — Error handling framework (8 error codes)
- `ast.sh` — File-backed AST node store
- `string.sh` — JSON string encode/decode with Unicode support
- `number.sh` — Number validation and comparison
- `lexer.sh` — Character-level JSON tokenizer
- `parser.sh` — Recursive descent parser
- `object.sh` — Object helper functions (get, keys, has, length)
- `array.sh` — Array helper functions (get, length)
- `writer.sh` — AST → JSON serializer
- `query.sh` — JSONPath engine
- `json.sh` — Public API entry point
