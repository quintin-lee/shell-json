#!/usr/bin/env bash
# example: error_handling.sh — Demonstrate error handling patterns
#
# Usage: bash examples/error_handling.sh
# Demonstrates: json.last_error, json.clear_error, error recovery

source ./src/json.sh

echo "=== Parse invalid JSON ==="
root=$(json.parse_string '{bad json}') || {
    echo "Error code: $(json.last_error)"
    json.clear_error
}
echo

echo "=== Parse valid JSON after error ==="
root=$(json.parse_string '{"valid": true}') || {
    echo "Unexpected error: $(json.last_error)" >&2
    exit 1
}
echo "Parsed OK, root ID: $root"

echo
echo "=== Query non-existent path (not an error) ==="
results=$(json.query "$root" '$.nonexistent')
if [[ -z "$results" ]]; then
    echo "No results (empty, not an error)"
fi

json.free "$root"
echo "Done."
