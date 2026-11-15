#!/usr/bin/env bash
# Tests the tflint step of templates/steps/validate.yml in native mode.
# With a fake tflint on the PATH:
#   t1. tflintPluginInit false (untrusted, the default): the repository's
#       .tflint.hcl is ignored; tflint runs once with --config pointing at a
#       pipeline-owned file (outside the repository), never --init
#   t2. tflintPluginInit true (trusted): the repository's config is used,
#       --init when it declares a plugin source (also on a one-line block)
#   t3. GITHUB_TOKEN set on the agent never reaches tflint
# With the real tflint, when installed:
#   t4. the plugin_dir bypass: a PR commits a plugin binary and a .tflint.hcl
#       with config { plugin_dir = "./bin" } and no source line. The binary
#       must not run when tflintPluginInit is false.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

ruby tests/extract_scripts.rb "$work/sh" templates/steps/validate.yml >/dev/null
script="$(grep -l 'tflintPluginInit is false' "$work"/sh/*.sh | head -1)"
[[ -n "$script" ]] || { echo "FAIL could not extract the tflint script"; exit 1; }

mkdir -p "$work/fake" "$work/tf" "$work/tmp"
cat >"$work/fake/tflint" <<'FAKE'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"$d/calls"
env >"$d/env.out"
exit 0
FAKE
chmod +x "$work/fake/tflint"

run() { # BIN_DIR PLUGIN_INIT
  rm -f "$work/fake/calls" "$work/fake/env.out"
  set +e
  out="$(env -i PATH="$1:$PATH" HOME="$HOME" WORK_DIR="$work/tf" MODE=native \
    TFLINT_IMAGE=unused PLUGIN_INIT="$2" AGENT_TEMP="$work/tmp" GITHUB_TOKEN=gh-secret-not-for-tflint \
    bash "$script" 2>&1)"
  rc=$?
  set -e
}

printf 'plugin "evil" {\n  enabled = true\n  source  = "github.com/attacker/tflint-ruleset-evil"\n  version = "0.1.0"\n}\n' >"$work/tf/.tflint.hcl"
run "$work/fake" False
calls="$(cat "$work/fake/calls" 2>/dev/null || true)"
cfg="$(sed -n 's/.*--config=\([^ ]*\).*/\1/p' <<<"$calls")"
if [[ $rc -eq 0 && "$(wc -l <<<"$calls" | tr -d ' ')" == 1 && "$calls" != *"--init"* &&
  -n "$cfg" && "$cfg" != "$work/tf"* && "$out" == *"Ignoring the repository's .tflint.hcl"* ]]; then
  pass "t1: untrusted: repository config ignored, pipeline-owned --config, no --init"
else
  bad "t1: rc=$rc calls=$calls out=$out"
fi
if grep -q '^GITHUB_TOKEN=' "$work/fake/env.out"; then
  bad "t3: GITHUB_TOKEN reached tflint"
else
  pass "t3: GITHUB_TOKEN does not reach tflint"
fi

printf 'plugin "aws" { enabled = true, source = "github.com/terraform-linters/tflint-ruleset-aws", version = "0.1.0" }\n' >"$work/tf/.tflint.hcl"
run "$work/fake" True
calls="$(cat "$work/fake/calls" 2>/dev/null || true)"
if [[ $rc -eq 0 && "$(sed -n 1p <<<"$calls")" == *"--init"* && "$(sed -n 2p <<<"$calls")" == *"--no-color"* && "$calls" != *"--config="* ]]; then
  pass "t2: trusted: repository config, --init (one-line block), then lint"
else
  bad "t2: rc=$rc calls=$calls"
fi

# t4: the real tflint and the plugin_dir bypass.
if command -v tflint >/dev/null 2>&1; then
  cp tests/fixtures/random/*.tf "$work/tf/"
  mkdir -p "$work/tf/bin"
  printf '#!/bin/sh\ntouch "%s/PWNED"\nexit 1\n' "$work" >"$work/tf/bin/tflint-ruleset-evil"
  chmod +x "$work/tf/bin/tflint-ruleset-evil"
  printf 'config {\n  plugin_dir = "./bin"\n}\nplugin "evil" {\n  enabled = true\n}\n' >"$work/tf/.tflint.hcl"
  real_bin="$(dirname "$(command -v tflint)")"
  run "$real_bin" False
  if [[ ! -e "$work/PWNED" ]]; then
    pass "t4: real tflint: a plugin_dir in the PR's .tflint.hcl is not used (rc=$rc)"
  else
    bad "t4: real tflint ran the PR's plugin binary"
  fi
else
  echo "skip t4: tflint not installed"
fi

if [[ $fails -eq 0 ]]; then echo "PASS validate_tflint_test"; else echo "FAIL validate_tflint_test ($fails)"; exit 1; fi
