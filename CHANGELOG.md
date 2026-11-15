# Changelog

## v2.0.0 (unreleased)

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
- Tests: canonical run status sets (`tests/status_sets_test.rb`), output variable references (`tests/output_refs_test.rb`) and the step scripts against a fake tfci (`tests/steps_fake_tfci_test.sh`).
- Docs: Required template checks on the variable groups and the PR agent pool.
- Local tests, run with `bash tests/run.sh`: template checker and its self-tests, tfci command manifests for v1.4.0 and v1.5.0, shellcheck on every template script, a fake Azure DevOps API test for the PR comment, Terraform checks on the fixture, and a check that `docs/reference.md` matches the templates.
- Docs: setup, private TFE, internal registry, security, a generated reference, troubleshooting.

### Changed

- `hostname` is required on every template that calls tfci; there is no `app.terraform.io` default.
- Native mode runs tfci under `env -i` with an allowlist, so no `TF_VAR_*` from the agent or pipeline reaches a run.
- PR status: `planned_and_finished` and `post_plan_completed` succeed; `policy_soft_failed` fails with "soft-mandatory policy failed: override in TFE".

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

- Plan and apply use separate team tokens. The apply token's variable group is limited to the main pipeline, with an approval and a branch control check on `refs/heads/main`.
- PR validation runs in a job with no variable group, so untrusted PR code never shares a job with a token.
- Secrets reach scripts only through `env:`. Docker gets the token by name (`-e TF_API_TOKEN`), never on the command line.
- PR metadata and other user-controlled values reach scripts only through `env:`, as quoted shell variables.
- The PR comment updates only a thread written by the build identity, so a pasted marker cannot take over or block it.
- Values from TFE are checked before they become pipeline variables.
- The smoke test fixes the TFE hostname and organisation in YAML, so the token cannot be sent to a host typed into the queue form.
- Docs recommend team tokens, never user tokens, and drop the `set -x` advice.

## v1 (July 2025)

Initial version, not tagged: Azure DevOps pipeline templates (`pipeline-templates/`) and task templates (`tasks/`) for HCP Terraform, modelled on `hashicorp/tfc-workflows-github`.
