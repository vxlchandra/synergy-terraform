-- v_extraction_cost_company_daily
-- Grain: one row per (eventDate, task). Company-wide total.
--
-- `freeTextLayerPageShare` is the headline efficiency number: the fraction of
-- pages served by the FREE PDF text layer (rung 0 of the OCR sieve) instead of
-- a paid vision call. Moving this number up is the whole point of the sieve;
-- it is reported next to cost so a saving cannot be claimed without it.
SELECT
  eventDate,
  task,
  COUNT(DISTINCT projectId)                     AS projects,
  COUNT(DISTINCT documentId)                    AS documents,
  COUNT(*)                                      AS invocations,
  SUM(pageCount)                                AS pages,
  SUM(pagesProcessed)                           AS pagesProcessed,
  SUM(directTextPages)                          AS freeTextLayerPages,
  SUM(ocrPages)                                 AS paidOcrPages,
  SUM(needsOcrReviewPages)                      AS needsOcrReviewPages,
  SAFE_DIVIDE(SUM(directTextPages), NULLIF(SUM(pagesProcessed), 0))
                                                AS freeTextLayerPageShare,
  SUM(promptTokens)                             AS inputTokens,
  SUM(completionTokens)                         AS outputTokens,
  COUNTIF(NOT costRateKnown)                    AS unpricedInvocations,
  SUM(IF(costRateKnown, estimatedCostUsd, 0))   AS estimatedCostUsd,
  SAFE_DIVIDE(
    SUM(IF(costRateKnown, estimatedCostUsd, 0)),
    NULLIF(SUM(IF(costRateKnown, pagesProcessed, 0)), 0)
  )                                             AS estimatedCostUsdPerPage
FROM `${project_id}.${dataset_id}.v_extraction_cost_by_document`
GROUP BY eventDate, task
