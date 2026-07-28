-- v_extraction_cost_by_organization_daily
-- Grain: one row per (eventDate, organizationId, task).
--
-- 🔴 organizationId is NOT on the classifier event. It is resolved by LEFT JOIN
-- through dim_project_organization (populated by aeromontek-functions from
-- Firestore projects/{id}.organizationId). A project with no mapping rolls up
-- to the sentinel 'UNATTRIBUTED' rather than vanishing — an org rollup that
-- silently drops spend is a billing defect, not a reporting gap.
--
-- `unattributedProjects` on every row is the honesty check: if it is non-zero,
-- the organization totals are incomplete and the dimension needs backfilling.
SELECT
  p.eventDate,
  COALESCE(d.organizationId, 'UNATTRIBUTED')    AS organizationId,
  d.organizationName,
  p.task,
  COUNT(DISTINCT p.projectId)                   AS projects,
  COUNTIF(d.organizationId IS NULL)             AS unattributedProjects,
  SUM(p.invocations)                            AS invocations,
  SUM(p.documents)                              AS documents,
  SUM(p.pages)                                  AS pages,
  SUM(p.pagesProcessed)                         AS pagesProcessed,
  SUM(p.freeTextLayerPages)                     AS freeTextLayerPages,
  SUM(p.paidOcrPages)                           AS paidOcrPages,
  SUM(p.needsOcrReviewPages)                    AS needsOcrReviewPages,
  SUM(p.inputTokens)                            AS inputTokens,
  SUM(p.outputTokens)                           AS outputTokens,
  SUM(p.unpricedInvocations)                    AS unpricedInvocations,
  SUM(p.estimatedCostUsd)                       AS estimatedCostUsd,
  SAFE_DIVIDE(SUM(p.estimatedCostUsd), NULLIF(SUM(p.pagesProcessed), 0))
                                                AS estimatedCostUsdPerPage
FROM `${project_id}.${dataset_id}.v_extraction_cost_by_project_daily` AS p
LEFT JOIN `${project_id}.${dataset_id}.dim_project_organization` AS d
  ON d.projectId = p.projectId
GROUP BY p.eventDate, organizationId, d.organizationName, p.task
