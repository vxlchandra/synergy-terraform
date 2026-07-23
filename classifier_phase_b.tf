# Phase B infra for the classifier hybrid engine (created imperatively 2026-07-23,
# codified here). Gated on `enable_classifier`.

# ---------------------------------------------------------------------------
# Trained-head model artifact bucket — LEAST PRIVILEGE.
# The head is derived vectors + labels (governance-safe, no raw content) but a
# proprietary artifact: dedicated bucket, uniform access, public-access-prevention
# enforced, read granted ONLY to the classifier runtime SA (+ project admins).
# HEAD_PATH = gs://<this bucket>/trained_head_full.pkl
# ---------------------------------------------------------------------------
variable "classifier_models_bucket_name" {
  description = "Bucket for the trained-head model artifact (proprietary, least-privilege)."
  type        = string
  default     = "zsynergy-classifier-models"
}

resource "google_storage_bucket" "classifier_models" {
  count         = var.enable_classifier ? 1 : 0
  name          = var.classifier_models_bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = {
    component = "classifier"
    purpose   = "model-artifact"
  }
}

# Runtime read for the classifier SA only (no project-viewer, no public).
resource "google_storage_bucket_iam_member" "classifier_models_reader" {
  count  = var.enable_classifier ? 1 : 0
  bucket = google_storage_bucket.classifier_models[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.classifier[0].email}"
}

# ---------------------------------------------------------------------------
# Cloud SQL wiring for the classifier service (Phase B) — DOCUMENTED PATCH, not
# applied here.
#
# WHY NOT A RESOURCE EDIT: `google_cloud_run_v2_service.classifier` in main.tf is
# DRIFTED from prod (it does not define the 6 runtime secrets the live service has —
# DB_PASSWORD/OPENAI/GEMINI/HF/INTERNAL_API_SECRET/FIREBASE_ADMIN_SA_PATH — because the
# service is deployed imperatively via cloudbuild.yaml `gcloud run deploy`). Applying an
# edited classifier resource would CLOBBER those secrets. Reconcile the resource with prod
# FIRST (adopt the full env/secrets), THEN add the block below. Until then, the Cloud SQL
# wiring is applied imperatively at flip time (see the Phase B runbook).
#
# When reconciled, add to `google_cloud_run_v2_service.classifier` template:
#
#   template {
#     volumes {
#       name = "cloudsql"
#       cloud_sql_instance {
#         instances = ["${var.project_id}:${var.region}:${var.cloud_sql_instance_name}"]
#       }
#     }
#     containers {
#       volume_mounts {
#         name       = "cloudsql"
#         mount_path = "/cloudsql"
#       }
#       env { name = "CLOUD_SQL_INSTANCE"
#             value = "${var.project_id}:${var.region}:${var.cloud_sql_instance_name}" }
#       env { name = "DB_NAME" value = var.cloud_sql_database }   # "zsynergy"
#       env { name = "DB_USER" value = var.cloud_sql_user }       # "zsynergy"
#       # DATABASE_URL carries the password → source from a SECRET, never a plain value:
#       env {
#         name = "DATABASE_URL"
#         value_source { secret_key_ref {
#           secret  = "aeromon-classifier-database-url"   # create: postgresql://zsynergy:<pw>@/zsynergy?unix_sock=/cloudsql/<inst>/.s.PGSQL.5432
#           version = "latest"
#         } }
#       }
#     }
#   }
#
# The classifier SA already has roles/cloudsql.client (google_project_iam_member.classifier_cloudsql).
# db.py supports the unix_sock URL form (PR #92). CLASSIFIER_ENGINE stays unset until the flip.
