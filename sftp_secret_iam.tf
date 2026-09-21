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
# FIX: a custom, least-privilege role — not the built-in roles/secretmanager
# .admin, which would hand the Spring Boot service control over EVERY secret
# in the project (including the DB passwords other services depend on, e.g.
# aeromon-db-password). Scoped to exactly the four permissions
# GcpSftpSecretResolver actually calls: create (new secret container per
# account), delete (rollback on partial failure + account deletion), and
# addVersion/access (write/read the credential payload). Mirrors this
# project's existing graphsvc_reader/graphsvc_kb_writer least-privilege
# pattern (cloudsql.tf) applied to Secret Manager instead of Cloud SQL.
#
# Granted at the PROJECT level (not per-secret, unlike the two existing
# grants above) because SFTP secrets are created dynamically — one per
# (userId, accountId) pair, an unbounded set — so there is no fixed secret
# resource to scope a per-secret IAM binding to before it exists.

resource "google_project_iam_custom_role" "sftp_secret_manager" {
  role_id     = "sftpSecretManager"
  title       = "SFTP Secret Manager (create/delete/version)"
  description = "Least-privilege role for creating and managing per-account SFTP credential secrets — scoped to exactly what GcpSftpSecretResolver calls, nothing else in Secret Manager."
  project     = var.project_id
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "springboot_sftp_secret_manager" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.sftp_secret_manager.id
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}
