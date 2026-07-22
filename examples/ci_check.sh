#!/usr/bin/env bash
set -euo pipefail
# example: ci_check.sh — Validate a JSON file in a CI pipeline
#
# Usage: bash examples/ci_check.sh [file.json]
#   If no file specified, validates itself as a sample.
#
# Demonstrates: json.parse with error handling (CI-friendly)

source ./src/json.sh

file="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data.json"}"

if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file" >&2
    exit 2
fi

root=$(json.parse "$file") || {
    echo "FAIL: Invalid JSON — $(json.last_error)" >&2
    exit 1
}

echo "PASS: Valid JSON — $file"
json.free "$root"
exit 0
