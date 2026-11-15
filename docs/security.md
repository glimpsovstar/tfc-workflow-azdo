# Security

## Threat model

What these templates protect:

- **The TFE tokens.** The plan token can queue plans. The apply token can change infrastructure.
- **The approval.** Nothing should be applied that a person did not approve in Azure DevOps.
- **The PR feedback.** The plan shown on a PR should be the plan of that PR's code, posted by the pipeline.

Who they protect them from:

- **PR authors.** A PR changes code that the pipeline runs: Terraform configuration, `.tflint.hcl`, and any value that reaches a script (branch name, PR title).
- **Anyone who can queue or edit a pipeline,** but should not reach production.
- **Other jobs on a shared agent.**

Out of scope: a compromised TFE, a compromised Azure DevOps organisation, and a malicious approver.

## Split tokens

There are two variable groups with two team tokens ([setup.md](setup.md#1-team-tokens)):

- `tfc-plan`: a team with **plan** permission. Used by PR builds and the Plan stage. A leaked plan token can queue plans, not apply them.
- `tfc-apply`: the apply token. Only the Apply stage of `apply-run.yml` loads it. The group has pipeline permission for the main pipeline only, an approval, and a branch control check on `refs/heads/main`. The Apply stage also runs on an environment with its own approval and branch control.

PR code never runs in a job that holds the apply token. In `speculative-run.yml` the `validate` job, which runs PR code on the agent, has **no variable group at all**, so no token exists in that job. The `plan` job loads `tfc-plan` and only uploads files and calls the TFE API.

## Secrets only through `env:`

- The token reaches a script only through `env:` ([`tfci.yml`](../templates/steps/tfci.yml)): `TF_API_TOKEN: $(<tokenVariable>)`. No secret macro is expanded inside a script body. The checker rule `no-secret-macro-in-script` enforces this.
- Docker gets the token by name: `docker run -e TF_API_TOKEN`. The value never appears on a command line, so it is not in `ps` output or the process table.
- tfci's JSON output is written to a file. The step prints only a fixed list of non-secret keys (`status`, `run_id`, `run_status`, and so on), never the whole document.
- `pr-comment.yml` sends `System.AccessToken` to curl through a header read from a process substitution, not on curl's argv, and never prints it.
- No script uses `set -x`. The checker rule `no-set-x` enforces this.

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
- **The approver sees the plan summary, not the full plan.** Approvers should open the run link and read the plan in TFE.
- **Tag pins are mutable.** Until images are pinned by digest, a re-pushed tag changes what runs.
