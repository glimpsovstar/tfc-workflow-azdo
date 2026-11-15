#!/bin/bash
# Behaviour test for the step scripts that call tfci, with a fake tfci.
#
# Extracts the bash scripts of templates/steps/tfci.yml, run-create.yml,
# run-apply.yml and plan-output.yml with tests/extract_scripts.rb and runs
# them with a fake `tfci` first on the PATH. The fake records its arguments
# and environment, prints canned JSON (keys from tfci v1.4.0: run_create.go,
# run_apply.go, plan_output.go) and exits with a chosen code. Each step runs
# as Azure DevOps would: tfci.yml writes the JSON file, the outputs step of
# the calling template reads it.
#
# Cases:
#   n1. native mode: tfci gets the token, hostname, TF_LOG and SSL_CERT_DIR,
#       each textArgs value as one argument, and no TF_VAR_FOO
#   n2. a caBundle path that does not exist fails before tfci runs
#   n3. an unknown logLevel fails before tfci runs
#   c1. run create: RUN_ID, RUN_STATUS, PLAN_ID, PLAN_STATUS, RUN_LINK are set
#       with ##vso[task.setvariable ...;isOutput=true]
#   c2. run create: tfci exits 1, the tfci step fails
#   c3. run create: JSON with an empty run_id, the outputs step fails
#   a1. run apply: Success sets RUN_STATUS and APPLY_RESULT
#   a2. run apply: Noop (planned_and_finished) succeeds
#   a3. run apply: "cannot be applied" (policy_override) fails with the
#       override message
#   p1. plan output: writes the summary and sets ADD, CHANGE, DESTROY
#
# Usage: bash tests/steps_fake_tfci_test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Extract the scripts, one directory per template, in file order.
extract() { # template -> prints script paths, in order
  local d="$work/scripts/$1"
  ruby tests/extract_scripts.rb "$d" "templates/steps/$1.yml" >/dev/null
  ls "$d"/*.sh
}
read -r tfci_sh < <(extract tfci)
mapfile -t create_sh < <(extract run-create) # check, outputs
mapfile -t apply_sh < <(extract run-apply)   # check, outputs
mapfile -t plan_sh < <(extract plan-output)  # check, summary
if [[ ${#create_sh[@]} -ne 2 || ${#apply_sh[@]} -ne 2 || ${#plan_sh[@]} -ne 2 ]]; then
  echo "FAIL expected 2 scripts each in run-create, run-apply, plan-output"
  exit 1
fi

# The fake tfci. It finds its canned answer next to itself, because tfci.yml
# runs it under env -i in native mode.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/tfci" <<'FAKE'
#!/bin/bash
set -euo pipefail
d="$(cd "$(dirname "$0")" && pwd)"
env >"$d/env.out"
printf '%s\n' "$@" >"$d/args.out"
cat "$d/stdout.json"
if [[ -s "$d/stderr.txt" ]]; then cat "$d/stderr.txt" >&2; fi
exit "$(cat "$d/rc")"
FAKE
chmod +x "$bin/tfci"

fake() { # JSON RC [STDERR]
  printf '%s\n' "$1" >"$bin/stdout.json"
  echo "$2" >"$bin/rc"
  printf '%s' "${3:-}" >"$bin/stderr.txt"
  rm -f "$bin/env.out" "$bin/args.out"
}

ca="$work/ca.pem"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'not a real certificate' '-----END CERTIFICATE-----' >"$ca"
mkdir -p "$work/wd" "$work/tmp"
token="tok-$RANDOM-not-a-real-secret"

# run_tfci COMMAND ARGS OUTFILE [extra VAR=value...]: runs tfci.yml's script in
# native mode; sets rc, out (stdout and stderr).
run_tfci() {
  local command="$1" args="$2" outfile="$3"
  shift 3
  set +e
  out="$(env -i PATH="$bin:$PATH" HOME="$HOME" \
    TF_API_TOKEN="$token" TF_HOSTNAME="tfe.example.internal" TF_CLOUD_ORGANIZATION="my-org" TF_MAX_TIMEOUT="1h" \
    TFCI_COMMAND="$command" TFCI_ARGS="$args" TFCI_MODE=native TFCI_IMAGE="hashicorp/tfci:v1.4.0" \
    TFCI_CA_BUNDLE="$ca" TFCI_WORKDIR="$work/wd" TFCI_OUTPUT_FILE="$outfile" \
    TFCI_TOKEN_VARIABLE=TF_API_TOKEN TFCI_STEP_NAME=step_tfci TFCI_TEMP_DIR="$work/tmp" TFCI_LOG_LEVEL="" \
    TF_VAR_FOO="must-not-reach-tfci" \
    "$@" bash "$tfci_sh" 2>&1)"
  rc=$?
  set -e
}

# run_script SCRIPT [VAR=value...]: sets rc, out.
run_script() {
  local script="$1"
  shift
  set +e
  out="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash "$script" 2>&1)"
  rc=$?
  set -e
}

has_output() { [[ "$out" == *"##vso[task.setvariable variable=$1;isOutput=true]$2"* ]]; }

create_json='{"status":"Success","run_id":"run-abc123","run_status":"planned_and_saved","run_message":"Azure DevOps build 1","plan_id":"plan-def456","plan_status":"finished","configuration_version_id":"cv-ghi789","run_link":"https://tfe.example.internal/app/my-org/workspaces/ws/runs/run-abc123"}'

# (n1) Native mode environment and arguments.
fake "$create_json" 0
run_tfci "run create" "--plan-only=false --save-plan=true" "$work/tmp/tfci-run.json" \
  TFCI_LOG_LEVEL=DEBUG "TFCI_TEXT_workspace=my ws" "TFCI_TEXT_message=build 1; echo hi" \
  HTTPS_PROXY=http://proxy.example.internal:3128
if [[ $rc -eq 0 && -s "$work/tmp/tfci-run.json" ]]; then
  pass "n1: tfci step exits 0 and writes the JSON file"
else
  bad "n1: rc=$rc out: $out"
fi
if ! grep -q -- "$token" "$bin/args.out" && ! grep -Eq '(^|[^[:alnum:]_])env -i' "$tfci_sh"; then
  pass "n1: the token is never on a command line (no env -i NAME=value, not in tfci argv)"
else
  bad "n1: token on a command line, or the script uses env -i"
fi
if grep -qx 'HTTPS_PROXY=http://proxy.example.internal:3128' "$bin/env.out"; then
  pass "n1: proxy variables pass through"
else
  bad "n1: HTTPS_PROXY did not reach tfci"
fi
if grep -q '^TF_VAR_' "$bin/env.out"; then
  bad "n1: a TF_VAR_* variable reached tfci: $(grep '^TF_VAR_' "$bin/env.out" | cut -d= -f1)"
else
  pass "n1: TF_VAR_FOO does not reach tfci"
fi
if grep -qx "TF_API_TOKEN=$token" "$bin/env.out" && grep -qx 'TF_HOSTNAME=tfe.example.internal' "$bin/env.out" &&
  grep -qx 'TF_CLOUD_ORGANIZATION=my-org' "$bin/env.out" && grep -qx 'TF_LOG=DEBUG' "$bin/env.out" &&
  grep -q '^SSL_CERT_DIR=' "$bin/env.out" && ! grep -q '^TFCI_' "$bin/env.out"; then
  pass "n1: tfci gets the token, hostname, organization, TF_LOG and SSL_CERT_DIR, no TFCI_* variables"
else
  bad "n1: env: $(cut -d= -f1 "$bin/env.out" | tr '\n' ' ')"
fi
expected_args=$'run\ncreate\n--json\n--plan-only=false\n--save-plan=true'
if [[ "$(head -5 "$bin/args.out")" == "$expected_args" ]] && grep -qx -- '--workspace=my ws' "$bin/args.out" &&
  grep -qx -- '--message=build 1; echo hi' "$bin/args.out"; then
  pass "n1: command, --json, args, and each textArgs value as one argument"
else
  bad "n1: args: $(tr '\n' '|' <"$bin/args.out")"
fi
if [[ "$out" == *"$token"* ]]; then bad "n1: token printed"; else pass "n1: token not printed"; fi

# (n1b) An agent-wide TF_LOG is dropped when logLevel is empty.
fake "$create_json" 0
run_tfci "run create" "" "$work/tmp/n1b.json" TF_LOG=TRACE
if [[ $rc -eq 0 ]] && ! grep -q '^TF_LOG=' "$bin/env.out"; then
  pass "n1b: an agent-wide TF_LOG does not reach tfci when logLevel is empty"
else
  bad "n1b: rc=$rc TF_LOG: $(grep '^TF_LOG=' "$bin/env.out" || true)"
fi

# (n2) Wrong caBundle path.
fake "$create_json" 0
run_tfci "run create" "" "$work/tmp/n2.json" TFCI_CA_BUNDLE="$work/no-such-ca.pem"
if [[ $rc -ne 0 && "$out" == *"caBundle"* && ! -e "$bin/args.out" ]]; then
  pass "n2: a missing caBundle fails before tfci runs"
else
  bad "n2: rc=$rc tfci ran: $([[ -e "$bin/args.out" ]] && echo yes || echo no) out: $out"
fi

# (n3) Unknown logLevel.
fake "$create_json" 0
run_tfci "run create" "" "$work/tmp/n3.json" TFCI_LOG_LEVEL=VERBOSE
if [[ $rc -ne 0 && "$out" == *"logLevel"* && ! -e "$bin/args.out" ]]; then
  pass "n3: an unknown logLevel fails before tfci runs"
else
  bad "n3: rc=$rc out: $out"
fi

# (c1) run create outputs.
fake "$create_json" 0
run_tfci "run create" "--plan-only=false" "$work/tmp/tfci-run.json"
run_script "${create_sh[1]}" TFCI_OUT="$work/tmp/tfci-run.json"
if [[ $rc -eq 0 ]] && has_output RUN_ID run-abc123 && has_output RUN_STATUS planned_and_saved &&
  has_output PLAN_ID plan-def456 && has_output PLAN_STATUS finished &&
  has_output RUN_LINK "https://tfe.example.internal/app/my-org/workspaces/ws/runs/run-abc123"; then
  pass "c1: run-create sets RUN_ID, RUN_STATUS, PLAN_ID, PLAN_STATUS, RUN_LINK as outputs"
else
  bad "c1: rc=$rc out: $out"
fi

# (c2) tfci exits 1.
fake '{"status":"Error","run_id":"run-abc123","run_status":"errored"}' 1 'run errored'
run_tfci "run create" "--plan-only=false" "$work/tmp/tfci-run.json"
if [[ $rc -eq 1 && "$out" == *"tfci run create exited with 1"* ]]; then
  pass "c2: tfci exit 1 fails the run-create tfci step"
else
  bad "c2: rc=$rc out: $out"
fi

# (c3) Empty run_id.
fake '{"status":"Error","run_id":"","run_status":""}' 0
run_tfci "run create" "--plan-only=false" "$work/tmp/tfci-run.json"
run_script "${create_sh[1]}" TFCI_OUT="$work/tmp/tfci-run.json"
if [[ $rc -ne 0 && "$out" == *"no valid run_id"* && "$out" != *"isOutput=true"* ]]; then
  pass "c3: an empty run_id fails the outputs step and sets nothing"
else
  bad "c3: rc=$rc out: $out"
fi

# (a1) run apply Success.
fake '{"status":"Success","run_id":"run-abc123","run_status":"applied","run_link":"https://tfe.example.internal/x"}' 0
run_tfci "run apply" "" "$work/tmp/tfci-apply.json"
tfci_rc=$rc
run_script "${apply_sh[1]}" TFCI_OUT="$work/tmp/tfci-apply.json" RUN_ID=run-abc123
if [[ $tfci_rc -eq 0 && $rc -eq 0 ]] && has_output RUN_STATUS applied && has_output APPLY_RESULT Success; then
  pass "a1: run-apply Success sets RUN_STATUS and APPLY_RESULT"
else
  bad "a1: rc=$tfci_rc/$rc out: $out"
fi

# (a2) run apply Noop.
fake '{"status":"Noop","run_id":"run-abc123","run_status":"planned_and_finished"}' 0 'run run-abc123, is planned and finished. There is nothing to do.'
run_tfci "run apply" "" "$work/tmp/tfci-apply.json"
tfci_rc=$rc
run_script "${apply_sh[1]}" TFCI_OUT="$work/tmp/tfci-apply.json" RUN_ID=run-abc123
if [[ $tfci_rc -eq 0 && $rc -eq 0 && "$out" == *"nothing to apply"* ]] && has_output APPLY_RESULT Noop; then
  pass "a2: run-apply Noop succeeds and says nothing to apply"
else
  bad "a2: rc=$tfci_rc/$rc out: $out"
fi

# (a3) run apply on a run that is not confirmable.
fake '{"status":"Error","run_id":"run-abc123","run_status":"policy_override"}' 1 'run run-abc123, cannot be applied'
run_tfci "run apply" "" "$work/tmp/tfci-apply.json"
tfci_rc=$rc
run_script "${apply_sh[1]}" TFCI_OUT="$work/tmp/tfci-apply.json" RUN_ID=run-abc123
if [[ $tfci_rc -eq 1 && $rc -ne 0 && "$out" == *"override it in TFE (or discard the run), then re-run the pipeline"* && "$out" != *"isOutput=true"* ]]; then
  pass "a3: 'cannot be applied' fails with the override message"
else
  bad "a3: rc=$tfci_rc/$rc out: $out"
fi

# (a4) run apply on a saved plan TFE discarded (a newer run applied first;
# seen in the lab end-to-end run).
fake '{"status":"Error","run_id":"run-abc123","run_status":"discarded"}' 1 'run run-abc123, cannot be applied'
run_tfci "run apply" "" "$work/tmp/tfci-apply.json"
tfci_rc=$rc
run_script "${apply_sh[1]}" TFCI_OUT="$work/tmp/tfci-apply.json" RUN_ID=run-abc123
if [[ $tfci_rc -eq 1 && $rc -ne 0 && "$out" == *"was discarded in TFE"* && "$out" == *"Nothing was applied"* ]]; then
  pass "a4: a discarded saved plan fails with the re-run message"
else
  bad "a4: rc=$tfci_rc/$rc out: $out"
fi

# (p1) plan output summary.
fake '{"status":"Success","plan_id":"plan-def456","plan_status":"finished","add":"1","change":"0","destroy":"2"}' 0
run_tfci "plan output" "" "$work/tmp/tfci-plan.json"
tfci_rc=$rc
run_script "${plan_sh[1]}" TFCI_OUT="$work/tmp/tfci-plan.json" SUMMARY_FILE="$work/tmp/plan-summary.md" \
  WORKSPACE=ws RUN_LINK="https://tfe.example.internal/x" RUN_STATUS=planned_and_saved CV_ID=cv-ghi789
if [[ $tfci_rc -eq 0 && $rc -eq 0 ]] && grep -qF '| 1 | 0 | 2 |' "$work/tmp/plan-summary.md" &&
  grep -qF '## Terraform plan: ws' "$work/tmp/plan-summary.md" &&
  has_output ADD 1 && has_output CHANGE 0 && has_output DESTROY 2 &&
  [[ "$out" == *"##vso[task.uploadsummary]$work/tmp/plan-summary.md"* ]]; then
  pass "p1: plan-output writes the summary, uploads it and sets ADD, CHANGE, DESTROY"
else
  bad "p1: rc=$tfci_rc/$rc out: $out"
fi

if [[ $fail -ne 0 ]]; then
  echo "FAIL steps_fake_tfci_test"
  exit 1
fi
echo "PASS steps_fake_tfci_test"
