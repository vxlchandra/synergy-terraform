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
# WHY NOT A RESOURCE EDIT: `google_cloud_run_v2_service.classifier` in main.tf and the live
# prod service have a TWO-WAY drift (the classifier is deployed IMPERATIVELY via
# cloudbuild.yaml `gcloud run deploy`, so terraform is not the deploy source of truth):
#   * The TF resource is actually a FULLER config than prod runs — it ALREADY defines DB
#     connectivity env (DB_HOST / DB_NAME / DB_USER / CLOUD_SQL_CONNECTION_NAME + the
#     aeromon-db-password secret) plus PUSH_* / CORS_ORIGINS / CHROMA_SNAPSHOT_BUCKET /
#     FLOW_CONTROL_MAX_MESSAGES / AUTO_CREATE_PUBSUB_RESOURCES that prod's current revision
#     does NOT have. It has 5 of 6 runtime secrets (openai/gemini/hf/firebase-admin/db-password).
#   * It is MISSING vs prod: INTERNAL_API_SECRET (NOT in var.secret_names — needs adding +
#     an import) and GCP_REGION.
# So `terraform apply` on this resource would ADD a lot of config to prod AND DROP
# INTERNAL_API_SECRET (breaking functions↔classifier auth) + GCP_REGION. It is NOT apply-safe.
# Reconcile with `terraform plan` against prod state (decide authoritative config; add
# INTERNAL_API_SECRET to var.secret_names via import; confirm zero-diff) BEFORE any apply.
# TF already INTENDS the Cloud SQL DB env — the gap is that it uses DB_HOST-style env, while
# the hybrid engine reads DATABASE_URL (config._req). Reconcile that too. Until then the
# classifier is imperatively managed; the flip wiring goes on via `gcloud run services update`
# (see the Phase B runbook), and prod-classifier snapshot is scratchpad/prod-classifier-full.json.
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
#       # Graph-source mirror-write (classifier PR #93, flag-gated OFF in code).
#       # When "true", pipeline.orchestrator.run_document best-effort upserts each
#       # Layer-2 ExtractionRecord into the (tenant,project)-scoped `extractions`
#       # table so graphsvc can rebuild a scope's derived AGE graph from Cloud SQL
#       # (POST /graph/build {tenant,project}). SET ONLY once graphsvc is deployed
#       # (enable_graphsvc=true) AND graph population is intended — it writes
#       # customer-doc-derived structured data (msn/serials/fields) into Cloud SQL
#       # (stays in-GCP, no AI provider). Omit the env entirely to keep it off.
#       env { name = "GRAPH_SOURCE_WRITE" value = "true" }
#     }
#   }
#
# The classifier SA already has roles/cloudsql.client (google_project_iam_member.classifier_cloudsql).
# db.py supports the unix_sock URL form (PR #92). CLASSIFIER_ENGINE stays unset until the flip.
# GRAPH_SOURCE_WRITE stays unset until graphsvc is live and graph population is wanted; it can be
# toggled imperatively at that point via `gcloud run services update ... --update-env-vars`.
