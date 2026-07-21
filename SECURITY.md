# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.x     | :white_check_mark: |

## Reporting a Vulnerability

shell-json is a shell-based JSON processor — it does not handle untrusted input over a network, deserialize user-controlled data, or run with elevated privileges. However, if you find:

- **Code execution** through crafted JSON input
- **Arbitrary file read/write** via JSONPath queries
- **Resource exhaustion** attacks

Please open an issue with label `security` or email the maintainer directly. We aim to respond within 48 hours.

## Known Security Considerations

- JSON input is parsed in the current shell — the parser trusts the input well-formedness. Malformed JSON produces errors but does not execute arbitrary code.
- `json.parse` reads files — do not pass user-controlled paths without sanitization.
- The file-backed AST creates temp files in `/tmp` — on shared systems, other users can read temp filenames (but not content, which is base64-encoded).
- No eval statements are used (no `eval`, no `source` of untrusted content).
