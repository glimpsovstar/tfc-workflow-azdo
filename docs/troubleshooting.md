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

**Fix.** Open the run link in TFE and see what it waits for. Clear the queue, start an agent, or override the policy. The step templates take `maxTimeout`; the pipeline templates do not pass it, so they use the `1h` default.

## The Apply stage is skipped

**Symptom.** The main pipeline succeeds, the Apply stage shows as skipped, and nothing is applied.

**Cause.** The Apply stage runs only when the Plan stage succeeded and the run status is `planned`, `cost_estimated`, `policy_checked` or `policy_override`. The common case is `planned_and_finished`: the plan has no changes. The gate step then logs `No changes: nothing to apply. The Apply stage is skipped.`

Any other status fails the Plan stage in the gate step (`Decide whether to apply`), so it does not skip silently: `Run <id> ended the plan in '<status>', which this pipeline cannot apply.`

**Fix.** For no changes, nothing to fix. For a failed gate, open the run in TFE. A status such as `policy_soft_failed` needs an override in TFE before the run can be applied; then re-run the pipeline.

## Auto apply detected

**Symptom.** The gate step fails with `Run <id> is already <status> without an approval: turn Auto apply off on the workspace.`

**Cause.** The workspace has Auto apply on. TFE applied, or started applying, the run as soon as the plan finished, before the Azure DevOps approval. The gate looks for `applying`, `apply_queued`, `applied` or `confirmed`.

**Fix.** Turn Auto apply off in the workspace's settings. Check what was applied in TFE. The gate cannot undo it.

## PR comment fails with 403

**Symptom.** `Post plan to pull request` fails with `Azure DevOps returned HTTP 403 for ... The build service identity needs 'Contribute to pull requests' on this repository`.

**Cause.** The build service identity cannot write PR threads or statuses.

**Fix.** Project settings, Repositories, your repository, Security: give `<Project> Build Service (<org>)` **Contribute to pull requests**. See [setup.md](setup.md#5-build-service-permission-for-pr-comments). A 401 has the same message; check that the job can use `System.AccessToken`.

## The PR comment is duplicated

**Symptom.** Each push adds a new plan thread instead of updating the first one.

**Cause.** `pr-comment.yml` updates only a thread whose first comment has the marker `<!-- tfc-workflow-azdo:<workspace> -->` and was written by the identity the build runs as (`connectionData`, `authenticatedUser.id`). A new thread each time means the identity changed between builds, for example the job authorisation scope switched between project and collection, so the earlier thread belongs to another identity. Two pipelines with different `workspace` values also each get their own thread, by design.

**Fix.** Keep the job authorisation scope stable ([setup.md](setup.md#9-project-settings)). Resolve or delete the old threads by hand. New builds then update the newest thread.

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
