# tfc-workflow-azdo v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Azure DevOps templates so PR and main pipelines drive HCP Terraform or Terraform Enterprise correctly through tfci, with TFE, private CA, internal image and split-token support, proven end to end against the lab TFE.

**Architecture:** One `tfci` step wrapper owns image, hostname, CA, token and mode (docker or native). Small step templates chain configuration version, run ID and plan output through `--json` and output variables. Two extends templates (PR, main) compose them. Local static tests guard every defect class from the 2026-11-15 review.

**Tech Stack:** Azure Pipelines YAML, bash, jq, curl, tfci v1.4.0, Terraform 1.17, tflint, Python 3 (PyYAML) for tests, shellcheck, Kubernetes manifests for the lab agent.

**Spec:** `docs/superpowers/specs/2026-11-15-modernise-design.md`

## Global Constraints

- tfci default image `hashicorp/tfci:v1.4.0`; image is always a parameter, never `:latest`.
- Only these tfci commands: `upload`, `run create|apply|show|discard|cancel`, `plan output`, `workspace output list`. Global flags (`--hostname`, `--organization`, `--token`) go before the command; `--json` is a per-command flag and goes after it (`tfci run create --json ...`). Verified in tfci v1.4.0 `cli.go` and `internal/command/meta.go:70`.
- Every bash script starts with `set -euo pipefail`.
- Secrets only via `env:`; `docker run -e NAME` with the name only. No `$(SECRET)` in a script body, no `set -x`.
- User-controlled values (branch, PR title, requester) only via `env:` and quoted shell variables.
- Commit identity is the repo's (`glimpsovstar@gmail.com`). No AI attribution. Never push.
- No em dashes in docs or commit messages. Mermaid for diagrams.

## Review Focus

1. Run with policy checks or cost estimation ends `policy_checked` or `cost_estimated`, not `planned`: the main pipeline must still reach the approval and apply.
2. Plan with no changes (`planned_and_finished`): apply stage must succeed as a no-op, not fail and not hang.
3. Two PRs at once: each PR comment must show its own run, because each run is pinned to its own configuration version.
4. PR updated several times: the pipeline updates its own PR thread instead of adding a new one each push.
5. Private CA missing or wrong: tfci must fail with a TLS error, never fall back to skipping verification.

Each is pinned by a test or an end-to-end check in the task that owns it.

---

### Task 1: Clean up and test harness (tests fail on the old templates)

**Files:**
- Delete: `update-best-practices.sh`
- Move: `terraform/` to `tests/fixtures/random/` (drop `timestamp()` from tags, fix `.tflint.hcl`, `required_version >= 1.6`, commit `.terraform.lock.hcl`)
- Modify: `.gitignore` (stop ignoring the lock file; add `.terraformrc`, `terraform.rc`, `credentials.tfrc.json`, `.env`, `*.tfplan`)
- Create: `tests/check_templates.rb`, `tests/tfci-v1.4.0-commands.txt`, `tests/run.sh`, `progress.md`

**Interfaces:**
- Produces: `tests/run.sh` exits 0 only when every check passes; `check_templates.rb <dir>` prints `file:line rule message` per violation.

