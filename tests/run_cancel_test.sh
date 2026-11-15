#!/bin/bash
# Behaviour test for templates/steps/run-cancel.yml.
#
# Extracts the step's bash script with tests/extract_scripts.rb and runs it
# against a local fake TFE: Ruby WEBrick over HTTPS on localhost, with a test
# CA made here, so the caBundle (--cacert) path is exercised too. The fake
# records every request (method, raw URI, Authorization header, body). It serves:
#   GET  /api/v2/organizations/<org>/workspaces/<ws>  {data: {id: ws-abc123}}
#   GET  /api/v2/workspaces/ws-abc123/runs            runs for the MODE
#   GET  /api/v2/runs/run-given                       a cancelable run
#   POST /api/v2/runs/<id>/actions/(cancel|discard)   202
# Cases:
#   (a) lookup by configuration version: the newest run on cv-target (not the
#       first in the list, and not the newer run on another cv) is cancelable:
#       POST cancel to it, with the comment naming the build; the organization
#       name is URL-encoded; the list asks for plan_only runs too
#   (b) the run is discardable only: POST discard
#   (c) the run has finished: no POST, exit 0
#   (d) no run on the configuration version: no POST, exit 0, "no TFE run to cancel"
#   (e) runId given: no workspace or list lookup, GET the run, POST cancel
#   (f) the workspace GET returns 500: warning with HTTP 500, exit 0; the
#       cancel POST returns 500: warning with HTTP 500, exit 0
#   (g) every case: the token is never in stdout or stderr, and every request
#       carries the Authorization header
#   (h) a bad configurationVersionId or runId is rejected before any request,
#       exit 0 with a warning; an unset configuration version (a literal
#       "$(upload.CONFIGURATION_VERSION_ID)") is "no TFE run to cancel"
#
# Usage: bash tests/run_cancel_test.sh
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

