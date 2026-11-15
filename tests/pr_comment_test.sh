#!/bin/bash
# Behaviour test for templates/steps/pr-comment.yml.
#
# Extracts the step's bash script with tests/extract_scripts.rb and runs it
# against a local fake Azure DevOps API (Ruby WEBrick on 127.0.0.1) that
# records every request. Run statuses are real plan-only end states of tfci
# run create (getDesiredRunStatus, run.go, v1.4.0). Cases:
#   a. planned_and_finished, no existing thread: one POST to threads, then a
#      succeeded PR status; the comment and status name the short commit
#   b. post_plan_completed, a thread with our marker exists: PATCH that
#      comment, no new thread, succeeded status
#   c. errored: PR status failed
#   s. policy_soft_failed: PR status failed, "soft-mandatory policy failed"
#   n. a newer push exists (lastMergeSourceCommit differs): no comment, no
#      status, exit 0
#   d. HTTP 403: non-zero exit, message names "Contribute to pull requests"
#   e. the token never appears in stdout or stderr (checked in every case)
#   p1. a plan log file: appended in <details><summary>Terraform plan</summary>
#       and a ```text fence; triple backticks in the log are replaced
#   p2. includePlanLog false: no plan block
#   p3. a plan log over 100,000 characters: capped, with a trimmed note
#   p4. includePlanLog true and no plan log file: one line saying the plan
#       text is not available, with the run link
#   p5. a log with </details>, raw HTML and backtick runs stays inside the
#       fence; triple backticks are replaced
#   p6. a failed POST whose response echoes the comment: the response printed
#       to stderr has every "##" broken up, so no logging command reaches the
#       job log
# Also: the bad checker case for this step reports no-user-macro-in-script.
#
# Usage: bash tests/pr_comment_test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 0. Checker case for this step.
set +e
out="$(ruby tests/check_templates.rb tests/cases/bad/pr-comment/no-user-macro-in-script.yml)"
rc=$?
set -e
rules="$(printf '%s\n' "$out" | awk 'NF {print $2}' | sort -u)"
if [[ $rc -eq 1 && "$rules" == "no-user-macro-in-script" ]]; then
  pass "checker flags \$(System.PullRequest.PullRequestId) in a script body"
else
  bad "checker case: expected only no-user-macro-in-script, got rc=$rc: $out"
fi

