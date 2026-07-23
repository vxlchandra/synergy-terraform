# Nightly trained-head retrain trigger (P3 confirmation loop).
#
# Cloud Scheduler POSTs the classifier `/admin/retrain-head`; that endpoint refits the
# trained head from `confirmed_exemplars`, republishes it to the `gs://` HEAD_PATH, and
# hot-reloads the engine. Gated on `enable_classifier` and applied only at deploy
# sign-off. Server-side no-op until enough exemplars exist (train_and_save refuses
# < 4 examples / < 2 sections), so it is safe to enable early.
#
# Auth is two-layer, matching the platform's service-to-service calls to the classifier:
#   1. OIDC token (audience = classifier URL) via the classifier SA  -> Cloud Run IAM.
#   2. X-Internal-Secret header (var below)                          -> app require_internal_auth.

variable "classifier_retrain_cron" {
  description = "Cron schedule (UTC) for the nightly classifier trained-head retrain."
  type        = string
  default     = "0 7 * * *" # 07:00 UTC daily (low-traffic window)
}

variable "classifier_internal_secret" {
  description = <<-EOT
    App-level shared secret for the classifier require_internal_auth gate, sent as the
    X-Internal-Secret header by the retrain scheduler. Managed in Secret Manager and
    supplied at apply time; leave empty in dev. The OIDC token satisfies Cloud Run IAM;
    this satisfies the classifier's app-level auth.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# The scheduler's OIDC identity (classifier SA) must be allowed to invoke the classifier.
resource "google_cloud_run_v2_service_iam_member" "classifier_retrain_invoker" {
  count    = var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.classifier[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_cloud_scheduler_job" "classifier_retrain_head" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = "classifier-retrain-head-nightly"

  description = "Nightly: refit the classifier trained head from confirmed exemplars (P3 loop)"
  schedule    = var.classifier_retrain_cron
  time_zone   = "UTC"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "60s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.classifier[0].uri}/admin/retrain-head"

    headers = {
      "Content-Type"      = "application/json"
      "X-Internal-Secret" = var.classifier_internal_secret
    }

    body = base64encode(jsonencode({})) # all tenants; pass {"tenant": "..."} to scope

    oidc_token {
      service_account_email = google_service_account.classifier[0].email
      audience              = google_cloud_run_v2_service.classifier[0].uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service.classifier,
    google_cloud_run_v2_service_iam_member.classifier_retrain_invoker,
  ]
}
