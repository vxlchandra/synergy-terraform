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
# NOT validated by `terraform plan` alone: the MQL query below is HCL-syntax-
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
  filter = join("\n", [
    "resource.type=\"cloud_run_revision\"",
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

  filter = join("\n", [
    "resource.type=\"cloud_run_revision\"",
    "resource.labels.service_name=\"oningestionactivated\"",
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
        "resource.type=\"cloud_run_revision\"",
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
      "First check: `gcloud functions logs read onIngestionActivated --project=${var.project_id}` (or Cloud Run revision logs, resource.type=cloud_run_revision, service_name=oningestionactivated — NOT resource.type=cloud_function, see trap 7 in this repo's memory).",
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

    condition_monitoring_query_language {
      query = join("\n", [
        "fetch cloud_run_revision",
        "| { metric 'logging.googleapis.com/user/${google_logging_metric.active_ingestion_writes[0].name}'",
        "  ; metric 'logging.googleapis.com/user/${google_logging_metric.ingestion_activation_invocations[0].name}' }",
        "| align rate(${var.alert_ingestion_divergence_window_seconds}s)",
        "| every ${var.alert_ingestion_divergence_window_seconds}s",
        "| join",
        "| value [writes: val(0), invocations: val(1), gap_ratio: (val(0) - val(1)) / val(0)]",
        "| condition gap_ratio.gap_ratio > ${var.alert_ingestion_divergence_ratio_threshold} '1'",
      ])
      duration = "${var.alert_ingestion_divergence_window_seconds}s"
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
      "First check: `gcloud functions logs read onIngestionActivated --project=${var.project_id}` (resource.type=cloud_run_revision, service_name=oningestionactivated — NOT resource.type=cloud_function, see trap 7 in this repo's memory).",
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
