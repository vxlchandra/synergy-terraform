# =============================================================================
# monitoring.tf — Cloud Monitoring notification channels + alert policies
# =============================================================================
# Wires alert policies for:
#   - DLQ depth > threshold sustained > window  (per DLQ topic)
#   - SYN-1802: ingestion-delivery canary absence + passive write/invocation
#     divergence (onIngestionActivated silently not firing)
#
# Channels are derived from var.alert_email_recipients. If that list is empty,
# no notification channels and no alert policies are created (zero-cost
# pass-through, useful for ephemeral / dev environments).
#
# Reference: docs/CLOUD_READY_DESIGN.md §7.2 + §13.3 + §14 finding #10.
# =============================================================================

# Email notification channels — one per recipient
resource "google_monitoring_notification_channel" "alert_email" {
  for_each     = toset(var.alert_email_recipients)
  project      = var.project_id
  display_name = "AeroMontek alerts → ${each.key}"
  type         = "email"
  labels = {
    email_address = each.key
  }

  user_labels = {
    app       = "aeromontek"
    component = "alerting"
  }
}

# DLQ depth alert — fires when undelivered messages remain > threshold for window.
# One policy per DLQ topic. Skipped when recipients list is empty.
resource "google_monitoring_alert_policy" "dlq_depth" {
  for_each     = length(var.alert_email_recipients) > 0 ? toset(var.dlq_topic_names) : toset([])
  project      = var.project_id
  display_name = "DLQ depth > ${var.alert_dlq_depth_threshold} — ${each.key}"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Undelivered messages on ${each.key}"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\"",
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=monitoring.regex.full_match(\".*${each.key}.*\")",
      ])
      duration        = "${var.alert_dlq_window_seconds}s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_dlq_depth_threshold

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [
    for c in google_monitoring_notification_channel.alert_email : c.id
  ]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content = join("\n", [
      "DLQ topic *${each.key}* has accumulated more than ${var.alert_dlq_depth_threshold} undelivered messages for ${var.alert_dlq_window_seconds}s.",
      "",
      "Runbook: docs/RUNBOOK.md → DLQ growing.",
      "Design: docs/CLOUD_READY_DESIGN.md §7.2 + §11.3.",
    ])
    mime_type = "text/markdown"
  }

  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }

  depends_on = [google_pubsub_topic.topics]
}

# =============================================================================
# SYN-1802 — ingestion-delivery liveness canary + passive divergence monitor
# =============================================================================
# The 2026-08-22 to 09-01 incident had onIngestionActivated (a Firebase v2
# Firestore trigger — runs on Cloud Run, logs under resource.type=
# "cloud_run_revision", NOT "cloud_function") silently stop firing for 9
# days. It produced ZERO application-level error logs, so every alert above
# (all error-rate/depth based) would never have caught it. Two independent
# signals close that blind spot:
#
#   1. Canary (absence alert): functions/src/scheduled/ingestionCanaryCron.ts
#      writes a fresh, uniquely-tagged, non-customer activation every 15
#      minutes. onIngestionActivated acknowledges it (before reaching any
#      real seeding logic) by logging INGESTION_CANARY_ACK_LOG_MESSAGE
#      (functions/src/utils/activeIngestions.ts). If that log goes silent
#      longer than the canary's own interval plus a grace period, the
#      trigger has stopped acknowledging — page.
#
#   2. Passive divergence (threshold alert): every real active_ingestions
#      write goes through the SAME audited helper
#      (writeActiveIngestion, activeIngestions.ts), which logs
#      ACTIVE_INGESTION_WRITE_LOG_MESSAGE before the write. onIngestionActivated
#      logs INGESTION_ACTIVATION_INVOKED_LOG_MESSAGE unconditionally, before
#      any early return, on every invocation. If writes keep happening but
#      invocations don't, delivery itself is broken — a signal that does not
#      depend on the trigger's own execution to exist, unlike log lines
#      emitted only ON invocation.
#
# 2026-10-03 CORRECTION — two of these three metrics never received a point.
# Where a functions log line lands depends on the LOGGER, not the runtime:
#   getLogger() (winston + LoggingWinston, functions/src/logger.ts)
#     -> resource.type="cloud_function", resource.labels.function_name=<lower>
#   firebase-functions/logger
#     -> resource.type="cloud_run_revision", resource.labels.service_name=<lower>
# INGESTION_CANARY_ACK_LOG_MESSAGE and ACTIVE_INGESTION_WRITE_LOG_MESSAGE are
# logged through getLogger() (activeIngestions.ts), so filtering them on
# cloud_run_revision matched nothing: syn1802_ingestion_canary_ack and
# syn1802_active_ingestion_writes had ZERO points in the 30 days to
# 2026-10-03 while Cloud Logging held 96 canary acks per day (all
# cloud_function) and 674 writes in 7 days (all cloud_function). With no
# first point, the canary MetricAbsence policy never armed, and the divergence
# query's `filter writes > 0` never passed — both alerts were silently inert.
# INGESTION_ACTIVATION_INVOKED_LOG_MESSAGE is logged through
# firebase-functions/logger (ingestionTrigger.ts) and DOES land on
# cloud_run_revision (882 in 7 days) — that metric is correct and unchanged.
#
# NOT validated by `terraform plan` alone: the query below is HCL-syntax-
# checked, not GCP-semantically validated (that requires a real `terraform
# apply` against a live project, out of scope for this session per this
# repo's own CLAUDE.md — apply requires an authorised operator). Verify the
# query against real log-based-metric data after applying.

