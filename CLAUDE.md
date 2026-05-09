# CLAUDE.md — terraform/

GCP infrastructure for the ZSynergy / AeroMontek platform. Cloud SQL, GCS,
networking, IAM, secret bindings.

## Stack

- Terraform 1.5+
- Google provider
- Remote state in GCS (configured per-environment)

## Standalone vs monorepo development

This directory is **local-only at present** — it has no upstream remote. It
is treated as a monorepo-managed sub-project via `manifest.yaml` in the root
`gcp-builds` repo, but you can also work on it in place.

### Standalone (in-tree)

```bash
cd terraform
terraform init
terraform plan -out=plan.bin
terraform apply plan.bin
```

The `plan.bin` artefact is what `infra/scripts/build.sh` checks for during
the orchestrator's build phase.

### Within the gcp-builds monorepo (integrated)

The parent `gcp-builds` repo orchestrates this directory along with the
other 4 sub-projects through `manifest.yaml` and `infra/scripts/`:

```bash
# from gcp-builds/ root
bash infra/scripts/build.sh --only terraform
# After review:
cd terraform && terraform apply plan.bin
```

`terraform apply` is **out of the cloudbuild.yaml deploy pipeline** — it must
be run by an authorised operator with project owner / editor IAM. The
orchestrator's `deploy.sh` reminds you of this.

## Pinning

Because this directory has no remote, the manifest pins it via `branch: main`
and the orchestrator's `checkout.sh` only verifies the directory exists. If
you decide to host this in its own remote later:

1. Create the upstream repo (e.g. `git@github_vxl:VXL-ZSDS-AI/aeromontek-terraform.git`)
2. Push `main` from here to that remote
3. Update `manifest.yaml`'s `terraform.repo_url` to the new URL
4. Re-run `bash infra/scripts/checkout.sh` to verify
