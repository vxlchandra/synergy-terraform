# MIT License - Copyright (c) 2026 Z-Score Data Systems LLC.
# =============================================================================
# observability_stall_alerts.tf — stall / starvation alerting + request-log sink
# =============================================================================
# Two independent, default-OFF switches:
#
#   var.enable_job_health_alerting   log-based metrics + alert policies for
#                                    stalls (job-health detector, ingestion
#                                    stagnation reconciler) and resource
#                                    starvation (Pub/Sub age, Cloud Run / Cloud
#                                    SQL / Firestore saturation, rate limiter,
#                                    Cloud Tasks backlog). Also requires
#                                    var.alert_email_recipients to be non-empty,
#                                    same as monitoring.tf.
#   var.enable_request_log_sink_v2   a us-east4, PARTITIONED BigQuery dataset +
#                                    log sink covering every Cloud Run service
#                                    the 2026-05-11 sink (aeromon-cloud-run-
#                                    requests, api + classifier only, US,
#                                    date-sharded, not in terraform) misses.
#
# ─── THE enable_* DELETE TRAP — read before applying ────────────────────────
# terraform.tfvars is gitignored, so a clean checkout evaluates these flags at
# their DEFAULT. Once applied with a flag = true, a later plan from a clean
# checkout plans count = 0 and proposes DESTROYING what you applied (this
# deleted-in-plan the live graphsvc service on 2026-07-31). Therefore:
#   1. Applying either flag MUST flip its default to true IN THE SAME CHANGE.
#   2. The two data-bearing resources (dataset, sink) carry
#      lifecycle.prevent_destroy, so a forgotten flip is a hard plan error,
#      not a silent deletion. Metrics and policies do not (losing one is
#      recoverable and prevent_destroy would block intentional tuning that
#      requires replacement).
#
# ─── WHERE FUNCTIONS LOGS ACTUALLY LAND (verified 2026-10-03) ────────────────
# The resource type depends on the LOGGER, not on the runtime:
#   getLogger() (winston + LoggingWinston, functions/src/logger.ts)
#     -> resource.type="cloud_function", logName .../winston_log,
#        resource.labels.function_name=<lowercased export name>,
#        extra fields under jsonPayload.metadata.*
#   firebase-functions/logger
#     -> resource.type="cloud_run_revision", logName run.googleapis.com/stdout,
#        resource.labels.service_name=<lowercased export name>
# The job-health detector and the stagnation reconciler both use getLogger(),
# so their metrics below filter on cloud_function + jsonPayload.metadata.*.
#
# Every threshold below cites the production measurement it was derived from
# (Cloud Monitoring / BigQuery, 30-day window ending 2026-10-03, unless noted).
# NOT validated by apply: like monitoring.tf, these are HCL-checked only. The
# PromQL and filters must be confirmed against live data after an authorised
# apply.
# =============================================================================

locals {
  job_health_alerting_on = var.enable_job_health_alerting && length(var.alert_email_recipients) > 0
  job_health_count       = local.job_health_alerting_on ? 1 : 0

  email_channel_ids = [for c in google_monitoring_notification_channel.alert_email : c.id]
  # Critical policies also go to any pager/SMS channel ids supplied (none exist
  # today — all 7 live channels are email; adding one is an owner decision).
  critical_channel_ids = concat(local.email_channel_ids, var.alert_pager_channel_ids)

  runbook = "Runbook: arch-obs-standard.md (stall/starvation platform standard; to be published under Synergy-Architecture-And-Design docs/platform/)"

  request_log_services_filter = join(" OR ", [
    for s in var.request_log_services : "resource.labels.service_name=\"${s}\""
  ])
}

# =============================================================================
# 1. STALLS — log-based metrics
# =============================================================================

