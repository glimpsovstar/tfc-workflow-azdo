# End-to-end proof: lab, 2026-11-15

tfc-workflow-azdo `v2.0.0-rc.1` was run in Azure DevOps Services against Terraform Enterprise 2.1.1 in the lab. TFE is private: the only way in is from inside the lab network. The agent ran as a pod in the lab AKS cluster (native mode, `tfci` v1.4.0, lab CA). Nothing called into the lab. Run IDs and statuses only; no secrets, tenant or subscription IDs.

## Setup

- Azure DevOps project with two repositories: the templates at tag `v2.0.0-rc.1`, and a consumer (`lab/e2e/consumer`) with the random-provider fixture.
- Pipelines: PR (`speculative-run.yml`, through branch-policy build validation) and main (`apply-run.yml`).
- Variable groups `tfc-plan` and `tfc-apply` with TFE team tokens (plan and write access, 7-day expiry).
- Environment with an approval and a branch control check; the same checks on `tfc-apply`.
- Agent pool with two agent pods (`lab/azdo-agent`).

## Results

| # | What | Azure DevOps build | TFE run | Result |
|---|---|---|---|---|
| 1 | PR plan on the PR's own configuration version, posted to the PR | 7 | `run-RtB19kyQyXYEg2zz` (plan-only, `planned_and_finished`, `cv-KvVqESqjwZF1rg2a`) | Pass. Comment by the build identity, PR status `succeeded`, `+3 ~0 -0`. |
| 2 | Second push to the same PR updates the same thread | 8 | | Pass. One plan thread, new commit. The connectionData identity matches the comment author. |
| 3 | Main: saved plan, gate, approval, apply | 11 | `run-TA1rska3qMzRv16p` (`save-plan=true`, `applied`) | Pass. `tfci run apply` applies a `planned_and_saved` run. |
| 4 | Main with no changes | 12 | `run-Ry9UNJJ4EoCMQyWC` (`planned_and_finished`) | Pass. Apply stage skipped, no approval asked, run result succeeded. |
| 5 | A leftover saved plan does not block the workspace | 10 then 11 | | Pass. Run 11 planned while run 10's saved plan was still in TFE. |
| 6 | Two main runs plan at once | 14 and 15 | 15: `run-Dh2Z2HLbERMyE6aB` | Pass. 14 applied. TFE discarded 15's saved plan when 14 applied; 15's Apply failed safely with run status `discarded`. Nothing stale was applied. |
| 7 | Soft-mandatory policy fails on a PR | 16 | | Pass. PR status `failed: soft-mandatory policy failed: override in TFE`. |
| 8 | Policy passes on a later push to the same PR | 17 | | Pass. PR status `succeeded`, same thread. |
| 9 | Main with a policy set attached | 18 | `run-YQAG4XSnZ4PRrqGz` (`applied`) | Pass. Policy passed, approval, applied. See the note below. |
| 10 | Agent deregisters through the REST API when its pod stops | | | Pass. The stopped pod's agent left the pool; the new one registered. |
| 11 | A plan-permission team token cannot apply (for `applyMethod: tfe`) | | control `run-9GA6wGMfc4bWAqNg` | Pass. With a temporary token for the plan team: configuration version upload allowed; run create without auto-apply allowed (control run, then discarded); run create with `auto-apply: true` refused (404); `POST /runs/:id/actions/apply` refused (404). Temporary tokens deleted afterwards. |
| 12 | Plan text in the PR comment and pipeline log (`v2.0.0-rc.3`, `showPlanLog: true` on the lab PR) | 19, 20 | | Pass. Collapsed "Terraform plan" block in the PR comment and a group in the job log. rc.2 showed TFE's raw JSON log events; rc.3 prints each event's message, so it reads like Terraform output ("random_string.test: Plan to replace", "Plan: 2 to add, 0 to change, 2 to destroy."). Same single thread. |
| 13 | `applyMethod: tfe`: the pipeline plans with the plan token only, a person confirms in TFE | 22 | `run-3GKkDL3EwqfNcKYB` (`policy_checked`, then `applied`, `save-plan=false`, `auto-apply=false`) | Pass. Plan stage only, no Apply stage, no approval in Azure DevOps; the gate logged "Confirm and apply run ... in TFE". Confirmed in the TFE UI by a user with apply permission; TFE applied it. Also exercises `policy_checked` on main. |
| 14 | Who can cancel or discard a run (for `run-cancel`, v2.0.1) | | | Pass. With temporary team tokens: a plan-permission token got HTTP 404 for cancel (run still planning) and for discard (run waiting for confirmation), even on runs it queued itself; the uncancelled plan-only run then finished on its own. An apply-permission token cancelled a planning run and discarded a waiting run (HTTP 202). Temporary tokens deleted afterwards. |
| 15 | Non-VCS policy set published through the API | | | Pass. A Sentinel policy set was created with `POST /organizations/:org/policy-sets`, a version uploaded through the upload URL from `POST /policy-sets/:id/versions`, and attached to the workspace; runs 7 to 9 and 13 evaluated it. |

Run 9: with saved plans on, TFE reports `planned_and_saved` after the policy check, so the gate sees that rather than `policy_checked`. Run 13 (`applyMethod: tfe`, no saved plan) shows `policy_checked` on main.

## Problems the run found, and the fixes

- **Empty agent pool.** Deregistering the only agent after each job left the pool empty, and Azure DevOps failed a queued job at once ("No agent found in pool"). Fixed: two agent replicas, and the agent re-registers inside the pod after each job (`lab/azdo-agent`).
- **Branch control with a template repository.** With Allowed branches `refs/heads/main` the check failed ("Branch protection check failed."): the template repository is used at a tag. Fixed in `docs/setup.md`: allow `refs/heads/main,refs/tags/v2.*`.
- **Stale saved plans.** Observed that TFE discards them; `run-apply.yml` now says so and the test suite covers it.

## Not covered by this run

- Docker mode (the lab agent is a pod without Docker). Covered by the step tests and a local run of the real `tfci` image.
- A wrong CA bundle: the lab agent's own bundle already trusts the lab CA, so the parameter cannot fail there. The x509 failure was shown locally with the real `tfci` image.
- `policy_override` on main (a soft-mandatory failure that needs an override in TFE). Covered by the step tests.
- Validate in the PR pipeline (the lab agent has no `terraform` or `tflint`). Covered by `tests/run.sh` and a local smoke test.
