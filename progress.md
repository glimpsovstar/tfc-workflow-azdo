# progress

## Goal / scope
Rebuild tfc-workflow-azdo (v2) so Azure DevOps PR and main pipelines drive HCP Terraform or Terraform Enterprise correctly through tfci, including private TFE with no ingress, private CA, internal images and split plan/apply tokens. Proven end to end against the lab TFE.

## Done
- 2026-11-15: Task 8 end to end in the lab (Azure DevOps project `lab-project` in org `my-azdo-org`, TFE 2.1.1). 10 checks pass; record in `docs/PROOF.md`. Found and fixed: empty agent pool, branch control with a template tag, discarded saved plans. Templates pushed to Azure Repos at tag `v2.0.0-rc.1`.
- 2026-11-15: Task 9 whole-branch review (13 findings) fixed in `d454cf3`, then an independent review of the fixes (rule 7) found the token on argv in native mode and unsourced claims; fixed in the same commit. 14 checks in `tests/run.sh` pass. Terraform 1.17.0 refuses a stale saved plan (tested locally).
- 2026-11-15: Task 2 tfci wrapper and run steps (`f38fbb7`). CA via `SSL_CERT_DIR` (private CA alone works; tested with the real tfci image against a local TLS server). `textArgs` passes values with spaces as one literal argument.
- 2026-11-15: Task 3 PR comment step (`658aac5`, `0885bf6`): updates only a marker thread written by the build identity; fake-API test in `tests/run.sh`.
- 2026-11-15: Task 4 validate step (`a789504`): terraform 1.17.0 and tflint v0.66.0 pinned; smoke-tested in docker and native mode. Fixture lock file has linux_amd64, linux_arm64, darwin_arm64.
- 2026-11-15: Task 7 lab agent (`a7f7c24`, `bb6edbe`, `0c2a4c0`): jobs as UID 1001 with no capabilities, PAT from a root-only file, REST deregistration from root, one job per registration.
- 2026-11-15: Task 1 test harness. Checker reports 95 violations on the v1 templates across 8 rules. tfci manifests v1.4.0 and v1.5.0 identical.
- 2026-11-15: Full three-reviewer review; spec and plan. Branch `djoo/modernise`.

## In progress
- Nothing. Lab resources still running (see Next).

## Next
1. Decide the release: tag `v2.0.0` and push to GitHub (only when David asks).
2. Lab clean-up when done: delete Azure DevOps project `lab-project` (or keep for demos), the TFE workspace `lab-app`, teams `azdo-plan` and `azdo-apply`, policy set `lab-e2e`, and the `azdo-agents` namespace. TFE team tokens and the agent PAT expire 2026-11-22.
3. Open question for David: a soft-mandatory policy failure on a PR sets the PR status to failed but the build passes, so the merge is not blocked unless a status policy requires `terraform/tfe-plan`. Recommend adding that status policy, or failing the build on soft failure.

## Key context
- Spec: `docs/superpowers/specs/2026-11-15-modernise-design.md`. Plan: `docs/superpowers/plans/2026-11-15-modernise.md`.
- tfci: github.com/hashicorp/tfc-workflows-tooling. v1.5.0 released 2026-11-12, but Docker Hub's newest image is v1.4.0; command code is identical. Default pin `hashicorp/tfci:v1.4.0`. Binary is static at `/usr/local/bin/tfci`.
- tfci reads `TF_HOSTNAME` (not `TF_CLOUD_HOSTNAME`). `--json` is a per-command flag after the command (`tfci run create --json`); only `--hostname`, `--organization`, `--token` go before it. `run create` and `run apply` block until a terminal state.
- Azure Repos ignores YAML `pr:` triggers; PR builds come from branch-policy build validation.
- Lab: lab in a lab tenant (`AZURE_CONFIG_DIR=~/.azure-lab`, `KUBECONFIG=~/.kube/lab.config`). Access details in the lab repo's git-ignored `lab.local.md`. Agent runs as a pod on existing nodes: no new compute.
- Tests: `tests/run.sh` (from Task 1).

## Corrections
- 2026-11-15: Rules check found gaps: docs were left to the end (Task 6) instead of updated in each task, plan ticks were not kept, and tasks got no independent review until the end. From now on: every change updates its docs, ticks its plan item, and gets an independent reviewer before commit.
- 2026-11-15: While parallel agents have staged changes, commit by path only (`git commit -- <paths>`). A plain commit swept another task's staged moves into the Task 7 commit.
- 2026-11-15: Check tfci flag placement against source, not memory: `--json` goes after the command.
