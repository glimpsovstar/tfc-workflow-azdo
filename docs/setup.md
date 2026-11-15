# Setup

An end-to-end checklist, in order. Each step names the setting in Azure DevOps or TFE and the template parameter it relates to. Parameter details are in [reference.md](reference.md).

Assumption: Azure DevOps Services (cloud) with Azure Repos Git. Menu names are from the Azure DevOps web UI and may move between releases.

## 1. Team tokens

Create two TFE (or HCP Terraform) teams and a team token for each:

| Token | Team permission on the workspaces | Used by |
| --- | --- | --- |
| Plan token | Plan (can queue plans, cannot apply) | PR builds and the Plan stage of `apply-run.yml` |
| Apply token | Write, or a custom permission that can apply runs | The Apply stage of `apply-run.yml` only |

Use team tokens, never user tokens:

- A user token carries everything that person can do, in every organisation they belong to. A team token carries only that team's permissions.
- A user token stops working when the person leaves or loses access, and the pipeline breaks with them.
- Runs and audit entries show the team, not a person who did not start them.

Set an expiry on both tokens and rotate them.

## 2. Variable groups

In Pipelines, Library, create two variable groups. Each holds the variable `TF_API_TOKEN`, marked secret (the padlock):

| Variable group | `TF_API_TOKEN` | Template parameter |
| --- | --- | --- |
| `tfc-plan` | The plan token | `variableGroup` (speculative-run.yml), `planVariableGroup` (apply-run.yml) |
| `tfc-apply` | The apply token | `applyVariableGroup` (apply-run.yml) |

The variable name is the `tokenVariable` parameter (default `TF_API_TOKEN`). Both groups use the same name.

Protect `tfc-apply`:

1. **Pipeline permissions:** open the group, Pipeline permissions, and allow only the main pipeline. Do not open it to all pipelines.
2. **Approvals and checks:** add an Approvals check, and a Branch control check with Allowed branches set to `refs/heads/main,refs/tags/v2.*`. Branch control checks the ref of every repository the stage uses, including this template repository at its pinned tag, so the tag pattern must be allowed too (found in the lab run, 2026-11-15: with `refs/heads/main` alone the check fails with "Branch protection check failed."). Turn on "Verify branch protection" if your branch policies allow it.

`tfc-plan` needs pipeline permission for the PR pipeline, the main pipeline and the smoke test.

