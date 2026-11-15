#!/bin/bash
# Behaviour test for templates/steps/pr-comment.yml.
#
# Extracts the step's bash script with tests/extract_scripts.rb and runs it
# against a local fake Azure DevOps API (Ruby WEBrick on 127.0.0.1) that
# records every request. Cases:
#   a. no existing thread: one POST to threads, then a succeeded PR status
#   b. a thread with our marker exists: PATCH that comment, no new thread
#   c. runStatus errored: PR status failed
#   d. HTTP 403: non-zero exit, message names "Contribute to pull requests"
#   e. the token never appears in stdout or stderr (checked in every case)
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

# run_case NAME MODE RUN_STATUS [SUMMARY_FILE]: sets rc, out, err; leaves requests in $work/requests.jsonl.
run_case() {
  local name="$1" mode="$2" run_status="$3" summary_file="${4:-$summary}"
  echo "$mode" >"$work/mode"
  : >"$work/requests.jsonl"
  set +e
  env -i PATH="$PATH" HOME="$HOME" \
    SYSTEM_ACCESSTOKEN="$token" \
    COLLECTION_URI="http://127.0.0.1:$port/org/" \
    PROJECT="My Project" \
    REPO_ID="0f2e0c4a-1111-2222-3333-444455556666" \
    PR_ID="17" \
    SUMMARY_FILE="$summary_file" \
    WORKSPACE="ws-demo" \
    RUN_LINK="https://tfe.example/app/org/workspaces/ws-demo/runs/run-abc" \
    RUN_STATUS="$run_status" \
    PLAN_ADD="1" PLAN_CHANGE="0" PLAN_DESTROY="0" \
    STATUS_GENRE="terraform" STATUS_NAME="tfe-plan" \
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
run_case "a" empty planned
if [[ $rc -eq 0 && "$(count GET /threads)" == 1 && "$(count POST /threads)" == 1 && "$(count PATCH /comments/1)" == 0 && "$(count POST /statuses)" == 1 ]]; then
  pass "a: one GET, one POST to threads, one POST to statuses (marker thread by someone else ignored)"
else
  bad "a: rc=$rc requests: $(cat "$work/requests.jsonl") stdout: $out stderr: $err"
fi
methods="$(jq -s -r '[.[] | .method + " " + .path] | join(",")' "$work/requests.jsonl")"
if [[ "$methods" == "GET /org/_apis/connectionData,GET $base_path/threads,POST $base_path/threads,POST $base_path/statuses" ]]; then
  pass "a: request order and URL (project URL-encoded, plain http kept)"
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
expected_content="$(printf '<!-- tfc-workflow-azdo:ws-demo -->\n%s' "$(cat "$summary")")"
if jq -e --arg c "$expected_content" \
  '.status == 1 and (.comments | length == 1) and .comments[0].parentCommentId == 0 and .comments[0].commentType == 1 and .comments[0].content == $c' \
  <<<"$thread_body" >/dev/null; then
  pass "a: thread body has marker plus summary, commentType 1, status 1"
else
  bad "a: thread body: $thread_body"
fi
status_body="$(body_of POST /statuses)"
if jq -e '.state == "succeeded" and .context.genre == "terraform" and .context.name == "tfe-plan" and .targetUrl == "https://tfe.example/app/org/workspaces/ws-demo/runs/run-abc" and .description == "Plan: +1 ~0 -0 (planned)"' \
  <<<"$status_body" >/dev/null; then
  pass "a: status succeeded for planned, with context, targetUrl and description"
else
  bad "a: status body: $status_body"
fi

# (b) Our thread exists: update it.
run_case "b" existing cost_estimated
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
  pass "b: status succeeded for cost_estimated"
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

if [[ $fail -ne 0 ]]; then
  echo "FAIL pr_comment_test"
  exit 1
fi
echo "PASS pr_comment_test"