- [x] Write `check_templates.rb` rules: yaml-parse, param-crosscheck, no-macro-in-bool-param, no-template-if-in-script, no-parent-template-path, no-latest-image, no-secret-macro-in-script, strict-bash, tfci-command-exists (reads the manifest), no-user-macro-in-script (`System.PullRequest.*`, `Build.SourceBranch*`, `Build.RequestedFor`).
- [x] Generate `tfci-v1.4.0-commands.txt` and `tfci-v1.5.0-commands.txt` from tfci source at both tags (`cli.go` commands, each command's `f.*Var` flags, plus global `--json --hostname --organization --token`). Record the source URL and tag at the top. A test asserts the two manifests list the same commands and flags (verified 2026-11-15: v1.5.0 changes only Go and dependencies), so moving the default image to v1.5.0 is a one-line change.
- [x] Run against the current `tasks/` and `pipeline-templates/`: expect failures for `--format=json`, `workspace list`, `:latest`, `$(TF_API_TOKEN)` in scripts, `${{ if` in scripts, missing `set -euo pipefail`. Save the output in the commit message body.
- [x] `tests/run.sh`: python check, shellcheck on extracted scripts, `terraform fmt -check`, `validate`, `tflint` on the fixture.
- [x] Commit: `Test harness that catches the review's defect classes; clean up generator script and sample`.

### Task 2: tfci step wrapper and run steps

**Files:** Create `templates/steps/{tfci,upload,run-create,run-apply,plan-output}.yml`. Delete `tasks/`.

**Interfaces:**
- `tfci.yml` parameters: `command` (string), `args` (string), `name` (step name), `displayName`, `mode` (docker|native, default docker), `image` (default `hashicorp/tfci:v1.4.0`), `hostname` (default `app.terraform.io`), `organization`, `caBundle` (path, optional), `workingDirectory`, `tokenVariable` (default `TF_API_TOKEN`), `outputFile` (where JSON stdout is written).
- `upload.yml`: params `directory`, `workspace`, `speculative` (bool) + wrapper params. Output `upload.CONFIGURATION_VERSION_ID`.
- `run-create.yml`: params `workspace`, `configurationVersionId`, `planOnly` (bool), `message`. Outputs `run.RUN_ID`, `run.RUN_STATUS`, `run.PLAN_ID`, `run.PLAN_STATUS`, `run.RUN_LINK`. Fails when `RUN_ID` is empty.
- `run-apply.yml`: params `runId`, `comment`. Fails on non-zero tfci exit.
- `plan-output.yml`: params `planId`. Writes `$(Agent.TempDirectory)/plan-summary.md` and outputs `ADD`, `CHANGE`, `DESTROY`.

- [x] Tests first: add fixture YAML under `tests/cases/` that misuse each step (missing configurationVersionId, wrong flag) and assert the checker flags them.
- [x] Implement. Docker mode mounts the working directory to `/tfci/workspace` and the CA to `/etc/ssl/certs/tfe-ca.pem` with `SSL_CERT_FILE` set. Native mode sets `SSL_CERT_FILE` to `caBundle`.
- [x] `tests/run.sh` passes.
- [x] Commit.

### Task 3: PR comment step

**Files:** Create `templates/steps/pr-comment.yml`.

**Interfaces:** params `summaryFile`, `runLink`, `runStatus`, `statusContext` (default `terraform/tfe-plan`). Uses `System.AccessToken`, `System.CollectionUri`, `System.TeamProject`, `Build.Repository.ID`, `System.PullRequest.PullRequestId` through `env:` only.

- [x] Test first: checker case that puts `$(System.PullRequest.PullRequestId)` in the script body must fail.
- [x] Implement: find an existing thread carrying the marker `<!-- tfc-workflow-azdo:<workspace> -->` and update it, else create one (Review Focus 4). Post a PR status `succeeded` or `failed` from `runStatus`. API version 7.1.
- [x] `tests/run.sh` passes. Commit.

### Task 4: Validate step

**Files:** Create `templates/steps/validate.yml`.

**Interfaces:** params `directory`, `terraformImage` (default `hashicorp/terraform:1.17.0`), `tflintImage` (pinned tag), `enableTflint` (bool). No backend init (`terraform init -backend=false`).

- [x] Test first, implement, `tests/run.sh` passes, commit.

### Task 5: Pipelines and examples

**Files:** Create `templates/pipelines/{speculative-run,apply-run}.yml`, `examples/azure-pipelines.{pr,main}.yml`, `examples/smoke-test.yml`. Delete `pipeline-templates/`, old `examples/*.yml`.

**Interfaces:**
- Both pipelines take: `workspace`, `organization`, `hostname`, `directory`, `pool`, `mode`, `image`, `caBundle`, `variableGroup`.
- `speculative-run.yml`: validate, upload (speculative), run-create (planOnly), plan-output, pr-comment.
- `apply-run.yml`: stage Plan (upload, run-create, plan-output); stage Apply as a `deployment` job on `environment`, condition on Plan success and `RUN_STATUS` in `planned, cost_estimated, policy_checked, policy_override` (Review Focus 1); `planned_and_finished` skips apply with a message, stage succeeds (Review Focus 2).

- [x] Tests first (cross-check cases), implement, `tests/run.sh` passes, commit.

### Task 6: Docs and changelog

**Files:** Rewrite `README.md`, `docs/{setup,tfe-private-network,internal-registry,security,reference,troubleshooting}.md`; delete `docs/migration-guide.md`, old `docs/README.md`, `examples/README.md`; create `CHANGELOG.md` (v2.0.0).

- [x] Every parameter in `reference.md` generated from or checked against the templates by `check_templates.rb --docs`.
- [x] Setup covers: branch-policy build validation, two variable groups with permissions and branch control, team tokens, build service "Contribute to pull requests", environment approval, workspace auto-apply off.
- [x] Commit.

### Task 7: Lab agent on AKS

**Files:** Create `lab/azdo-agent/{namespace,configmap-start,deployment,README}.yaml|md`.

- [x] Deployment: init container `hashicorp/tfci:v1.4.0` copies `/usr/local/bin/tfci` to an emptyDir; agent container (pinned Ubuntu image) runs Microsoft's documented `start.sh`; secret `azdo-agent` (URL, pool, PAT) created by David; lab CA from a ConfigMap; no privileged mode, non-root where the agent allows.
- [x] `kubectl apply --dry-run=server` passes. Commit.

### Task 8: End to end in the lab (with David)

- [x] David: Azure DevOps org/project, agent pool `lab-aks`, PAT secret, repos (template repo and a consumer repo with the fixture), variable groups and their secrets, environment `lab-prod` with approval.
- [x] Apply the agent, confirm it is online.
- [x] PR: speculative run on the PR's own configuration version, thread and status posted. Two PRs at once (Review Focus 3). Push twice to one PR (Review Focus 4).
- [x] Merge: plan, approval, apply. A no-change merge (Review Focus 2).
- [x] Wrong CA bundle: TLS failure (Review Focus 5).
- [x] Record evidence in `docs/PROOF.md` (run IDs and statuses only, no secrets, no tenant IDs). Commit.

### Task 9: Whole-branch review

- [x] Fresh reviewer (2026-11-15: 13 findings; fixes in progress) over the branch: correctness, security, docs vs code. Fix, re-run `tests/run.sh`, commit. Update `progress.md`.

## Status (2026-11-15)

- [x] Task 1 to 7 done. - [x] Task 8 end to end (2026-11-15, docs/PROOF.md). - [x] Task 9 fixes and re-review.
- Deviation: Tasks 2, 3, 4 and 7 ran in parallel in one working tree on disjoint files, committed by path, not in separate worktrees.

## Parallelism

After Task 1: Tasks 2, 3, 4 and 7 touch separate files and run as parallel subagents in separate worktrees; only the main session merges and commits. Task 5 needs 2 to 4. Task 6 needs 5. Task 8 needs 5 and 7.

---

### Task 10: Apply method `tfe` (the approver confirms in TFE)

The customer design wants prod applies confirmed by a person in TFE. The prod pipeline then holds only a plan-permission token, so a leaked pipeline token cannot apply prod, and the approver sees the real plan and policy results in TFE. `pipeline` (Azure DevOps approval, then a pipeline apply) stays the default.

**Files:** Modify `templates/pipelines/apply-run.yml`, `tests/status_sets_test.rb`, `tests/output_refs_test.rb`, `tests/alias_test.sh`, `tests/gen_reference.rb`, `docs/{setup,security,troubleshooting,reference}.md`, `README.md`, `CHANGELOG.md`. Create `tests/render.rb`, `tests/apply_method_test.rb`, `examples/azure-pipelines.main-prod.yml`.

**Interfaces:**
- `apply-run.yml`: new parameter `applyMethod` (`pipeline` default, or `tfe`). `environment` defaults to `''`; a check step fails the Plan job before upload when `applyMethod: pipeline` and `environment` is empty.
- `tfe` mode: Plan stage only, `planVariableGroup` only, run-create gets `savePlan: false` (a confirmable run), the gate logs "Confirm and apply run <id> in TFE: <link>. The pipeline does not apply in this mode." The Apply stage, `environment` and `applyVariableGroup` are left out at compile time.

- [x] Tests first: `apply_method_test.rb` renders apply-run.yml for both modes and asserts the stages, groups, savePlan and the environment check; `output_refs_test.rb` checks references in both renderings; `status_sets_test.rb` finds the Apply stage inside `${{ if }}`; alias test for `examples/azure-pipelines.main-prod.yml` (no environment, no apply group).
- [x] Implement `applyMethod` in `apply-run.yml`; gate messages per mode.
- [x] Decide on `waitForTfeApply` (optional): skipped (2026-11-15). tfci.yml is one tfci call per step by design, so a poll loop would duplicate its token, CA and mode handling; and a job polling for a human confirmation would hold a self-hosted agent for hours. The pipeline result is the plan's result; documented in setup.md step 11.
- [x] Docs: setup "Production: confirm in TFE", security, troubleshooting, README, CHANGELOG, `reference.md` regenerated.
- [x] `bash tests/run.sh` passes.

### Task 11: Show the Terraform plan text in Azure DevOps

tfci with `--json` sends plan logs to its internal logger, off by default, so the pipeline shows only counts and a link.

**Files:** Create `templates/steps/plan-log.yml`, `tests/plan_log_test.sh`. Modify `templates/steps/pr-comment.yml`, both pipelines, `tests/pr_comment_test.sh`, `tests/run.sh`, `tests/gen_reference.rb`, docs.

**Interfaces:**
- `plan-log.yml` parameters: `planId`, `hostname`, `caBundle`, `tokenVariable`, `maxLines` (number, 300), `outputFile` (`$(Agent.TempDirectory)/plan-log.txt`), `condition`, `displayName`. GET `/api/v2/plans/<id>` with the token (`curl -K -`, header on stdin), then fetch `data.attributes.log-read-url` without the Authorization header, strip ANSI, neutralise logging commands, print the full log in `##[group]Terraform plan`, write a trimmed copy to `outputFile`.
- `pr-comment.yml`: `planLogFile` (default `$(Agent.TempDirectory)/plan-log.txt`), `includePlanLog` (true). Appends the log in `<details><summary>Terraform plan</summary>` and a `text` fence, capped at 100,000 characters, triple backticks replaced.
- Pipelines: parameter `showPlanLog` (true); plan-log after plan-output with `condition: and(succeededOrFailed(), ne(variables['run.PLAN_ID'], ''))`.

- [x] Tests first: `plan_log_test.sh` with a fake TFE over HTTPS (WEBrick, test CA): group, ANSI stripped, trimming, Authorization to the API only, token never in output, bad planId fails. Extend `pr_comment_test.sh`: log included, collapsed, capped, backticks neutralised. Wire into `run.sh`.
- [x] Implement `plan-log.yml`, `pr-comment.yml` changes, wire into both pipelines.
- [x] Docs: security (what the log exposes, how to turn it off), troubleshooting (empty log, expired URL), `reference.md` regenerated, README, CHANGELOG.
- [x] `bash tests/run.sh` passes.

### Task 12: Cancel the TFE run when the Azure DevOps job is cancelled

When a job is cancelled (by a user or a job timeout), the TFE run it started keeps going. The step running `tfci run create` is killed before tfci prints its JSON, so `run.RUN_ID` is never set.

**Files:** Create `templates/steps/run-cancel.yml`, `tests/run_cancel_test.sh`. Modify both pipelines, `tests/run.sh`, `tests/apply_method_test.rb`, `tests/gen_reference.rb`, `docs/{troubleshooting,security,reference}.md`, `README.md`, `CHANGELOG.md`.

**Interfaces:**
- `run-cancel.yml` parameters: `hostname` (required), `organization`, `workspace`, `caBundle`, `tokenVariable`, `configurationVersionId`, `runId` (optional), `condition` (default `canceled()`), `displayName`. With a valid `runId` it acts on that run; otherwise it finds the newest run in the workspace on `configurationVersionId`. It cancels when `attributes.actions.is-cancelable`, discards when `is-discardable`, and otherwise logs that the run has finished. curl `-K -` with the header on stdin, `--max-time 20` per call, `--cacert` when `caBundle` is set. API errors log a warning with the HTTP status and exit 0.
- Pipelines: `run-cancel` after `run-create` in `speculative-run.yml` and in the `apply-run.yml` Plan stage (`configurationVersionId: $(upload.CONFIGURATION_VERSION_ID)`), and after `run-apply` in the Apply stage (`runId: $(RUN_ID)`). Every job that holds a cancel step sets `cancelTimeoutInMinutes: 5`.

- [x] Tests first: `run_cancel_test.sh` with a fake TFE (WEBrick over HTTPS, test CA): lookup by configuration version, cancel, discard, finished, no run, `runId` given, API 500, token never printed and Authorization sent, bad IDs rejected before any request. Wiring checks in `apply_method_test.rb`. Wire into `run.sh`.
- [x] Implement `run-cancel.yml` and wire it into both pipelines.
- [x] Docs: troubleshooting "Job cancelled: what happens to the TFE run", security, README, CHANGELOG v2.0.1, `reference.md` regenerated.
- [x] `bash tests/run.sh` passes.
