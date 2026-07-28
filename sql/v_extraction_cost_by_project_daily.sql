-- v_extraction_cost_by_project_daily
-- Grain: one row per (eventDate, projectId, task).
--
-- Cost sums INCLUDE ONLY rows where costRateKnown = TRUE. Rows priced against a
-- model with no published rate carry a negative sentinel and are counted in
-- `unpricedInvocations` instead of being folded into the total. A total that
-- silently absorbs a fabricated rate is worse than a total with a visible hole.
SELECT
  eventDate,
  projectId,
  task,
  COUNT(*)                                      AS invocations,
  COUNT(DISTINCT documentId)                    AS documents,
  SUM(pageCount)                                AS pages,
  SUM(pagesProcessed)                           AS pagesProcessed,
  SUM(directTextPages)                          AS freeTextLayerPages,
  SUM(ocrPages)                                 AS paidOcrPages,
  SUM(needsOcrReviewPages)                      AS needsOcrReviewPages,
  SUM(promptTokens)                             AS inputTokens,
  SUM(completionTokens)                         AS outputTokens,
  COUNTIF(NOT costRateKnown)                    AS unpricedInvocations,
  SUM(IF(costRateKnown, estimatedCostUsd, 0))   AS estimatedCostUsd,
  SAFE_DIVIDE(
    SUM(IF(costRateKnown, estimatedCostUsd, 0)),
    NULLIF(SUM(IF(costRateKnown, pagesProcessed, 0)), 0)
  )                                             AS estimatedCostUsdPerPage,
  SAFE_DIVIDE(
    SUM(IF(costRateKnown, estimatedCostUsd, 0)),
    NULLIF(COUNT(DISTINCT IF(costRateKnown, documentId, NULL)), 0)
  )                                             AS estimatedCostUsdPerDocument
FROM `${project_id}.${dataset_id}.v_extraction_cost_by_document`
WHERE projectId IS NOT NULL
GROUP BY eventDate, projectId, task
