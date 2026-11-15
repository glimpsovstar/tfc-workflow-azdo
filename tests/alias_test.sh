#!/bin/bash
# Cross-checks the examples' extends parameters against the local pipeline
# templates. The examples reference templates/pipelines/*.yml@tfc; with
# --alias tfc=. the checker resolves @tfc to this repository.
set -euo pipefail

cd "$(dirname "$0")/.."
CHECKER=(ruby tests/check_templates.rb --alias tfc=.)
BAD=tests/cases/bad/alias/param-crosscheck.yml
fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. Every example passes against the local templates.
set +e
out="$("${CHECKER[@]}" examples)"
rc=$?
set -e
if [[ $rc -eq 0 && -z "$out" ]]; then
  pass "examples match the local templates' parameters"
else
  bad "examples: expected no violations, got rc=$rc"
  printf '%s\n' "$out"
fi

# 2. The examples really reference @tfc, so step 1 checked something.
for f in examples/azure-pipelines.pr.yml examples/azure-pipelines.main.yml; do
  if grep -Eq '^  template: templates/pipelines/[a-z-]+\.yml@tfc$' "$f"; then
    pass "$f extends a template @tfc"
  else
    bad "$f does not extend a template @tfc"
  fi
done

# 3. A misspelled apply-run parameter fails with param-crosscheck and both the
#    unknown name and the missing required one are reported.
set +e
out="$("${CHECKER[@]}" "$BAD")"
rc=$?
set -e
rules="$(printf '%s\n' "$out" | awk 'NF {print $2}' | sort -u)"
if [[ $rc -eq 1 && "$rules" == "param-crosscheck" ]] &&
  grep -q "parameter 'enviroment' is not declared" <<<"$out" &&
  grep -q "required parameter 'environment'" <<<"$out"; then
  pass "misspelled apply-run parameter is caught through the alias"
else
  bad "bad/alias: expected param-crosscheck for 'enviroment', got rc=$rc"
  printf '%s\n' "$out"
fi

# 4. Without the alias the same file is skipped (another repository).
set +e
out="$(ruby tests/check_templates.rb "$BAD")"
rc=$?
set -e
if [[ $rc -eq 0 && -z "$out" ]]; then
  pass "without --alias, @tfc references are skipped"
else
  bad "without --alias: expected no violations, got rc=$rc"
  printf '%s\n' "$out"
fi

exit "$fail"
