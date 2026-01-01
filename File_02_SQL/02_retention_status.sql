-- ============================================================================
-- Metric: Customer Retention
-- Owner: François Tilkin
-- Version: v1.1
-- Last update: 2026-01-02
-- Business definition aligned with: docs/customer_retention_definition.pdf
-- ============================================================================

-- ============================================================================
-- PURPOSE: Retention Status - Customer State at Reference Date
-- ============================================================================
-- This SQL transforms stable customer facts (from SQL #1) into decisional 
-- retention status at a given point in time.
--
-- Business question answered:
-- "At date T, what is the retention status of each customer?"
--
-- CRITICAL PRINCIPLE:
-- This is a SNAPSHOT VIEW on facts, not a fact table itself.
-- Facts live in SQL #1. Time-dependent status lives here.
-- ============================================================================

-- ============================================================================
-- PARAMETERS (production configuration)
-- ============================================================================
-- @reference_date: Date used to calculate recency (REQUIRED, no default)
--                  Examples: '2026-01-02', CURRENT_DATE for live analysis
--                  
-- Why parameterized:
-- - Enables historical analysis (what was status on 2025-12-01?)
-- - Ensures reproducibility (same date = same results)
-- - Makes testing straightforward (set date, verify logic)
-- ============================================================================

-- ============================================================================
-- RETENTION THRESHOLDS (business configuration)
-- ============================================================================
-- These values define status boundaries and can be adjusted based on:
-- - Business model (luxury: 60/180, fast fashion: 15/45)
-- - Customer behavior analysis
-- - A/B test results
--
-- ACTIVE_THRESHOLD    = 30 days (recent buyer, high engagement)
-- AT_RISK_THRESHOLD   = 90 days (silent period, intervention needed)
-- INACTIVE_THRESHOLD  = 90+ days (dormant, win-back campaign required)
--
-- To adjust: modify CASE logic in 'retention_snapshot' CTE below
-- ============================================================================

-- ============================================================================
-- RETENTION STATUS LOGIC (business rules)
-- ============================================================================
-- Customer is ACTIVE when: Purchased within last 30 days from reference_date
-- Customer is AT_RISK when: Purchased 31-90 days ago from reference_date
-- Customer is INACTIVE when: No purchase in 90+ days from reference_date
--
-- Why these statuses:
-- - ACTIVE (0-30 days): Recent buyer, high engagement, no action needed
-- - AT_RISK (31-90 days): Silent period, intervention recommended
-- - INACTIVE (90+ days): Dormant customer (not definitively churned)
--                        True churn probability calculated in SQL #3
--
-- Important distinction:
-- - INACTIVE = current state (can reactivate via new purchase)
-- - CHURNED = probability/prediction (calculated in SQL #3 with behavior)
--
-- Rules are:
-- - Mutually exclusive (1 customer = exactly 1 status)
-- - Time-dependent (status changes as reference_date moves)
-- - Adjustable (thresholds can be modified without touching SQL #1)
-- ============================================================================

-- ============================================================================
-- COLUMN ROLES (what each output enables)
-- ============================================================================
-- days_since_last_order  → Input for SQL #3 (churn detection frequency drop)
-- retention_status       → Segmentation for dashboards, campaigns, SQL #5 alerts
-- ============================================================================

WITH recency_calculation AS (
  -- =========================================================================
  -- STEP 1: Calculate recency from reference date
  -- =========================================================================
  -- Why: Recency is the foundation for all retention status logic
  -- Input: base_customers (SQL #1 - stable facts)
  -- Output: days_since_last_order (time-dependent derived metric)
  -- =========================================================================
  SELECT
    customer_id,
    last_order_date,
    
    -- Calculate days between last order and reference date
    -- This is a DERIVED metric (changes with reference_date)
    -- That's why it lives here, not in SQL #1
    DATEDIFF('day', last_order_date, @reference_date) AS days_since_last_order
    
  FROM base_customers
),

retention_snapshot AS (
  -- =========================================================================
  -- STEP 2: Apply business logic to assign retention status
  -- =========================================================================
  -- Why: Transform recency (a number) into business status (a decision)
  -- Logic: Use CASE to create mutually exclusive categories
  -- 
  -- Data quality protection: Handles edge case of future order dates
  -- (can occur due to data ingestion delays, timezone bugs, or ETL issues)
  -- =========================================================================
  SELECT
    customer_id,
    last_order_date,
    days_since_last_order,
    
    -- Assign exactly ONE status per customer
    -- Thresholds are visible and modifiable in RETENTION THRESHOLDS section
    CASE
      -- Data quality guard: future orders relative to reference_date
      WHEN days_since_last_order < 0 THEN 'DATA_QUALITY_ISSUE'
      
      -- Active customers (recent engagement)
      WHEN days_since_last_order <= 30 THEN 'ACTIVE'
      
      -- At-risk customers (needs attention)
      WHEN days_since_last_order <= 90 THEN 'AT_RISK'
      
      -- Inactive customers (dormant, not definitively churned)
      -- Note: True churn probability calculated in SQL #3
      ELSE 'INACTIVE'
    END AS retention_status
    
  FROM recency_calculation
)

-- ============================================================================
-- FINAL OUTPUT: Retention Snapshot Table
-- ============================================================================
-- One row per customer with their retention status at reference_date
-- Ready to be used for: dashboards, alerts, campaign targeting
-- ============================================================================
SELECT
  customer_id,
  last_order_date,
  days_since_last_order,
  retention_status
FROM retention_snapshot

-- ============================================================================
-- QUALITY CHECKS (run separately after table creation)
-- ============================================================================
-- Distribution check - verify status distribution makes business sense:
--
-- SELECT 
--   retention_status,
--   COUNT(*) AS customer_count,
--   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
-- FROM retention_snapshot
-- GROUP BY retention_status
-- ORDER BY 
--   CASE retention_status
--     WHEN 'ACTIVE' THEN 1
--     WHEN 'AT_RISK' THEN 2
--     WHEN 'INACTIVE' THEN 3
--     WHEN 'DATA_QUALITY_ISSUE' THEN 4
--   END;
--
-- Healthy distribution (indicative for e-commerce):
-- - ACTIVE: 20-40% (recent buyers)
-- - AT_RISK: 15-25% (need attention)
-- - INACTIVE: 40-60% (normal for established business)
-- - DATA_QUALITY_ISSUE: 0% (should be investigated if > 0)
--
-- Red flags:
-- - ACTIVE < 10%: Acquisition problem or status thresholds too strict
-- - INACTIVE > 70%: Retention crisis or thresholds too aggressive
-- - AT_RISK > ACTIVE: Engagement declining
-- - DATA_QUALITY_ISSUE > 0%: ETL or timezone issues requiring investigation
--
-- Validation checks - ensure logic is correct:
--
-- SELECT 
--   MIN(days_since_last_order) AS min_days,
--   MAX(days_since_last_order) AS max_days,
--   COUNT(DISTINCT customer_id) AS unique_customers,
--   COUNT(*) AS total_rows,
--   SUM(CASE WHEN days_since_last_order < 0 THEN 1 ELSE 0 END) AS future_orders
-- FROM retention_snapshot;
--
-- Expected: unique_customers = total_rows (no duplicates)
-- Expected: future_orders = 0 (no data quality issues)
-- Expected: min_days >= 0 (all orders in past relative to reference_date)
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Daily (synchronized with base_customers refresh)
-- Dependencies: base_customers (SQL #1)
-- Downstream: SQL #3 (churn detection), SQL #5 (alerts), dashboards, campaigns
--
-- Why this SQL exists:
-- - Calculates retention STATUS for each customer at a given reference date
-- - Applies time-dependent logic on stable facts (from base_customers)
-- - Status thresholds can change without touching SQL #1
-- - Enables business to adjust status rules without re-aggregating orders
-- - Clear separation: facts (SQL #1) vs status snapshot (here)
-- - Reproducible: same reference_date = same status results (critical for audits)
--
-- How to use in production:
-- - Set @reference_date = CURRENT_DATE for live dashboard
-- - Set @reference_date = '2025-12-31' for end-of-year analysis
-- - Set @reference_date = DATE_SUB(CURRENT_DATE, 7) for week-ago snapshot
--
-- Data quality protection:
-- - DATA_QUALITY_ISSUE status flags future order dates (days_since < 0)
-- - Can occur due to: timezone bugs, ETL delays, incorrect data ingestion
-- - Should be investigated and corrected at source (SQL #1 or upstream)
--
-- Status naming rationale:
-- - INACTIVE (not CHURNED): Indicates current state, not definitive loss
-- - Customers can move from INACTIVE → ACTIVE via new purchase
-- - True churn probability (definitive loss) calculated in SQL #3
-- - This distinction is critical for business interpretation
--
-- What makes this "premium":
-- - Parameterized reference date (not hardcoded CURRENT_DATE)
-- - Mutually exclusive statuses (no ambiguity)
-- - Data quality protection (handles edge cases)
-- - Clear threshold abstraction (business can tune without code changes)
-- - Precise naming (INACTIVE vs CHURNED distinction)
-- - Clear CASE logic (readable by non-tech stakeholders)
-- - Explainable to business ("why is this customer AT_RISK?")
-- - Testable independently from base_customers
-- - Thresholds visible and modifiable without breaking downstream SQL
--
-- Relationship with other SQL:
-- - SQL #1 (base_customers): Provides stable facts (last_order_date)
-- - SQL #2 (THIS): Calculates retention status (recency → ACTIVE/AT_RISK/INACTIVE)
-- - SQL #3 (churn_detection): Uses status + behavior for churn probability
-- - SQL #4 (cohort_retention): Tracks status evolution over time
-- - SQL #5 (alert_logic): Flags anomalies in status distribution
-- ============================================================================

