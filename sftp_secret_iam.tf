# =============================================================================
# sftp_secret_iam.tf — Secret Manager write access for SFTP account credentials
# =============================================================================
#
# BUG BEING FIXED: SFTP "test connection" succeeds but "save" fails in
# production. Root cause, verified directly against the code (not guessed):
# SftpAccountManagementService.createAccount() -> GcpSftpSecretResolver.store()
# calls SecretManagerServiceClient.createSecret(...) — a PROJECT-LEVEL
# operation requiring secretmanager.secrets.create. The Spring Boot SA
# (google_service_account.springboot, main.tf) has never held that permission
# anywhere — only the two narrow, pre-existing secretAccessor grants below
# (main.tf:359-370) on two SPECIFIC secrets that already existed at grant
# time. testConnection() never touches Secret Manager at all (it only probes
# reachability), which is exactly why test succeeds and save doesn't.
#
# FIX: two custom, least-privilege roles instead of one, because their two
# permission groups have different scoping ceilings:
#
#   1. sftp_secret_manager_create — secretmanager.secrets.create ONLY.
#      Left PROJECT-scoped with no resource condition. This is not a missed
#      opportunity: secrets.create is authorized against the PARENT
#      (the project) because the secret named in the request doesn't exist
#      yet at authorization-check time, so a condition referencing the
#      not-yet-existing secret's resource.name has nothing real to match
#      against. Checked empirically before accepting this: adding a
#      `resource.name.startsWith(...)` condition to a create-only binding
#      passed `terraform validate`/`terraform plan` without error — but that
#      only proves Terraform's client-side schema accepts the HCL shape, not
#      that Secret Manager's server-side policy evaluator would ever honor
#      it. That only resolves at `setIamPolicy` (apply) time, which this fix
#      does not perform. Rather than ship a condition that either silently
#      no-ops (false sense of scoping) or is rejected at apply, this stays
#      honestly project-scoped for `create` alone — one permission, nothing
#      else, matching the actual GCP constraint on creation-time conditions.
#
#   2. sftp_secret_manager_manage — secretmanager.secrets.delete,
#      secretmanager.versions.add, secretmanager.versions.access. These act
#      on secrets that already exist, so they CAN and DO carry a resource
#      condition restricting them to the `sftp-` name prefix (see
#      GcpSftpSecretResolver.secretId(userId, accountId) in aeromontek-api:
#      `"sftp-" + sanitizedUserId + "-" + accountId`) — confirmed as a
#      supported pattern by Secret Manager's own docs ("allow a user to
#      manage secret versions only on secrets that begin with a specific
#      prefix", cloud.google.com/secret-manager/docs/access-control).
#
# Prior version of this file bound all four permissions — including delete,
# version-add, and version-access — in a single project-scoped role with no
# condition. That let the Spring Boot SA read/overwrite/delete every secret
# in the project (aeromon-db-password, aeromon-internal-api-secret,
# aeromon-oauth-state-secret, etc.), not just SFTP ones, despite this file's
# earlier comment claiming it "avoids roles/secretmanager.admin's reach" —
# false for exactly those three capabilities, which are present in both.
# This version is honest about what's actually scoped: `create` remains
# project-wide only because GCP's own IAM-conditions model doesn't support
# scoping it any tighter (not a choice this file is making); `delete` /
# `versions.add` / `versions.access` are both permission-minimal AND
# resource-minimal, restricted to the `sftp-*` secret family.
#
# Mirrors this project's existing graphsvc_reader least-privilege pattern
# (cloudsql.tf) — a dedicated, narrowly-scoped principal per integration
# rather than reusing a broad built-in role — applied here to Secret Manager
# instead of Cloud SQL. (graphsvc_kb_writer, previously also cited here, does
# not exist in this branch/PR's base — it lives only on the separate,
# unmerged feat/ontology-graph-admin branch. Removed the reference rather
# than cite a sibling resource that isn't actually part of this codebase.)
#
# CORRECTED (re-review): the Spring Boot SA does NOT arrive at this PR with
# zero Secret Manager access, as an earlier version of this comment claimed.
# `gcloud projects get-iam-policy zsynergy` shows it already holds a
# project-wide, UNCONDITIONED `roles/secretmanager.secretAccessor`
# (== secretmanager.versions.access) — undeclared drift, not present anywhere
# in this Terraform config, shared with three other service accounts. IAM is
# additive: that pre-existing grant makes `sftp_secret_manager_manage`'s own
# `versions.access` permission redundant today (the SA can already read every
# secret version in the project regardless of what this PR adds), so the
# "permission-minimal AND resource-minimal" claim two paragraphs up is only
# fully true for `secrets.delete` and `versions.add`. Keeping `versions.access`
# in this role anyway is still correct: it makes the role self-describing and
# it becomes load-bearing (not merely redundant) the day someone cleans up the
# out-of-band grant. That cleanup is real platform work but is explicitly OUT
# OF SCOPE for this PR — tracked as a follow-up, not fixed here.

resource "google_project_iam_custom_role" "sftp_secret_manager_create" {
  count       = var.enable_springboot ? 1 : 0
  role_id     = "sftpSecretManagerCreate"
  title       = "SFTP Secret Manager (create)"
  description = "Least-privilege role for creating new per-account SFTP credential secrets. Project-scoped: secrets.create is authorized against the parent project, not an existing resource, so it cannot be further restricted by an IAM condition (see file header)."
  project     = var.project_id
  permissions = [
    "secretmanager.secrets.create",
  ]
}

resource "google_project_iam_member" "springboot_sftp_secret_manager_create" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.sftp_secret_manager_create[0].id
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_project_iam_custom_role" "sftp_secret_manager_manage" {
  count       = var.enable_springboot ? 1 : 0
  role_id     = "sftpSecretManagerManage"
  title       = "SFTP Secret Manager (delete/version)"
  description = "Least-privilege role for deleting and adding/accessing versions of per-account SFTP credential secrets — resource-scoped to the sftp- secret family via an IAM condition, not just permission-minimal."
  project     = var.project_id
  permissions = [
    "secretmanager.secrets.delete",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "springboot_sftp_secret_manager_manage" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.sftp_secret_manager_manage[0].id
  member  = "serviceAccount:${google_service_account.springboot[0].email}"

  condition {
    title       = "sftp-secrets-only"
    description = "Restricts delete/versions.add/versions.access to secrets named sftp-<userId>-<accountId> (GcpSftpSecretResolver.secretId) — not every secret in the project."
    expression  = "resource.name.startsWith(\"projects/${data.google_project.project.number}/secrets/sftp-\")"
  }
}
