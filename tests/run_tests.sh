#!/usr/bin/env bash
# Test runner for shell-json
# Usage: ./run_tests.sh [test_name...]
#
# Part of shell-json (https://github.com/quintin/shell-json)

SELF_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
_ALL_FAILED=0

# If specific test names given, only run those
if (( $# > 0 )); then
    for name in "$@"; do
        test_file="$SELF_DIR/test_${name}.sh"
        if [[ -f "$test_file" ]]; then
            printf '=== %s ===\n' "$name"
            bash "$test_file" || _ALL_FAILED=1
            printf '\n'
        else
            printf 'Test not found: %s (%s)\n' "$name" "$test_file"
            _ALL_FAILED=1
        fi
    done
else
    for test_file in "$SELF_DIR"/test_*.sh; do
        name="${test_file##*/test_}"
        name="${name%.sh}"
        # Skip helper
        [[ "$name" == "helper" ]] && continue
        printf '=== %s ===\n' "$name"
        bash "$test_file" || _ALL_FAILED=1
        printf '\n'
    done
fi

if (( _ALL_FAILED )); then
    printf 'Some tests FAILED.\n'
    exit 1
fi

printf 'All tests passed.\n'
