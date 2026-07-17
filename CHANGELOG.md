# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of shell-json
- Full JSON parsing pipeline (lexer → parser → AST)
- File-backed AST with base64-encoded values
- JSONPath query engine (RFC 9535 subset)
- Compact and pretty-print serialization
- Structured error handling with codes and positions
- 136 passing tests across 5 test suites
- Comprehensive documentation (README, design spec, implementation plan)

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