resource "google_logging_metric" "active_ingestion_writes" {
  count   = length(var.alert_email_recipients) > 0 ? 1 : 0
  project = var.project_id
  name    = "syn1802_active_ingestion_writes"

  # Deliberately NOT scoped to one resource.labels.service_name: real writes
  # originate from several functions (generateDemoProjectCallable,
  # neverSeededReconcilerCron, rerunProjectCallable,
  # forceStartIngestionCallable, ingestionCanaryCron) — every one of them
  # goes through writeActiveIngestion, so the message text alone identifies
  # the event.
  # Both resource types: writeActiveIngestion (activeIngestions.ts) logs via
  # getLogger() -> cloud_function; seedingStore.checkpointAndContinue logs the
  # same message via firebase-functions/logger -> cloud_run_revision.
  filter = join("\n", [
    "(resource.type=\"cloud_function\" OR resource.type=\"cloud_run_revision\")",
    "jsonPayload.message=\"active_ingestions activation write issued\"",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "ingestion_activation_invocations" {
  count   = length(var.alert_email_recipients) > 0 ? 1 : 0
  project = var.project_id
  name    = "syn1802_ingestion_activation_invocations"

  # Scoped to the one function this line is logged from — resource.type
  # MUST be cloud_run_revision (trap 7): a filter against "cloud_function"
  # returns near-empty results that look exactly like "confirmed zero
  # invocations", which is the same false negative that already happened
  # twice in the real incident investigation.
  filter = join("\n", [
    "resource.type=\"cloud_run_revision\"",
    "resource.labels.service_name=\"oningestionactivated\"",
    "jsonPayload.message=\"onIngestionActivated invoked\"",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "ingestion_canary_ack" {
  count   = length(var.alert_email_recipients) > 0 ? 1 : 0
  project = var.project_id
  name    = "syn1802_ingestion_canary_ack"

  # getLogger() -> cloud_function (see the 2026-10-03 correction above).
  filter = join("\n", [
    "resource.type=\"cloud_function\"",
    "resource.labels.function_name=\"oningestionactivated\"",
    "jsonPayload.message=\"ingestion canary acknowledged\"",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Acceptance criterion 1: "assert a correlated onIngestionActivated
# invocation lands within a bounded window; missing acknowledgement pages
# on-call." MetricAbsence is the correct built-in tool for this — not a
# hand-rolled "did my previous run get acked" check in application code.
resource "google_monitoring_alert_policy" "ingestion_canary_missing_ack" {
  count        = length(var.alert_email_recipients) > 0 ? 1 : 0
  project      = var.project_id
  display_name = "Ingestion delivery canary — no acknowledgement"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "No ingestion canary ack received"

    condition_absent {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.ingestion_canary_ack[0].name}\"",
        "resource.type=\"cloud_function\"",
      ])
      duration = "${var.alert_ingestion_canary_absence_window_seconds}s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = [
    for c in google_monitoring_notification_channel.alert_email : c.id
  ]

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    content = join("\n", [
      "**Trigger not firing at all** (distinct from trigger firing but throwing — that is covered by ordinary error-rate alerting).",
      "",
      "ingestionCanaryCron writes a fresh activation every 15 minutes; onIngestionActivated should acknowledge it immediately. No acknowledgement for ${var.alert_ingestion_canary_absence_window_seconds}s means the trigger has stopped firing — the exact failure mode of the 2026-08-22 to 09-01 incident, which produced zero error logs.",
      "",
      "First check: `gcloud functions logs read onIngestionActivated --project=${var.project_id}` The ack line itself is a winston log: resource.type=cloud_function, function_name=oningestionactivated, logName winston_log. The trigger's own invocation line is on resource.type=cloud_run_revision, service_name=oningestionactivated. Check both.",
      "",
      "**Operational caveat (found by Codex review, not fixable in HCL alone):** `MetricAbsence` only opens once the underlying time series has received at least one point. If onIngestionActivated is ALREADY broken at the moment this policy is first applied, the ack metric never gets its first data point and this condition never fires — silence at deploy time is not proof of health. After applying, manually confirm at least one real acknowledgement lands (wait ~15-20 min, then check the syn1802_ingestion_canary_ack metric or this policy's own incident history) before trusting this alert as a live safety net.",
    ])
    mime_type = "text/markdown"
  }

  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }

  depends_on = [google_logging_metric.ingestion_canary_ack]
}

# Acceptance criterion 2: passive monitor comparing real write volume against
# real invocation volume over a rolling window, independent of the canary's
# fixed cadence (catches a PARTIAL delivery-rate degradation the canary might
# miss between its own 15-minute checks).
resource "google_monitoring_alert_policy" "ingestion_delivery_divergence" {
  count        = length(var.alert_email_recipients) > 0 ? 1 : 0
  project      = var.project_id
  display_name = "Ingestion delivery divergence — writes outpacing invocations"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "active_ingestions writes sustained ahead of onIngestionActivated invocations"

    # 2026-10-03: rewritten from MQL to PromQL. After the correction above the
    # writes metric has series on cloud_function (and, for seeder
    # continuations, cloud_run_revision) while invocations are on
    # cloud_run_revision only; MQL's `fetch <resource> :: <metric>` is
    # per-resource-type, PromQL's sum() is not. Semantics preserved from the
    # dual-reviewed MQL: both sides collapsed to one series, a missing
    # invocations side counts as 0 (`or vector(0)`, the outer_join 0
    # equivalent — the real delivery gap has NO invocation points at all), and
    # no writes means no evaluation (division by an empty vector yields no
    # sample, the old `filter writes > 0`).
    condition_prometheus_query_language {
      query = join("", [
        "(sum(rate(logging_googleapis_com:user_${google_logging_metric.active_ingestion_writes[0].name}[${var.alert_ingestion_divergence_window_seconds}s]))",
        " - (sum(rate(logging_googleapis_com:user_${google_logging_metric.ingestion_activation_invocations[0].name}[${var.alert_ingestion_divergence_window_seconds}s])) or vector(0)))",
        " / sum(rate(logging_googleapis_com:user_${google_logging_metric.active_ingestion_writes[0].name}[${var.alert_ingestion_divergence_window_seconds}s]))",
        " > ${var.alert_ingestion_divergence_ratio_threshold}",
      ])
      duration            = "${var.alert_ingestion_divergence_window_seconds}s"
      evaluation_interval = "60s"
    }
  }

  notification_channels = [
    for c in google_monitoring_notification_channel.alert_email : c.id
  ]

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    content = join("\n", [
      "**Trigger not firing at all** (distinct from trigger firing but throwing — that is covered by ordinary error-rate alerting).",
      "",
      "active_ingestions writes are outpacing onIngestionActivated invocations by more than ${var.alert_ingestion_divergence_ratio_threshold * 100}% over a ${var.alert_ingestion_divergence_window_seconds}s window — real activations are landing but the trigger is not (fully) processing them. This is the same failure class the canary alert catches, from the real-traffic side rather than the synthetic side, so it can catch a PARTIAL delivery-rate degradation between the canary's own 15-minute checks.",
      "",
      "First check: invocations are on resource.type=cloud_run_revision, service_name=oningestionactivated (firebase-functions/logger); writes are winston lines on resource.type=cloud_function (getLogger). See the 2026-10-03 correction at the top of this section.",
    ])
    mime_type = "text/markdown"
  }

  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }

  depends_on = [
    google_logging_metric.active_ingestion_writes,
    google_logging_metric.ingestion_activation_invocations,
  ]
}
