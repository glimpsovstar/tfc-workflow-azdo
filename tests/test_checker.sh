#!/bin/bash
# Self-tests for check_templates.rb.
# Each tests/cases/bad/<rule>.yml must fail with exactly <rule>.
# Everything under tests/cases/good must pass.
set -euo pipefail

cd "$(dirname "$0")/.."
CHECKER=(ruby tests/check_templates.rb)
fail=0

for case_file in tests/cases/bad/*.yml; do
  rule="$(basename "$case_file" .yml)"
  set +e
  out="$("${CHECKER[@]}" "$case_file")"
  rc=$?
  set -e
  rules="$(printf '%s\n' "$out" | awk 'NF {print $2}' | sort -u)"
  if [[ $rc -ne 1 ]]; then
    echo "FAIL bad/$rule: expected exit 1, got $rc"
    printf '%s\n' "$out"
    fail=1
  elif [[ "$rules" != "$rule" ]]; then
    echo "FAIL bad/$rule: expected only rule '$rule', got: $(echo "$rules" | tr '\n' ' ')"
    printf '%s\n' "$out"
    fail=1
  else
    echo "ok   bad/$rule"
  fi
done

set +e
out="$("${CHECKER[@]}" tests/cases/good)"
rc=$?
set -e
if [[ $rc -ne 0 || -n "$out" ]]; then
  echo "FAIL good: expected no violations, got exit $rc"
  printf '%s\n' "$out"
  fail=1
else
  echo "ok   good ($(find tests/cases/good -name '*.yml' | wc -l | tr -d ' ') files)"
fi

exit "$fail"