# 1. Extract the script.
ruby tests/extract_scripts.rb "$work/scripts" templates/steps/run-cancel.yml >/dev/null
scripts=("$work"/scripts/*.sh)
if [[ ${#scripts[@]} -ne 1 ]]; then
  echo "FAIL expected one bash script in run-cancel.yml, found ${#scripts[@]}"
  exit 1
fi
script="${scripts[0]}"

# 2. Fake TFE over HTTPS with a test CA. MODE file: cancel, discard, finished,
# nomatch, ws500, post500, post404.
cat >"$work/server.rb" <<'RUBY'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'json'
dir = ARGV[0]
log = File.join(dir, 'requests.jsonl')

def name(cn) OpenSSL::X509::Name.parse("/CN=#{cn}") end
ca_key = OpenSSL::PKey::RSA.new(2048)
ca = OpenSSL::X509::Certificate.new
ca.version = 2; ca.serial = 1; ca.subject = name('run-cancel-test CA'); ca.issuer = ca.subject
ca.public_key = ca_key.public_key; ca.not_before = Time.now - 60; ca.not_after = Time.now + 3600
ef = OpenSSL::X509::ExtensionFactory.new(ca, ca)
ca.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
ca.add_extension(ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
ca.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash', false))
ca.sign(ca_key, OpenSSL::Digest::SHA256.new)
key = OpenSSL::PKey::RSA.new(2048)
cert = OpenSSL::X509::Certificate.new
cert.version = 2; cert.serial = 2; cert.subject = name('localhost'); cert.issuer = ca.subject
cert.public_key = key.public_key; cert.not_before = Time.now - 60; cert.not_after = Time.now + 3600
ef = OpenSSL::X509::ExtensionFactory.new(cert, ca)
cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
cert.add_extension(ef.create_extension('subjectAltName', 'DNS:localhost', false))
cert.add_extension(ef.create_extension('extendedKeyUsage', 'serverAuth', false))
cert.sign(ca_key, OpenSSL::Digest::SHA256.new)
File.write(File.join(dir, 'ca.pem'), ca.to_pem)

def run(id, cv, created, status, cancel, discard)
  { id: id, type: 'runs',
    attributes: { status: status, 'created-at' => created,
                  actions: { 'is-cancelable' => cancel, 'is-discardable' => discard,
                             'is-confirmable' => false, 'is-force-cancelable' => false } },
    relationships: { 'configuration-version' => { data: { id: cv, type: 'configuration-versions' } } } }
end

server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, SSLEnable: true,
                                 SSLCertificate: cert, SSLPrivateKey: key,
                                 Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
handler = lambda do |req, res|
  mode = File.read(File.join(dir, 'mode')).strip
  File.open(log, 'a') do |f|
    f.puts JSON.generate(method: req.request_method, uri: req.unparsed_uri, path: req.path,
                         auth: req['Authorization'].to_s, body: req.body.to_s)
  end
  res['Content-Type'] = 'application/vnd.api+json'
  uri = req.unparsed_uri
  if req.request_method == 'GET' && uri.start_with?('/api/v2/organizations/')
    if mode == 'ws500'
      res.status = 500
      res.body = '{"errors":[{"status":"500"}]}'
    else
      res.body = JSON.generate(data: { id: 'ws-abc123', type: 'workspaces' })
    end
  elsif req.request_method == 'GET' && req.path == '/api/v2/workspaces/ws-abc123/runs'
    target = case mode
             when 'discard' then run('run-new', 'cv-target', '2026-11-15T10:05:00.000Z', 'planned', false, true)
             when 'finished' then run('run-new', 'cv-target', '2026-11-15T10:05:00.000Z', 'applied', false, false)
             else run('run-new', 'cv-target', '2026-11-15T10:05:00.000Z', 'planning', true, false)
             end
    runs = [
      run('run-other', 'cv-other', '2026-11-15T10:09:00.000Z', 'planning', true, false),
      run('run-old', 'cv-target', '2026-11-15T10:01:00.000Z', 'planning', true, false),
      target
    ]
    runs = [runs[0]] if mode == 'nomatch'
    res.body = JSON.generate(data: runs)
  elsif req.request_method == 'GET' && req.path == '/api/v2/runs/run-given'
    res.body = JSON.generate(data: run('run-given', 'cv-target', '2026-11-15T10:05:00.000Z', 'applying', true, false))
  elsif req.request_method == 'POST' && req.path =~ %r{\A/api/v2/runs/run-[a-z]+/actions/(cancel|discard)\z}
    if mode == 'post500'
      res.status = 500
      res.body = '{"errors":[{"status":"500"}]}'
    elsif mode == 'post404'
      res.status = 404
      res.body = '{"errors":[{"status":"404","title":"not found"}]}'
    else
      res.status = 202
      res.body = ''
    end
  else
    res.status = 404
    res.body = '{"errors":[{"status":"404"}]}'
  end
end
servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
  define_method(:service) { |req, res| handler.call(req, res) }
end
server.mount('/', servlet)
File.write(File.join(dir, 'port'), server.config[:Port].to_s)
trap('TERM') { server.shutdown }
server.start
RUBY

echo cancel >"$work/mode"
ruby "$work/server.rb" "$work" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
port="$(cat "$work/port")"

token="tok-$RANDOM-not-a-real-secret-$RANDOM"

# run_case NAME MODE CV_ID [RUN_ID]: sets rc, out. Checks (g) every time.
run_case() {
  local name="$1" mode="$2" cv="$3" rid="${4:-}"
  echo "$mode" >"$work/mode"
  : >"$work/requests.jsonl"
  set +e
  env -i PATH="$PATH" HOME="$HOME" \
    TFE_TOKEN="$token" \
    TOKEN_VARIABLE="TF_API_TOKEN" \
    TFE_HOSTNAME="localhost:$port" \
    TFE_ORGANIZATION="my org" \
    TFE_WORKSPACE="ws-one" \
    CA_BUNDLE="$work/ca.pem" \
    CV_ID="$cv" \
    RUN_ID_IN="$rid" \
    BUILD_ID="4711" \
    bash "$script" >"$work/out" 2>"$work/err"
  rc=$?
  set -e
  out="$(cat "$work/out" "$work/err")"
  if grep -qF "$token" "$work/out" "$work/err"; then
    bad "$name (g): token appears in stdout or stderr"
  else
    pass "$name (g): token not in stdout or stderr"
  fi
  local n_req n_auth
  n_req="$(jq -s 'length' "$work/requests.jsonl")"
  n_auth="$(jq -s --arg a "Bearer $token" '[.[] | select(.auth == $a)] | length' "$work/requests.jsonl")"
  if [[ "$n_req" == "$n_auth" ]]; then
    pass "$name (g): every request ($n_req) carries the Authorization header"
  else
    bad "$name (g): $n_auth of $n_req requests carry the Authorization header"
  fi
}

posts() { jq -s -r '[.[] | select(.method == "POST") | .path] | join(" ")' "$work/requests.jsonl"; }
count() { jq -s --arg p "$1" '[.[] | select(.path | startswith($p))] | length' "$work/requests.jsonl"; }
nreq() { jq -s 'length' "$work/requests.jsonl"; }

# (a)
run_case a cancel cv-target
if [[ $rc -eq 0 && "$(posts)" == "/api/v2/runs/run-new/actions/cancel" ]]; then
  pass "a: the newest run on cv-target (run-new) is cancelled, exit 0"
else
  bad "a: rc=$rc posts='$(posts)' out: $out"
fi
body="$(jq -s -r '[.[] | select(.method == "POST")][0].body' "$work/requests.jsonl")"
if [[ "$(jq -r '.comment' <<<"$body" 2>/dev/null)" == "Azure DevOps job cancelled (build 4711)" ]]; then
  pass "a: the cancel comment names the build"
else
  bad "a: cancel body: $body"
fi
if jq -s -e '[.[] | select(.uri == "/api/v2/organizations/my%20org/workspaces/ws-one")] | length == 1' "$work/requests.jsonl" >/dev/null; then
  pass "a: the organization name is URL-encoded"
else
  bad "a: workspace request: $(jq -s -r '.[0].uri' "$work/requests.jsonl")"
fi
list_uri="$(jq -s -r '[.[] | select(.path == "/api/v2/workspaces/ws-abc123/runs")][0].uri' "$work/requests.jsonl")"
if [[ "$list_uri" == *"page%5Bsize%5D=20"* && "$list_uri" == *"filter%5Boperation%5D="*plan_only* ]]; then
  pass "a: the run list asks for 20 runs, plan_only included"
else
  bad "a: run list URI: $list_uri"
fi

# (b)
run_case b discard cv-target
if [[ $rc -eq 0 && "$(posts)" == "/api/v2/runs/run-new/actions/discard" ]]; then
  pass "b: a discardable run is discarded"
else
  bad "b: rc=$rc posts='$(posts)' out: $out"
fi

# (c)
run_case c finished cv-target
if [[ $rc -eq 0 && -z "$(posts)" && "$out" == *"run-new is applied: it has finished"* ]]; then
  pass "c: a finished run gets no POST, exit 0, logged"
else
  bad "c: rc=$rc posts='$(posts)' out: $out"
fi

# (d)
run_case d nomatch cv-target
if [[ $rc -eq 0 && -z "$(posts)" && "$out" == *"no TFE run to cancel"* ]]; then
  pass "d: no matching run: exit 0, 'no TFE run to cancel'"
else
  bad "d: rc=$rc posts='$(posts)' out: $out"
fi

# (e)
run_case e cancel cv-target run-given
if [[ $rc -eq 0 && "$(count /api/v2/organizations/)" == 0 && "$(count /api/v2/workspaces/)" == 0 &&
  "$(count /api/v2/runs/run-given)" == 2 && "$(posts)" == "/api/v2/runs/run-given/actions/cancel" ]]; then
  pass "e: runId given: no lookup, GET the run, POST cancel"
else
  bad "e: rc=$rc requests: $(jq -s -c '[.[] | .method + " " + .uri]' "$work/requests.jsonl") out: $out"
fi

# (f)
run_case f1 ws500 cv-target
if [[ $rc -eq 0 && -z "$(posts)" && "$out" == *"##vso[task.logissue type=warning]run-cancel:"*"HTTP 500"* ]]; then
  pass "f: the workspace GET returns 500: warning with HTTP 500, exit 0"
else
  bad "f1: rc=$rc out: $out"
fi
run_case f2 post500 cv-target
if [[ $rc -eq 0 && "$out" == *"##vso[task.logissue type=warning]run-cancel:"*"HTTP 500"* ]]; then
  pass "f: the cancel POST returns 500: warning with HTTP 500, exit 0"
else
  bad "f2: rc=$rc out: $out"
fi

run_case f3 post404 cv-target
if [[ $rc -eq 0 && "$out" == *"##vso[task.logissue type=warning]run-cancel:"*"HTTP 404"*"needs apply permission"* ]]; then
  pass "f: the cancel POST returns 404 (plan-only token): warning naming apply permission, exit 0"
else
  bad "f3: rc=$rc out: $out"
fi

# (h)
run_case h1 cancel 'cv-x/../../admin'
if [[ $rc -eq 0 && "$(nreq)" == 0 && "$out" == *"warning]run-cancel: configurationVersionId is not"* && "$out" != *"admin"* ]]; then
  pass "h: a bad configurationVersionId is rejected before any request, not echoed"
else
  bad "h1: rc=$rc requests=$(nreq) out: $out"
fi
run_case h2 cancel cv-target 'run-1;x'
if [[ $rc -eq 0 && "$(nreq)" == 0 && "$out" == *"warning]run-cancel: runId is not"* ]]; then
  pass "h: a bad runId is rejected before any request"
else
  bad "h2: rc=$rc requests=$(nreq) out: $out"
fi
# shellcheck disable=SC2016 # the literal macro text on purpose
run_case h3 cancel '$(upload.CONFIGURATION_VERSION_ID)'
if [[ $rc -eq 0 && "$(nreq)" == 0 && "$out" == *"no TFE run to cancel"* ]]; then
  pass "h: an unset configuration version (killed before upload finished): no request, 'no TFE run to cancel'"
else
  bad "h3: rc=$rc requests=$(nreq) out: $out"
fi

if [[ $fail -ne 0 ]]; then
  echo "FAIL run_cancel_test"
  exit 1
fi
echo "PASS run_cancel_test"