# Emitted once per detector run, clean or not (jobHealthDetector.ts summary line).
resource "google_logging_metric" "job_health_detector_runs" {
  count   = local.job_health_count
  project = var.project_id
  name    = "job_health_detector_runs"
  filter = join("\n", [
    "resource.type=\"cloud_function\"",
    "resource.labels.function_name=\"jobhealthdetectorcron\"",
    "jsonPayload.message=\"Job health detector run complete\"",
  ])
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Runs that found at least one critical finding (stalled / deadline_exceeded /
# lease_expired / continuation_lost).
resource "google_logging_metric" "job_health_critical_runs" {
  count   = local.job_health_count
  project = var.project_id
  name    = "job_health_critical_runs"
  filter = join("\n", [
    "resource.type=\"cloud_function\"",
    "resource.labels.function_name=\"jobhealthdetectorcron\"",
    "jsonPayload.message=\"Job health detector run complete\"",
    "jsonPayload.metadata.criticalFindings>0",
  ])
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# ingestionStagnationReconciler.ts has logged this since SYN-1803 with NO
# alert policy. Measured: 347 lines across 3 projects in the 7 days to
# 2026-10-03, paging no one (one of them was the IBA project, 8.6 h stale).
resource "google_logging_metric" "ingestion_stagnation_detected" {
  count   = local.job_health_count
  project = var.project_id
  name    = "ingestion_stagnation_detected"
  filter = join("\n", [
    "resource.type=\"cloud_function\"",
    "resource.labels.function_name=\"ingestionstagnationreconcilercron\"",
    "jsonPayload.message=\"Ingestion progress stagnation detected\"",
  ])
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# RateLimitFilter.java logs "[rate-limit] client=... tier=... path=..." as a
# plain-text line (textPayload, not JSON) before returning 429.
resource "google_logging_metric" "api_rate_limit_rejections" {
  count   = local.job_health_count
  project = var.project_id
  name    = "api_rate_limit_rejections"
  filter = join("\n", [
    "resource.type=\"cloud_run_revision\"",
    "resource.labels.service_name=\"aeromontek-api\"",
    "textPayload:\"[rate-limit]\"",
  ])
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# =============================================================================
# 2. STALLS — alert policies
# =============================================================================

resource "google_monitoring_alert_policy" "job_health_critical" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Job stalled — job-health detector critical finding"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Detector run reported >= 1 critical finding"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.job_health_critical_runs[0].name}\"",
        "resource.type=\"cloud_function\"",
      ])
      # Each detector run is one sample; the finding itself already sits
      # 4x heartbeat-interval past the last proof of life, so no extra wait.
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.critical_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "A long-running job stopped proving liveness (heartbeat older than 4x its own interval), passed its deadline, or a seeding lease/continuation was abandoned.",
      "",
      "First check: BigQuery `analytics.v_job_health_findings` (latest rows) or Cloud Logging `resource.type=\"cloud_function\" resource.labels.function_name=\"jobhealthdetectorcron\" jsonPayload.message=\"Job health finding\"` — each line names source, jobType, subjectId, finding and ageMs.",
      "The detector is report-only; nothing has been repaired automatically.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "critical"
  }
}

resource "google_monitoring_alert_policy" "job_health_detector_absent" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Job-health detector silent — no run summary"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "No detector summary line"
    condition_absent {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.job_health_detector_runs[0].name}\"",
        "resource.type=\"cloud_function\"",
      ])
      # 4 missed 5-minute runs.
      duration = "1200s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "The stall detector itself has stopped reporting, so stalls are currently undetected.",
      "MetricAbsence only arms after the first data point: this stays silent until JOB_HEALTH_DETECTOR_ENABLED=true has produced at least one run. Confirm one summary line lands after enabling.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

resource "google_monitoring_alert_policy" "ingestion_stagnation" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Ingestion stagnation — active project past its size-tiered SLA"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Stagnation reconciler reported a stagnant project"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.ingestion_stagnation_detected[0].name}\"",
        "resource.type=\"cloud_function\"",
      ])
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        # The reconciler runs every 30 minutes.
        alignment_period   = "1800s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "7200s"
  }
  documentation {
    content = join("\n", [
      "An ACTIVE project has made no progress past its size-tiered SLA (30 min / 2 h / 6 h by file count, ingestionStagnationReconciler.ts STAGNATION_SLA_TIERS).",
      "Each log line carries projectId, staleForMs, slaMs and a recoveryAction. reconcileStaleProjectsCron may already have attempted a counter repair (unless PROJECT_RECONCILE_DISABLED).",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

# =============================================================================
# 3. STARVATION — alert policies on platform metrics
# =============================================================================

# Pub/Sub delivery starvation on every ACTIVE subscription.
# Evidence (hourly max of oldest_unacked_message_age, 30 d): request-python-sub
# p95 63 s / max 10,502 s; classification-wake-push p95 116 s / max 2,365 s;
# every eventarc-* subscription p95 <= 1 s, max 6,646 s. 900 s is 7.7x the
# highest active-subscription p95 and matches the existing hand-made
# "Classifier queue stuck" policy's 900 s on request-python-sub.
# EXCLUDED (var.pubsub_starvation_excluded_subscription_regex): DLQ
# subscriptions (old messages are their normal state) and the two pull
# subscriptions with no consumer in any repo (result-springboot-sub,
# progress-firebase-sub: hourly-max backlog p50 6,196 / 4,862 messages, oldest
# up to 604,902 s) — an un-excluded rule would fire permanently on them.
resource "google_monitoring_alert_policy" "pubsub_starvation" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Pub/Sub starvation — oldest unacked message > ${var.alert_pubsub_oldest_unacked_seconds}s"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Oldest unacked message age on an active subscription"
    condition_prometheus_query_language {
      query = join("", [
        "max by (subscription_id) (",
        "pubsub_googleapis_com:subscription_oldest_unacked_message_age{",
        "monitored_resource=\"pubsub_subscription\",",
        "subscription_id!~\"${var.pubsub_starvation_excluded_subscription_regex}\"",
        "}) > ${var.alert_pubsub_oldest_unacked_seconds}",
      ])
      duration            = "600s"
      evaluation_interval = "60s"
    }
  }

  notification_channels = local.critical_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "A subscription's oldest unacknowledged message has been waiting longer than ${var.alert_pubsub_oldest_unacked_seconds}s for 10 minutes: its consumer is down, saturated, or rejecting (429/5xx) faster than Pub/Sub can retry.",
      "First check: the consumer service's request log for 429/5xx (BigQuery analytics_logs.v_request_latency_hourly), then its instance count against maxScale.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "critical"
  }
}

