#!/usr/bin/env bash
# Tests for number.sh
#
# Part of shell-json (https://github.com/quintin/shell-json)

_self="${BASH_SOURCE[0]:-${(%):-%x}}"
source "$(cd "$(dirname "$_self")" && pwd -P)/test_helper.sh"

# ── number_validate ──────────────────────────────────────────────────

test_start "number_validate: integer"
number_validate "42"
assert_eq $? 0 "integer"

test_start "number_validate: negative"
number_validate "-42"
assert_eq $? 0 "negative"

test_start "number_validate: zero"
number_validate "0"
assert_eq $? 0 "zero"

test_start "number_validate: decimal"
number_validate "3.14"
assert_eq $? 0 "decimal"

test_start "number_validate: negative decimal"
number_validate "-3.14"
assert_eq $? 0 "negative decimal"

test_start "number_validate: scientific notation"
number_validate "1e10"
assert_eq $? 0 "sci uppercase e"

number_validate "1E10"
assert_eq $? 0 "sci lowercase E"

number_validate "1e+10"
assert_eq $? 0 "sci positive exp"

number_validate "1e-10"
assert_eq $? 0 "sci negative exp"

test_start "number_validate: decimal with exponent"
number_validate "3.14e-5"
assert_eq $? 0 "decimal sci"

test_start "number_validate: leading zero invalid"
number_validate "0123"
assert_eq $? 1 "leading zero"

test_start "number_validate: empty"
number_validate ""
assert_eq $? 1 "empty"

test_start "number_validate: just minus"
number_validate "-"
assert_eq $? 1 "just minus"

test_start "number_validate: double dot"
number_validate "1.2.3"
assert_eq $? 1 "double dot"

test_start "number_validate: letters"
number_validate "abc"
assert_eq $? 1 "letters"

# ── number_compare ───────────────────────────────────────────────────

test_start "number_compare: equal ints"
result=$(number_compare "5" "5")
assert_eq "$result" "0" "5==5"

test_start "number_compare: less int"
result=$(number_compare "3" "7")
assert_eq "$result" "-1" "3<7"

test_start "number_compare: greater int"
result=$(number_compare "7" "3")
assert_eq "$result" "1" "7>3"

test_start "number_compare: equal floats"
result=$(number_compare "3.14" "3.14")
assert_eq "$result" "0" "3.14==3.14"

test_start "number_compare: negative vs positive"
result=$(number_compare "-5" "3")
assert_eq "$result" "-1" "-5<3"

test_start "number_compare: scientific"
result=$(number_compare "1e5" "100")
assert_eq "$result" "1" "1e5>100"

# ── Summary ──────────────────────────────────────────────────────────

test_summary
