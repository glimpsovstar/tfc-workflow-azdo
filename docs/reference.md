# Template reference

Every template's parameters and output variables. Everything below the "generated" marker is produced from the templates by `tests/gen_reference.rb`; do not edit it by hand. After changing a template, run:

```bash
ruby tests/gen_reference.rb --write
```

`bash tests/run.sh` fails when this file is out of date.

## How to read it

- **Required** means the parameter has no default.
- **Pipeline templates** (`templates/pipelines/`) are used with `extends`. Their tables list the stages and jobs they create, and the output variables the steps inside set.
- **Step templates** (`templates/steps/`) are used as `- template:` steps in your own job. Output variables live under the step's `name` parameter. The tables show the default name; if you pass `name: x`, read `$(x.RUN_ID)`.
- Output variable forms, from Microsoft's [Set variables in scripts](https://learn.microsoft.com/azure/devops/pipelines/process/set-variables-scripts) and [Expressions, dependencies](https://learn.microsoft.com/azure/devops/pipelines/process/expressions#dependencies):
  - same job: `$(<step>.<VAR>)`
  - another job in the same stage (job `dependsOn` the first): `dependencies.<job>.outputs['<step>.<VAR>']`
  - a job in a later stage: `stageDependencies.<stage>.<job>.outputs['<step>.<VAR>']`
  - a later stage's `condition`: `dependencies.<stage>.outputs['<job>.<step>.<VAR>']`
- The step templates also create helper steps named `<name>_check` (input checks) and `<name>_tfci` (the tfci call). They set no output variables.

Assumption: the deployment job in `apply-run.yml` sets `RUN_STATUS` and `APPLY_RESULT` but nothing reads them in a later stage, so the generator gives only the same-job form for it. Deployment jobs use a different cross-stage form; see Microsoft's [deployment jobs](https://learn.microsoft.com/azure/devops/pipelines/process/deployment-jobs) page if you need it.

<!-- BEGIN GENERATED: ruby tests/gen_reference.rb --write -->

## speculative-run.yml

File: [`templates/pipelines/speculative-run.yml`](../templates/pipelines/speculative-run.yml)

Extends template for pull request validation builds: a speculative (plan-only) run on this PR's own code, posted back to the PR.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `workspace` | string |  | yes | Workspace name in the organization. |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `directory` | string | `./` | no | Terraform configuration directory, relative to the repository root. |
| `pool` | object |  | yes | Agent pool for the jobs, for example `{name: tfe-agents}`. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `variableGroup` | string | `tfc-plan` | no | Variable group with the plan token. |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `jobTimeoutInMinutes` | number | `90` | no | `timeoutInMinutes` of every job. Must exceed `maxTimeout`, or Azure DevOps cancels the job while tfci still waits. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |
| `enableValidate` | boolean | `true` | no | Run validate.yml (fmt, init and validate, tflint) before the plan. |
| `showPlanLog` | boolean | `false` | no | Print the Terraform plan text in the job log (plan-log.yml). In speculative-run.yml it also adds a trimmed copy to the PR comment. The plan shows values not marked sensitive. |
| `enableTflint` | boolean | `true` | no | Run tflint in validate.yml. |
| `terraformImage` | string | `hashicorp/terraform:1.17.0` | no | Terraform image for docker mode. |
| `tflintImage` | string | `ghcr.io/terraform-linters/tflint:v0.66.0` | no | tflint image for docker mode. |
| `cliConfigFile` | string | `''` | no | Path on the agent to a Terraform CLI config file, set as `TF_CLI_CONFIG_FILE` (for a provider mirror). |
| `validateCaBundle` | string | `''` | no | Passed to validate.yml as `caBundle`. Set as `SSL_CERT_FILE` for `terraform init`, which replaces the system roots. |

Stages and jobs:

- Stage `Plan`, job `validate`: no variable group.
- Stage `Plan`, job `plan`: variable group from `variableGroup` (default `tfc-plan`); depends on `validate` when validate is on.

Output variables set by the steps inside. The template has one stage, so the later-stage forms are for reference only:

