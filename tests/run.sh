#!/bin/bash
# Run every local check. Prints PASS, FAIL or SKIP per check and exits
# non-zero if any check fails.
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURE=tests/fixtures/random
failures=0
results=()

record() { # name status
  results+=("$2 $1")
  echo "==> $2 $1"
  if [[ "$2" == FAIL ]]; then failures=$((failures + 1)); fi
}

run_check() { # name command...
  local name="$1"
  shift
  echo "--- $name"
  if "$@"; then record "$name" PASS; else record "$name" FAIL; fi
}

# Directories of v2 templates and example pipelines to check.
TEMPLATE_DIRS=()
for d in templates examples; do
  if [[ -d "$d" ]]; then
    TEMPLATE_DIRS+=("$d")
  else
    echo "note: $d/ does not exist yet, skipping it"
  fi
done

# 0. The checker's own tests.
run_check "checker self-tests" bash tests/test_checker.sh
run_check "pr-comment fake API test" bash tests/pr_comment_test.sh
run_check "plan-log fake TFE test" bash tests/plan_log_test.sh
run_check "validate: tflint plugin guard" bash tests/validate_tflint_test.sh
run_check "examples vs templates (--alias tfc=.)" bash tests/alias_test.sh
run_check "status sets (gate, Apply condition, pr-comment)" ruby tests/status_sets_test.rb
run_check "apply methods and plan log wiring (rendered)" ruby tests/apply_method_test.rb
run_check "output variable references" ruby tests/output_refs_test.rb
run_check "step scripts with a fake tfci" bash tests/steps_fake_tfci_test.sh

# 1. Static template checks.
if [[ ${#TEMPLATE_DIRS[@]} -gt 0 ]]; then
  run_check "check_templates" ruby tests/check_templates.rb --alias tfc=. "${TEMPLATE_DIRS[@]}"
else
  record "check_templates (no template dirs)" SKIP
fi

# 1b. Docs: docs/reference.md matches the templates; links resolve; no em dashes.
run_check "docs/reference.md up to date" ruby tests/gen_reference.rb --check
run_check "docs links and style" ruby tests/check_docs.rb

# 2. The v1.4.0 and v1.5.0 tfci manifests list the same commands and flags.
manifests_equal() {
  diff <(grep -v '^#' tests/tfci-v1.4.0-commands.txt) <(grep -v '^#' tests/tfci-v1.5.0-commands.txt)
}
run_check "tfci manifests v1.4.0 == v1.5.0" manifests_equal

# 3. shellcheck on every extracted bash script.
shellcheck_scripts() {
  local dir rc=0
  dir="$(mktemp -d)"
  ruby tests/extract_scripts.rb "$dir" ${TEMPLATE_DIRS[@]+"${TEMPLATE_DIRS[@]}"} tests/cases/good >/dev/null || rc=$?
  if [[ $rc -eq 0 ]]; then
    local files=("$dir"/*.sh)
    echo "shellcheck: ${#files[@]} scripts"
    shellcheck -S warning "${files[@]}" || rc=$?
  fi
  rm -rf "$dir"
  return "$rc"
}
if command -v shellcheck >/dev/null 2>&1; then
  run_check "shellcheck" shellcheck_scripts
else
  record "shellcheck (not installed)" FAIL
fi

# 4. terraform fmt.
run_check "terraform fmt" terraform fmt -check -recursive tests/fixtures

# 5. terraform init and validate on the fixture. .terraform/ is removed on exit.
trap 'rm -rf "$FIXTURE/.terraform"' EXIT
tf_validate() {
  terraform -chdir="$FIXTURE" init -backend=false -input=false >/dev/null &&
    terraform -chdir="$FIXTURE" validate
}
run_check "terraform validate" tf_validate

# 6. tflint, with the bundled terraform ruleset only (no plugin download).
if ! command -v tflint >/dev/null 2>&1; then
  record "tflint (not installed)" SKIP
elif grep -Eq '^\s*source\s*=' "$FIXTURE/.tflint.hcl"; then
  echo "warning: $FIXTURE/.tflint.hcl needs a plugin download (tflint --init); skipping"
  record "tflint (needs plugin download)" SKIP
else
  run_check "tflint" tflint --chdir="$FIXTURE"
fi

echo
echo "Summary:"
printf '  %s\n' "${results[@]}"
if [[ $failures -gt 0 ]]; then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "PASS"
