#!/usr/bin/env bash
# example: parse_file.sh — Parse a JSON file and explore the AST
#
# Usage: bash examples/parse_file.sh
# Demonstrates: json.parse, json.dump, json.free

source ./src/json.sh

data_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Parse JSON file ==="
root=$(json.parse "$data_dir/data.json") || {
    echo "Parse failed: $(json.last_error)" >&2
    exit 1
}
echo "Root node ID: $root"
echo

echo "=== Serialize entire JSON ==="
json.dump "$root" 2
echo

echo "=== Compact output ==="
json.dump "$root"
echo

json.free "$root"
echo "Done."
