# =============================================================================
# cloudtasks.tf — Cloud Tasks queues
# =============================================================================
# Provisions the "drive-file-transfers" queue used by the Spring Boot API's
# async transfer fan-out (source→GCS discover/process-file tasks). Prior to
# this file the queue existed only implicitly (created on first task-push
# with Cloud Tasks service defaults — ~500 dispatches/s, ~1000 concurrent
# dispatches), which is unbounded enough for a single large job to self-DDoS
# the caller's Box OAuth token and/or exhaust Cloud NAT ports. See T27 (C4).

# Name/location MUST match what the app addresses: Spring Boot builds
# QueueName.of(projectId, location, "drive-file-transfers") with location
# from CLOUD_TASKS_LOCATION (default "us-east4" — application.yaml:409).
# var.region defaults to "us-east4" (variables.tf) so this stays in sync.
resource "google_cloud_tasks_queue" "drive_file_transfers" {
  name     = "drive-file-transfers"
  location = var.region
  project  = var.project_id

  # Ensure the Cloud Tasks API is enabled before the queue is created (avoids a
  # transient first-apply "API not enabled" error). cloudtasks.googleapis.com is
  # in var.enabled_apis (variables.tf).
  depends_on = [google_project_service.required_apis["cloudtasks.googleapis.com"]]

  # Coherence: max_concurrent_dispatches bounds how many discover-folder /
  # process-file tasks run at once — each one holds a concurrent connection
  # to Box. This is kept well under Cloud Run's springboot_concurrency (40)
  # × springboot_max_instances (10) = ~400 request slots, and deliberately
  # modest relative to Cloud NAT capacity and Box's own per-app rate limits,
  # so a large transfer fan-out can't starve either.
  rate_limits {
    max_dispatches_per_second = var.transfer_queue_max_dispatches_per_second
    max_concurrent_dispatches = var.transfer_queue_max_concurrent_dispatches
  }

  # max_attempts must stay >= the app's app.transfer.max-attempts (default 5,
  # AppRuntimeProperties.Transfer.maxAttempts) so the app's own retry/DLQ
  # bookkeeping (T24 classification of exhausted vs. retryable) is always the
  # thing that terminates a task — the queue must never give up first.
  retry_config {
    max_attempts  = var.transfer_queue_max_attempts
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 4
  }
}
