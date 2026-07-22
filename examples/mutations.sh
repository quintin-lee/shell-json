#!/usr/bin/env bash
set -euo pipefail
# example: mutations.sh — Demonstrate JSON mutation operations
#
# Usage: bash examples/mutations.sh
# Demonstrates: json.set, json.delete, json.push

source ./src/json.sh

echo "=== Initial data ==="
root=$(json.parse_string '{"name":"Alice","age":30,"tags":["dev","ops"],"items":[{"id":1,"name":"widget"}]}') || {
    echo "Parse failed: $(json.last_error)" >&2
    exit 1
}
json.dump "$root" 2
echo

# ── Set: update existing key ──────────────────────────────────────────────
echo "=== json.set: update existing key ==="
json.set "$root" '$.name' '"Bob"'
json.dump "$root" 2
echo

# ── Set: add new key ──────────────────────────────────────────────────────
echo "=== json.set: add new key ==="
json.set "$root" '$.email' '"bob@example.com"'
json.dump "$root" 2
echo

# ── Set: replace array element by index ───────────────────────────────────
echo "=== json.set: replace array element by index ==="
json.set "$root" '$.tags[0]' '"eng"'
json.dump "$root" 2
echo

# ── Push: append to array ────────────────────────────────────────────────
echo "=== json.push: append string to array ==="
json.push "$root" '$.tags' '"cloud"'
json.dump "$root" 2
echo

# ── Push: append object to array ─────────────────────────────────────────
echo "=== json.push: append object to array ==="
json.push "$root" '$.items' '{"id":2,"name":"gadget"}'
json.dump "$root" 2
echo

# ── Delete: remove key ───────────────────────────────────────────────────
echo "=== json.delete: remove key ==="
json.delete "$root" '$.email'
json.dump "$root" 2
echo

# ── Delete: remove array element by index ─────────────────────────────────
echo "=== json.delete: remove array element by index ==="
json.delete "$root" '$.items[0]'
json.dump "$root" 2
echo

# ── Wildcard set: replace all elements ────────────────────────────────────
echo "=== json.set: wildcard replace all tags ==="
json.set "$root" '$.tags[*]' '"all"'
json.dump "$root" 2
echo

# ── Error handling ────────────────────────────────────────────────────────
echo "=== Error handling ==="
if ! json.set "$root" '$.nonexistent.key' '"x"'; then
    echo "Expected error: $(json.last_error)"
fi
json.clear_error

if ! json.push "$root" '$.name' '"not-an-array"'; then
    echo "Expected error: $(json.last_error)"
fi

json.free "$root"
echo
echo "Done."