| Variable | Same job | Later stage (condition) | Later stage (job variable) |
| --- | --- | --- | --- |
| `CONFIGURATION_VERSION_ID` (job `plan`) | `$(upload.CONFIGURATION_VERSION_ID)` | `dependencies.Plan.outputs['plan.upload.CONFIGURATION_VERSION_ID']` | `stageDependencies.Plan.plan.outputs['upload.CONFIGURATION_VERSION_ID']` |
| `RUN_ID` (job `plan`) | `$(run.RUN_ID)` | `dependencies.Plan.outputs['plan.run.RUN_ID']` | `stageDependencies.Plan.plan.outputs['run.RUN_ID']` |
| `RUN_STATUS` (job `plan`) | `$(run.RUN_STATUS)` | `dependencies.Plan.outputs['plan.run.RUN_STATUS']` | `stageDependencies.Plan.plan.outputs['run.RUN_STATUS']` |
| `PLAN_ID` (job `plan`) | `$(run.PLAN_ID)` | `dependencies.Plan.outputs['plan.run.PLAN_ID']` | `stageDependencies.Plan.plan.outputs['run.PLAN_ID']` |
| `PLAN_STATUS` (job `plan`) | `$(run.PLAN_STATUS)` | `dependencies.Plan.outputs['plan.run.PLAN_STATUS']` | `stageDependencies.Plan.plan.outputs['run.PLAN_STATUS']` |
| `RUN_LINK` (job `plan`) | `$(run.RUN_LINK)` | `dependencies.Plan.outputs['plan.run.RUN_LINK']` | `stageDependencies.Plan.plan.outputs['run.RUN_LINK']` |
| `ADD` (job `plan`) | `$(plan_output.ADD)` | `dependencies.Plan.outputs['plan.plan_output.ADD']` | `stageDependencies.Plan.plan.outputs['plan_output.ADD']` |
| `CHANGE` (job `plan`) | `$(plan_output.CHANGE)` | `dependencies.Plan.outputs['plan.plan_output.CHANGE']` | `stageDependencies.Plan.plan.outputs['plan_output.CHANGE']` |
| `DESTROY` (job `plan`) | `$(plan_output.DESTROY)` | `dependencies.Plan.outputs['plan.plan_output.DESTROY']` | `stageDependencies.Plan.plan.outputs['plan_output.DESTROY']` |

## apply-run.yml

File: [`templates/pipelines/apply-run.yml`](../templates/pipelines/apply-run.yml)

Extends template for the main branch: plan, approval, apply.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `workspace` | string |  | yes | Workspace name in the organization. |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `directory` | string | `./` | no | Terraform configuration directory, relative to the repository root. |
| `pool` | object |  | yes | Agent pool for the jobs, for example `{name: tfe-agents}`. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `planVariableGroup` | string | `tfc-plan` | no | Variable group for the Plan stage, with the plan token. |
| `applyVariableGroup` | string | `tfc-apply` | no | Variable group for the Apply stage, with the apply token. |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `applyMethod` | string | `pipeline` | no | `pipeline`: an Azure DevOps environment approval, then the pipeline applies with the apply token. `tfe`: a person confirms and applies the run in TFE; the run is confirmable (`savePlan` forced off), there is no Apply stage, and `environment` and `applyVariableGroup` are not used. Allowed: `pipeline`, `tfe`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `jobTimeoutInMinutes` | number | `90` | no | `timeoutInMinutes` of every job. Must exceed `maxTimeout`, or Azure DevOps cancels the job while tfci still waits. |
| `savePlan` | boolean | `true` | no | Create the main-branch run as a saved plan (`--save-plan`). A rejected or expired approval then leaves a saved plan that does not block the workspace. Always off when `applyMethod` is `tfe`. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |
| `environment` | string | `''` | no | Azure DevOps environment for the Apply deployment job. Give it an approval and a branch control check. Required when `applyMethod` is `pipeline` (the Plan job fails at once without it); not used when it is `tfe`. |
| `showPlanLog` | boolean | `true` | no | Print the Terraform plan text in the job log (plan-log.yml). In speculative-run.yml it also adds a trimmed copy to the PR comment. The plan shows values not marked sensitive. |
| `enableValidate` | boolean | `false` | no | Run validate.yml (fmt, init and validate, tflint) before the plan. |
| `enableTflint` | boolean | `true` | no | Run tflint in validate.yml. |
| `tflintPluginInit` | boolean | `false` | no | Use the repository `.tflint.hcl` and let `tflint --init` download the plugins it declares. Off by default: tflint then ignores the repository config and uses only the bundled terraform ruleset, because on a PR the config comes from the PR author and tflint runs its plugins. Turn on only for trusted code. |
| `terraformImage` | string | `hashicorp/terraform:1.17.0` | no | Terraform image for docker mode. |
| `tflintImage` | string | `ghcr.io/terraform-linters/tflint:v0.66.0` | no | tflint image for docker mode. |
| `cliConfigFile` | string | `''` | no | Path on the agent to a Terraform CLI config file, set as `TF_CLI_CONFIG_FILE` (for a provider mirror). |
| `validateCaBundle` | string | `''` | no | Passed to validate.yml as `caBundle`. Set as `SSL_CERT_FILE` for `terraform init`, which replaces the system roots. |

