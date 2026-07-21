# Contributing to shell-json

Thank you for considering contributing to shell-json! This document outlines the process.

## Development Setup

```bash
git clone https://github.com/quintin/shell-json.git
cd shell-json
```

No build tools required — this is pure bash. Just `source json.sh` and start using it.

## Running Tests

```bash
# Run all tests
bash tests/run_tests.sh

# Run a specific test suite
bash tests/run_tests.sh parser
bash tests/run_tests.sh query
```

All tests must pass before submitting changes. We test across bash 4.3–5.2 in CI.

Before committing, also run:

```bash
shellcheck src/*.sh
```

## Code Style

- **4-space indentation**, no tabs
- **`set -euo pipefail`** in new scripts
- **Quoted variables** — always `"$var"`, never `$var`
- **`[[ ... ]]`** for conditionals (bash-specific), never `[ ... ]`
- **`(( ... ))`** for arithmetic
- **`printf`** over `echo`
- **Functions** use `snake_case`, prefixed by module: `ast_get_type`, `_q_eval_segment`
- **Public API** (json.* functions) documented in README API Reference

See `.editorconfig` and `.shellcheckrc` for automated style enforcement.

## Adding Features

1. Open an issue first to discuss the feature
2. Write tests before implementation (in `tests/test_*.sh`)
3. Implement in `src/*.sh`
4. Verify all tests pass
5. Update `CHANGELOG.md` under `[Unreleased]`
6. Submit a pull request

## Reporting Bugs

Include:

- Bash version (`bash --version`)
- OS / distribution
- Minimal reproduction script (3–10 lines preferred)
- Expected vs actual output
- Whether it reproduces with `set -euo pipefail`

## Project Structure

```
src/              # Source modules (sourced by json.sh)
  json.sh         # Public API entry point
  error.sh        # Error handling
  ast.sh          # File-backed AST node store
  lexer.sh        # JSON tokenizer
  parser.sh       # Recursive descent parser
  string.sh       # String encode/decode
  number.sh       # Number validation
  object.sh       # Object helpers
  array.sh        # Array helpers
  writer.sh       # AST → JSON serializer
  query.sh        # JSONPath engine
tests/            # Test suites
examples/         # Runnable example scripts
docs/             # Documentation
  benchmarks.md   # Performance benchmarks
  limitations.md  # Known limitations
  plan.md         # Implementation plan
dist/             # Single-file distribution bundles
```

## Compatibility

shell-json supports **bash 4.3+** and **zsh 5.0+**. Avoid:

- `associative arrays` (not needed for current design)
- Bash 5.x-only features (`\u` escapes, `@Q` operator)
- External dependencies (no `jq`, `python`, `awk` for core functionality — though `base64` is required on some systems)
