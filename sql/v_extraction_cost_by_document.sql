-- v_extraction_cost_by_document
-- Grain: ONE ROW PER MODEL INVOCATION at document grain (task='extraction').
--
-- Source: analytics.model_invocations_v1, which the classifier already feeds
-- via Pub/Sub -> Cloud Functions. The per-document cost fields live inside the
-- metaJson STRING column because the live table has no documentId column and no
-- cost column (verified read-only: `bq show --schema`). The classifier writes
-- them in service/document_extractor_service._cost_attribution().
--
-- SAFE-BY-CONSTRUCTION NOTES
--   * documentId falls back to metaJson.pdfName only as a LAST resort and is
--     labelled by documentIdSource, so a filename is never silently treated as
--     a stable id.
--   * costRateKnown = FALSE means estimatedCostUsd is the unknown-model
--     sentinel (negative), not a real figure. Every rollup below EXCLUDES those
--     rows from its cost sums and counts them separately instead. Do not remove
--     that guard: a fabricated rate is exactly what this work set out to kill.
--   * pageCount = 0 is preserved as NULL costPerPage rather than a divide-by-
--     zero or a fake 1-page denominator.
SELECT
  mi.eventId,
  mi.eventTs,
  DATE(mi.eventTs)                                        AS eventDate,
  mi.sourceSystem,
  mi.operation                                            AS task,
  mi.status,

  -- ── Attribution keys ────────────────────────────────────────────────────
  COALESCE(
    JSON_VALUE(mi.metaJson, '$.documentId'),
    JSON_VALUE(mi.metaJson, '$.pdfName')
  )                                                       AS documentId,
  CASE
    WHEN JSON_VALUE(mi.metaJson, '$.documentId') IS NOT NULL THEN 'documentId'
    WHEN JSON_VALUE(mi.metaJson, '$.pdfName')    IS NOT NULL THEN 'pdfName_fallback'
    ELSE 'missing'
  END                                                     AS documentIdSource,
  COALESCE(mi.projectId, JSON_VALUE(mi.metaJson, '$.projectId')) AS projectId,
  COALESCE(mi.userId, JSON_VALUE(mi.metaJson, '$.userId'))       AS userId,
  -- NULL today by design: organizationId does not exist on the classifier
  -- request path. Resolved by JOIN in the organization rollup.
  JSON_VALUE(mi.metaJson, '$.organizationId')             AS organizationIdOnEvent,
  JSON_VALUE(mi.metaJson, '$.startedBy')                  AS startedBy,
  JSON_VALUE(mi.metaJson, '$.trigger')                    AS trigger,

  -- ── Volume ──────────────────────────────────────────────────────────────
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.pageCount')          AS INT64) AS pageCount,
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.pagesProcessed')     AS INT64) AS pagesProcessed,
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.directTextPages')    AS INT64) AS directTextPages,
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.ocrPages')           AS INT64) AS ocrPages,
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.needsOcrReviewPages') AS INT64) AS needsOcrReviewPages,

  -- ── Sieve outcome ───────────────────────────────────────────────────────
  JSON_VALUE(mi.metaJson, '$.engine')                     AS winningEngine,
  JSON_QUERY(mi.metaJson, '$.sieveAttempts')              AS sieveAttemptsJson,

  -- ── Cost ────────────────────────────────────────────────────────────────
  mi.modelProvider,
  mi.modelName,
  COALESCE(JSON_VALUE(mi.metaJson, '$.costModel'), mi.modelName) AS costModel,
  mi.promptTokens,
  mi.completionTokens,
  mi.totalTokens,
  mi.latencyMs,
  COALESCE(
    SAFE_CAST(JSON_VALUE(mi.metaJson, '$.costRateKnown') AS BOOL),
    FALSE
  )                                                       AS costRateKnown,
  SAFE_CAST(JSON_VALUE(mi.metaJson, '$.estimatedCostUsd') AS FLOAT64)
                                                          AS estimatedCostUsd,
  -- Cost per page, only where BOTH the rate and a non-zero page count exist.
  SAFE_DIVIDE(
    IF(
      COALESCE(SAFE_CAST(JSON_VALUE(mi.metaJson, '$.costRateKnown') AS BOOL), FALSE),
      SAFE_CAST(JSON_VALUE(mi.metaJson, '$.estimatedCostUsd') AS FLOAT64),
      NULL
    ),
    NULLIF(SAFE_CAST(JSON_VALUE(mi.metaJson, '$.pagesProcessed') AS INT64), 0)
  )                                                       AS estimatedCostUsdPerPage
FROM `${project_id}.${dataset_id}.model_invocations_v1` AS mi
WHERE mi.kind = 'model_invocation'
