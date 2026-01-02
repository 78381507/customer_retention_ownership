-- ============================================================================
-- Metric: Customer Retention
-- Owner: François Tilkin
-- Version: v2.0
-- Last update: 2026-01-02
-- Business definition aligned with: docs/customer_retention_definition.pdf
-- Granularity: Cohort-month-maturity (one row per cohort per maturity month)
-- ============================================================================

-- ============================================================================
-- PURPOSE: Cohort Retention Evolution - Strategic Long-Term View
-- ============================================================================
-- This query does not measure individual retention.
-- It measures how customer engagement evolves over time across acquisition cohorts.
--
-- Business question answered:
-- "Do customers acquired in a given period behave better or worse than previous
--  cohorts, and how does their engagement evolve over time?"
--
-- CRITICAL PRINCIPLE:
-- This is STRATEGIC vision, not operational decision-making.
-- SQL #2 = snapshot today
-- SQL #3 = individual risk
-- SQL #4 = collective evolution over time
-- ============================================================================

-- ============================================================================
-- INPUTS (strict dependency control)
-- ============================================================================
-- From SQL #1 (base_customers):
--   - customer_id, first_order_date
--
-- From orders table (activity tracking):
--   - customer_id, order_date
--
-- TIMEZONE CONSIDERATION:
-- - Assumes order_date is stored in consistent timezone (e.g., UTC)
-- - For global businesses: Ensure orders table uses standardized timezone
-- - DATE_TRUNC('month', ...) applied consistently across all records
-- - Mixed timezones would create cohort assignment errors
--
-- FORBIDDEN:
-- - NO retention_status (SQL #2) - agnostic of current state
-- - NO churn_risk_score (SQL #3) - not about individual scoring
-- - NO alert logic - purely observational
-- - NO CURRENT_DATE dependencies - historical analysis only
-- ============================================================================

-- ============================================================================
-- COHORT DEFINITION (explicit and immutable)
-- ============================================================================
-- A cohort = customers whose first order occurred in the same acquisition period
--
-- Cohort granularity: MONTH (not day - too noisy, not quarter - too coarse)
-- Cohort identifier: cohort_month = DATE_TRUNC('month', first_order_date)
--
-- Example cohorts:
-- - 2024-01: All customers with first order in January 2024
-- - 2024-02: All customers with first order in February 2024
--
-- Cohorts are IMMUTABLE: A customer's cohort never changes
-- ============================================================================

-- ============================================================================
-- TEMPORAL AXES (fundamental structure)
-- ============================================================================
-- Axis 1: Cohort acquisition month (cohort_month)
--         When did this group of customers first purchase?
--
-- Axis 2: Cohort maturity (months_since_acquisition)
--         How many months after acquisition are we measuring?
--         M+0 = acquisition month, M+1 = first month after, etc.
--
-- This creates a Time × Cohort matrix for heatmap visualization
--
-- ANALYSIS WINDOW RECOMMENDATION (optional):
-- For cohort comparability, limit analysis to M+0 through M+12
-- Why: Newer cohorts lack M+13+ data, creating incomplete comparisons
-- Implementation: Add WHERE months_since_acquisition <= 12 in final SELECT
-- ============================================================================

-- ============================================================================
-- METRICS (few but meaningful)
-- ============================================================================
-- CORE METRIC (mandatory):
-- - retention_rate: % of cohort customers active at M+N
--
-- OPTIONAL METRICS (max 2):
-- - active_customers: Count of customers active at M+N
-- - cohort_size: Initial size of cohort (constant for all M+N)
--
-- NOT INCLUDED (by design):
-- - Revenue metrics (different analysis)
-- - Churn scores (individual, not cohort)
-- - Complex segmentation (keeps it strategic)
-- ============================================================================

WITH cohort_assignment AS (
  -- =========================================================================
  -- STEP 1: Assign each customer to their acquisition cohort
  -- =========================================================================
  -- Why: Cohort = immutable group based on first purchase month
  -- Output: One row per customer with their cohort_month
  -- =========================================================================
  SELECT
    customer_id,
    DATE_TRUNC('month', first_order_date) AS cohort_month
  FROM base_customers
),

monthly_activity AS (
  -- =========================================================================
  -- STEP 2: Track customer activity by month
  -- =========================================================================
  -- Why: Need to know which customers were active in each month
  -- Definition of "active": At least one order in that month
  -- 
  -- IMPORTANT: Assumes 'orders' table contains only completed/validated orders
  -- - Excludes cancelled, refunded, or pending orders
  -- - If orders table includes all statuses, add WHERE clause:
  --   WHERE order_status IN ('completed', 'delivered', 'paid')
  -- - This ensures retention metrics reflect genuine customer engagement
  -- =========================================================================
  SELECT
    customer_id,
    DATE_TRUNC('month', order_date) AS activity_month
  FROM orders
  GROUP BY customer_id, DATE_TRUNC('month', order_date)
),

cohort_activity_matrix AS (
  -- =========================================================================
  -- STEP 3: Calculate maturity for each customer activity
  -- =========================================================================
  -- Why: Transform absolute dates into relative maturity (M+0, M+1, M+2...)
  -- Logic: Compare activity_month to customer's cohort_month
  -- =========================================================================
  SELECT
    ca.cohort_month,
    ca.customer_id,
    ma.activity_month,
    
    -- Calculate months since acquisition (cohort maturity)
    -- M+0 = acquisition month, M+1 = first month after, etc.
    DATEDIFF('month', ca.cohort_month, ma.activity_month) AS months_since_acquisition
    
  FROM cohort_assignment ca
  INNER JOIN monthly_activity ma
    ON ca.customer_id = ma.customer_id
),

cohort_size_baseline AS (
  -- =========================================================================
  -- STEP 4a: Calculate initial cohort sizes (denominator)
  -- =========================================================================
  -- Why: Retention rate needs stable denominator (initial cohort size)
  -- This is constant for each cohort across all maturity months
  -- =========================================================================
  SELECT
    cohort_month,
    COUNT(DISTINCT customer_id) AS cohort_size
  FROM cohort_assignment
  GROUP BY cohort_month
),

cohort_retention_aggregation AS (
  -- =========================================================================
  -- STEP 4b: Aggregate activity by cohort and maturity
  -- =========================================================================
  -- Why: Calculate how many customers from each cohort are active at M+N
  -- Output: Active customer count per cohort per maturity month
  -- =========================================================================
  SELECT
    cohort_month,
    months_since_acquisition,
    COUNT(DISTINCT customer_id) AS active_customers
  FROM cohort_activity_matrix
  WHERE months_since_acquisition >= 0  -- Only post-acquisition activity
  GROUP BY cohort_month, months_since_acquisition
)

-- ============================================================================
-- FINAL OUTPUT: Cohort Retention Evolution
-- ============================================================================
-- One row per cohort per maturity month
-- Compatible with heatmap visualization (Looker, Tableau, Metabase)
-- Supports diagonal reading (cohort performance over time)
--
-- Optional: Add WHERE months_since_acquisition <= 12
--           to limit analysis window for cohort comparability
-- ============================================================================
SELECT
  cra.cohort_month,
  cra.months_since_acquisition,
  csb.cohort_size,
  cra.active_customers,
  
  -- Retention rate: % of original cohort still active at this maturity
  ROUND(
    (cra.active_customers * 100.0 / csb.cohort_size),
    2
  ) AS retention_rate
  
FROM cohort_retention_aggregation cra
INNER JOIN cohort_size_baseline csb
  ON cra.cohort_month = csb.cohort_month

-- Uncomment to limit analysis to 12-month window for comparability:
-- WHERE cra.months_since_acquisition <= 12

ORDER BY cra.cohort_month, cra.months_since_acquisition

-- ============================================================================
-- QUALITY CHECKS (run separately after table creation)
-- ============================================================================
-- Cohort size consistency check:
--
-- SELECT 
--   cohort_month,
--   cohort_size,
--   COUNT(DISTINCT months_since_acquisition) AS maturity_months_tracked
-- FROM cohort_retention_evolution
-- GROUP BY cohort_month, cohort_size
-- ORDER BY cohort_month;
--
-- Expected: cohort_size is constant for each cohort across all maturity months
-- Red flag: cohort_size varies for same cohort (logic error)
--
-- Retention rate sanity check:
--
-- SELECT 
--   cohort_month,
--   months_since_acquisition,
--   retention_rate,
--   active_customers,
--   cohort_size
-- FROM cohort_retention_evolution
-- WHERE retention_rate > 100 OR retention_rate < 0;
--
-- Expected: Zero rows (retention_rate always between 0-100%)
-- Red flag: Any rows returned (calculation error)
--
-- M+0 retention validation (should be 100% by definition):
--
-- SELECT 
--   cohort_month,
--   months_since_acquisition,
--   retention_rate
-- FROM cohort_retention_evolution
-- WHERE months_since_acquisition = 0
--   AND retention_rate < 95;
--
-- Expected: Zero rows (M+0 should be ~100%, allowing for edge cases)
-- Red flag: Multiple cohorts with M+0 < 95% (definition problem)
--
-- Cohort progression pattern check:
--
-- SELECT 
--   cohort_month,
--   MAX(retention_rate) - MIN(retention_rate) AS retention_drop,
--   MAX(months_since_acquisition) AS max_maturity_tracked
-- FROM cohort_retention_evolution
-- GROUP BY cohort_month
-- ORDER BY cohort_month;
--
-- Expected insights:
-- - retention_drop should be positive (retention declines over time)
-- - Newer cohorts have lower max_maturity (haven't aged yet)
-- - Healthy e-commerce: 30-50% retention drop from M+0 to M+12
--
-- Diagonal reading validation (cohort comparison):
--
-- SELECT 
--   months_since_acquisition,
--   cohort_month,
--   retention_rate
-- FROM cohort_retention_evolution
-- WHERE months_since_acquisition = 3
-- ORDER BY cohort_month;
--
-- Purpose: Compare all cohorts at same maturity (M+3)
-- Expected: Trend visible (improving/declining cohort quality over time)
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Monthly (or when historical data updates)
-- Dependencies: base_customers (SQL #1), orders table
-- Downstream: Executive dashboards, cohort heatmaps, strategic reviews
-- Granularity: Cohort-month-maturity (one row per cohort per maturity month)
-- Output naming: cohort_retention_evolution (as materialized view)
--
-- Why this SQL exists:
-- - Provides strategic long-term view of customer engagement evolution
-- - Enables comparison of cohort quality across acquisition periods
-- - Tracks how retention patterns change over customer lifetime
-- - Identifies if retention is improving/declining for new customer cohorts
-- - Supports investment decisions (marketing spend, customer success)
--
-- Key distinction from other SQL:
-- - SQL #2 (retention_status): Snapshot of current state (operational)
-- - SQL #3 (churn_detection): Individual customer risk (tactical)
-- - SQL #4 (THIS): Collective cohort evolution (strategic)
-- - SQL #5 (alert_logic): Anomaly detection (monitoring)
--
-- How to use in production:
-- - Heatmap visualization: cohort_month (Y-axis) × months_since_acquisition (X-axis)
-- - Diagonal reading: Compare cohort_month values at same months_since_acquisition
-- - Horizontal reading: Track single cohort's retention over its lifetime
-- - Vertical reading: Compare all cohorts at acquisition (M+0)
--
-- Frozen window recommendation (optional but recommended):
-- - For comparability, limit analysis to M+0 through M+12
-- - Why: Newer cohorts haven't reached M+13+, creating incomplete comparisons
-- - Implementation: Add WHERE months_since_acquisition <= 12 in final SELECT
-- - Use case: Board presentations, cohort performance benchmarking
-- - Alternative: Show all data but highlight M+0 to M+12 zone in dashboard
--
-- Cohort maturity considerations:
-- - Recent cohorts: Limited maturity months (e.g., Jan 2026 only has M+0)
-- - Older cohorts: Full maturity visible (e.g., Jan 2024 has M+0 to M+24)
-- - Analysis window: Typically focus on M+0 to M+12 for comparability
--
-- Business interpretation examples:
-- - "Jan 2024 cohort retains 35% at M+12" → Baseline performance
-- - "Feb 2024 cohort retains 42% at M+12" → Improved acquisition quality
-- - "All 2024 cohorts declining at M+6" → Engagement issue to investigate
--
-- What makes this "premium":
-- - No CURRENT_DATE dependencies (pure historical analysis)
-- - Immutable cohort definitions (stable over time)
-- - Explicit temporal logic (months_since_acquisition clearly calculated)
-- - Business-explained metrics (retention_rate, not complex formulas)
-- - Dashboard-ready output (no post-processing needed)
-- - Compatible with standard BI tools (heatmap visualization)
-- - Frozen window option documented (comparability guidance)
-- - Timezone awareness documented (global business ready)
-- - Order validation assumption explicit (data quality clarity)
--
-- Common pitfalls avoided:
-- - NOT filtering to only active customers (would bias retention upward)
-- - NOT recalculating cohort each run (would break historical comparisons)
-- - NOT using global averages (cohort-specific patterns matter)
-- - NOT mixing retention status logic (separate concerns)
-- - NOT assuming timezone consistency without documentation
-- - NOT assuming orders table quality without stating expectations
--
-- Future enhancements (optional):
-- - Add revenue metrics per cohort maturity (separate analysis)
-- - Segment cohorts by acquisition channel (requires channel in base_customers)
-- - Calculate cohort LTV curves (cumulative revenue over maturity)
--
-- Relationship with other SQL:
-- - SQL #1 (base_customers): Provides first_order_date for cohort assignment
-- - SQL #2 (retention_status): Independent - operates on current state
-- - SQL #3 (churn_detection): Independent - operates on individual risk
-- - SQL #4 (THIS): Strategic cohort evolution over time
-- - SQL #5 (alert_logic): Could flag if cohort retention drops abnormally
-- ============================================================================


-- ============================================================================
-- QUALITY CHECKS (run separately after table creation)
-- ============================================================================
-- Cohort size consistency check:
--
-- SELECT 
--   cohort_month,
--   cohort_size,
--   COUNT(DISTINCT months_since_acquisition) AS maturity_months_tracked
-- FROM cohort_retention_evolution
-- GROUP BY cohort_month, cohort_size
-- ORDER BY cohort_month;
--
-- Expected: cohort_size is constant for each cohort across all maturity months
-- Red flag: cohort_size varies for same cohort (logic error)
--
-- Retention rate sanity check:
--
-- SELECT 
--   cohort_month,
--   months_since_acquisition,
--   retention_rate,
--   active_customers,
--   cohort_size
-- FROM cohort_retention_evolution
-- WHERE retention_rate > 100 OR retention_rate < 0;
--
-- Expected: Zero rows (retention_rate always between 0-100%)
-- Red flag: Any rows returned (calculation error)
--
-- M+0 retention validation (should be 100% by definition):
--
-- SELECT 
--   cohort_month,
--   months_since_acquisition,
--   retention_rate
-- FROM cohort_retention_evolution
-- WHERE months_since_acquisition = 0
--   AND retention_rate < 95;
--
-- Expected: Zero rows (M+0 should be ~100%, allowing for edge cases)
-- Red flag: Multiple cohorts with M+0 < 95% (definition problem)
--
-- Cohort progression pattern check:
--
-- SELECT 
--   cohort_month,
--   MAX(retention_rate) - MIN(retention_rate) AS retention_drop,
--   MAX(months_since_acquisition) AS max_maturity_tracked
-- FROM cohort_retention_evolution
-- GROUP BY cohort_month
-- ORDER BY cohort_month;
--
-- Expected insights:
-- - retention_drop should be positive (retention declines over time)
-- - Newer cohorts have lower max_maturity (haven't aged yet)
-- - Healthy e-commerce: 30-50% retention drop from M+0 to M+12
--
-- Diagonal reading validation (cohort comparison):
--
-- SELECT 
--   months_since_acquisition,
--   cohort_month,
--   retention_rate
-- FROM cohort_retention_evolution
-- WHERE months_since_acquisition = 3
-- ORDER BY cohort_month;
--
-- Purpose: Compare all cohorts at same maturity (M+3)
-- Expected: Trend visible (improving/declining cohort quality over time)
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Monthly (or when historical data updates)
-- Dependencies: base_customers (SQL #1), orders table
-- Downstream: Executive dashboards, cohort heatmaps, strategic reviews
-- Granularity: Cohort-month-maturity (one row per cohort per maturity month)
-- Output naming: cohort_retention_evolution (as materialized view)
--
-- Why this SQL exists:
-- - Provides strategic long-term view of customer engagement evolution
-- - Enables comparison of cohort quality across acquisition periods
-- - Tracks how retention patterns change over customer lifetime
-- - Identifies if retention is improving/declining for new customer cohorts
-- - Supports investment decisions (marketing spend, customer success)
--
-- Key distinction from other SQL:
-- - SQL #2 (retention_status): Snapshot of current state (operational)
-- - SQL #3 (churn_detection): Individual customer risk (tactical)
-- - SQL #4 (THIS): Collective cohort evolution (strategic)
-- - SQL #5 (alert_logic): Anomaly detection (monitoring)
--
-- How to use in production:
-- - Heatmap visualization: cohort_month (Y-axis) × months_since_acquisition (X-axis)
-- - Diagonal reading: Compare cohort_month values at same months_since_acquisition
-- - Horizontal reading: Track single cohort's retention over its lifetime
-- - Vertical reading: Compare all cohorts at acquisition (M+0)
--
-- Frozen window recommendation (optional but recommended):
-- - For comparability, limit analysis to M+0 through M+12
-- - Why: Newer cohorts haven't reached M+13+, creating incomplete comparisons
-- - Implementation: Add WHERE months_since_acquisition <= 12 in final SELECT
-- - Use case: Board presentations, cohort performance benchmarking
-- - Alternative: Show all data but highlight M+0 to M+12 zone in dashboard
--
-- Cohort maturity considerations:
-- - Recent cohorts: Limited maturity months (e.g., Jan 2026 only has M+0)
-- - Older cohorts: Full maturity visible (e.g., Jan 2024 has M+0 to M+24)
-- - Analysis window: Typically focus on M+0 to M+12 for comparability
--
-- Business interpretation examples:
-- - "Jan 2024 cohort retains 35% at M+12" → Baseline performance
-- - "Feb 2024 cohort retains 42% at M+12" → Improved acquisition quality
-- - "All 2024 cohorts declining at M+6" → Engagement issue to investigate
--
-- What makes this "premium":
-- - No CURRENT_DATE dependencies (pure historical analysis)
-- - Immutable cohort definitions (stable over time)
-- - Explicit temporal logic (months_since_acquisition clearly calculated)
-- - Business-explained metrics (retention_rate, not complex formulas)
-- - Dashboard-ready output (no post-processing needed)
-- - Compatible with standard BI tools (heatmap visualization)
-- - Frozen window option documented (comparability guidance)
--
-- Common pitfalls avoided:
-- - NOT filtering to only active customers (would bias retention upward)
-- - NOT recalculating cohort each run (would break historical comparisons)
-- - NOT using global averages (cohort-specific patterns matter)
-- - NOT mixing retention status logic (separate concerns)
--
-- Future enhancements (optional):
-- - Add revenue metrics per cohort maturity (separate analysis)
-- - Segment cohorts by acquisition channel (requires channel in base_customers)
-- - Calculate cohort LTV curves (cumulative revenue over maturity)
--
-- Relationship with other SQL:
-- - SQL #1 (base_customers): Provides first_order_date for cohort assignment
-- - SQL #2 (retention_status): Independent - operates on current state
-- - SQL #3 (churn_detection): Independent - operates on individual risk
-- - SQL #4 (THIS): Strategic cohort evolution over time
-- - SQL #5 (alert_logic): Could flag if cohort retention drops abnormally
-- ============================================================================