Stages and jobs:

- Stage `Plan`, job `plan`: variable group from `planVariableGroup` (default `tfc-plan`).
- Stage `Apply`, deployment `apply`: variable group from `applyVariableGroup` (default `tfc-apply`); environment from `environment`; only when `eq(parameters.applyMethod, 'pipeline')`.

Output variables set by the steps inside. The `Apply` stage reads `RUN_STATUS` and `RUN_ID` with the later-stage forms:

| Variable | Same job | Later stage (condition) | Later stage (job variable) |
| --- | --- | --- | --- |
| `CONFIGURATION_VERSION_ID` (job `plan`) | `$(upload.CONFIGURATION_VERSION_ID)` | `dependencies.Plan.outputs['plan.upload.CONFIGURATION_VERSION_ID']` | `stageDependencies.Plan.plan.outputs['upload.CONFIGURATION_VERSION_ID']` |
| `RUN_ID` (job `plan`) | `$(run.RUN_ID)` | `dependencies.Plan.outputs['plan.run.RUN_ID']` | `stageDependencies.Plan.plan.outputs['run.RUN_ID']` |
| `RUN_STATUS` (job `plan`) | `$(run.RUN_STATUS)` | `dependencies.Plan.outputs['plan.run.RUN_STATUS']` | `stageDependencies.Plan.plan.outputs['run.RUN_STATUS']` |
| `PLAN_ID` (job `plan`) | `$(run.PLAN_ID)` | `dependencies.Plan.outputs['plan.run.PLAN_ID']` | `stageDependencies.Plan.plan.outputs['run.PLAN_ID']` |
| `PLAN_STATUS` (job `plan`) | `$(run.PLAN_STATUS)` | `dependencies.Plan.outputs['plan.run.PLAN_STATUS']` | `stageDependencies.Plan.plan.outputs['run.PLAN_STATUS']` |
| `RUN_LINK` (job `plan`) | `$(run.RUN_LINK)` | `dependencies.Plan.outputs['plan.run.RUN_LINK']` | `stageDependencies.Plan.plan.outputs['run.RUN_LINK']` |
| `ADD` (job `plan`) | `$(plan_output.ADD)` | `dependencies.Plan.outputs['plan.plan_output.ADD']` | `stageDependencies.Plan.plan.outputs['plan_output.ADD']` |
| `CHANGE` (job `plan`) | `$(plan_output.CHANGE)` | `dependencies.Plan.outputs['plan.plan_output.CHANGE']` | `stageDependencies.Plan.plan.outputs['plan_output.CHANGE']` |
| `DESTROY` (job `plan`) | `$(plan_output.DESTROY)` | `dependencies.Plan.outputs['plan.plan_output.DESTROY']` | `stageDependencies.Plan.plan.outputs['plan_output.DESTROY']` |
| `RUN_STATUS` (job `apply`) | `$(apply.RUN_STATUS)` | not generated | not generated |
| `APPLY_RESULT` (job `apply`) | `$(apply.APPLY_RESULT)` | not generated | not generated |

## tfci.yml

File: [`templates/steps/tfci.yml`](../templates/steps/tfci.yml)

One step that runs any tfci command: `tfci <command> --json <args> <textArgs>`.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `name` | string |  | yes | Step name. Output variables are read as `<name>.<VARIABLE>`. |
| `displayName` | string |  | yes | Step display name. |
| `command` | string |  | yes | tfci command, for example `run create`. Must be in `tests/tfci-v1.4.0-commands.txt`. |
| `args` | string | `''` | no | Flags without spaces, for example `--plan-only=true`. Split on whitespace. Never user-controlled text. |
| `textArgs` | object | `{}` | no | Map of flag name to value. Each becomes one argument `--<name>=<value>`, passed through env. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `workingDirectory` | string | `$(System.DefaultWorkingDirectory)` | no | Directory tfci runs in (mounted at `/tfci/workspace` in docker mode). |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `outputFile` | string | `''` | no | File for tfci's JSON output. Empty: `$(Agent.TempDirectory)/tfci-<name>.json`. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |
| `condition` | string | `succeeded()` | no | Step condition. |

