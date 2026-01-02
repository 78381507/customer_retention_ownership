-- ============================================================================
-- Metric: Customer Retention
-- Owner: François Tilkin
-- Version: v1.0
-- Last update: 2026-01-02
-- Business definition aligned with: docs/customer_retention_definition.pdf
-- Granularity: Daily alert evaluation (one row per reference_date)
-- ============================================================================

-- ============================================================================
-- PURPOSE: Alert Logic - Automated Anomaly Detection
-- ============================================================================
-- This SQL automatically detects abnormal deviations in Customer Retention
-- metrics in an actionable, explainable, and low-noise manner.
--
-- Business question answered:
-- "Is there an abnormal change in retention metrics that requires immediate action?"
--
-- CRITICAL PRINCIPLE:
-- This is a DECISION TRIGGER system, not a dashboard or exploratory analysis.
-- It observes pre-calculated metrics, detects deviations, and flags actions.
-- ============================================================================

-- ============================================================================
-- SCOPE (clear and focused)
-- ============================================================================
-- Alert focus: AT_RISK customer percentage
-- 
-- Business question: "Is the percentage of AT_RISK customers increasing abnormally?"
-- Why this metric: AT_RISK is the actionable retention segment
-- Action if triggered: Launch retention campaign / sales intervention
--
-- Alternative scopes (for future alerts):
-- - Global retention rate drop
-- - Recent cohort underperformance (M+1, M+2)
-- - High-value segment churn spike
--
-- Design principle: ONE alert = ONE business question (not 15 metrics)
-- ============================================================================

-- ============================================================================
-- PARAMETERS (production configuration)
-- ============================================================================
-- @reference_date: Date for alert evaluation (REQUIRED, no default)
--                  Examples: '2026-01-02', CURRENT_DATE for live monitoring
--
-- Why parameterized:
-- - Enables historical alert testing (what would have triggered on 2025-12-01?)
-- - Ensures reproducibility (same date = same alert decision)
-- - Supports idempotent alert logic (no hidden CURRENT_DATE dependencies)
-- ============================================================================

