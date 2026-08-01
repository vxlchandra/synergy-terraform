# =============================================================================
# membership_reconcile_scheduler.tf — nightly membership drift detection
# =============================================================================
#
# ADR 0034 stage 1: report-only reconciliation of the membership LEDGER
# (PostgreSQL) against its projections (Firestore membership index) and the
# identity store (Firebase Auth).
#
# WHY CLOUD SCHEDULER AND NOT AN IN-PROCESS TIMER
# -----------------------------------------------
# aeromontek-api has no `minScale`, so it scales to zero. A Spring
# ScheduledExecutorService would appear configured and silently never fire when
# no instance is running — worse than having no reconciler, because it looks
# like detection exists.
#
# CADENCE
# -------
# Daily, not fortnightly. The scan is read-only over a few hundred rows and
# completes in seconds; the drift it detects is authorization outliving
# revocation, which must not be allowed to persist for two weeks. 04:40 UTC sits
# after the Functions-side reconciler (04:20) so the two do not overlap, and
# clear of the 03:15 ET purge window.
#
# The endpoint REPORTS and repairs nothing, so a duplicate or retried run is
# harmless — which is why retry_config is permitted to retry at all.

variable "enable_membership_reconciler" {
  description = "Create the nightly membership reconciliation Cloud Scheduler job (ADR 0034 stage 1)."
  type        = bool
  default     = true
}

variable "membership_reconcile_cron" {
  description = "Cron for membership drift detection. Daily — see the cadence note in this file before slowing it down."
  type        = string
  default     = "40 4 * * *"
}

resource "google_cloud_scheduler_job" "membership_reconcile" {
  count   = var.enable_membership_reconciler && var.enable_springboot ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = "membership-reconcile-nightly"

  description = "Nightly: report drift between the membership ledger (PostgreSQL), the Firestore index, and Firebase Auth (ADR 0034)"
  schedule    = var.membership_reconcile_cron
  time_zone   = "UTC"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "60s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.springboot[0].uri}/api/internal/reconcile/membership"

    headers = {
      "Content-Type" = "application/json"
    }

    # The Spring chain for /api/internal/reconcile/** requires a Google OIDC
    # service-account token; a Firebase user token is rejected. The audience must
    # be the bare Cloud Run origin — a path-suffixed audience fails validation.
    oidc_token {
      service_account_email = google_service_account.springboot[0].email
      audience              = google_cloud_run_v2_service.springboot[0].uri
    }
  }

  depends_on = [google_cloud_run_v2_service.springboot]
}

output "membership_reconcile_job" {
  description = "Nightly membership drift detection job name, or disabled."
  value       = var.enable_membership_reconciler && var.enable_springboot ? google_cloud_scheduler_job.membership_reconcile[0].name : "disabled"
}