# Classifier starvation = saturated AND backlog aging. Either alone is normal:
# active instances hit maxScale (30) in ~1% of hours (hourly max p99 = 30,
# p95 = 11), and the backlog ages briefly during bursts (p95 63 s).
resource "google_monitoring_alert_policy" "classifier_starvation" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Classifier starvation — at max scale AND request backlog aging"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "Active classifier instances >= 90% of maxScale"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/container/instance_count\"",
        "resource.type=\"cloud_run_revision\"",
        "resource.labels.service_name=\"aeromontek-classifier\"",
        "metric.labels.state=\"active\"",
      ])
      duration        = "600s"
      comparison      = "COMPARISON_GT"
      threshold_value = floor(var.alert_classifier_max_scale * 0.9) - 0.5
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.service_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "Request subscription oldest unacked > 300s"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\"",
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=\"document-classification-request-python-sub\"",
      ])
      duration        = "600s"
      comparison      = "COMPARISON_GT"
      threshold_value = 300
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.critical_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "The classifier is pinned at maxScale while classification requests wait: throughput is capped, not failing. Raising maxScale only helps if Cloud SQL / provider quotas have headroom.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "critical"
  }
}

# API saturation per REVISION (summing revisions double-counts during a
# rollout). Evidence: active instances hourly max p99 = 7, max = 15 (summed
# across revisions) against maxScale 10.
resource "google_monitoring_alert_policy" "api_saturation" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "API saturation — aeromontek-api revision at >= 90% of maxScale"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Active instances per revision >= 90% of maxScale"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/container/instance_count\"",
        "resource.type=\"cloud_run_revision\"",
        "resource.labels.service_name=\"aeromontek-api\"",
        "metric.labels.state=\"active\"",
      ])
      duration        = "900s"
      comparison      = "COMPARISON_GT"
      threshold_value = floor(var.alert_api_max_scale * 0.9) - 0.5
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.revision_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "aeromontek-api is close to maxScale. Its Hikari pool is 14 per instance (application-cloudrun.yaml) against Cloud SQL max_connections 200, so scale-out headroom is also connection headroom — check Cloud SQL num_backends.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

# Firestore contention. Evidence (hourly ABORTED count, 30 d): p50 0,
# p95 2,144, p99 27,624 (~460/min); the 2026-09-28 / 09-30 contention storms
# ran 110,822-462,790/h (1,847-7,713/min). The ABORTED *ratio* does not
# separate storms from normal hours (p95 13.6% vs storm-hour 13.6%), so the
# threshold is an absolute rate just above the 30-day p99.
resource "google_monitoring_alert_policy" "firestore_contention" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Firestore contention — ABORTED > ${var.alert_firestore_aborted_per_minute}/min"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "ABORTED request rate"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"firestore.googleapis.com/api/request_count\"",
        "resource.type=\"datastore_request\"",
        "metric.labels.response_code=\"ABORTED\"",
      ])
      duration        = "900s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_firestore_aborted_per_minute / 60
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.critical_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "Transactions are being aborted on contention at storm level (the 2026-09-28 and 2026-09-30 ABORTED peaks were 110k-463k per hour). Look for a hot document written by many concurrent transactions (counters, job docs).",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "critical"
  }
}

# Memory pressure on the API. Evidence: hourly p99 of
# container/memory/utilizations p50 0.74, p95 0.85, p99 0.96, max 0.99.
resource "google_monitoring_alert_policy" "api_memory_pressure" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "API memory pressure — p99 utilization > ${var.alert_api_memory_utilization}"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "aeromontek-api memory utilization p99"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/container/memory/utilizations\"",
        "resource.type=\"cloud_run_revision\"",
        "resource.labels.service_name=\"aeromontek-api\"",
      ])
      duration        = "1800s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_api_memory_utilization
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.labels.revision_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "aeromontek-api has run above ${var.alert_api_memory_utilization} memory utilization (p99) for 30 minutes — the step before an OOM restart.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

