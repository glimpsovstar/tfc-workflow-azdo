# Changelog

## v2.0.1 (2026-11-15)

### Added

- `templates/steps/run-cancel.yml`: when an Azure DevOps job is cancelled (by a person or the job timeout), cancels the TFE run it started if the run is planning or applying, or discards it if it waits for a person. It finds the run by the build's configuration version, or uses `runId` when known. API errors are warnings; the step never fails the job.
- Both pipelines run it after `run-create` in the plan jobs, and `apply-run.yml` runs it after `run-apply` in the Apply job (on `$(RUN_ID)`). Those jobs set `cancelTimeoutInMinutes: 5`.
- Tests: `tests/run_cancel_test.sh` (fake TFE over HTTPS), and wiring checks in `tests/apply_method_test.rb`.
- Lab-tested (`docs/PROOF.md` rows 14 and 16): a real Azure DevOps cancel fires the step and it finds the run; a plan-permission token is refused cancel and discard (HTTP 404), so in Plan jobs the step logs which runs are harmless and which to discard in TFE; an apply-permission token cancels and discards (HTTP 202).

### Fixed

- A cancelled job no longer leaves its TFE run going without a word. In a Plan job the step uses the plan token, and TFE needs apply permission to cancel or discard, so there it may log a warning and leave the run for a person ([docs/troubleshooting.md](docs/troubleshooting.md#job-cancelled-what-happens-to-the-tfe-run)).

## v2.0.0 (2026-11-15)

A rebuild after a full review on 2026-11-15. v1 pipelines do not carry over: consumers move to the `extends` templates. See [README.md](README.md#quick-start).

### Added

- `templates/pipelines/speculative-run.yml`: PR pipeline. Validates in a job with no secrets, uploads the PR's code as a speculative configuration version, creates a plan-only run on it, writes a plan summary and posts it to the PR.
- `templates/pipelines/apply-run.yml`: main pipeline. Plan stage, then an Apply deployment job on an Azure DevOps environment that applies the same run after approval.
- `templates/steps/tfci.yml`: one wrapper for every tfci call, with `docker` and `native` modes.
- Step templates `upload.yml`, `run-create.yml`, `plan-output.yml`, `run-apply.yml`, `pr-comment.yml` and `validate.yml`, chained by configuration version ID and run ID.
- TFE support: `hostname`, `caBundle` (private CA through `SSL_CERT_DIR`) and `image` parameters; `validateCaBundle` and `cliConfigFile` for `terraform init` against a private provider mirror.
- PR feedback from the pipeline: a PR thread updated in place and a PR status, through the Azure DevOps REST API.
- Examples pinned by tag (`examples/azure-pipelines.pr.yml`, `examples/azure-pipelines.main.yml`) and a smoke test (`examples/smoke-test.yml`).
- Lab agent as a Kubernetes pod in native mode (`lab/azdo-agent/`).
- `apply-run.yml` creates the main-branch run as a saved plan (`savePlan`, default `true`; `run-create.yml` takes `savePlan`, default `false`). A rejected or expired approval leaves a saved plan that does not block the workspace. The Apply stage sets `lockBehavior: sequential`.
- `jobTimeoutInMinutes` (default 90) on both pipeline templates, set as `timeoutInMinutes` on every job.
- `logLevel` on every tfci template, set as `TF_LOG` for tfci.
- The gate warns when a run waits in `policy_override`; `run-apply.yml` explains a run that cannot be applied.
- `pr-comment.yml` skips the comment and the status when a newer push exists on the PR, and names the short commit in both.
- `apply-run.yml` parameter `applyMethod`: `pipeline` (default, an Azure DevOps approval then a pipeline apply) or `tfe` (a person confirms and applies the run in TFE). In `tfe` mode the run is confirmable (`savePlan` forced off), there is no Apply stage, and the pipeline holds only the plan token. `environment` now defaults to `''`; with `applyMethod: pipeline` a check step fails the Plan job before upload when it is empty. Example: `examples/azure-pipelines.main-prod.yml`.
- `templates/steps/plan-log.yml`: prints the Terraform plan text (from the plan's `log-read-url`) in a collapsed log group, ANSI and logging commands stripped, and writes a trimmed copy (`maxLines`, default 300). Both pipelines run it after the plan summary, controlled by `showPlanLog` (default `true` on `apply-run.yml`, `false` on `speculative-run.yml`).
- `pr-comment.yml` parameters `planLogFile` and `includePlanLog`: the PR thread carries the trimmed plan in a collapsed block, capped at 100,000 characters. With `includePlanLog` on and no plan log file, the comment says the plan text is not available and links the run.
- Tests: `tests/plan_log_test.sh` (fake TFE over HTTPS), `tests/apply_method_test.rb` and `tests/render.rb` (both apply methods rendered), plan log cases in `tests/pr_comment_test.sh`.
- Tests: canonical run status sets (`tests/status_sets_test.rb`), output variable references (`tests/output_refs_test.rb`) and the step scripts against a fake tfci (`tests/steps_fake_tfci_test.sh`).
- Docs: Required template checks on the variable groups and the PR agent pool.
- Local tests, run with `bash tests/run.sh`: template checker and its self-tests, tfci command manifests for v1.4.0 and v1.5.0, shellcheck on every template script, a fake Azure DevOps API test for the PR comment, Terraform checks on the fixture, and a check that `docs/reference.md` matches the templates.
- Docs: setup, private TFE, internal registry, security, a generated reference, troubleshooting.

### Changed

- `hostname` is required on every template that calls tfci; there is no `app.terraform.io` default.
- Native mode runs tfci under `env -i` with an allowlist, so no `TF_VAR_*` from the agent or pipeline reaches a run.
- PR status: `planned_and_finished` and `post_plan_completed` succeed; `policy_soft_failed` fails with "soft-mandatory policy failed: override in TFE".
- `apply-run.yml` in `pipeline` mode: a missing `environment` now fails at runtime, in the `config_check` step of the Plan job before any upload, instead of at compile time.
- The plan text is printed in the main pipeline's job log by default (`showPlanLog: true` on `apply-run.yml`).
- A failed plan log fetch ends the `Terraform plan log` step as "succeeded with issues", so the build shows "partially succeeded"; the Apply stage still runs.
- The PR default for `showPlanLog` is off (`speculative-run.yml`): on a PR the plan text would let a PR author print values the workspace can read.

- Consumers `extends` the templates from a repository resource pinned to a tag, instead of copying pipeline files.
- Images are pinned and are parameters: `hashicorp/tfci:v1.4.0`, `hashicorp/terraform:1.17.0`, `ghcr.io/terraform-linters/tflint:v0.66.0`.
- Two variable groups, `tfc-plan` and `tfc-apply`, replace the single `terraform-variables` group.
- Every bash script runs with `set -euo pipefail`.
- The sample Terraform configuration moved from `terraform/` to `tests/fixtures/random`, with its `.terraform.lock.hcl` committed.

### Fixed

- `run create` now gets `--configuration_version`, so a PR plan runs the PR's code, not the workspace's latest.
- Only real tfci v1.4.0 commands and flags are used (no `--format=json`, `.data.attributes.status` or `workspace list`); `--json` goes after the command. A test checks them against the manifest.
- Run IDs come from `--json` output through `jq`, not a regex that never matched. `set +e` no longer hides failures.
- Poll loops removed: `tfci run create` and `tfci run apply` already wait for a terminal state, bounded by `TF_MAX_TIMEOUT`.
- No `${{ if }}` inside script strings, and no runtime macros passed into boolean template parameters.
- The Terraform image is no longer given an extra `terraform` argument.
- An errored, canceled or discarded run fails the pipeline. A run with no changes skips the Apply stage and the pipeline succeeds.
- The main pipeline fails if the workspace applied the run before the approval (Auto apply on).
- Docs describe only what the code does.

### Removed

- `pipeline-templates/` and `tasks/` (v1).
- `examples/README.md`, `examples/connectivity-test.yml` and `examples/simple-test.yml`. `examples/smoke-test.yml` replaces the test pipelines.
- `update-best-practices.sh`, which overwrote templates when run.
- `docs/migration-guide.md`, `docs/README.md` and `docs/setup-guide.md`, replaced by the new docs.
- The Docker Hub service connection requirement.

### Security

- tflint no longer trusts the repository's `.tflint.hcl` by default: with `tflintPluginInit: false` (the default) it lints with a pipeline-owned config holding only the bundled terraform ruleset, so a PR cannot make tflint download or run a plugin (including through `plugin_dir`). `GITHUB_TOKEN` is never passed to tflint. Set `tflintPluginInit: true` only for trusted code.
- Plan and apply use separate team tokens. The apply token's variable group is limited to the main pipeline, with an approval and a branch control check on `refs/heads/main`.
- PR validation runs in a job with no variable group, so untrusted PR code never shares a job with a token.
- Secrets reach scripts only through `env:`. Docker gets the token by name (`-e TF_API_TOKEN`), never on the command line.
- PR metadata and other user-controlled values reach scripts only through `env:`, as quoted shell variables.
- The PR comment updates only a thread written by the build identity, so a pasted marker cannot take over or block it.
- Values from TFE are checked before they become pipeline variables.
- The smoke test fixes the TFE hostname and organisation in YAML, so the token cannot be sent to a host typed into the queue form.
- Docs recommend team tokens, never user tokens, and drop the `set -x` advice.
- `applyMethod: tfe` keeps the apply token out of Azure DevOps for production: the approver confirms in TFE with their own permission.
- The plan text shows non-sensitive values to anyone who can read the job log or the PR. It is off by default on PRs; `showPlanLog: false` turns it off on `main`. `plan-log.yml` sends the token to curl on stdin, fetches the signed log URL without it, and breaks up every `##` in the log text so no logging command survives. It uses `caBundle` only for the TFE host (compared in lower case, `:443` dropped) and does not let curl follow redirects; one redirect is followed by hand with the CA chosen by the same rule.

## v1 (July 2025)

Initial version, not tagged: Azure DevOps pipeline templates (`pipeline-templates/`) and task templates (`tasks/`) for HCP Terraform, modelled on `hashicorp/tfc-workflows-github`.
