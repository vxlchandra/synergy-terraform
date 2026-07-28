-- v_ocr_sieve_efficiency_daily
-- Grain: one row per (eventDate, engine, outcome).
--
-- Unnests the per-page sieve trace the classifier writes into
-- metaJson.sieveAttempts. THIS is the view that proves the cost-ordered sieve
-- is working: it shows, per engine, how often a cheap rung CLEARED the quality
-- gate (a saved expensive call) versus escalated, and WHY it escalated
-- (low_quality / error / timeout / unavailable).
--
-- Reading it:
--   outcome='cleared'      -> this rung produced the page. Cheapest rung with a
--                             high cleared count is where the saving comes from.
--   outcome='low_quality'  -> the gate rejected it; `reason` carries the score
--                             vs the threshold. Persistent low_quality on a
--                             cheap rung means the gate, not the engine, needs
--                             tuning — or the rung is genuinely unsuitable.
--   outcome='error'        -> the rung raised; `reason` is the exception CLASS
--                             name only (never document text — customer data).
--   outcome='timeout'      -> exceeded its budget.
--   outcome='unavailable'  -> registered but its dependency is not installed.
--
-- A rung that never appears here is not being tried: check extraction_engine
-- (which rung the sieve STARTS at) and ocr_engine_order.
SELECT
  DATE(mi.eventTs)                                        AS eventDate,
  JSON_VALUE(attempt, '$.engine')                         AS engine,
  JSON_VALUE(attempt, '$.outcome')                        AS outcome,
  COUNT(*)                                                AS attempts,
  COUNT(DISTINCT JSON_VALUE(mi.metaJson, '$.documentId')) AS documents,
  AVG(SAFE_CAST(JSON_VALUE(attempt, '$.confidence') AS FLOAT64)) AS avgConfidence,
  APPROX_QUANTILES(
    SAFE_CAST(JSON_VALUE(attempt, '$.latencyMs') AS INT64), 100
  )[OFFSET(50)]                                           AS p50LatencyMs,
  APPROX_QUANTILES(
    SAFE_CAST(JSON_VALUE(attempt, '$.latencyMs') AS INT64), 100
  )[OFFSET(95)]                                           AS p95LatencyMs,
  SUM(SAFE_CAST(JSON_VALUE(attempt, '$.inputTokens')  AS INT64)) AS inputTokens,
  SUM(SAFE_CAST(JSON_VALUE(attempt, '$.outputTokens') AS INT64)) AS outputTokens,
  -- Distinct escalation reasons seen, so a new failure mode is visible without
  -- a new dashboard. Capped: reason is a short code, never document content.
  ARRAY_AGG(DISTINCT JSON_VALUE(attempt, '$.reason') IGNORE NULLS LIMIT 20)
                                                          AS reasons
FROM `${project_id}.${dataset_id}.model_invocations_v1` AS mi,
  UNNEST(JSON_QUERY_ARRAY(mi.metaJson, '$.sieveAttempts')) AS attempt
WHERE mi.kind = 'model_invocation'
  AND mi.metaJson IS NOT NULL
GROUP BY eventDate, engine, outcome