Outputs: none.

## upload.yml

File: [`templates/steps/upload.yml`](../templates/steps/upload.yml)

Upload a directory as a new configuration version: `tfci upload --json`.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `name` | string | `upload` | no | Step name. Output variables are read as `<name>.<VARIABLE>`. |
| `displayName` | string | `Upload configuration` | no | Step display name. |
| `workspace` | string |  | yes | Workspace name in the organization. |
| `directory` | string | `./` | no | Directory to upload, relative to `workingDirectory`. |
| `speculative` | boolean | `false` | no | Upload a speculative configuration version (plan only, for PRs). |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `workingDirectory` | string | `$(System.DefaultWorkingDirectory)` | no | Directory tfci runs in (mounted at `/tfci/workspace` in docker mode). |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |

Outputs (step name from the `name` parameter; the default is shown):

| Variable | Same job | Another job | Another stage |
| --- | --- | --- | --- |
| `CONFIGURATION_VERSION_ID` | `$(upload.CONFIGURATION_VERSION_ID)` | `dependencies.<job>.outputs['upload.CONFIGURATION_VERSION_ID']` | `stageDependencies.<stage>.<job>.outputs['upload.CONFIGURATION_VERSION_ID']` |

## run-create.yml

File: [`templates/steps/run-create.yml`](../templates/steps/run-create.yml)

Create a run on a given configuration version and wait for the plan: `tfci run create --json`.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `name` | string | `run` | no | Step name. Output variables are read as `<name>.<VARIABLE>`. |
| `displayName` | string | `Create run and wait for the plan` | no | Step display name. |
| `workspace` | string |  | yes | Workspace name in the organization. |
| `configurationVersionId` | string |  | yes | Configuration version ID (`cv-...`), from upload.yml. |
| `planOnly` | boolean | `false` | no | Create a plan-only (speculative) run. |
| `savePlan` | boolean | `false` | no | Create a saved-plan run (`--save-plan`). It ends in `planned_and_saved` and does not lock the workspace until it is applied. |
| `message` | string | `Azure DevOps build $(Build.BuildId)` | no | Run message. No user-controlled text. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `workingDirectory` | string | `$(System.DefaultWorkingDirectory)` | no | Directory tfci runs in (mounted at `/tfci/workspace` in docker mode). |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |

Outputs (step name from the `name` parameter; the default is shown):

| Variable | Same job | Another job | Another stage |
| --- | --- | --- | --- |
| `RUN_ID` | `$(run.RUN_ID)` | `dependencies.<job>.outputs['run.RUN_ID']` | `stageDependencies.<stage>.<job>.outputs['run.RUN_ID']` |
| `RUN_STATUS` | `$(run.RUN_STATUS)` | `dependencies.<job>.outputs['run.RUN_STATUS']` | `stageDependencies.<stage>.<job>.outputs['run.RUN_STATUS']` |
| `PLAN_ID` | `$(run.PLAN_ID)` | `dependencies.<job>.outputs['run.PLAN_ID']` | `stageDependencies.<stage>.<job>.outputs['run.PLAN_ID']` |
| `PLAN_STATUS` | `$(run.PLAN_STATUS)` | `dependencies.<job>.outputs['run.PLAN_STATUS']` | `stageDependencies.<stage>.<job>.outputs['run.PLAN_STATUS']` |
| `RUN_LINK` | `$(run.RUN_LINK)` | `dependencies.<job>.outputs['run.RUN_LINK']` | `stageDependencies.<stage>.<job>.outputs['run.RUN_LINK']` |

## plan-output.yml

File: [`templates/steps/plan-output.yml`](../templates/steps/plan-output.yml)