Add a Required template check to both groups too: see [step 10](#10-required-template-checks).

## 3. Environment

In Pipelines, Environments, create the environment named in the `environment` parameter of `apply-run.yml` (the example uses `my-app-dev`). Under Approvals and checks add:

- **Approvals:** the people who approve applies.
- **Branch control:** Allowed branches `refs/heads/main,refs/tags/v2.*` (the template repository's release tags must be allowed too; see step 2).
- **Exclusive lock:** recommended. The Apply stage sets `lockBehavior: sequential`, so with this check runs take the environment one at a time, in order. Without `lockBehavior` the default is `runLatest`, which cancels older runs. Microsoft: [Exclusive lock](https://learn.microsoft.com/azure/devops/pipelines/process/approvals?view=azure-devops#exclusive-lock) ("This can be specified for the whole pipeline or for a given stage").

The Apply stage is a deployment job on this environment, so it waits for these checks before it touches the apply token's variable group.

The Plan stage creates a saved-plan run (`savePlan`, default `true`). If the approval is rejected or expires, the saved plan stays in TFE but does not lock the workspace. Re-run the pipeline to apply later, so the apply uses a fresh plan. See [troubleshooting.md](troubleshooting.md#approval-rejected-or-expired).

## 4. Branch policy build validation

Azure Repos ignores the YAML `pr:` trigger. PR builds come from a branch policy:

1. Create the PR pipeline from your copy of [`examples/azure-pipelines.pr.yml`](../examples/azure-pipelines.pr.yml). It sets `trigger: none` and `pr: none`.
2. Project settings, Repositories, your repository, Policies, Branch policies, `main`, Build validation: add the PR pipeline. Set it to Required and to re-run when the source branch updates.

Create the main pipeline from [`examples/azure-pipelines.main.yml`](../examples/azure-pipelines.main.yml). It runs on pushes to `main` (`trigger: branches: include: main`) and sets `pr: none`.

## 5. Build service permission for PR comments

[`pr-comment.yml`](../templates/steps/pr-comment.yml) posts the plan as a PR thread and sets a PR status with `System.AccessToken`. That token belongs to the build service identity, which needs **Contribute to pull requests**:

- Project settings, Repositories, your repository, Security.
- Find the user `<Project> Build Service (<org>)`, for example `MyProject Build Service (my-org)`.
- Set **Contribute to pull requests** to Allow.

Assumption: the job authorisation scope is the project (see step 9). If it is the collection, the identity is `Project Collection Build Service (<org>)` instead.

## 6. Workspace settings

On each workspace the pipelines use:

- **Workflow:** CLI-driven (API-driven). The pipelines upload configuration versions; the workspace is not connected to a VCS repository.
- **Auto apply:** off. With it on, TFE applies the run as soon as the plan finishes, before anyone approves in Azure DevOps. The Plan stage's gate step fails when it sees the run already `applying`, `apply_queued`, `applied` or `confirmed`.
- **Execution mode:** remote or agent. Remote runs on HCP Terraform or TFE workers. Agent runs on HCP Terraform agents in your network; pick it when the run needs to reach private resources. The pipelines work the same with either: tfci only talks to the TFE API.

## 7. Agent requirements

Set the `mode` parameter to match the agent:

| Mode | The agent needs | Fits |
| --- | --- | --- |
| `docker` (default) | Docker, bash, jq, curl 7.76 or later | VM or scale-set agents |
| `native` | `tfci` on the PATH, bash, jq, curl 7.76 or later; `terraform` and `tflint` on the PATH when validation is on | Agents without Docker, such as pods |

curl 7.76 is the first release with `--fail-with-body`, which `pr-comment.yml` uses.

In native mode tfci runs with every other variable unset, keeping an allowlist (token, hostname, organization, timeout, `TF_LOG`, CA and proxy variables, `PATH`, `HOME`), because tfci reads every `TF_VAR_*` as a run variable. Agent-wide `TF_VAR_*` variables never reach a run. See [troubleshooting.md](troubleshooting.md#a-tf_var_-variable-has-no-effect-on-the-run).

Every job sets `timeoutInMinutes` from `jobTimeoutInMinutes` (default `90`). It must exceed `maxTimeout` (default `1h`), or Azure DevOps cancels the job while tfci still waits for the run.

`logLevel` (default `''`) sets tfci's `TF_LOG`: `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. In docker mode the agent pulls `hashicorp/tfci`, `hashicorp/terraform` and the tflint image; see [internal-registry.md](internal-registry.md) to serve them from your own registry.

The agent must reach TFE on 443 and Azure DevOps outbound. For a private TFE see [tfe-private-network.md](tfe-private-network.md). Pass the TFE CA bundle path as `caBundle` when TFE uses a private CA.

Use separate agent pools for PR builds and for the Apply stage. See [security.md](security.md).

## 8. Smoke test

[`examples/smoke-test.yml`](../examples/smoke-test.yml) uploads `tests/fixtures/random` as a speculative configuration version, creates a plan-only run on it and prints the plan summary. It proves network access, the plan token and the CA bundle. Nothing is applied.

1. Edit the `TFE_HOSTNAME` and `TFE_ORGANIZATION` variables in the file and commit. They are fixed in the YAML, not queue-time parameters, so the token can only go to the TFE named in a reviewed commit.
2. Pipelines, New pipeline, Existing Azure Pipelines YAML file, `examples/smoke-test.yml`.
3. Run it with the runtime parameters `workspace` (a CLI-driven workspace), `poolName`, `mode` and `caBundle` (`none` for a public CA, or the absolute path of the CA file on the agent).

A passing run ends with the plan summary: run link, status and add, change and destroy counts.

## 9. Project settings

Project settings, Pipelines, Settings:

- **Limit job authorization scope to current project for non-release pipelines:** on. `System.AccessToken` then only reaches this project.
- **Protect access to repositories in YAML pipelines:** on. A pipeline must be granted access to each repository it uses, including this template repository, the first time it runs. Approve it once per pipeline.

Assumption: the template repository is in the same project as the consumer, or the consumer's build service has read access to it. Cross-project repository resources need that access.

## 10. Required template checks

A PR build runs the PR branch's copy of the consumer pipeline YAML. Without a check, a PR author can rewrite that file so it no longer `extends` these templates, load `tfc-plan` and use the plan token directly. A Required template check makes Azure DevOps refuse the stage unless the pipeline extends the template you name.

Add it under Approvals and checks, Required template, on:

| Resource | Required template |
| --- | --- |
| Variable group `tfc-plan` | `templates/pipelines/speculative-run.yml` and `templates/pipelines/apply-run.yml` (the plan token serves both) |
| Variable group `tfc-apply` | `templates/pipelines/apply-run.yml` |
| The PR agent pool | `templates/pipelines/speculative-run.yml` |

For each: Repository type Azure Repos, Repository `<Project>/tfc-workflow-azdo`, Ref the pinned tag, for example `refs/tags/v2.0.0`. Update the Ref when you move consumers to a new tag.

Microsoft: [Templates for security, Required templates](https://learn.microsoft.com/azure/devops/pipelines/security/templates?view=azure-devops#required-templates) and [Approvals and checks, Required template](https://learn.microsoft.com/azure/devops/pipelines/process/approvals?view=azure-devops#required-template). "This check applies only when the pipeline extends from a template."

The smoke test does not extend a pipeline template, so with this check on `tfc-plan` it cannot load the group. Run it with its own variable group and a plan token, or before you add the check.