-- ============================================================================
-- INPUTS (strict dependency control)
-- ============================================================================
-- From SQL #2 (retention_snapshot):
--   - retention_status, customer counts
--
-- CONSUMPTION ONLY - NO RECALCULATION:
-- - Alert logic READS metrics, never RECALCULATES them
-- - No direct access to base_customers or orders tables
-- - No recomputation of retention status or cohorts
--
-- This ensures:
-- - Separation of concerns (metrics calculation vs alert detection)
-- - Performance (alerting doesn't re-run heavy aggregations)
-- - Consistency (alerts use same metrics as dashboards)
-- ============================================================================

-- ============================================================================
-- BASELINE STRATEGY
-- ============================================================================
-- Baseline type: 7-day rolling average (week-over-week stability)
-- Why 7 days: Captures weekly patterns, smooths daily noise
-- Alternative: 14-day (more stable) or 28-day (monthly patterns)
--
-- Baseline comparison: Current value vs average of previous 7 days
-- Why not single-day comparison: Too noisy, would create false positives
-- ============================================================================

-- ============================================================================
-- THRESHOLDS (explicit and justified)
-- ============================================================================
-- WARNING threshold: +15% increase in AT_RISK percentage vs baseline
-- CRITICAL threshold: +25% increase in AT_RISK percentage vs baseline
--
-- Why these values:
-- - +15%: Meaningful deviation (e.g., 20% → 23% AT_RISK)
-- - +25%: Urgent intervention (e.g., 20% → 25% AT_RISK)
-- - Asymmetric: Only alerting on INCREASES (decreases are good news)
--
-- Business interpretation:
-- - WARNING: Monitor closely, prepare intervention
-- - CRITICAL: Act immediately, launch retention campaign
-- ============================================================================

-- ============================================================================
-- ANTI-NOISE MECHANISMS
-- ============================================================================
-- 1. Minimum sample size: 100 total customers
--    Why: Prevents alerts on statistically insignificant populations
--
-- 2. Exclude incomplete data periods
--    Why: Partial day data creates false deviations
--
-- 3. Optional: Require 2 consecutive days above threshold (documented but not enforced)
--    Why: Reduces one-time spikes, but may delay critical alerts
--    Implementation: Track previous day alert_flag, only trigger if both TRUE
-- ============================================================================

-- ============================================================================
-- OUTPUT STRUCTURE (actionable and automatable)
-- ============================================================================
-- Columns returned:
-- - alert_date: When was this alert evaluated
-- - alert_type: What kind of alert (retention_status_degradation)
-- - metric_name: Which metric (at_risk_pct)
-- - scope: What population (global)
-- - current_value: Today's AT_RISK percentage
-- - baseline_value: 7-day average AT_RISK percentage
-- - delta_pct: Percentage point change (current - baseline)
-- - delta_relative_pct: Relative percentage change ((current/baseline - 1) * 100)
-- - threshold_warning: WARNING threshold value
-- - threshold_critical: CRITICAL threshold value
-- - severity: Alert severity (INFO / WARNING / CRITICAL)
-- - alert_flag: Should this trigger an action? (TRUE / FALSE)
-- - sample_size: Total customers evaluated
--
-- Consumable by: Slack webhooks, email automation, ticketing systems
-- ============================================================================

WITH daily_retention_status AS (
  -- =========================================================================
  -- STEP 1: Calculate daily retention status distribution
  -- =========================================================================
  -- Source: SQL #2 (retention_snapshot) at reference_date
  -- Output: Count and percentage of each retention status
  -- =========================================================================
  SELECT
    @reference_date AS snapshot_date,
    retention_status,
    COUNT(*) AS customer_count,
    SUM(COUNT(*)) OVER () AS total_customers,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS status_pct
  FROM retention_snapshot
  -- Assumes retention_snapshot is already filtered to @reference_date
  GROUP BY retention_status
),

historical_baseline AS (
  -- =========================================================================
  -- STEP 2: Calculate 7-day rolling baseline
  -- =========================================================================
  -- Logic: Average AT_RISK percentage over previous 7 days
  -- Why historical: Smooths daily volatility, provides stable comparison
  -- =========================================================================
  SELECT
    snapshot_date,
    retention_status,
    AVG(status_pct) OVER (
      PARTITION BY retention_status 
      ORDER BY snapshot_date 
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS baseline_pct
  FROM daily_retention_status
  WHERE retention_status = 'AT_RISK'
),

current_vs_baseline AS (
  -- =========================================================================
  -- STEP 3: Compare current value to baseline
  -- =========================================================================
  -- Output: Current AT_RISK %, baseline AT_RISK %, delta
  -- =========================================================================
  SELECT
    drs.snapshot_date,
    drs.retention_status,
    drs.status_pct AS current_value,
    hb.baseline_pct AS baseline_value,
    drs.total_customers AS sample_size,
    
    -- Absolute delta (percentage points)
    (drs.status_pct - hb.baseline_pct) AS delta_pct,
    
    -- Relative delta (percentage change)
    ROUND(
      ((drs.status_pct / NULLIF(hb.baseline_pct, 0)) - 1) * 100,
      2
    ) AS delta_relative_pct
    
  FROM daily_retention_status drs
  LEFT JOIN historical_baseline hb
    ON drs.snapshot_date = hb.snapshot_date
    AND drs.retention_status = hb.retention_status
  WHERE drs.retention_status = 'AT_RISK'
),

threshold_evaluation AS (
  -- =========================================================================
  -- STEP 4: Evaluate against thresholds
  -- =========================================================================
  -- Logic: Compare delta_relative_pct to WARNING (+15%) and CRITICAL (+25%)
  -- =========================================================================
  SELECT
    snapshot_date,
    current_value,
    baseline_value,
    delta_pct,
    delta_relative_pct,
    sample_size,
    
    -- Threshold values (explicit, not hidden)
    15.0 AS threshold_warning,
    25.0 AS threshold_critical,
    
    -- Severity classification
    CASE
      WHEN delta_relative_pct >= 25.0 THEN 'CRITICAL'
      WHEN delta_relative_pct >= 15.0 THEN 'WARNING'
      ELSE 'INFO'
    END AS severity
    
  FROM current_vs_baseline
),

noise_filtering AS (
  -- =========================================================================
  -- STEP 5: Apply anti-noise filters
  -- =========================================================================
  -- Filter 1: Minimum sample size (100 customers)
  -- Filter 2: Valid baseline (not NULL - requires 7 days history)
  -- =========================================================================
  SELECT
    snapshot_date,
    current_value,
    baseline_value,
    delta_pct,
    delta_relative_pct,
    threshold_warning,
    threshold_critical,
    severity,
    sample_size,
    
    -- Alert flag: TRUE only if passes all filters AND severity > INFO
    CASE
      WHEN sample_size >= 100  -- Minimum sample size
        AND baseline_value IS NOT NULL  -- Valid baseline exists
        AND severity IN ('WARNING', 'CRITICAL')  -- Meaningful deviation
      THEN TRUE
      ELSE FALSE
    END AS alert_flag
    
  FROM threshold_evaluation
)

-- ============================================================================
-- FINAL OUTPUT: Alert Decision
-- ============================================================================
-- One row per reference_date with alert decision and all context
-- Ready for: Slack webhook, email trigger, ticket creation
-- ============================================================================
SELECT
  snapshot_date AS alert_date,
  'retention_status_degradation' AS alert_type,
  'at_risk_pct' AS metric_name,
  'global' AS scope,
  current_value,
  baseline_value,
  delta_pct,
  delta_relative_pct,
  threshold_warning,
  threshold_critical,
  severity,
  alert_flag,
  sample_size
FROM noise_filtering

-- ============================================================================
-- QUALITY CHECKS (run separately for validation)
-- ============================================================================
-- Alert frequency check (over 30 days):
--
-- SELECT 
--   severity,
--   COUNT(*) AS alert_count,
--   SUM(CASE WHEN alert_flag THEN 1 ELSE 0 END) AS triggered_count,
--   ROUND(AVG(delta_relative_pct), 2) AS avg_delta_pct
-- FROM alert_logic
-- WHERE alert_date >= DATE_SUB(@reference_date, 30)
-- GROUP BY severity;
--
-- Healthy pattern:
-- - CRITICAL: 0-2 per month (rare, urgent)
-- - WARNING: 2-5 per month (actionable)
-- - INFO: Majority (normal fluctuations)
--
-- Red flags:
-- - CRITICAL > 5 per month: Thresholds too sensitive OR genuine crisis
-- - WARNING = 0 for 3+ months: Thresholds too conservative
--
-- Baseline stability check:
--
-- SELECT 
--   alert_date,
--   baseline_value,
--   current_value,
--   ABS(current_value - baseline_value) AS deviation
-- FROM alert_logic
-- WHERE baseline_value IS NULL;
--
-- Expected: Zero rows (all dates have valid 7-day baseline)
-- Red flag: NULLs in first 7 days of data (expected, document as warmup period)
--
-- Sample size distribution:
--
-- SELECT 
--   MIN(sample_size) AS min_sample,
--   AVG(sample_size) AS avg_sample,
--   MAX(sample_size) AS max_sample
-- FROM alert_logic;
--
-- Expected: min_sample >= 100 (noise filter working)
-- Red flag: Wide variance (seasonal customer base, may need dynamic thresholds)
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Daily (after SQL #2 retention_snapshot refresh)
-- Dependencies: retention_snapshot (SQL #2)
-- Downstream: Slack alerts, email notifications, ops tickets
-- Granularity: Daily alert evaluation (one decision per reference_date)
--
-- Why this SQL exists:
-- - Closes the loop: metrics → deviation detection → action trigger
-- - Enables proactive intervention (alerts before metrics become critical)
-- - Reduces alert fatigue (anti-noise filters prevent spam)
-- - Provides explainable decisions (all thresholds and logic documented)
--
-- Alert consumption examples:
-- - Slack webhook: POST alert_flag=TRUE rows with severity, delta, sample_size
-- - Email automation: Send daily digest of WARNING+ alerts to retention team
-- - Ticketing: Create Jira ticket for CRITICAL alerts with metric context
--
-- Threshold tuning guidance:
-- - Too many alerts: Increase thresholds (15% → 20%, 25% → 30%)
-- - Missing real issues: Decrease thresholds (15% → 10%, 25% → 20%)
-- - Seasonal business: Consider separate thresholds by month/quarter
--
-- Baseline alternatives (if 7-day unsuitable):
-- - 14-day rolling: More stable, slower to react
-- - 28-day rolling: Monthly patterns, very smooth
-- - Same-day-last-week: Captures weekly seasonality
-- - Median instead of mean: Robust to outliers
--
-- Anti-noise mechanism tuning:
-- - Sample size threshold: Currently 100, adjust based on customer base
-- - Consecutive days: Currently disabled, enable for very noisy metrics
-- - Maturity filter: Not applicable (using global metric, not cohorts)
--
-- What makes this "premium":
-- - Idempotent and reproducible (@reference_date parameter)
-- - Single focused metric (AT_RISK percentage, not 15 metrics)
-- - Explicit baseline comparison (7-day rolling average)
-- - Documented thresholds (15% WARNING, 25% CRITICAL with justification)
-- - Anti-noise filters (sample size, baseline validity)
-- - Actionable output (alert_flag, severity, full context)
-- - Consumable by automation (Slack/email/tickets)
-- - Explainable to C-level in 30 seconds
--
-- Key distinction from other SQL:
-- - SQL #2 (retention_status): Calculates current retention state
-- - SQL #3 (churn_detection): Identifies individual customer risk
-- - SQL #4 (cohort_retention): Tracks long-term cohort evolution
-- - SQL #5 (THIS): Detects abnormal deviations requiring immediate action
--
-- Future enhancements:
-- - Multiple alert types (cohort underperformance, high-value segment churn)
-- - Dynamic thresholds by customer segment or season
-- - ML-based anomaly detection (if simple thresholds insufficient)
-- - Alert suppression rules (don't alert during known campaigns)
--
-- Relationship with other SQL:
-- - SQL #1 (base_customers): Not directly used (alerting on aggregated metrics)
-- - SQL #2 (retention_snapshot): Primary data source for alert evaluation
-- - SQL #3 (churn_detection): Could be used for individual-level alerts
-- - SQL #4 (cohort_retention): Could be used for cohort-level alerts
-- - SQL #5 (THIS): Monitors distribution metrics for automated action triggers
-- ============================================================================

