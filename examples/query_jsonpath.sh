#!/usr/bin/env bash
set -euo pipefail
# example: query_jsonpath.sh — Demonstrate JSONPath queries
#
# Usage: bash examples/query_jsonpath.sh
# Demonstrates: json.parse_string, json.query, json.dump, json.free

source ./src/json.sh

json='{
    "store": {
        "books": [
            {"title": "A", "price": 10},
            {"title": "B", "price": 20},
            {"title": "C", "price": 30}
        ]
    }
}'

root=$(json.parse_string "$json") || { echo "Error: $(json.last_error)"; exit 1; }

echo "=== Root ==="
json.query "$root" '$'

echo
echo "=== All titles (dot notation) ==="
for node in $(json.query "$root" '$.store.books[*].title'); do
    echo "  $(json.dump "$node")"
done

echo
echo "=== Second book (array index) ==="
json.dump "$(json.query "$root" '$.store.books[1]')" 2

echo
echo "=== Books where price < 25 (filter) ==="
for node in $(json.query "$root" '$.store.books[?(@.price < 25)]'); do
    json.dump "$node"
done

echo
echo "=== Recursive descent for all titles ==="
for node in $(json.query "$root" '$..title'); do
    echo "  $(json.dump "$node")"
done

json.free "$root"
