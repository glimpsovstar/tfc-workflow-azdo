# Internal registry and pinned images

In docker mode the agent pulls three images. Mirror them into your internal registry, pin them by digest, and set the image parameters to the mirrored names. This is normal supply-chain practice: builds then use exactly the bytes you reviewed, and do not depend on a public registry being reachable.

## The images

| Image (default) | Parameter | Used by |
| --- | --- | --- |
| `hashicorp/tfci:v1.4.0` | `image` | Every tfci call ([`tfci.yml`](../templates/steps/tfci.yml)) |
| `hashicorp/terraform:1.17.0` | `terraformImage` | `terraform fmt`, `init`, `validate` ([`validate.yml`](../templates/steps/validate.yml)) |
| `ghcr.io/terraform-linters/tflint:v0.66.0` | `tflintImage` | tflint ([`validate.yml`](../templates/steps/validate.yml)) |

The defaults are pinned by tag. The header of [`validate.yml`](../templates/steps/validate.yml) records the digests of the Terraform and tflint images as pulled on 2026-11-15.

## Mirror and pin

For each image:

1. Pull the tag, check it, and copy it to your registry. A tool that copies the whole multi-platform index, such as `crane copy` or `skopeo copy --all`, keeps the digest the same as upstream.
2. Read the digest of what you pushed, for example with `docker buildx imagetools inspect registry.example.internal/hashicorp/tfci:v1.4.0`.
3. Set the parameter to `name:tag@sha256:<digest>`. The tag is kept for people; the digest is what the pull uses.

```yaml
extends:
  template: templates/pipelines/apply-run.yml@tfc
  parameters:
    image: registry.example.internal/hashicorp/tfci:v1.4.0@sha256:<digest>
    terraformImage: registry.example.internal/hashicorp/terraform:1.17.0@sha256:<digest>
    tflintImage: registry.example.internal/terraform-linters/tflint:v0.66.0@sha256:<digest>
```

`speculative-run.yml` takes the same three parameters. The template checker (`tests/check_templates.rb`) rejects `:latest` and untagged images; a digest passes.

Assumption: the agent is already logged in to the internal registry, or the registry allows anonymous pulls from the agent network. The templates do not run `docker login`.

## Native mode: tfci in the agent image

Native mode runs `tfci` from the agent's PATH, with no Docker. The binary in `hashicorp/tfci` is static at `/usr/local/bin/tfci`, so you can copy it out of the pinned image into your own agent image:

```dockerfile
FROM registry.example.internal/hashicorp/tfci:v1.4.0@sha256:<digest> AS tfci

FROM registry.example.internal/your-agent-base:<tag>
COPY --from=tfci /usr/local/bin/tfci /usr/local/bin/tfci
```

The lab does the same thing at runtime: an init container from `hashicorp/tfci:v1.4.0` runs `cp /usr/local/bin/tfci /opt/tools/bin/tfci` into a shared volume that the agent container mounts read-only (see [`lab/azdo-agent/deployment.yaml`](../lab/azdo-agent/deployment.yaml) and its [README](../lab/azdo-agent/README.md)). A baked image is better for production: no copy at start, and the binary is part of an image you scanned.

When validation is on in native mode, also put `terraform` and `tflint` on the agent's PATH at the versions you want.

## Moving to tfci v1.5.0

The templates default to `hashicorp/tfci:v1.4.0`. tfci v1.5.0 is released, and its Docker image is not yet on Docker Hub at the time of writing (2026-11-15). When it is published:

- **Consumers:** set the `image` parameter. That is a one-line change in the consumer pipeline.
- **This repository:** the default `hashicorp/tfci:v1.4.0` is written in seven templates (both pipelines and the five tfci step templates). Change all of them together, plus the lab's init container.

The command line does not change. `tests/run.sh` checks that the command manifests built from the v1.4.0 and v1.5.0 sources (`tests/tfci-v1.4.0-commands.txt` and `tests/tfci-v1.5.0-commands.txt`) list the same commands and flags. If a later version changes them, that check fails first.