Read a plan's resource counts and write a markdown summary: `tfci plan output --json`.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `name` | string | `plan_output` | no | Step name. Output variables are read as `<name>.<VARIABLE>`. |
| `displayName` | string | `Plan summary` | no | Step display name. |
| `planId` | string |  | yes | Plan ID (`plan-...`), from run-create.yml. |
| `workspace` | string | `''` | no | Workspace name in the organization. |
| `runLink` | string | `''` | no | Run URL, from run-create.yml. |
| `runStatus` | string | `''` | no | Run status, from run-create.yml. |
| `configurationVersionId` | string | `''` | no | Configuration version ID, shown in the summary. |
| `summaryFile` | string | `$(Agent.TempDirectory)/plan-summary.md` | no | Markdown summary file. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `workingDirectory` | string | `$(System.DefaultWorkingDirectory)` | no | Directory tfci runs in (mounted at `/tfci/workspace` in docker mode). |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |
| `condition` | string | `succeeded()` | no | Step condition. |

Outputs (step name from the `name` parameter; the default is shown):

| Variable | Same job | Another job | Another stage |
| --- | --- | --- | --- |
| `ADD` | `$(plan_output.ADD)` | `dependencies.<job>.outputs['plan_output.ADD']` | `stageDependencies.<stage>.<job>.outputs['plan_output.ADD']` |
| `CHANGE` | `$(plan_output.CHANGE)` | `dependencies.<job>.outputs['plan_output.CHANGE']` | `stageDependencies.<stage>.<job>.outputs['plan_output.CHANGE']` |
| `DESTROY` | `$(plan_output.DESTROY)` | `dependencies.<job>.outputs['plan_output.DESTROY']` | `stageDependencies.<stage>.<job>.outputs['plan_output.DESTROY']` |

## plan-log.yml

File: [`templates/steps/plan-log.yml`](../templates/steps/plan-log.yml)

Print the human-readable Terraform plan in the pipeline log, and keep a trimmed copy for the PR comment.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `planId` | string |  | yes | Plan ID (`plan-...`), from run-create.yml. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname (`host` or `host:port`). The API call goes to `https://<hostname>/api/v2/plans/<planId>`. Required, so the token only goes to a host the caller names. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file for curl `--cacert`, used for the API call and for the log URL when it is on the same host. Replaces the system roots for those calls. |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped through `env:` and given to curl on stdin (`curl -K -`), never on argv. |
| `maxLines` | number | `300` | no | Lines of the plan log kept in `outputFile`, followed by a "trimmed" line when the log is longer. The job log always gets the whole log. |
| `outputFile` | string | `$(Agent.TempDirectory)/plan-log.txt` | no | File for the trimmed plan log, read by pr-comment.yml. |
| `condition` | string | `succeeded()` | no | Step condition. |
| `displayName` | string | `Terraform plan log` | no | Step display name. |

Outputs: none.

## run-apply.yml

File: [`templates/steps/run-apply.yml`](../templates/steps/run-apply.yml)

Apply a run that is waiting for confirmation: `tfci run apply --json`.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `name` | string | `apply` | no | Step name. Output variables are read as `<name>.<VARIABLE>`. |
| `displayName` | string | `Apply run` | no | Step display name. |
| `runId` | string |  | yes | Run ID (`run-...`), from run-create.yml. |
| `comment` | string | `Applied by Azure DevOps build $(Build.BuildId)` | no | Apply comment. No user-controlled text. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `image` | string | `hashicorp/tfci:v1.4.0` | no | tfci image for docker mode. Pin it, ideally by digest. |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform). |
| `organization` | string |  | yes | HCP Terraform or TFE organization name. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`. |
| `workingDirectory` | string | `$(System.DefaultWorkingDirectory)` | no | Directory tfci runs in (mounted at `/tfci/workspace` in docker mode). |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`. |
| `maxTimeout` | string | `1h` | no | Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run. |
| `logLevel` | string | `''` | no | tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution. |

Outputs (step name from the `name` parameter; the default is shown):

| Variable | Same job | Another job | Another stage |
| --- | --- | --- | --- |
| `RUN_STATUS` | `$(apply.RUN_STATUS)` | `dependencies.<job>.outputs['apply.RUN_STATUS']` | `stageDependencies.<stage>.<job>.outputs['apply.RUN_STATUS']` |
| `APPLY_RESULT` | `$(apply.APPLY_RESULT)` | `dependencies.<job>.outputs['apply.APPLY_RESULT']` | `stageDependencies.<stage>.<job>.outputs['apply.APPLY_RESULT']` |

## run-cancel.yml

File: [`templates/steps/run-cancel.yml`](../templates/steps/run-cancel.yml)

