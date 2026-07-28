# =============================================================================
# bigquery_extraction_cost.tf — Extraction cost model (per document → project →
#                               organization → company)
# =============================================================================
# 🔴 NOT APPLIED. Authored only. `terraform plan` / `bq query --dry_run` were
#    run; nothing was created in production.
#
# WHY THIS FILE EXISTS
# --------------------
# The existing `v_admin_*` / `v_biller_*` views in zsynergy:analytics were
# HAND-CREATED in the console and have NO definition anywhere in any repo. They
# cannot be reviewed, diffed or rebuilt. This file is the first BigQuery
# resource in this Terraform root and sets the pattern for the rest:
#
#   * SQL lives in a separate .sql file under sql/ (reviewable, lintable,
#     dry-runnable on its own) and is pulled in with templatefile().
#   * The dataset itself is a DATA SOURCE, not a managed resource — it already
#     exists and holds production data. Terraform must never be in a position to
#     replace or destroy it.
#   * Views are `google_bigquery_table` with a `view` block, per the task brief.
#
# SOURCE OF TRUTH
# ---------------
# Everything here reads `analytics.model_invocations_v1`, the table the
# classifier already feeds via Pub/Sub → Cloud Functions. No new ingestion path
# is introduced. The per-document cost fields (pageCount, engine, sieveAttempts,
# estimatedCostUsd, documentId, projectId, userId, organizationId) arrive inside
# the existing `metaJson` STRING column, because — verified read-only against
# production — that table has NO documentId column and no cost column:
#
#   bq show --schema zsynergy:analytics.model_invocations_v1
#   -> schemaVersion, kind, eventId, eventTs, receivedAt, sourceSystem, userId,
#      projectId, jobId, modelProvider, modelName, operation, promptTokens,
#      completionTokens, totalTokens, latencyMs, status, errorCode,
#      errorMessage, traceId, metaJson
#
# The Functions writer drops documentId
# (aeromontek-functions/functions/src/analytics/sinks/bigquery/
#  modelInvocation.bq.ts:20-22) even though the bootstrap DDL declares it
# (.../bigquery/bootstrap.ts:105-133). Promoting these to real columns is the
# proper fix and is tracked separately; parsing metaJson makes per-document cost
# attributable WITHOUT that change, and the views survive the promotion.
# =============================================================================

variable "analytics_dataset_id" {
  description = "BigQuery dataset holding the analytics event tables."
  type        = string
  default     = "analytics"
}

variable "extraction_cost_deletion_protection" {
  description = "Deletion protection for cost-model views/tables."
  type        = bool
  default     = true
}

# The dataset already exists and holds production data — read it, never manage
# it. A `google_bigquery_dataset` resource here would let a stray destroy take
# the warehouse with it.
data "google_bigquery_dataset" "analytics" {
  project    = var.project_id
  dataset_id = var.analytics_dataset_id
}

# -----------------------------------------------------------------------------
# 1. project → organization dimension
# -----------------------------------------------------------------------------
# 🔴 REQUIRED because `organizationId` is NOT available in the classifier. The
# Pub/Sub ClassificationRequest carries userId + projectId only
# (classifier/schema/classification_request_schema.py:26-28). The owning
# organization lives in Firestore `projects/{projectId}.organizationId`, written
# by aeromontek-functions (functions/src/project.ts:174) for NEW projects only —
# historical projects have no such field (functions/src/restrictions/
# countLimits.ts:307-310).
#
# So the organization rollup JOINS through this dimension rather than trusting a
# denormalised key on the event. Rows are written by Functions (a Firestore
# trigger on projects/{id}); Terraform owns the schema only. A project with no
# row here rolls up to the sentinel 'UNATTRIBUTED' — visible, never silently
# dropped from the company total.
resource "google_bigquery_table" "dim_project_organization" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "dim_project_organization"
  deletion_protection = var.extraction_cost_deletion_protection

  description = <<-EOT
    Project -> owning organization dimension. Populated by aeromontek-functions
    from Firestore projects/{id}.organizationId. Schema owned by Terraform.
    Required because the classifier has no organizationId on the request path.
  EOT

  schema = file("${path.module}/sql/dim_project_organization.schema.json")

  labels = {
    owner  = "platform"
    domain = "cost"
  }
}

# -----------------------------------------------------------------------------
# 2. Per-document extraction cost (the grain everything else rolls up from)
# -----------------------------------------------------------------------------
resource "google_bigquery_table" "v_extraction_cost_by_document" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "v_extraction_cost_by_document"
  deletion_protection = var.extraction_cost_deletion_protection

  description = "Per-document extraction cost, page count and OCR sieve outcome."

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/sql/v_extraction_cost_by_document.sql", {
      project_id = var.project_id
      dataset_id = data.google_bigquery_dataset.analytics.dataset_id
    })
  }
}

# -----------------------------------------------------------------------------
# 3. Rollups: project -> organization -> company
# -----------------------------------------------------------------------------
resource "google_bigquery_table" "v_extraction_cost_by_project_daily" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "v_extraction_cost_by_project_daily"
  deletion_protection = var.extraction_cost_deletion_protection

  description = "Daily extraction cost rolled up per project."

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/sql/v_extraction_cost_by_project_daily.sql", {
      project_id = var.project_id
      dataset_id = data.google_bigquery_dataset.analytics.dataset_id
    })
  }

  depends_on = [google_bigquery_table.v_extraction_cost_by_document]
}

resource "google_bigquery_table" "v_extraction_cost_by_organization_daily" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "v_extraction_cost_by_organization_daily"
  deletion_protection = var.extraction_cost_deletion_protection

  description = "Daily extraction cost rolled up per organization (via dim_project_organization)."

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/sql/v_extraction_cost_by_organization_daily.sql", {
      project_id = var.project_id
      dataset_id = data.google_bigquery_dataset.analytics.dataset_id
    })
  }

  depends_on = [
    google_bigquery_table.v_extraction_cost_by_project_daily,
    google_bigquery_table.dim_project_organization,
  ]
}

resource "google_bigquery_table" "v_extraction_cost_company_daily" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "v_extraction_cost_company_daily"
  deletion_protection = var.extraction_cost_deletion_protection

  description = "Company-wide daily extraction cost + OCR sieve efficiency."

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/sql/v_extraction_cost_company_daily.sql", {
      project_id = var.project_id
      dataset_id = data.google_bigquery_dataset.analytics.dataset_id
    })
  }

  depends_on = [google_bigquery_table.v_extraction_cost_by_document]
}

# -----------------------------------------------------------------------------
# 4. Sieve efficiency — which rung actually paid, and why it escalated
# -----------------------------------------------------------------------------
# This is the view that PROVES the sieve works (or does not). Without it the
# only claim available is "we added engines".
resource "google_bigquery_table" "v_ocr_sieve_efficiency_daily" {
  project             = var.project_id
  dataset_id          = data.google_bigquery_dataset.analytics.dataset_id
  table_id            = "v_ocr_sieve_efficiency_daily"
  deletion_protection = var.extraction_cost_deletion_protection

  description = "Daily OCR sieve escalation outcomes per engine, with reasons."

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/sql/v_ocr_sieve_efficiency_daily.sql", {
      project_id = var.project_id
      dataset_id = data.google_bigquery_dataset.analytics.dataset_id
    })
  }
}