# Rate-limiter rejections. Evidence (hourly 429 count on aeromontek-api,
# 30 d): 11 of 720 hours had any 429 at all; p95 0, p99 695, max 4,703 (the
# 2026-09-28 incident where RateLimitFilter starved Cloud Tasks callbacks).
resource "google_monitoring_alert_policy" "api_rate_limit_rejections" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "API rate limiter rejecting — > ${var.alert_api_rate_limit_rejections_per_15m} per 15 min"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "[rate-limit] rejections"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.api_rate_limit_rejections[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
      ])
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_api_rate_limit_rejections_per_15m
      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "RateLimitFilter is returning 429. Each log line names client, tier and path — a single internal client (Cloud Tasks, a scheduled sweep) being throttled starves a whole pipeline, as on 2026-09-28.",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

# Cloud Tasks backlog. Evidence (hourly max queue depth, 30 d):
# drive-file-transfers p95 0, p99 3,325, max 15,248; drive-file-discovery-v2
# p95 526, p99 2,558, max 2,653. Depth alone is not starvation, so the window
# is long (30 min) and the threshold sits above both queues' p99.
resource "google_monitoring_alert_policy" "cloud_tasks_backlog" {
  count        = local.job_health_count
  project      = var.project_id
  display_name = "Cloud Tasks backlog — queue depth > ${var.alert_cloud_tasks_depth} for 30 min"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Queue depth"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"cloudtasks.googleapis.com/queue/depth\"",
        "resource.type=\"cloud_tasks_queue\"",
      ])
      duration        = "1800s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_cloud_tasks_depth
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.email_channel_ids
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content = join("\n", [
      "A Cloud Tasks queue has held more than ${var.alert_cloud_tasks_depth} tasks for 30 minutes. Check task_attempt_count by response_code for the queue: 'unavailable' / 429 attempts mean the target is rejecting (see the rate-limiter alert).",
      local.runbook,
    ])
    mime_type = "text/markdown"
  }
  user_labels = {
    app       = "aeromontek"
    component = "alerting"
    severity  = "high"
  }
}

# =============================================================================
# 4. REQUEST-LOG SINK v2 — every Cloud Run service, us-east4, partitioned
# =============================================================================
# Volume (run.googleapis.com/request_count, 2026-09-26..10-02): 1,848,493
# requests across 81 services; the existing sink covers 365,590 (19.8%).
# Bytes/row measured on the existing tables: 711-770 B. All services:
# ~264k req/day x ~740 B ~= 195 MB/day ~= 5.9 GB/month. ASSUMED list prices
# (verify before apply): streaming ingestion ~$0.05/GB -> ~$0.30/month;
# active storage ~$0.02/GB-month -> ~$1.56/month at the 400-day steady state
# (~78 GB). The default service list (no Firebase Functions) is far smaller:
# api + classifier + App Hosting (zsynergy) + graphsvc + rastersvc = 408,495
# requests/7 d.

resource "google_bigquery_dataset" "request_logs" {
  count                           = var.enable_request_log_sink_v2 ? 1 : 0
  project                         = var.project_id
  dataset_id                      = var.request_log_dataset_id
  location                        = "us-east4" # same location as `analytics`, so the two can be JOINed
  description                     = "Cloud Run HTTP request logs (all covered services), partitioned. Sink: aeromon-cloud-run-requests-v2."
  default_partition_expiration_ms = var.request_log_retention_days * 86400000

  labels = {
    app        = "aeromontek"
    component  = "observability"
    managed-by = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_logging_project_sink" "cloud_run_requests_v2" {
  count       = var.enable_request_log_sink_v2 ? 1 : 0
  project     = var.project_id
  name        = "aeromon-cloud-run-requests-v2"
  description = "Cloud Run HTTP requests for every service in var.request_log_services (or all, when request_log_include_all_services). Partitioned tables, us-east4."
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.request_logs[0].dataset_id}"

  filter = var.request_log_include_all_services ? join("\n", [
    "resource.type=\"cloud_run_revision\"",
    "httpRequest.requestUrl:*",
    ]) : join("\n", [
    "resource.type=\"cloud_run_revision\"",
    "httpRequest.requestUrl:*",
    "(${local.request_log_services_filter})",
  ])

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_dataset_iam_member" "request_logs_sink_writer" {
  count      = var.enable_request_log_sink_v2 ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.request_logs[0].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.cloud_run_requests_v2[0].writer_identity
}