Cancel or discard the TFE run this job started, when the Azure DevOps job is cancelled (by a user or by the job timeout).

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `hostname` | string |  | yes | HCP Terraform or TFE hostname (`host` or `host:port`). The API calls go to `https://<hostname>/api/v2/`. Required, so the token only goes to a host the caller names. |
| `organization` | string | `''` | no | Organization name, URL-encoded into the workspace lookup. Needed when `runId` is empty. |
| `workspace` | string | `''` | no | Workspace name, URL-encoded into the workspace lookup. Needed when `runId` is empty. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM file for curl `--cacert`. Replaces the system roots for the API calls. |
| `tokenVariable` | string | `TF_API_TOKEN` | no | Name of the secret pipeline variable that holds the token. Mapped through `env:` and given to curl on stdin (`curl -K -`), never on argv. Cancel and discard need apply permission in TFE. |
| `configurationVersionId` | string | `''` | no | Configuration version ID (`cv-...`), from upload.yml. With `runId` empty, the newest of the last 20 runs on it is the one to cancel. |
| `runId` | string | `''` | no | Run ID (`run-...`) when it is known, as in the Apply stage. Empty: find the run by `configurationVersionId`. |
| `condition` | string | `canceled()` | no | Step condition. The default `canceled()` runs the step only when the job is cancelled. |
| `displayName` | string | `Cancel the TFE run (job cancelled)` | no | Step display name. |

Outputs: none.

## pr-comment.yml

File: [`templates/steps/pr-comment.yml`](../templates/steps/pr-comment.yml)

Post the Terraform plan summary to the pull request as one thread, and set a PR status, through the Azure DevOps REST API with System.AccessToken.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `summaryFile` | string | `$(Agent.TempDirectory)/plan-summary.md` | no | Markdown summary to post, from plan-output.yml. |
| `workspace` | string |  | yes | Workspace name in the organization. |
| `runLink` | string | `''` | no | Run URL, from run-create.yml. |
| `runStatus` | string | `''` | no | Run status, from run-create.yml. |
| `add` | string | `''` | no | Resources to add, from plan-output.yml. For the PR status. |
| `change` | string | `''` | no | Resources to change, from plan-output.yml. For the PR status. |
| `destroy` | string | `''` | no | Resources to destroy, from plan-output.yml. For the PR status. |
| `planLogFile` | string | `$(Agent.TempDirectory)/plan-log.txt` | no | Trimmed plan log from plan-log.yml. Appended to the comment, collapsed, when it exists. |
| `includePlanLog` | boolean | `true` | no | Append `planLogFile` to the comment in a collapsed block, capped at 100,000 characters. |
| `statusContextGenre` | string | `terraform` | no | PR status context genre. |
| `statusContextName` | string | `tfe-plan` | no | PR status context name. |
| `condition` | string | `succeededOrFailed()` | no | Step condition. |
| `displayName` | string | `Post plan to pull request` | no | Step display name. |

Outputs: none.

## validate.yml

File: [`templates/steps/validate.yml`](../templates/steps/validate.yml)

Validate step template: terraform fmt -check, init -backend=false and validate, then tflint. Steps only, so the caller keeps them in its own job.

| Parameter | Type | Default | Required | Description |
| --- | --- | --- | --- | --- |
| `directory` | string | `$(System.DefaultWorkingDirectory)` | no | Absolute path of the Terraform configuration directory. |
| `mode` | string | `docker` | no | `docker`: run the pinned image. `native`: run the binaries on the agent PATH. Allowed: `docker`, `native`. |
| `terraformImage` | string | `hashicorp/terraform:1.17.0` | no | Terraform image for docker mode. |
| `tflintImage` | string | `ghcr.io/terraform-linters/tflint:v0.66.0` | no | tflint image for docker mode. |
| `enableTflint` | boolean | `true` | no | Run tflint in validate.yml. |
| `tflintPluginInit` | boolean | `false` | no | Use the repository `.tflint.hcl` and let `tflint --init` download the plugins it declares. Off by default: tflint then ignores the repository config and uses only the bundled terraform ruleset, because on a PR the config comes from the PR author and tflint runs its plugins. Turn on only for trusted code. |
| `caBundle` | string | `''` | no | Absolute path on the agent to a PEM bundle for `terraform init`. Set as `SSL_CERT_FILE`, which replaces the system roots. |
| `cliConfigFile` | string | `''` | no | Path on the agent to a Terraform CLI config file, set as `TF_CLI_CONFIG_FILE` (for a provider mirror). |

Outputs: none.

<!-- END GENERATED -->
