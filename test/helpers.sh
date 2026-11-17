#!/bin/bash
# Assertions shared by the test files. Source it after setting ROOT.

pass=0
fail=0

ok() { pass=$((pass + 1)); }
not_ok() {
  fail=$((fail + 1))
  echo "FAIL: $*"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok; else not_ok "$desc: expected [$expected], got [$actual]"; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok; else not_ok "$desc: expected to contain [$needle], got: $haystack"; fi
}

refute_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then not_ok "$desc: expected NOT to contain [$needle], got: $haystack"; else ok; fi
}

assert_file() {
  if [ -f "$2" ]; then ok; else not_ok "$1: expected file [$2] to exist"; fi
}

refute_file() {
  if [ -e "$2" ]; then not_ok "$1: expected [$2] to be absent"; else ok; fi
}

# json_get EXPR: evaluates a Perl expression on the decoded JSON from stdin,
# with the data in $d. Prints INVALID_JSON when stdin is not one JSON value,
# and EVAL_ERROR plus Perl's message when EXPR itself fails.
json_get() {
  /usr/bin/perl -MJSON::PP -e '
    local $/; my $raw = <STDIN>;
    my ($d, $ok);
    $ok = eval { $d = JSON::PP->new->utf8->allow_nonref->decode($raw); 1 };
    unless ($ok) { print "INVALID_JSON"; exit 0 }
    binmode STDOUT, ":encoding(UTF-8)";
    my $v = eval $ARGV[0];
    if ($@) { print "EVAL_ERROR: $@"; exit 0 }
    print defined $v ? $v : "";
  ' "$1"
}

finish_tests() {
  echo ""
  echo "${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}
