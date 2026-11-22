#!/bin/bash
# shellcheck disable=SC2016 # json_get takes Perl, so the $ in single quotes is literal
# Tests for test/helpers.sh. Each check runs the helper under test in a
# subshell with fresh counters, so its failures never count against this file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/helpers.sh
source "$ROOT/test/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# isolated CMD...: runs CMD and then finish_tests with zeroed counters.
isolated() { (pass=0; fail=0; "$@"; finish_tests) 2>&1; }

# --- passing assertions keep finish_tests green ---
out=$(isolated assert_eq "d" "a" "a"); rc=$?
assert_eq "matching assert_eq passes" "0" "$rc"
assert_contains "matching assert_eq counts one pass" "$out" "1 passed, 0 failed"

# --- assert_eq ---
# breaks-if: assert_eq counts a mismatch as ok
out=$(isolated assert_eq "d" "a" "b"); rc=$?
assert_contains "assert_eq mismatch reported" "$out" "FAIL: d: expected [a], got [b]"
assert_eq "finish_tests fails on an assert_eq failure" "1" "$rc"

# --- assert_contains / refute_contains ---
# breaks-if: assert_contains counts a missing needle as ok
out=$(isolated assert_contains "d" "haystack" "needle"); rc=$?
assert_contains "assert_contains miss reported" "$out" "FAIL: d: expected to contain [needle]"
assert_eq "finish_tests fails on an assert_contains failure" "1" "$rc"
# breaks-if: refute_contains has its branches swapped
out=$(isolated refute_contains "d" "has needle" "needle"); rc=$?
assert_contains "refute_contains hit reported" "$out" "FAIL: d: expected NOT to contain [needle]"
assert_eq "finish_tests fails on a refute_contains failure" "1" "$rc"
out=$(isolated refute_contains "d" "haystack" "needle"); rc=$?
assert_eq "refute_contains passes when the needle is absent" "0" "$rc"

# --- assert_file / refute_file ---
# breaks-if: assert_file counts a missing file as ok
out=$(isolated assert_file "d" "$WORK/missing"); rc=$?
assert_contains "assert_file miss reported" "$out" "FAIL: d: expected file"
assert_eq "finish_tests fails on an assert_file failure" "1" "$rc"
mkdir -p "$WORK/a-dir"
# breaks-if: refute_file tests -f where -e is needed, so a directory counts as absent
out=$(isolated refute_file "d" "$WORK/a-dir"); rc=$?
assert_contains "refute_file on a directory reported" "$out" "FAIL: d: expected [$WORK/a-dir] to be absent"
assert_eq "finish_tests fails on a refute_file failure" "1" "$rc"

# --- json_get ---
assert_eq "json_get reads a value" "1" "$(printf '{"a":1}' | json_get '$d->{a}')"
assert_eq "json_get of a missing key is empty" "" "$(printf '{"a":1}' | json_get '$d->{b}')"
assert_eq "json_get accepts a null document" "" "$(printf 'null' | json_get '$d')"
# breaks-if: json_get stops printing INVALID_JSON for bad input
assert_eq "empty stdin" "INVALID_JSON" "$(printf '' | json_get '1')"
# breaks-if: json_get treats a decode error on truncated input as a value
assert_eq "truncated json" "INVALID_JSON" "$(printf '{"a":' | json_get '1')"
# breaks-if: json_get stops checking $@ after evaluating the expression
assert_contains "broken expression reported" "$(printf '{"a":1}' | json_get '$d->{a')" "EVAL_ERROR:"

# --- reset_test_env ---
left=$( export SUM_MODEL=opus sum_app_id=com.apple.Notes NPM_CONFIG_PREFIX=/x SUMMARY=keep sum=keep
  reset_test_env
  printf '%s|%s|%s|%s|%s' "${SUM_MODEL-unset}" "${sum_app_id-unset}" "${NPM_CONFIG_PREFIX-unset}" \
    "${SUMMARY-unset}" "${sum-unset}" )
# breaks-if: reset_test_env stops unsetting one of SUM_*, sum_* or NPM_CONFIG_PREFIX, or its globs
# also catch names without the underscore
assert_eq "reset_test_env drops SUM_*, sum_* and NPM_CONFIG_PREFIX only" "unset|unset|unset|keep|keep" "$left"
# breaks-if: reset_test_env leaks its loop variable into the caller
assert_eq "reset_test_env leaves no variable behind" "unset" "$( reset_test_env; printf '%s' "${var-unset}" )"

finish_tests
