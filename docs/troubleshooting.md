# Troubleshooting

Each entry has the symptom you see in the log, the cause and the fix. Step and parameter names are in [reference.md](reference.md).

Never print the token to debug a failure. Check the variable group and the team's permissions in TFE instead.

## tfci returns 401 or 403

**Symptom.** A tfci step (Upload configuration, Create run and wait for the plan, Plan summary, Apply run) fails with an unauthorised or forbidden error from the TFE API, and the step ends with `tfci <command> exited with <code>`.

**Cause.** One of:

- The token in the variable group is wrong, expired or revoked.
- The team behind the token lacks permission on the workspace: the plan team cannot queue plans there, or the Apply stage is using a plan-only token.
- `hostname` or `organization` points at a different TFE or organisation than the token belongs to.

**Fix.** Check the token's team and expiry in TFE, Organisation settings, Teams. Check the team's access on the workspace. Check `TF_API_TOKEN` in `tfc-plan` and `tfc-apply` holds the right token for each, and that `hostname` and `organization` match. Create a new team token if in doubt.

A related error appears before tfci runs: `tfci.yml: the token variable 'TF_API_TOKEN' is empty or not defined`. The job does not load the variable group, or the pipeline lacks permission to it, or `tokenVariable` names a variable that is not in the group.

## x509: certificate signed by unknown authority

**Symptom.** tfci fails with `x509: certificate signed by unknown authority` (or `tls: failed to verify certificate`).

**Cause.** TFE uses a private CA and tfci does not trust it: `caBundle` is empty, or the file holds the wrong CA.

