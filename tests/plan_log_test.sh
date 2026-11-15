#!/bin/bash
# Behaviour test for templates/steps/plan-log.yml.
#
# Extracts the step's bash script with tests/extract_scripts.rb and runs it
# against a local fake TFE: Ruby WEBrick over HTTPS on localhost, with a test
# CA made here, so the caBundle (--cacert) path is exercised too. The fake
# records every request. It serves:
#   GET /api/v2/plans/plan-x       JSON with data.attributes.log-read-url
#   GET /_archivist/v1/object/...  the log in $work/serve.log, with ANSI
#                                  colour codes, logging commands in several
#                                  spellings and triple backticks
#   GET /_archivist/redirect-*     a 302 to the same host or to another host
# Cases:
#   ok    the log is printed inside ##[group]Terraform plan ... ##[endgroup],
#         ANSI codes are stripped, every "##" in the log is broken up
#         (##[error], ##VSO[, ## + soft hyphen + vso[, ##vso[, ###vso[), the
#         file holds the first maxLines lines plus a "trimmed" line, the API
#         call carries the bearer token and the log URL call carries none
#   full  maxLines above the log length: the file is the whole log, no trim line
#   bad   a bad planId fails before any request and does not echo the value
#   notok an empty token fails before any request
#   exp   the log URL returns 403 (expired): warning, succeeded with issues,
#         exit 0, no file
#   host  the log URL is on another host: system roots, TLS fails, warning,
#         exit 0
#   case  hostname in upper case still matches the log host: the CA is used
#   rdsame  the log URL redirects to the same host: followed once, with the CA
#   rdother the log URL redirects to another host: system roots, TLS fails
#   401   the API returns 401: warning, exit 0
#   404   the API returns 404: warning, exit 0, no log fetch
#   empty the log is empty: warning, exit 0, no file
#   large a 5,000-line log: the job log has all 5,000 lines, the file is trimmed
#   notrail a 301-line log with no newline at the end: trimmed at 300, and the
#         "trimmed" line counts 301
# The expected text is written out by hand, not made with the step's own sed.
# In every case: the token and the signed URL's signature never appear in
# stdout or stderr, and the only logging commands in stdout are the step's own.
#
# Usage: bash tests/plan_log_test.sh
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
ruby tests/extract_scripts.rb "$work/scripts" templates/steps/plan-log.yml >/dev/null
scripts=("$work"/scripts/*.sh)
if [[ ${#scripts[@]} -ne 1 ]]; then
  echo "FAIL expected one bash script in plan-log.yml, found ${#scripts[@]}"
  exit 1
fi
script="${scripts[0]}"

# 2. The plan log the fake serves: 16 lines, ANSI colours, logging commands in
# several spellings, triple backticks and a CRLF line ending.
esc=$'\033'
shy=$'\xc2\xad' # U+00AD soft hyphen, UTF-8
{
  printf '%s[0m%s[1mTerraform used the selected providers to generate the following execution plan.%s[0m\n' "$esc" "$esc" "$esc"
  printf '  %s[32m+%s[0m create\r\n' "$esc" "$esc"
  printf '\n'
  printf 'Terraform will perform the following actions:\n'
  printf '  # random_pet.name will be created\n'
  printf '  + resource "random_pet" "name" {\n'
  printf '      + id     = (known after apply)\n'
  printf '      + prefix = "##vso[task.setvariable variable=EVIL]pwned"\n'
  printf '      + note   = "```"\n'
  printf '##[error]x\n'
  printf '##VSO[task.setvariable variable=X]y\n'
  printf '##%svso[task.setvariable variable=Z]z\n' "$shy"
  printf '###vso[task.complete result=Failed]\n'
  printf '    }\n'
  printf '\n'
  printf '%s[1mPlan:%s[0m 1 to add, 0 to change, 0 to destroy.\n' "$esc" "$esc"
} >"$work/plan.log"
cp "$work/plan.log" "$work/serve.log"

# The same log as the step should print it, written out by hand.
expected="$work/expected.log"
{
  printf '%s\n' 'Terraform used the selected providers to generate the following execution plan.'
  printf '%s\n' '  + create'
  printf '\n'
  printf '%s\n' 'Terraform will perform the following actions:'
  printf '%s\n' '  # random_pet.name will be created'
  printf '%s\n' '  + resource "random_pet" "name" {'
  printf '%s\n' '      + id     = (known after apply)'
  printf '%s\n' '      + prefix = "# #vso[task.setvariable variable=EVIL]pwned"'
  printf '%s\n' '      + note   = "```"'
  printf '%s\n' '# #[error]x'
  printf '%s\n' '# #VSO[task.setvariable variable=X]y'
  printf '# #%svso[task.setvariable variable=Z]z\n' "$shy"
  printf '%s\n' '# # #vso[task.complete result=Failed]'
  printf '%s\n' '    }'
  printf '\n'
  printf '%s\n' 'Plan: 1 to add, 0 to change, 0 to destroy.'
} >"$expected"

# 3. Fake TFE over HTTPS with a test CA. MODE file: ok, expired, otherhost,
# unauthorized, notfound, rdsame, rdother.
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
ca.version = 2; ca.serial = 1; ca.subject = name('plan-log-test CA'); ca.issuer = ca.subject
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

server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, SSLEnable: true,
                                 SSLCertificate: cert, SSLPrivateKey: key,
                                 Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
port = server.config[:Port]
handler = lambda do |req, res|
  mode = File.read(File.join(dir, 'mode')).strip
  File.open(log, 'a') do |f|
    f.puts JSON.generate(method: req.request_method, path: req.path, auth: req['Authorization'].to_s)
  end
  if req.path == '/api/v2/plans/plan-x'
    if mode == 'unauthorized'
      res.status = 401
      res.body = '{"errors":[{"status":"401","title":"unauthorized"}]}'
      next res
    end
    if mode == 'notfound'
      res.status = 404
      res.body = '{"errors":[{"status":"404","title":"not found"}]}'
      next res
    end
    host = mode == 'otherhost' ? "127.0.0.1:#{port}" : "localhost:#{port}"
    path = mode.start_with?('rd') ? "/_archivist/redirect-#{mode}/signed-sig-0f9e8d7c" : '/_archivist/v1/object/signed-sig-0f9e8d7c'
    res['Content-Type'] = 'application/vnd.api+json'
    res.body = JSON.generate(data: { id: 'plan-x', type: 'plans', attributes: {
                               status: 'finished', 'log-read-url' => "https://#{host}#{path}" } })
  elsif req.path.start_with?('/_archivist/redirect-')
    to = mode == 'rdother' ? "127.0.0.1:#{port}" : "localhost:#{port}"
    res.status = 302
    res['Location'] = "https://#{to}/_archivist/v1/object/signed-sig-0f9e8d7c?moved=1"
  elsif req.path.start_with?('/_archivist/')
    if mode == 'expired'
      res.status = 403
      res.body = 'signature expired'
    else
      res['Content-Type'] = 'text/plain'
      res.body = File.binread(File.join(dir, 'serve.log'))
    end
  else
    res.status = 404
  end
end
servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
  define_method(:service) { |req, res| handler.call(req, res) }
end
server.mount('/', servlet)
File.write(File.join(dir, 'port'), port.to_s)
trap('TERM') { server.shutdown }
server.start
RUBY

echo ok >"$work/mode"
ruby "$work/server.rb" "$work" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
port="$(cat "$work/port")"

token="tok-$RANDOM-not-a-real-secret-$RANDOM"
out_file="$work/agent-temp/plan-log.txt"

# run_case NAME MODE [PLAN_ID] [MAX_LINES] [TOKEN] [HOSTNAME]: sets rc, out, err.
run_case() {
  local name="$1" mode="$2" plan_id="${3:-plan-x}" max_lines="${4:-5}" tok="${5-$token}"
  local host="${6:-localhost:$port}"
  echo "$mode" >"$work/mode"
  : >"$work/requests.jsonl"
  rm -f "$out_file"
  set +e
  env -i PATH="$PATH" HOME="$HOME" \
    TFE_TOKEN="$tok" \
    TOKEN_VARIABLE="TF_API_TOKEN" \
    TFE_HOSTNAME="$host" \
    CA_BUNDLE="$work/ca.pem" \
    PLAN_ID="$plan_id" \
    MAX_LINES="$max_lines" \
    OUTPUT_FILE="$out_file" \
    bash "$script" >"$work/out" 2>"$work/err"
  rc=$?
  set -e
  out="$(cat "$work/out")"
  err="$(cat "$work/err")"
  if grep -qF "$token" "$work/out" "$work/err"; then
    bad "$name: token appears in output"
  else
    pass "$name: token not in stdout or stderr"
  fi
  if grep -qF "signed-sig-0f9e8d7c" "$work/out" "$work/err"; then
    bad "$name: the signed log URL appears in output"
  fi
  # The only logging commands allowed in stdout are the step's own lines.
  local stray
  stray="$(grep -i -E '##(\[|vso)' "$work/out" |
    grep -v -x -E '##\[group\]Terraform plan|##\[endgroup\]|##vso\[task\.logissue type=(warning|error)\]plan-log: .*|##vso\[task\.complete result=SucceededWithIssues;\]plan log not shown' || true)"
  if [[ -n "$stray" ]]; then
    bad "$name: a logging command from the log text reached stdout: $stray"
  fi
}

# The lines between ##[group]Terraform plan and ##[endgroup] in stdout.
group_body() { sed -n '/^##\[group\]Terraform plan$/,/^##\[endgroup\]$/p' "$work/out" | sed '1d;$d'; }

count() { jq -s --arg p "$1" '[.[] | select(.path | startswith($p))] | length' "$work/requests.jsonl"; }
auth_of() { jq -s -r --arg p "$1" '[.[] | select(.path | startswith($p))][0].auth' "$work/requests.jsonl"; }

# (ok)
run_case ok ok plan-x 5
if [[ $rc -eq 0 && "$(count /api/v2/plans/plan-x)" == 1 && "$(count /_archivist/)" == 1 ]]; then
  pass "ok: one API call, one log fetch, exit 0"
else
  bad "ok: rc=$rc requests: $(cat "$work/requests.jsonl") stdout: $out stderr: $err"
fi
if [[ "$(auth_of /api/v2/plans/plan-x)" == "Bearer $token" ]]; then
  pass "ok: Authorization sent to the API"
else
  bad "ok: API Authorization header missing or wrong"
fi
if [[ "$(auth_of /_archivist/)" == "" ]]; then
  pass "ok: no Authorization sent to the log URL"
else
  bad "ok: Authorization was sent to the log URL"
fi
if diff <(group_body) "$expected" >/dev/null; then
  pass "ok: the whole stripped log is printed inside ##[group]Terraform plan ... ##[endgroup]"
else
  bad "ok: group block does not hold the whole log: $(diff <(group_body) "$expected")"
fi
if grep -q "$esc" "$work/out"; then
  bad "ok: ANSI escape left in stdout"
else
  pass "ok: ANSI codes stripped"
fi
if group_body | grep -q '##'; then
  bad "ok: a '##' from the log text reached stdout: $(group_body | grep '##')"
else
  pass "ok: no '##' left in the printed log (##[error], ##VSO[, ## + soft hyphen, ##vso[, ###vso[)"
fi
if grep -qF '##vso[task.setvariable variable=EVIL' "$work/out"; then
  bad "ok: a logging command from the log reached stdout"
else
  pass "ok: logging commands in the log are broken up"
fi
if [[ -f "$out_file" && "$(wc -l <"$out_file" | tr -d ' ')" == 6 ]] &&
  diff <(head -n 5 "$out_file") <(head -n 5 "$expected") >/dev/null &&
  [[ "$(tail -n 1 "$out_file")" == *"trimmed: first 5 of 16 lines"* ]]; then
  pass "ok: trimmed copy holds the first maxLines lines and a trimmed line"
else
  bad "ok: trimmed copy: $(cat "$out_file" 2>/dev/null || echo missing)"
fi

# (full)
run_case full ok plan-x 300
if [[ $rc -eq 0 ]] && diff "$out_file" "$expected" >/dev/null; then
  pass "full: maxLines above the length writes the whole log, no trimmed line"
else
  bad "full: rc=$rc diff: $(diff "$out_file" "$expected" 2>&1)"
fi
if grep -i -q -E '##(\[|vso)' "$out_file" || grep -q '##' "$out_file"; then
  bad "full: a '##' from the log text is in the output file"
else
  pass "full: no '##' in the output file"
fi

# (bad)
run_case bad ok 'plan-x;id' 5
if [[ $rc -ne 0 && "$out" == *"is not a plan ID"* && "$out" != *"plan-x;id"* && "$(count /)" == 0 ]]; then
  pass "bad: a bad planId fails before any request, without echoing the value"
else
  bad "bad: rc=$rc stdout: $out requests: $(cat "$work/requests.jsonl")"
fi

# (notok)
run_case notok ok plan-x 5 ''
if [[ $rc -ne 0 && "$out" == *"TF_API_TOKEN"*"empty or not defined"* && "$(count /)" == 0 ]]; then
  pass "notok: an empty token fails before any request"
else
  bad "notok: rc=$rc stdout: $out"
fi

# (exp)
run_case exp expired plan-x 5
if [[ $rc -eq 0 && "$out" == *"task.logissue type=warning"*"expired"* && "$out" == *"result=SucceededWithIssues"* && ! -e "$out_file" ]]; then
  pass "exp: expired log URL warns, succeeds with issues, writes no file"
else
  bad "exp: rc=$rc stdout: $out"
fi

# (host)
run_case host otherhost plan-x 5
if [[ $rc -eq 0 && "$out" == *"another host"* && "$out" == *"result=SucceededWithIssues"* && "$(count /_archivist/)" == 0 ]]; then
  pass "host: log on another host uses the system roots (test CA not trusted there), warns, exit 0"
else
  bad "host: rc=$rc stdout: $out requests: $(cat "$work/requests.jsonl")"
fi

# (case) Upper-case hostname: still the same host, so the CA is used.
run_case case ok plan-x 300 "$token" "LOCALHOST:$port"
if [[ $rc -eq 0 && "$out" != *"another host"* && "$(count /_archivist/)" == 1 ]] && diff "$out_file" "$expected" >/dev/null; then
  pass "case: hostname compared in lower case, the CA is used for the log host"
else
  bad "case: rc=$rc stdout: $out"
fi

# (rdsame) Redirect to the same host: followed once, with the CA.
run_case rdsame rdsame plan-x 300
if [[ $rc -eq 0 && "$out" == *"redirected (HTTP 302)"* && "$(count /_archivist/v1/)" == 1 ]] && diff "$out_file" "$expected" >/dev/null; then
  pass "rdsame: a same-host redirect is followed once with the CA"
else
  bad "rdsame: rc=$rc stdout: $out requests: $(cat "$work/requests.jsonl")"
fi

# (rdother) Redirect to another host: the CA is not used there, TLS fails.
run_case rdother rdother plan-x 300
if [[ $rc -eq 0 && "$out" == *"redirected (HTTP 302)"* && "$out" == *"another host"* && "$out" == *"result=SucceededWithIssues"* &&
  "$(count /_archivist/v1/)" == 0 && ! -e "$out_file" ]]; then
  pass "rdother: a redirect to another host uses the system roots (test CA not trusted there), warns, exit 0"
else
  bad "rdother: rc=$rc stdout: $out requests: $(cat "$work/requests.jsonl")"
fi

# (401)
run_case 401 unauthorized plan-x 5
if [[ $rc -eq 0 && "$out" == *"HTTP 401"* && "$out" == *"result=SucceededWithIssues"* && "$(count /_archivist/)" == 0 ]]; then
  pass "401: API 401 warns and exits 0 without fetching a log"
else
  bad "401: rc=$rc stdout: $out"
fi

# (404) The plan does not exist.
run_case 404 notfound plan-x 5
if [[ $rc -eq 0 && "$out" == *"HTTP 404"* && "$out" == *"result=SucceededWithIssues"* && "$(count /_archivist/)" == 0 && ! -e "$out_file" ]]; then
  pass "404: API 404 warns and exits 0 without fetching a log"
else
  bad "404: rc=$rc stdout: $out"
fi

# (json) TFE's real format: structured JSON events, one per line, after a
# plain header. Each event prints as its readable @message.
{
  printf 'Terraform v1.17.0\non linux_amd64\n'
  printf '%s\n' '{"@level":"info","@message":"random_string.test: Plan to replace","type":"planned_change"}'
  printf '%s\n' '{"@level":"info","@message":"Plan: 2 to add, 0 to change, 2 to destroy.","type":"change_summary"}'
  printf '%s\n' '{"@level":"info","@message":"##vso[task.setvariable variable=X]y","type":"log"}'
  printf '%s\n' '{"no_message":true}'
  printf '%s\n' '{"@message":null}'
} >"$work/serve.log"
run_case json ok plan-x 300
expected_json=$'Terraform v1.17.0\non linux_amd64\nrandom_string.test: Plan to replace\nPlan: 2 to add, 0 to change, 2 to destroy.\n# #vso[task.setvariable variable=X]y\n{"no_message":true}\n{"@message":null}'
if [[ $rc -eq 0 && "$(group_body)" == "$expected_json" ]]; then
  pass "json: JSON events print as their @message, other lines as they are, ## broken up"
else
  bad "json: rc=$rc body: $(group_body)"
fi

# (empty) An empty log.
: >"$work/serve.log"
run_case empty ok plan-x 5
if [[ $rc -eq 0 && "$out" == *"is empty"* && "$out" == *"result=SucceededWithIssues"* && ! -e "$out_file" ]]; then
  pass "empty: an empty log warns, exits 0, writes no file"
else
  bad "empty: rc=$rc stdout: $out"
fi

# (large) 5,000 lines: the job log is complete, the file is trimmed.
for i in $(seq 1 5000); do printf '  + line %04d\n' "$i"; done >"$work/serve.log"
run_case large ok plan-x 300
if [[ $rc -eq 0 ]] && diff <(group_body) "$work/serve.log" >/dev/null; then
  pass "large: all 5,000 lines are in the job log"
else
  bad "large: rc=$rc job log has $(group_body | wc -l | tr -d ' ') lines"
fi
if [[ "$(wc -l <"$out_file" | tr -d ' ')" == 301 && "$(tail -n 1 "$out_file")" == *"trimmed: first 300 of 5000 lines"* ]] &&
  diff <(head -n 300 "$out_file") <(head -n 300 "$work/serve.log") >/dev/null; then
  pass "large: the file holds 300 lines and a trimmed line"
else
  bad "large: file has $(wc -l <"$out_file" | tr -d ' ') lines, last: $(tail -n 1 "$out_file")"
fi

# (notrail) 301 lines, no newline at the end.
{
  for i in $(seq 1 300); do printf 'line %03d\n' "$i"; done
  printf 'line 301'
} >"$work/serve.log"
run_case notrail ok plan-x 300
if [[ $rc -eq 0 && "$(wc -l <"$out_file" | tr -d ' ')" == 301 && "$(tail -n 1 "$out_file")" == *"trimmed: first 300 of 301 lines"* &&
  "$(sed -n 300p "$out_file")" == "line 300" ]]; then
  pass "notrail: a 301-line log with no final newline is trimmed at 300, with a trimmed line"
else
  bad "notrail: rc=$rc file: $(tail -n 3 "$out_file" 2>/dev/null)"
fi
if [[ "$(group_body | tail -n 1)" == "line 301" && "$(group_body | wc -l | tr -d ' ')" == 301 ]]; then
  pass "notrail: the job log ends with line 301, ##[endgroup] on its own line"
else
  bad "notrail: job log tail: $(group_body | tail -n 2)"
fi

if [[ $fail -ne 0 ]]; then
  echo "FAIL plan_log_test"
  exit 1
fi
echo "PASS plan_log_test"
