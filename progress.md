# progress

## Goal / scope
Rebuild tfc-workflow-azdo (v2) so Azure DevOps PR and main pipelines drive HCP Terraform or Terraform Enterprise correctly through tfci, including private TFE with no ingress, private CA, internal images and split plan/apply tokens. Proven end to end against the lab TFE.

## Done
- 2026-11-15: Full review by three parallel reviewers (correctness, security, docs). Neither v1 pipeline can work: run not pinned to the uploaded configuration version, invalid tfci flags and fields, validation always fails, failures pass silently, no TFE support, token on the command line, one token for PR and apply. Details in the spec.
- 2026-11-15: Spec and plan written. Branch `djoo/modernise`.

## In progress
- Task 1: clean up and test harness.

## Next
1. Task 1 test harness (fails on v1 templates).
2. Tasks 2, 3, 4, 7 in parallel (separate worktrees, main session commits).
3. Task 5 pipelines, Task 6 docs.
4. Task 8 end to end in the lab with David (he supplies Azure DevOps org, PAT and tokens).
5. Task 9 whole-branch review.

## Key context
- Spec: `docs/superpowers/specs/2026-11-15-modernise-design.md`. Plan: `docs/superpowers/plans/2026-11-15-modernise.md`.
- tfci: github.com/hashicorp/tfc-workflows-tooling. v1.5.0 released 2026-11-12, but Docker Hub's newest image is v1.4.0; command code is identical. Default pin `hashicorp/tfci:v1.4.0`. Binary is static at `/usr/local/bin/tfci`.
- tfci reads `TF_HOSTNAME` (not `TF_CLOUD_HOSTNAME`). `--json` is a global flag before the command. `run create` and `run apply` block until a terminal state.
- Azure Repos ignores YAML `pr:` triggers; PR builds come from branch-policy build validation.
- Lab: lab in a lab tenant (`AZURE_CONFIG_DIR=~/.azure-lab`, `KUBECONFIG=~/.kube/lab.config`). Access details in the lab repo's git-ignored `lab.local.md`. Agent runs as a pod on existing nodes: no new compute.
- Tests: `tests/run.sh` (from Task 1).

## Corrections
(none yet)