**Fix.** Set `caBundle` to the absolute path on the agent of a PEM file with the TFE CA. The CA alone is enough. Check the file with `openssl x509 -in <file> -noout -subject -issuer`. See [tfe-private-network.md](tfe-private-network.md#private-ca).

If the step instead fails with `caBundle '...' must be an absolute path to an existing file`, the path is relative or the file is not on that agent.

If `terraform init` in the validate job fails with the same x509 error, the provider mirror has a private certificate: set `validateCaBundle`. That bundle replaces the system roots, so it must include public roots too.

## configuration_version invalid

**Symptom.** The step `Create run and wait for the plan (check input)` fails with `run-create: configurationVersionId '...' is not a configuration version ID (cv-...)`.

**Cause.** The upload did not produce a configuration version ID. Usually the Upload configuration step failed first, or `configurationVersionId` was passed a variable that does not exist, so the value is the literal text `$(upload.CONFIGURATION_VERSION_ID)`.

**Fix.** Look at the Upload configuration step first. If you call the step templates yourself, pass `$(upload.CONFIGURATION_VERSION_ID)` where `upload` is the `name` of your upload step, and keep both steps in the same job. Across jobs use the `dependencies` form in [reference.md](reference.md).

## The run is stuck or times out

**Symptom.** Create run or Apply run waits a long time, then fails after about an hour.

**Cause.** tfci waits until the run reaches a terminal state, bounded by `TF_MAX_TIMEOUT` (the `maxTimeout` parameter, default `1h`). Common reasons a run does not finish: it is queued behind another run on the same workspace, no TFE agent is free (agent execution mode), the run is waiting for a policy override, or TFE capacity is full.

**Fix.** Open the run link in TFE and see what it waits for. Clear the queue, start an agent, or override the policy. If runs really take longer, raise `maxTimeout` on the pipeline template (both pipeline templates pass it to every tfci step) and keep `jobTimeoutInMinutes` above it.

## The job is canceled after 90 minutes

**Symptom.** A job ends as canceled, not failed, with a message that it exceeded the maximum execution time.

**Cause.** Every job in the pipeline templates sets `timeoutInMinutes` from `jobTimeoutInMinutes` (default `90`). The job hit that limit before tfci finished waiting, usually because `maxTimeout` was raised above it.

**Fix.** Keep `jobTimeoutInMinutes` above `maxTimeout`, with room for the upload and the other steps. With `maxTimeout: 2h`, set `jobTimeoutInMinutes: 150` or more.

A timeout cancels the job, so the TFE run is handled as in [Job cancelled: what happens to the TFE run](#job-cancelled-what-happens-to-the-tfe-run).

## Job cancelled: what happens to the TFE run

**Symptom.** A job was cancelled (by a person, or by the job timeout) while a TFE run was going. The step `Cancel the TFE run (job cancelled)` runs at the end of the job.

**What happens.** Cancelling the job kills the step that is running. If that is `Create run and wait for the plan`, tfci is killed before it prints the run ID, but the run in TFE keeps going. The step `run-cancel.yml` runs only on cancel (`condition: canceled()`) and:

1. Finds the run. In a Plan job it looks up the workspace, lists its last 20 runs (speculative runs included) and takes the newest run on this build's configuration version. In the Apply job it uses the run ID from the Plan stage.
2. Asks TFE what the run allows (`actions.is-cancelable`, `actions.is-discardable`). A run that is planning or applying is **cancelled**. A run that waits for a person (confirmation, a policy override, or its turn in the queue) is **discarded**. A finished run is left alone, and the step logs `it has finished, nothing to cancel`.
3. Never fails the job. Any error is a warning with the HTTP status, and the step exits 0.

The jobs set `cancelTimeoutInMinutes: 5`, which is how long Azure DevOps lets steps run after a cancel. Each API call is capped at 20 seconds.

What is **not** cancelled:

- A job cancelled before `Create run and wait for the plan` started: the step logs `no TFE run to cancel`.
- A job cancelled after the run was created and planned, during a later step (plan summary, plan log, gate). The run is already planned. In `pipeline` mode it is a saved plan that does not block the workspace; in `tfe` mode it waits in TFE for a person to confirm or discard it, as it does after a successful pipeline.
- A successful pipeline. In `tfe` mode the planned run waits in TFE for a person: that is the design, and nothing cancels it.

Cancelling an apply interrupts Terraform part way, so some changes may already be made. Check the run and the workspace state in TFE before the next run.

**Warnings you may see.**

- `the token cannot cancel this run (TFE needs apply permission)`, HTTP 403 or 404. TFE documents that cancel and discard need permission to apply runs. A Plan job holds the plan token, which has plan permission only, so in a Plan job this warning is expected. Cancel or discard the run in TFE by hand (the warning names the run ID). The Apply job holds the apply token and can cancel. **Assumption, to confirm in the lab:** that a plan-permission team token is refused cancel and discard, including on a speculative run it queued itself.
- `HTTP 409`: the run moved on between the read and the cancel (for example it finished). Check it in TFE.
- `failed (curl exit 28)`: an API call took more than 20 seconds. Check the run in TFE.
- `configurationVersionId is not a configuration version ID` or `runId is not a run ID`: a wiring mistake in a pipeline that calls the step itself. Nothing is sent.

**Fix.** Open the workspace in TFE, find the run (its message names the Azure DevOps build), and cancel or discard it if it is still going. To let the Plan job cancel by itself, the plan token would need apply permission, which removes the point of split tokens ([security.md](security.md#split-tokens)); the templates do not do that.

## The Apply stage is skipped

**Symptom.** The main pipeline succeeds, the Apply stage shows as skipped, and nothing is applied.

**Cause.** The Apply stage runs only when the Plan stage succeeded and the run status is in the APPLYABLE_MAIN set: `planned`, `planned_and_saved`, `cost_estimated`, `policy_checked`, `post_plan_completed` or `policy_override`. The canonical sets are in `tests/status_sets_test.rb`, which fails if the gate or the stage condition drift from them. The common skip is `planned_and_finished`: the plan has no changes. The gate step then logs `No changes: nothing to apply. The Apply stage is skipped.`

Any other status fails the Plan stage in the gate step (`Decide whether to apply`), so it does not skip silently: `Run <id> ended the plan in '<status>', which cannot be confirmed or applied.`

**Fix.** For no changes, nothing to fix. For a failed gate, open the run in TFE.

`policy_soft_failed` is a plan-only final state: a speculative (PR) run ends there when a soft-mandatory policy fails, and the PR status says `soft-mandatory policy failed: override in TFE`. A main-branch run that fails a soft-mandatory policy waits in `policy_override` instead (tfci treats `policy_override` as a finished state that needs human approval, `internal/cloud/run.go` in v1.4.0); see the next entry.

## A policy needs an override

**Symptom.** The gate step logs the warning `A policy needs an override in TFE before you approve this apply`, with the run link. If the apply is approved anyway, Apply run fails with `Run <id> is policy_override and cannot be applied yet. If a policy needs an override, override it in TFE (or discard the run), then re-run the pipeline.`

**Cause.** A soft-mandatory policy failed on the main-branch run. TFE holds the run in `policy_override` until someone with permission overrides the policy. Until then the run is not confirmable and `tfci run apply` exits with `cannot be applied` (`run_apply.go`, tfci v1.4.0).

**Fix.** Before approving, open the run link in TFE and override the policy, or discard the run if it should not be applied. After a failed apply, override the policy (or discard the run) and re-run the pipeline.

## Approval rejected or expired

**Symptom.** The environment approval was rejected or timed out. The Apply stage did not run.

**Cause.** The main pipeline creates a saved-plan run (`savePlan`, default `true`). It ends the plan in `planned_and_saved` and does not lock the workspace or become its current run until it is applied. The rejected run stays in TFE as a saved plan.

**Fix.** Nothing blocks the workspace: other runs can go ahead. To apply the change later, re-run the pipeline. Do not apply the old saved plan by hand: it was reviewed against the state at the time, so a re-run with a fresh plan is the safe path. Discard the stale run in TFE if you want a tidy run list.

Assumption, to confirm in the end-to-end test: `tfci run apply` applies a `planned_and_saved` run. tfci applies only runs that TFE reports as confirmable. The [TFE runs API](https://developer.hashicorp.com/terraform/enterprise/api-docs/run) lists `planned_and_saved` as a state that can be confirmed for apply; neither tfci v1.4.0 nor go-tfe says so directly.

Two merges close together: both plan at once (a saved plan does not lock the workspace) and `lockBehavior: sequential` applies them one after the other. The second saved plan was made against the state before the first apply. TFE discards it when the first run applies, so the second Apply fails safely with `Run <id> was discarded in TFE ... Nothing was applied.` Re-run that pipeline for a fresh plan. (Confirmed in the lab on TFE 2.1.1, 2026-11-15. Terraform itself also refuses a stale saved plan: `Error: Saved plan is stale`.)

## Auto apply detected

**Symptom.** The gate step fails with `Run <id> is already <status> without an approval: turn Auto apply off on the workspace.` (with `applyMethod: tfe`: `without a confirmation in TFE`).

**Cause.** The workspace has Auto apply on. TFE applied, or started applying, the run as soon as the plan finished, before the Azure DevOps approval or a confirmation in TFE. The gate looks for `applying`, `apply_queued`, `applied` or `confirmed`.

**Fix.** Turn Auto apply off in the workspace's settings. Check what was applied in TFE. The gate cannot undo it.

## PR comment fails with 403

**Symptom.** `Post plan to pull request` fails with `Azure DevOps returned HTTP 403 for ... The build service identity needs 'Contribute to pull requests' on this repository`.

**Cause.** The build service identity cannot write PR threads or statuses.

**Fix.** Project settings, Repositories, your repository, Security: give `<Project> Build Service (<org>)` **Contribute to pull requests**. See [setup.md](setup.md#5-build-service-permission-for-pr-comments). A 401 has the same message; check that the job can use `System.AccessToken`.

## The PR comment is duplicated

**Symptom.** Each push adds a new plan thread instead of updating the first one.

**Cause.** `pr-comment.yml` updates only a thread whose first comment has the marker `<!-- tfc-workflow-azdo:<workspace> -->` and was written by the identity the build runs as (`connectionData`, `authenticatedUser.id`). A new thread each time means the identity changed between builds, for example the job authorisation scope switched between project and collection, so the earlier thread belongs to another identity. Two pipelines with different `workspace` values also each get their own thread, by design.

**Fix.** Keep the job authorisation scope stable ([setup.md](setup.md#9-project-settings)). Resolve or delete the old threads by hand. New builds then update the newest thread.

## The PR comment and status were not updated

**Symptom.** `Post plan to pull request` succeeds and logs `A newer push exists on this PR (<commit>, this build planned <commit>): skipping the PR comment and status.`

**Cause.** By design. Before it writes, the step reads the PR ([Pull Requests, Get](https://learn.microsoft.com/rest/api/azure/devops/git/pull-requests/get-pull-request?view=azure-devops-rest-7.1)) and compares `lastMergeSourceCommit.commitId` with this build's `System.PullRequest.SourceCommitId`. When they differ, a newer push has its own build, and this older plan must not overwrite it.

**Fix.** None. Wait for the build of the newest push. The comment and the status description name the short commit they were planned from.

## Template not found when consumed cross-repo

**Symptom.** The pipeline does not start. Azure DevOps reports that the template file or the repository resource `tfc` cannot be found.

**Cause.** One of:

- `ref` in `resources.repositories` names a tag or branch that does not exist, for example `refs/tags/v2.0.0` before that tag is pushed.
- `name` is not `<Project>/tfc-workflow-azdo` for where the repository lives.
- The `extends` path is wrong. It is relative to the template repository root, with the alias: `templates/pipelines/speculative-run.yml@tfc`.
- The pipeline has not been granted access to the template repository ("Protect access to repositories in YAML pipelines").

**Fix.** Check the tag exists (`git ls-remote --tags`), check the repository name and path, and approve the repository access prompt on the first run.

## docker: command not found

**Symptom.** A tfci or validate step fails with `docker: command not found`.

**Cause.** `mode` is `docker` (the default), and the agent has no Docker, for example an agent that runs as a pod.

**Fix.** Set `mode: native` and put `tfci` on the agent's PATH (plus `terraform` and `tflint` if validation is on). See [internal-registry.md](internal-registry.md#native-mode-tfci-in-the-agent-image). Or run on agents that have Docker.

## A TF_VAR_* variable has no effect on the run

**Symptom.** A `TF_VAR_*` variable set on the agent or in the pipeline does not reach the TFE run.

**Cause.** By design. tfci reads every `TF_VAR_*` in its environment as a run variable (`var_file.go`, tfci v1.4.0). To keep agent and pipeline variables out of runs, docker mode passes only the variables it names with `-e`, and native mode runs tfci with every other variable unset, keeping an allowlist: `PATH`, `HOME`, `TF_API_TOKEN`, `TF_HOSTNAME`, `TF_CLOUD_ORGANIZATION`, `TF_MAX_TIMEOUT`, `TF_LOG`, `SSL_CERT_DIR`, `SSL_CERT_FILE` and the proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, either case).

**Fix.** Set Terraform variables on the workspace or a variable set in TFE.

## tfci needs more detail to debug

**Symptom.** A tfci step fails and the log does not say enough.

**Fix.** Set `logLevel` on the pipeline template to `ERROR`, `WARN`, `INFO` or `DEBUG` (default `''`, logging off). It becomes `TF_LOG` for tfci. Keep DEBUG out of shared logs as a precaution. Set it back to `''` when done. Any other value fails the step before tfci runs.

## environment is required when applyMethod is pipeline

**Symptom.** The first step of the Plan job, `Check template parameters`, fails with `apply-run: environment is required when applyMethod is pipeline`.

**Cause.** `environment` has a default of `''` so that `applyMethod: tfe` consumers can leave it out. With the default `applyMethod: pipeline` the Apply stage needs it.

**Fix.** Pass the Azure DevOps environment that holds the approval ([setup.md](setup.md#3-environment)), or set `applyMethod: tfe` if a person confirms in TFE ([setup.md](setup.md#11-production-confirm-in-tfe)). Nothing was uploaded and no run was created.

## Confirm in TFE: the next run waits

**Symptom.** With `applyMethod: tfe`, a main pipeline waits in `Create run and wait for the plan` and fails after `maxTimeout`. In TFE its run is pending behind an older one.

**Cause.** An earlier run is still waiting for confirmation. A confirmable run holds the workspace, so TFE queues later runs behind it until it is applied or discarded.

**Fix.** Confirm and apply, or discard, the older run in TFE (approvers team). Then re-run the pipeline. Agree a routine with the approvers so runs do not wait for long.

## The plan log is empty or not shown

**Symptom.** The `Terraform plan log` step ends as succeeded with issues, with a warning such as `plan-log: GET https://<host>/api/v2/plans/<id> returned HTTP 404`, `has no log-read-url yet` or `the plan log for <id> is empty`. The PR comment has no Terraform plan block.

**Cause.** One of:

- The plan did not start or produce output: the run errored before the plan, or was canceled.
- The token cannot read the plan (HTTP 401, 403 or 404): the token's team has no read access to the workspace's runs.
- The log was removed from TFE (data retention).
- `curl` failed before HTTP: a TLS error (the step prints curl's message for the API call) or a network problem.

**Fix.** Open the run link and check the plan in TFE. For 401, 403 or 404, check the team access as in [tfci returns 401 or 403](#tfci-returns-401-or-403). For a TLS error, check `caBundle`: in this step it is passed to curl as `--cacert`, which replaces the system roots for the API call. When the log is served by another host (HCP Terraform), curl uses the system roots for it and the step logs `The log is served by another host`. The host is compared with `hostname` in lower case, with a `:443` port dropped.

If the log URL redirects, the step logs `The plan log URL redirected` and follows it once by hand, choosing the CA by the same host rule; curl itself never follows redirects, so `caBundle` is never sent along to another host. A second redirect ends the step with the warning `redirected more than once`.

The step never fails the job for these: the plan text is for reading only. A bad `planId`, `hostname`, `maxLines` or `caBundle` does fail it, because that is a pipeline mistake.

## The plan log URL expired

**Symptom.** The `Terraform plan log` step warns `fetching the plan log returned HTTP 403` (or 401, or 404) `The signed log URL may have expired`.

**Cause.** The plan's `log-read-url` is a signed URL that TFE issues for a short time. The step fetches it straight after reading the plan, so it expires only if the agent is very slow, its clock is far off, or the log host refuses the request (for example a proxy between the agent and TFE strips or rewrites the query string).

**Fix.** Re-run the job; each run of the step asks TFE for a fresh URL. Check the agent's clock and any proxy rules for the log path. curl's own message is not printed for this request, because it could contain the signed URL.

To turn the plan text off, set `showPlanLog: false` on the pipeline template.
