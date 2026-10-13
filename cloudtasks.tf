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
  # to Box. This is kept well under Cloud Run's springboot_concurrency (10)
  # × springboot_max_instances (10) = ~100 request slots (lowered from 40 as
  # part of the 2026-09-26 OOM mitigation — see zsynergy.tfvars), and
  # deliberately modest relative to Cloud NAT capacity and Box's own
  # per-app rate limits, so a large transfer fan-out can't starve either.
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

# Separate queue for discover-folder tasks, split off drive-file-transfers
# 2026-09-24. A discover-folder task is one cheap Box/Drive metadata list
# call; a process-file task streams actual file bytes. Sharing one queue
# meant a massive folder's tree discovery competed with its own in-flight
# downloads for the same rate_limits budget, so downloads could starve
# remaining discovery -- the Transfer Center UI's file counts stalled behind
# whatever was already downloading instead of the tree finishing enumeration
# quickly. Split so each can be tuned against its own real cost: discovery
# is metadata-only and can run closer to Box's published per-user rate limit
# (1000 req/min ≈ 16.6/s, verified against developer.box.com 2026-09-24)
# than the existing transfer queue's more conservative default.
#
# INCIDENT (2026-09-25): the original "drive-file-discovery" queue was
# deleted at 19:14:52 UTC the same day (audit log: google.cloud.tasks.v2.
# CloudTasks.DeleteQueue, principal chandra@vxlllc.com — almost certainly an
# in-session gcloud action, not a deliberate deprovision), breaking every
# Box/Drive folder import with NOT_FOUND. A "-v2" rename was considered at
# the time (Cloud Tasks blocks recreating a queue under the same name for
# ~7 days after deletion) but was NOT carried through: both the live queue
# and the app's default (application.yaml's
# CLOUD_TASKS_DISCOVERY_QUEUE:drive-file-discovery, CloudTasksPublisher.java)
# use the plain name — confirmed 2026-10-01 via `gcloud tasks queues
# describe drive-file-discovery` (RUNNING) and Terraform state, after this
# resource was found orphaned from a divergent branch and recovered. Do not
# reintroduce "-v2" for this queue without updating the app default too.
#
# Name/location MUST match QueueName.of(projectId, location, <name>) as
# resolved by app.cloud-tasks.discovery-queue in CloudTasksPublisher.java,
# same location var as drive-file-transfers.
resource "google_cloud_tasks_queue" "drive_file_discovery" {
  name     = "drive-file-discovery"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.required_apis["cloudtasks.googleapis.com"]]

  rate_limits {
    max_dispatches_per_second = var.discovery_queue_max_dispatches_per_second
    max_concurrent_dispatches = var.discovery_queue_max_concurrent_dispatches
  }

  # Same reasoning as drive_file_transfers.retry_config above: must stay
  # >= app.transfer.max-attempts so the app's own T24 retry/DLQ
  # classification is always what terminates a task, never the queue.
  retry_config {
    max_attempts  = var.discovery_queue_max_attempts
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 4
  }
}

# Provisions the project-deletion queue used by CloudTasksPublisher.java's
# enqueueProjectDeletion (2026-09-28) — moves ProjectDeletionAdminService's
# GCS+Firestore+Postgres cascade off the admin DELETE request's own thread.
# See variables.tf's project_deletion_queue_* for the full incident context
# and why this MUST be applied before the app code that references it ships.
#
# Named -v2: the original "project-deletion" queue was destroyed within an hour of
# creation by a `terraform apply` run from a checkout that predated this resource —
# Terraform saw it in remote state but missing from that stale config and destroyed
# it as drift correction. Cloud Tasks then blocks recreating a queue under the same
# name for up to 7 days (same failure mode as the 2026-09-25 drive-file-discovery
# incident below). Always run `terraform plan` against a freshly-pulled `develop`
# before apply — never from an older branch/worktree — to avoid repeating this.
resource "google_cloud_tasks_queue" "project_deletion" {
  name     = "project-deletion-v2"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.required_apis["cloudtasks.googleapis.com"]]

  rate_limits {
    max_dispatches_per_second = var.project_deletion_queue_max_dispatches_per_second
    max_concurrent_dispatches = var.project_deletion_queue_max_concurrent_dispatches
  }

  retry_config {
    max_attempts  = var.project_deletion_queue_max_attempts
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 4
  }
}