# 1. Extract the script.
ruby tests/extract_scripts.rb "$work/scripts" templates/steps/pr-comment.yml >/dev/null
scripts=("$work"/scripts/*.sh)
if [[ ${#scripts[@]} -ne 1 ]]; then
  echo "FAIL expected one bash script in pr-comment.yml, found ${#scripts[@]}"
  exit 1
fi
script="${scripts[0]}"

# 2. Fake API. MODE file controls the response: empty, existing or forbidden.
cat >"$work/server.rb" <<'RUBY'
require 'webrick'
require 'json'
dir = ARGV[0]
log = File.join(dir, 'requests.jsonl')
server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                 Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
File.write(File.join(dir, 'port'), server.config[:Port].to_s)
# A servlet that takes every method: WEBrick's mount_proc rejects PATCH.
handler = lambda do |req, res|
  raw_path = req.unparsed_uri.split("?", 2).first # not decoded, to check URL encoding
  mode = File.read(File.join(dir, 'mode')).strip
  File.open(log, 'a') do |f|
    f.puts JSON.generate(method: req.request_method, path: raw_path, query: req.query_string.to_s,
                         auth: req['Authorization'].to_s, body: req.body.to_s)
  end
  res['Content-Type'] = 'application/json'
  if mode == 'forbidden'
    res.status = 403
    res.body = JSON.generate(message: 'TF401027: You need the Git permission PullRequestContribute')
    next res
  end
  if req.request_method == 'GET' && raw_path.end_with?('/pullRequests/17')
    head = File.read(File.join(dir, 'head')).strip
    res.body = JSON.generate(pullRequestId: 17, lastMergeSourceCommit: { commitId: head })
    next res
  end
  if raw_path.end_with?('/_apis/connectionData')
    res.body = JSON.generate(authenticatedUser: { id: 'build-identity-id' })
    next res
  end
  in_threads = raw_path.end_with?('/threads')
  if req.request_method == 'GET' && in_threads
    threads = [
      { id: 7, comments: [{ id: 1, parentCommentId: 0, content: 'Policy: build succeeded', commentType: 'system' }] }
    ]
    # A thread someone else wrote, carrying our marker: must never be treated as ours.
    threads << { id: 41, isDeleted: false, status: 'active',
                 comments: [{ id: 2, parentCommentId: 0, commentType: 'text', author: { id: 'someone-else' },
                              content: "<!-- tfc-workflow-azdo:ws-demo -->\nspoofed" }] }
    if mode == 'existing'
      threads << { id: 42, isDeleted: false, status: 'active',
                   comments: [{ id: 3, parentCommentId: 0, commentType: 'text',
                                author: { id: 'build-identity-id' },
                                content: "<!-- tfc-workflow-azdo:ws-demo -->\nold plan" },
                              { id: 4, parentCommentId: 3, content: 'reply' }] }
    end
    res.body = JSON.generate(value: threads, count: threads.length)
  elsif req.request_method == 'POST' && in_threads && mode == 'echo500'
    # A failing API that echoes the request, as some proxies do.
    res.status = 500
    res.body = req.body.to_s
  elsif req.request_method == 'POST' && in_threads
    res.body = JSON.generate(id: 99, comments: [{ id: 1 }])
  else
    res.body = '{"id":1}'
  end
end
servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
  define_method(:service) { |req, res| handler.call(req, res) }
end
server.mount("/", servlet)
trap("TERM") { server.shutdown }
server.start
RUBY

echo empty >"$work/mode"
commit="0123456789abcdef0123456789abcdef01234567"
newer="fedcba9876543210fedcba9876543210fedcba98"
echo "$commit" >"$work/head"
ruby "$work/server.rb" "$work" &
server_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
port="$(cat "$work/port")"

token="tok-$RANDOM-not-a-real-secret-$RANDOM"
summary="$work/plan-summary.md"
printf '%s\n' '### Terraform plan: `ws-demo`' '' 'Plan: 1 to add, 0 to change, 0 to destroy. "quotes" and \backslash' >"$summary"

# run_case NAME MODE RUN_STATUS [SUMMARY_FILE] [PR_HEAD] [PLAN_LOG_FILE] [INCLUDE]:
# sets rc, out, err; leaves requests in $work/requests.jsonl. PR_HEAD is the
# PR's newest source commit in the fake API (default: this build's commit).
# PLAN_LOG_FILE defaults to a file that does not exist; INCLUDE to False.
run_case() {
  local name="$1" mode="$2" run_status="$3" summary_file="${4:-$summary}" pr_head="${5:-$commit}"
  local plan_log_file="${6:-$work/no-plan-log.txt}" include="${7:-False}"
  echo "$mode" >"$work/mode"
  echo "$pr_head" >"$work/head"
  : >"$work/requests.jsonl"
  set +e
  env -i PATH="$PATH" HOME="$HOME" \
    SYSTEM_ACCESSTOKEN="$token" \
    COLLECTION_URI="http://127.0.0.1:$port/org/" \
    PROJECT="My Project" \
    REPO_ID="0f2e0c4a-1111-2222-3333-444455556666" \
    PR_ID="17" \
    SOURCE_COMMIT="$commit" \
    SUMMARY_FILE="$summary_file" \
    WORKSPACE="ws-demo" \
    RUN_LINK="https://tfe.example/app/org/workspaces/ws-demo/runs/run-abc" \
    RUN_STATUS="$run_status" \
    PLAN_ADD="1" PLAN_CHANGE="0" PLAN_DESTROY="0" \
    STATUS_GENRE="terraform" STATUS_NAME="tfe-plan" \
    PLAN_LOG_FILE="$plan_log_file" INCLUDE_PLAN_LOG="$include" \
    bash "$script" >"$work/out" 2>"$work/err"
  rc=$?
  set -e
  out="$(cat "$work/out")"
  err="$(cat "$work/err")"
  if grep -qF "$token" "$work/out" "$work/err"; then
    bad "$name: token appears in output (e)"
  else
    pass "$name: token not in stdout or stderr (e)"
  fi
}

# Count requests matching METHOD and a path suffix.
count() { jq -s --arg m "$1" --arg p "$2" '[.[] | select(.method == $m and (.path | endswith($p)))] | length' "$work/requests.jsonl"; }
# Body of the first request matching METHOD and a path suffix.
body_of() { jq -s -r --arg m "$1" --arg p "$2" '[.[] | select(.method == $m and (.path | endswith($p)))][0].body' "$work/requests.jsonl"; }

base_path="/org/My%20Project/_apis/git/repositories/0f2e0c4a-1111-2222-3333-444455556666/pullRequests/17"

# (a) No thread yet.
run_case "a" empty planned_and_finished
if [[ $rc -eq 0 && "$(count GET /threads)" == 1 && "$(count POST /threads)" == 1 && "$(count PATCH /comments/1)" == 0 && "$(count POST /statuses)" == 1 ]]; then
  pass "a: one GET, one POST to threads, one POST to statuses (marker thread by someone else ignored)"
else
  bad "a: rc=$rc requests: $(cat "$work/requests.jsonl") stdout: $out stderr: $err"
fi
methods="$(jq -s -r '[.[] | .method + " " + .path] | join(",")' "$work/requests.jsonl")"
if [[ "$methods" == "GET $base_path,GET /org/_apis/connectionData,GET $base_path/threads,POST $base_path/threads,POST $base_path/statuses" ]]; then
  pass "a: request order and URL: PR first, then identity, threads, status (project URL-encoded, plain http kept)"
else
  bad "a: unexpected requests: $methods"
fi
if jq -s -e '.[] | select((.path | endswith("/_apis/connectionData") | not) and .query != "api-version=7.1")' "$work/requests.jsonl" >/dev/null; then
  bad "a: a request does not use api-version=7.1"
else
  pass "a: every request uses api-version=7.1"
fi
if jq -s -e --arg t "Bearer $token" 'all(.[]; .auth == $t)' "$work/requests.jsonl" >/dev/null; then
  pass "a: bearer token sent on every request"
else
  bad "a: Authorization header missing or wrong"
fi
thread_body="$(body_of POST /threads)"
expected_content="$(printf '<!-- tfc-workflow-azdo:ws-demo -->\n%s\n\nCommit: `01234567`' "$(cat "$summary")")"
if jq -e --arg c "$expected_content" \
  '.status == 1 and (.comments | length == 1) and .comments[0].parentCommentId == 0 and .comments[0].commentType == 1 and .comments[0].content == $c' \
  <<<"$thread_body" >/dev/null; then
  pass "a: thread body has marker, summary and short commit, commentType 1, status 1"
else
  bad "a: thread body: $thread_body"
fi
status_body="$(body_of POST /statuses)"
if jq -e '.state == "succeeded" and .context.genre == "terraform" and .context.name == "tfe-plan" and .targetUrl == "https://tfe.example/app/org/workspaces/ws-demo/runs/run-abc" and .description == "Plan: +1 ~0 -0 (planned_and_finished), commit 01234567"' \
  <<<"$status_body" >/dev/null; then
  pass "a: status succeeded for planned_and_finished, with context, targetUrl and description with the short commit"
else
  bad "a: status body: $status_body"
fi

# (b) Our thread exists: update it.
run_case "b" existing post_plan_completed
if [[ $rc -eq 0 && "$(count POST /threads)" == 0 && "$(count PATCH /threads/42/comments/3)" == 1 && "$(count POST /statuses)" == 1 ]]; then
  pass "b: PATCH threads/42/comments/3, no new thread"
else
  bad "b: rc=$rc requests: $(cat "$work/requests.jsonl") stderr: $err"
fi
if jq -e --arg c "$expected_content" '.content == $c' <<<"$(body_of PATCH /comments/3)" >/dev/null; then
  pass "b: PATCH body carries the new content"
else
  bad "b: PATCH body: $(body_of PATCH /comments/3)"
fi
if [[ "$(jq -r .state <<<"$(body_of POST /statuses)")" == succeeded ]]; then
  pass "b: status succeeded for post_plan_completed"
else
  bad "b: status body: $(body_of POST /statuses)"
fi

# (c) Errored run: failed status.
run_case "c" empty errored
if [[ $rc -eq 0 && "$(jq -r .state <<<"$(body_of POST /statuses)")" == failed ]]; then
  pass "c: status failed for errored"
else
  bad "c: rc=$rc status body: $(body_of POST /statuses) stderr: $err"
fi

# (s) Soft-mandatory policy failed: failed status with the override hint.
run_case "s" empty policy_soft_failed
status_body="$(body_of POST /statuses)"
if [[ $rc -eq 0 ]] && jq -e '.state == "failed" and .description == "soft-mandatory policy failed: override in TFE, commit 01234567"' <<<"$status_body" >/dev/null; then
  pass "s: status failed for policy_soft_failed, description says override in TFE"
else
  bad "s: rc=$rc status body: $status_body stderr: $err"
fi

# (n) A newer push exists: skip the comment and the status.
run_case "n" empty planned_and_finished "$summary" "$newer"
if [[ $rc -eq 0 && "$(count GET /pullRequests/17)" == 1 && "$(count POST /threads)" == 0 && "$(count PATCH /comments/3)" == 0 && "$(count POST /statuses)" == 0 && "$out" == *"newer push"* ]]; then
  pass "n: newer push: only the PR GET, no comment, no status, exit 0, logged"
else
  bad "n: rc=$rc requests: $(cat "$work/requests.jsonl") stdout: $out"
fi

# (c2) Missing summary file: fallback text with run link and status.
run_case "c2" empty errored "$work/does-not-exist.md"
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
if [[ $rc -eq 0 && "$content" == "<!-- tfc-workflow-azdo:ws-demo -->"* && "$content" == *"plan output not available"* && "$content" == *"run-abc"* && "$content" == *"errored"* ]]; then
  pass "c2: missing summary posts the fallback with run link and status"
else
  bad "c2: rc=$rc content: $content"
fi

# (d) 403: fail with a clear message.
run_case "d" forbidden planned
if [[ $rc -ne 0 && "$out$err" == *"Contribute to pull requests"* ]]; then
  pass "d: 403 exits $rc and names 'Contribute to pull requests'"
else
  bad "d: rc=$rc stdout: $out stderr: $err"
fi
if [[ "$(count POST /threads)" == 0 && "$(count POST /statuses)" == 0 ]]; then
  pass "d: stops after the first 403"
else
  bad "d: kept calling after 403: $(cat "$work/requests.jsonl")"
fi

# (p1) Plan log included, collapsed, triple backticks replaced.
plan_log="$work/plan-log.txt"
printf '%s\n' 'Terraform will perform the following actions:' '  + note = "```"' 'Plan: 1 to add, 0 to change, 0 to destroy.' >"$plan_log"
run_case "p1" empty planned_and_finished "$summary" "$commit" "$plan_log" True
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
expected_block="$(printf '<details><summary>Terraform plan</summary>\n\n```text\n%s\n%s\n%s\n```\n\n</details>' \
  'Terraform will perform the following actions:' "  + note = \"'''\"" 'Plan: 1 to add, 0 to change, 0 to destroy.')"
if [[ $rc -eq 0 && "$content" == "$expected_content"$'\n\n'"$expected_block" ]]; then
  pass "p1: plan log appended after the summary in <details> and a text fence"
else
  bad "p1: rc=$rc content: $content"
fi
if [[ "$(grep -o '```' <<<"$content" | wc -l | tr -d ' ')" == 2 ]]; then
  pass "p1: triple backticks in the log replaced; only the two fence lines remain"
else
  bad "p1: unexpected triple backticks in: $content"
fi

# (p2) includePlanLog false: no plan block.
run_case "p2" empty planned_and_finished "$summary" "$commit" "$plan_log" False
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
if [[ $rc -eq 0 && "$content" == "$expected_content" ]]; then
  pass "p2: includePlanLog False leaves the plan out"
else
  bad "p2: rc=$rc content: $content"
fi

# (p3) A plan log over 100,000 characters is capped with a note.
big_log="$work/big-plan-log.txt"
for i in $(seq 1 2500); do printf '  + resource line %05d padded to about sixty characters......\n' "$i"; done >"$big_log"
run_case "p3" empty planned_and_finished "$summary" "$commit" "$big_log" True
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
plan_part="${content#*'```text'$'\n'}"
plan_part="${plan_part%%$'\n''```'*}"
if [[ $rc -eq 0 && ${#plan_part} -le 100000 && ${#plan_part} -gt 99000 && "$plan_part" == *"......" &&
  "$content" == *"Plan text trimmed at 100000 characters"*"</details>" ]]; then
  pass "p3: plan text capped at 100,000 characters (${#plan_part}), cut at a line end, with a trimmed note"
else
  bad "p3: rc=$rc plan part length ${#plan_part}, tail: ${content: -300}"
fi

# (p4) includePlanLog true, no plan log file: say so, with the run link.
run_case "p4" empty planned_and_finished "$summary" "$commit" "$work/no-plan-log.txt" True
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
if [[ $rc -eq 0 && "$content" == "$expected_content"$'\n\n'"Plan text not available here: see the run in TFE: https://tfe.example/app/org/workspaces/ws-demo/runs/run-abc" ]]; then
  pass "p4: a missing plan log adds one 'not available' line with the run link"
else
  bad "p4: rc=$rc content: $content"
fi

# (p5) HTML and </details> in the log stay inside the fence.
html_log="$work/html-plan-log.txt"
printf '%s\n' '  + a = "</details>"' '  + b = "<script>alert(1)</script>"' '  + c = "<img src=x onerror=alert(2)>"' \
  '  + d = "```"' '  + e = "````"' '  + f = "</summary><details open>"' >"$html_log"
run_case "p5" empty planned_and_finished "$summary" "$commit" "$html_log" True
content="$(jq -r '.comments[0].content' <<<"$(body_of POST /threads)")"
fence_body="$(printf '%s\n' '  + a = "</details>"' '  + b = "<script>alert(1)</script>"' '  + c = "<img src=x onerror=alert(2)>"' \
  "  + d = \"'''\"" "  + e = \"'''\`\"" '  + f = "</summary><details open>"')"
expected_block="$(printf '<details><summary>Terraform plan</summary>\n\n```text\n%s\n```\n\n</details>' "$fence_body")"
if [[ $rc -eq 0 && "$content" == "$expected_content"$'\n\n'"$expected_block" ]]; then
  pass "p5: </details> and raw HTML stay inside the text fence, and the block closes after it"
else
  bad "p5: rc=$rc content: $content"
fi
if [[ "$(grep -o '```' <<<"$content" | wc -l | tr -d ' ')" == 2 ]]; then
  pass "p5: backtick runs in the log replaced; only the two fence lines carry triple backticks"
else
  bad "p5: unexpected triple backticks in: $content"
fi

# (p6) A failed POST whose response echoes the comment, plan text included.
inj_log="$work/inj-plan-log.txt"
printf '%s\n' '##vso[task.setvariable variable=EVIL]x' '##[error]y' '##VSO[task.complete result=Failed]z' >"$inj_log"
run_case "p6" echo500 planned_and_finished "$summary" "$commit" "$inj_log" True
if [[ $rc -ne 0 && "$err" == *"# #vso[task.setvariable"* ]]; then
  pass "p6: a failed call exits $rc and prints the echoed response"
else
  bad "p6: rc=$rc stderr: $err"
fi
if grep -i -q -E '##(\[|vso)' "$work/err" || grep -q '##' "$work/err"; then
  bad "p6: a '##' from the plan text reached stderr: $(grep '##' "$work/err")"
else
  pass "p6: no '##' from the plan text in stderr"
fi
if grep -i -E '##(\[|vso)' "$work/out" | grep -v -q -E '^##vso\[task\.logissue type=error\]Azure DevOps API call failed: '; then
  bad "p6: a logging command from the plan text reached stdout: $out"
else
  pass "p6: the only logging command in stdout is the step's own error"
fi

if [[ $fail -ne 0 ]]; then
  echo "FAIL pr_comment_test"
  exit 1
fi
echo "PASS pr_comment_test"
