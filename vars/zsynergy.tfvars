# =============================================================================
# vars/zsynergy.tfvars — ZSynergy / AeroMontek Terraform Variables (Production)
# =============================================================================
# Usage:
#   terraform plan -var-file="vars/zsynergy.tfvars"
#   terraform apply -var-file="vars/zsynergy.tfvars"
# =============================================================================

project_id    = "zsynergy"
region        = "us-east4"
repo_location = "us"
repo_name     = "zsynergy"

# Firestore (default) DB lives in the nam5 multi-region — IMMUTABLE, do not change.
firestore_location = "nam5"
sa_prefix          = "zsds-sa"

# ─── VPC & Networking ──────────────────────────────────────────────────────
vpc_name                = "aeromontek-vpc"
springboot_subnet_cidr  = "10.10.0.0/24"
classifier_subnet_cidr  = "10.10.1.0/24"
private_svc_subnet_cidr = "10.10.2.0/24"

# ─── Cloud SQL ──────────────────────────────────────────────────────────────
cloud_sql_instance_name = "zsynergy-pg"
cloud_sql_database      = "zsynergy"
cloud_sql_user          = "zsynergy"
cloud_sql_tier          = "db-g1-small"
cloud_sql_version       = "POSTGRES_16"

# ─── Storage Buckets ────────────────────────────────────────────────────────
documents_bucket_name = "zsynergy-documents"
uploads_bucket_name   = "zsynergy-uploads"

# ─── Artifact Registry Cleanup (FinOps) ─────────────────────────────────
# STARTUP-SAFE: keeps 20 most-recent + deletes only UNTAGGED >30d. Never
# deletes a tagged image. Keep dry_run=true until the pre-enforcement digest
# audit (scripts/finops/audit-inuse-digests.sh) confirms no in-use digest is
# in the delete set, THEN flip to false and apply.
ar_cleanup_keep_count          = 20
ar_cleanup_untagged_older_than = "2592000s" # 30d
ar_cleanup_dry_run             = true
manage_aeromontek_api_repo     = true
aeromontek_api_repo_location   = "us-east4"

# ─── Component Toggles ───────────────────────────────────────────────────
enable_artifact_registry  = true
enable_frontend           = true
enable_springboot         = true
enable_classifier         = true
enable_firebase_functions = true
enable_eventarc           = true
enable_cloudbuild_trigger = false

# ─── Container Images (update after Cloud Build) ────────────────────────
springboot_image = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-api:latest"
classifier_image = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-classifier:latest"

# ─── Cloud Run — Spring Boot ─────────────────────────────────────────────
# memory/concurrency corrected 2026-10-01 (Copilot review, PR #23): these two
# values were still the pre-mitigation 1/40 despite variables.tf's own
# defaults being bumped to 2/10 to "match an OOM mitigation already applied
# directly to the live Cloud Run service" — since main.tf applies with
# `-var-file="vars/zsynergy.tfvars"`, THIS file's values are what actually
# govern an apply, not the variable defaults. The springboot service itself
# carries `lifecycle.ignore_changes = all` (main.tf, "managed by
# deploy_gcp.sh"), so day-to-day applies were not silently reverting the live
# mitigation — but a stale value here was still wrong-by-construction and
# would bite the moment that ignore_changes block is ever removed or the
# resource recreated from scratch.
springboot_service_name  = "aeromontek-api"
springboot_cpu           = "1"
springboot_memory        = 2
springboot_concurrency   = 10
springboot_min_instances = 0
springboot_max_instances = 10

# ─── Cloud Run — Classifier ──────────────────────────────────────────────
classifier_service_name  = "aeromontek-classifier"
classifier_cpu           = "2"
classifier_memory        = 2
classifier_concurrency   = 5
classifier_min_instances = 0
classifier_max_instances = 10

# ─── Monitoring & Alerts ────────────────────────────────────────────────
# Activates DLQ depth alerts in monitoring.tf. Empty list = no alerts.
alert_email_recipients = ["sales-zsds@zsds.io", "chandra@vxlllc.com"]

# ─── Cloud Build Trigger (optional) ──────────────────────────────────────
github_owner  = "zsds"
github_repo   = "gcp-builds"
github_branch = "main"
