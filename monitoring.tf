# =============================================================================
# monitoring.tf — Cloud Monitoring notification channels + alert policies
# =============================================================================
# Wires alert policies for:
#   - DLQ depth > threshold sustained > window  (per DLQ topic)
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
