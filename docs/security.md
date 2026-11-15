# Security

## Threat model

What these templates protect:

- **The TFE tokens.** The plan token can queue plans. The apply token can change infrastructure.
- **The approval.** Nothing should be applied that a person did not approve: in Azure DevOps (`applyMethod: pipeline`) or by confirming the run in TFE (`applyMethod: tfe`).
- **The PR feedback.** The plan shown on a PR should be the plan of that PR's code, posted by the pipeline.

Who they protect them from:

- **PR authors.** A PR changes code that the pipeline runs: Terraform configuration, `.tflint.hcl`, and any value that reaches a script (branch name, PR title). A PR build also runs the PR branch's copy of the consumer pipeline YAML, so a PR author can rewrite it to stop extending these templates and use the plan token directly. The [Required template checks](#required-template-checks) close that.
- **Anyone who can queue or edit a pipeline,** but should not reach production.
- **Other jobs on a shared agent.**

Out of scope: a compromised TFE, a compromised Azure DevOps organisation, and a malicious approver.

## Split tokens

There are two variable groups with two team tokens ([setup.md](setup.md#1-team-tokens)):

- `tfc-plan`: a team with **plan** permission. Used by PR builds and the Plan stage. A leaked plan token can queue plans, not apply them.
- `tfc-apply`: the apply token. Only the Apply stage of `apply-run.yml` loads it. The group has pipeline permission for the main pipeline only, an approval, and a branch control check on `refs/heads/main`. The Apply stage also runs on an environment with its own approval and branch control.

PR code never runs in a job that holds the apply token. In `speculative-run.yml` the `validate` job, which runs PR code on the agent, has **no variable group at all**, so no token exists in that job. The `plan` job loads `tfc-plan` and only uploads files and calls the TFE API.

## Production: confirm in TFE

With `applyMethod: tfe` on `apply-run.yml` ([setup.md](setup.md#11-production-confirm-in-tfe)) the pipeline only plans. A person on a TFE approvers team confirms and applies the run in TFE. This is the stronger control for production:

- **No apply token in Azure DevOps.** The pipeline holds only the plan token. A plan-permission token cannot apply (tested on TFE 2.1.1: run create with `auto-apply` and the apply action are both refused, see [PROOF.md](PROOF.md)), so a leaked pipeline token, a misconfigured variable group, a compromised agent or a pipeline edited to skip the approval still cannot apply production. In the default `pipeline` mode the apply token lives in Azure DevOps, protected by checks; here it does not exist.
- **The approval is where the apply happens.** TFE checks the approver's own permission (an apply-capable team) at the moment of the apply. There is no gap between an Azure DevOps approval and a later API call made with a shared token.
- **The approver sees the real plan.** They read the full plan and the policy results in TFE, on the run that will be applied, not a summary in Azure DevOps.
- **The audit trail names a person.** TFE records who confirmed the run, not a team token.

What it does not change: Auto apply must still be off (TFE setting, not enforceable from the pipeline), and the plan still runs the merged code with the workspace's plan credentials.

## The plan text in logs and PR comments

`showPlanLog` turns on the plan text. With it on, `plan-log.yml` prints the Terraform plan in the job log, and `speculative-run.yml` also adds a trimmed copy to the PR comment, collapsed. The defaults differ:

- **PR (`speculative-run.yml`): off by default.** On a PR the author controls the code being planned, so the plan text lets them show any value the workspace can read. For example, `output "x" { value = nonsensitive(var.secret) }` prints a secret workspace variable in the plan, and with `showPlanLog: true` everyone with read access to the repository sees it in the job log and the PR comment. Turn it on only when PR authors are trusted and the workspace holds no secrets they should not see.
- **Main (`apply-run.yml`): on by default.** On `main` the code has been reviewed and merged before it is planned, so the plan text shows only what reviewed code chose to output.

- **What it exposes.** Terraform masks values marked sensitive (`(sensitive value)`), but it prints every other attribute value in clear text: resource names, IP ranges, tags, non-sensitive variables and outputs, and anything a provider does not mark sensitive. Anyone who can read the pipeline log, or the PR, sees them. On a PR that includes everyone with read access to the repository.
- **How it is fetched.** The step reads the plan with the token (`curl -K -`, the header on stdin, never on argv), then fetches the plan's `log-read-url`, a signed URL, without the Authorization header. Neither the token nor the signed URL is printed.
- **Log injection.** The log text can carry values from the PR's code. The step strips ANSI codes and control characters and breaks up every `##` in the log text (`##` becomes `# #`) before it prints the log or writes the file, so no Azure DevOps logging command survives in any spelling: `##vso[`, `##VSO[`, `##[error]`, or `##` followed by an invisible character. A value in the plan cannot set a pipeline variable or fail the build. `pr-comment.yml` does the same to an API response it prints on a failed call. In the PR comment, triple backticks are replaced so the log cannot close its code fence, and HTML in the log stays inside that fence.
- **Private CA and redirects.** `caBundle` is used for the log URL only when its host matches `hostname` (lower case, `:443` dropped). curl does not follow redirects; the step follows one by hand and picks the CA by the same rule, so the private CA is never trusted for another host.
- **How to turn it off.** Set `showPlanLog: false` on the pipeline template. The pipeline then shows the counts and the run link only, as before. On `pr-comment.yml` alone, `includePlanLog: false` keeps the plan out of the PR while the job log still has it.

Mark sensitive variables and outputs as `sensitive = true` in the Terraform code. That is the control that keeps a value out of the plan text.

## Required template checks

Every protection in these templates assumes the pipeline actually extends them. The consumer YAML that a PR build runs comes from the PR branch, so a PR author controls it. Without a check, they can replace `extends` with their own job, load `tfc-plan` and send the plan token anywhere.

Add a **Required template** check ([setup.md](setup.md#10-required-template-checks)) on `tfc-plan`, `tfc-apply` and the PR agent pool, requiring `templates/pipelines/speculative-run.yml@tfc` or `templates/pipelines/apply-run.yml@tfc` at the pinned ref. Azure DevOps then refuses any stage that uses those resources unless the pipeline extends the named template. Microsoft: [Templates for security, Required templates](https://learn.microsoft.com/azure/devops/pipelines/security/templates?view=azure-devops#required-templates).

Pin the check's Ref to the tag. A check on a branch ref such as `refs/heads/main` of the template repository trusts whoever can push there; a tag is fixed until someone moves it.

## Secrets only through `env:`

- The token reaches a script only through `env:` ([`tfci.yml`](../templates/steps/tfci.yml)): `TF_API_TOKEN: $(<tokenVariable>)`. No secret macro is expanded inside a script body. The checker rule `no-secret-macro-in-script` enforces this.
- Docker gets the token by name: `docker run -e TF_API_TOKEN`. The value never appears on a command line, so it is not in `ps` output or the process table.
- tfci's JSON output is written to a file. The step prints only a fixed list of non-secret keys (`status`, `run_id`, `run_status`, and so on), never the whole document.
- `pr-comment.yml` sends `System.AccessToken` to curl through a header read from a process substitution, not on curl's argv, and never prints it.
- No script uses `set -x`. The checker rule `no-set-x` enforces this.
- `logLevel` (tfci's `TF_LOG`) is off by default. Keep DEBUG out of shared logs as a precaution.
- `hostname` is required, with no default, so the token only goes to a host the pipeline names.

## No TF_VAR_* leaks into runs

tfci reads every `TF_VAR_*` in its environment as a run variable (`var_file.go`, tfci v1.4.0). Docker mode passes only the variables named with `-e`. Native mode runs tfci with every other variable unset, keeping an allowlist: `PATH`, `HOME`, the `TF_*` variables the step sets, the CA variables and the proxy variables. `tests/steps_fake_tfci_test.sh` checks that `TF_VAR_FOO` does not reach a fake tfci.

## User-controlled values only through env

Branch names, PR titles and other values a PR author controls are never expanded into a script. Every pipeline value reaches a script through `env:` and is used as a quoted shell variable. The checker rules `no-user-macro-in-script` and `no-template-if-in-script` enforce this.

tfci flags with free text (`workspace`, `directory`, `message`, `comment`) go through the `textArgs` map of `tfci.yml`: each value is one literal argument `--<name>=<value>`, passed through an env variable, never parsed by the shell. The `message` and `comment` defaults name the build only (`Azure DevOps build $(Build.BuildId)`). Do not put PR text in them.

Values that come back from TFE are checked before they become pipeline variables: IDs must match `run-...`, `plan-...` or `cv-...`, and run-create rejects control characters, so a value cannot start a new `##vso` logging command.

## PR comment thread ownership

`pr-comment.yml` updates its own thread on each push instead of adding a new one. It finds the thread by a hidden marker, `<!-- tfc-workflow-azdo:<workspace> -->`. Anyone can paste that marker into a PR comment, so a marker alone is not trusted:

1. The step asks Azure DevOps who it is (`_apis/connectionData`, `authenticatedUser.id`).
2. It only updates a live thread whose first comment carries the marker **and** was written by that identity.
3. A pasted marker from anyone else is ignored and the step creates its own thread.

`tests/pr_comment_test.sh` covers a spoofed thread against a fake API.

An older build cannot overwrite a newer plan either: before writing, the step compares the PR's `lastMergeSourceCommit.commitId` with this build's `System.PullRequest.SourceCommitId` and skips the comment and the status when a newer push exists. The comment and the status name the short commit they were planned from.

## Pinned images and lock file

- Images are pinned by tag, and should be pinned by digest in production ([internal-registry.md](internal-registry.md)). The checker rejects `:latest` and untagged images.
- Commit `.terraform.lock.hcl` with hashes for every platform your agents and workstations use, so `terraform init` installs the provider builds you reviewed:

  ```bash
  terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
  ```

  The fixture in `tests/fixtures/random` does this. `validate.yml` does not use `-lockfile=readonly`; init adds any missing hashes for the agent's platform to the agent's checkout only.

## Separate agent pools

Use one agent pool for PR builds and another for the Apply stage. Pass them as the `pool` parameter of each pipeline.

PR code runs on the PR pool: `terraform init` downloads providers named by the PR, and tflint may download plugins. An agent that runs PR code should never also hold apply credentials, reach production networks, or keep state between jobs. Self-hosted agents keep their work directory and the agent's own credential readable by job code, so a PR job on a shared agent can affect the next job.

**Never use native mode on a shared pool for PR builds.** In native mode PR jobs run directly on the agent host, next to the `tfci`, `terraform` and `tflint` binaries that later jobs use.

## Speculative plans run PR code in TFE

This risk is inherent to speculative plans and these templates cannot remove it. A PR's speculative plan runs the PR's Terraform code in TFE, with the workspace's credentials and variables. Terraform code can run commands during a plan (for example through an `external` data source), so a PR author can use whatever credentials the workspace gives plan runs.

Mitigations:

- **Trusted contributors only.** Run PR builds only for people who can already push to the repository: Azure Repos contributors in the same project. Do not build PRs from forks.
- **Plan permission only.** The plan token cannot apply, so a PR cannot apply through the API.
- **Read-only credentials for plan runs.** Give plan runs read-only cloud credentials and apply runs a separate role, for example dynamic provider credentials with a Reader role for plan and a contributor role for apply, either Vault-backed or through workload identity.
- **Separate agent pools** for PR builds and apply deployments, as above.
- **No native mode on a shared pool** for PR builds, as above.

## The lab agent

The lab runs the agent as a Kubernetes pod in native mode: jobs run as UID 1001 with no capabilities and `no_new_privs`, the registration PAT sits in a root-only file and is never in a job's environment, the CA bundle and `tfci` are read-only to jobs, and the agent takes one job per registration with its state wiped at restart. The full model and its residual risks are in [lab/azdo-agent/README.md](../lab/azdo-agent/README.md#security-model). It is a lab design; its production differences are listed there too.

## Residual risks

- **Speculative plans run PR code with the workspace's credentials,** as above.
- **A self-hosted agent's own credential is readable by job code,** because jobs run as the agent's user. A job can act as that agent until the registration is removed.
- **`System.AccessToken` is in the PR job.** It is scoped by the job authorisation settings ([setup.md](setup.md#9-project-settings)) and needs only "Contribute to pull requests" on top of the defaults.
- **Workspace Auto apply is a TFE setting the pipeline cannot enforce.** If someone turns it on, TFE applies before the Azure DevOps approval. The Plan stage fails when it sees the run already applying or applied, but by then the apply has started.
- **In `pipeline` mode the approver approves in Azure DevOps, away from the plan.** The plan text is in the Plan job's log (`showPlanLog`), but approvers should open the run link and read the plan and policy results in TFE. `applyMethod: tfe` puts the approval on the plan itself.
- **The plan text shows non-sensitive values** in the job log and, when `showPlanLog` is turned on for PRs, in the PR comment, as above.
- **Tag pins are mutable.** Until images are pinned by digest, a re-pushed tag changes what runs.
