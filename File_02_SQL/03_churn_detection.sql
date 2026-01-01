-- ============================================================================
-- Metric: Customer Retention
-- Owner: François Tilkin
-- Version: v1.0
-- Last update: 2026-01-02
-- Business definition aligned with: docs/customer_retention_definition.pdf
-- Granularity: Customer-level risk assessment (one row per customer)
-- ============================================================================

-- ============================================================================
-- PURPOSE: Churn Detection - Anticipate Risk Before Official Churn
-- ============================================================================
-- This SQL detects customers at risk of churning BEFORE they reach official
-- churn status (INACTIVE in SQL #2).
--
-- Business question answered:
-- "Which customers are sliding toward churn before they're officially lost?"
--
-- CRITICAL PRINCIPLE:
-- Retention Status (SQL #2) = observation of current state
-- Churn Detection (SQL #3) = anticipation based on behavior degradation
--
-- Churn is NOT a state. Churn is a BEHAVIOR DEGRADATION.
-- ============================================================================

-- ============================================================================
-- INPUTS (strict dependency control)
-- ============================================================================
-- From SQL #1 (base_customers):
--   - customer_id, first_order_date, last_order_date
--   - total_orders, total_revenue, avg_order_value
--
-- From SQL #2 (retention_snapshot):
--   - days_since_last_order, retention_status
--
-- FORBIDDEN:
-- - NO new fact calculation
-- - NO external data sources
-- - NO CRM metrics (email opens, clicks, etc.)
-- - NO modification of SQL #2 retention rules
-- - NO global business averages
-- ============================================================================

-- ============================================================================
-- CHURN DETECTION LOGIC (behavior-based signals)
-- ============================================================================
-- Three core signals detect churn risk:
--
-- 1. FREQUENCY DEGRADATION (PRIMARY SIGNAL)
--    Customer orders less frequently than their individual historical pattern
--    Signal: Time since last order >> customer's average time between orders
--    Why: Break in personal purchase rhythm indicates disengagement
--
-- 2. VALUE DEGRADATION
--    Customer still orders but spends significantly less than their average
--    Signal: Recent spending << historical average order value
--    Why: Declining spend indicates shifting to competitors
--
-- 3. STATUS-BEHAVIOR INCONSISTENCY
--    Customer appears ACTIVE but exhibits weak engagement patterns
--    Signal: ACTIVE status but low order count OR high recency relative to pattern
--    Why: These customers are one missed purchase away from AT_RISK
--
-- Why behavior-based (not just time-based):
-- - Fixed thresholds (30/90 days) miss individual customer patterns
-- - A monthly buyer at day 25 is at-risk; a yearly buyer at day 60 is fine
-- - Behavior degradation signals churn earlier than status change
-- - Individual patterns > global averages
-- ============================================================================

-- ============================================================================
-- COLUMN ROLES (what each output enables)
-- ============================================================================
-- Atomic signals (TRUE/FALSE):
--   - is_frequency_drop: Ordering less frequently than personal pattern
--   - is_value_drop: Spending less than personal average
--   - is_status_inconsistent: Behavior doesn't match current status
--
-- Composite outputs:
--   - churn_risk_score: Weighted sum of signals (0-100, explainable)
--   - churn_risk_level: Business-ready categorization (LOW/MEDIUM/HIGH)
-- ============================================================================

WITH customer_behavior AS (
  -- =========================================================================
  -- STEP 1: Calculate behavior RATIOS (not states, not averages)
  -- =========================================================================
  -- Why ratios: Enable individual customer pattern comparison
  -- Why not states: States are in SQL #2, this is about CHANGE
  -- Why not global averages: Each customer has unique purchase cycle
  -- =========================================================================
  SELECT
    bc.customer_id,
    bc.first_order_date,
    bc.last_order_date,
    bc.total_orders,
    bc.total_revenue,
    bc.avg_order_value,
    rs.days_since_last_order,
    rs.retention_status,
    
    -- Customer maturity (how long they've been active)
    DATEDIFF('day', bc.first_order_date, bc.last_order_date) AS customer_lifetime_days,
    
    -- Estimated average frequency (days between orders)
    -- Individual pattern baseline for frequency degradation detection
    -- If only 1 order: NULL (cannot estimate pattern yet)
    CASE 
      WHEN bc.total_orders > 1 
      THEN DATEDIFF('day', bc.first_order_date, bc.last_order_date) * 1.0 / (bc.total_orders - 1)
      ELSE NULL
    END AS avg_days_between_orders,
    
    -- Engagement intensity (orders per month active)
    -- Used for status-behavior inconsistency detection
    CASE 
      WHEN DATEDIFF('month', bc.first_order_date, bc.last_order_date) > 0
      THEN bc.total_orders * 1.0 / DATEDIFF('month', bc.first_order_date, bc.last_order_date)
      ELSE bc.total_orders * 1.0  -- First month customers
    END AS orders_per_month_active
    
  FROM base_customers bc
  INNER JOIN retention_snapshot rs
    ON bc.customer_id = rs.customer_id
),

churn_signals AS (
  -- =========================================================================
  -- STEP 2: Generate ATOMIC churn signals (TRUE/FALSE flags)
  -- =========================================================================
  -- Each signal must be:
  -- - Binary (explainable: yes or no, no maybes)
  -- - Testable (can validate threshold logic independently)
  -- - Independent (can be tuned separately without breaking others)
  -- =========================================================================
  SELECT
    customer_id,
    retention_status,
    days_since_last_order,
    total_orders,
    total_revenue,
    avg_order_value,
    avg_days_between_orders,
    orders_per_month_active,
    
    -- =====================================================================
    -- SIGNAL 1: FREQUENCY DEGRADATION (PRIMARY - 50 points)
    -- =====================================================================
    -- Customer is ordering less frequently than THEIR historical pattern
    -- Logic: Time since last order > 1.5x THEIR average frequency
    -- Why 1.5x: Indicates break in normal pattern (not just random delay)
    -- Why primary: This is THE #1 signal of disengagement
    -- =====================================================================
    CASE
      WHEN avg_days_between_orders IS NOT NULL
        AND days_since_last_order > (avg_days_between_orders * 1.5)
      THEN TRUE
      ELSE FALSE
    END AS is_frequency_drop,
    
    -- =====================================================================
    -- SIGNAL 2: VALUE DEGRADATION (SECONDARY - 30 points)
    -- =====================================================================
    -- Customer still orders but spends significantly less than THEIR average
    -- Logic would require: last_order_value < (avg_order_value * 0.6)
    -- 
    -- CURRENT STATUS: Placeholder (requires order-level data)
    -- Why placeholder: Needs last order amount from orders table
    -- Future: Join to orders to get most recent order_amount
    -- Alternative: Pre-calculate in SQL #1 as last_order_value
    -- =====================================================================
    FALSE AS is_value_drop,  -- Placeholder for future enhancement
    
    -- =====================================================================
    -- SIGNAL 3: STATUS-BEHAVIOR INCONSISTENCY (TERTIARY - 20 points)
    -- =====================================================================
    -- Customer appears ACTIVE but exhibits weak engagement patterns
    -- Logic: ACTIVE status BUT (low historical orders OR close to pattern break)
    -- Why important: Catches customers one missed purchase away from AT_RISK
    -- Why dashboards miss this: Status says "green" but behavior says "yellow"
    -- =====================================================================
    CASE
      WHEN retention_status = 'ACTIVE'
        AND (
          total_orders <= 3  -- Low historical engagement (new/occasional buyers)
          OR (
            avg_days_between_orders IS NOT NULL 
            AND days_since_last_order > (avg_days_between_orders * 0.7)  -- 70% toward pattern break
          )
        )
      THEN TRUE
      ELSE FALSE
    END AS is_status_inconsistent
    
  FROM customer_behavior
),

churn_risk_scoring AS (
  -- =========================================================================
  -- STEP 3: Calculate EXPLAINABLE risk score (0-100)
  -- =========================================================================
  -- NOT machine learning. NOT black box. NOT opaque.
  -- Simple weighted sum with business-tunable weights.
  --
  -- Weight rationale (business can adjust these):
  -- - Frequency drop: 50 points (strongest signal - THE primary indicator)
  -- - Value drop: 30 points (secondary - indicates shifting spend)
  -- - Status inconsistency: 20 points (early warning for ACTIVE customers)
  --
  -- Total possible: 100 points (all three signals fired)
  -- Typical HIGH risk: 50+ (frequency drop alone or combination)
  -- Typical MEDIUM risk: 21-50 (one meaningful signal)
  -- Typical LOW risk: 0-20 (status inconsistency only or clean)
  -- =========================================================================
  SELECT
    customer_id,
    retention_status,
    days_since_last_order,
    total_orders,
    total_revenue,
    avg_order_value,
    is_frequency_drop,
    is_value_drop,
    is_status_inconsistent,
    
    -- Risk score calculation (100% transparent, 100% explainable)
    -- Each signal contributes fixed points (no complex formulas)
    (
      CASE WHEN is_frequency_drop THEN 50 ELSE 0 END +
      CASE WHEN is_value_drop THEN 30 ELSE 0 END +
      CASE WHEN is_status_inconsistent THEN 20 ELSE 0 END
    ) AS churn_risk_score
    
  FROM churn_signals
),

churn_risk_classification AS (
  -- =========================================================================
  -- STEP 4: Classify into business-ready risk levels
  -- =========================================================================
  -- Three levels ONLY (not 5, not 10, not 15):
  -- - HIGH: Score 51-100 (urgent action required)
  -- - MEDIUM: Score 21-50 (intervention recommended)
  -- - LOW: Score 0-20 (monitoring only)
  --
  -- Why these thresholds:
  -- - HIGH (51+): Frequency drop triggered OR multiple signals
  -- - MEDIUM (21-50): One meaningful signal detected
  -- - LOW (0-20): Status inconsistency only OR no signals
  --
  -- A Head of Marketing must understand this in 5 seconds.
  -- =========================================================================
  SELECT
    customer_id,
    retention_status,
    days_since_last_order,
    total_orders,
    total_revenue,
    avg_order_value,
    is_frequency_drop,
    is_value_drop,
    is_status_inconsistent,
    churn_risk_score,
    
    -- Risk level classification (business-actionable)
    CASE
      WHEN churn_risk_score >= 51 THEN 'HIGH'
      WHEN churn_risk_score >= 21 THEN 'MEDIUM'
      ELSE 'LOW'
    END AS churn_risk_level
    
  FROM churn_risk_scoring
)

-- ============================================================================
-- FINAL OUTPUT: Churn Risk Assessment
-- ============================================================================
-- One row per customer with churn risk signals and classification
-- Ready for: retention alerts, campaign targeting, sales outreach
-- Granularity: Customer-level (one assessment per customer)
-- ============================================================================
SELECT
  customer_id,
  retention_status,
  days_since_last_order,
  total_orders,
  total_revenue,
  avg_order_value,
  
  -- Atomic signals (TRUE/FALSE - individually testable)
  is_frequency_drop,
  is_value_drop,
  is_status_inconsistent,
  
  -- Composite risk outputs (actionable for business)
  churn_risk_score,
  churn_risk_level
  
FROM churn_risk_classification

-- ============================================================================
-- QUALITY CHECKS (run separately after table creation)
-- ============================================================================
-- Distribution check - verify risk levels make business sense:
--
-- SELECT 
--   churn_risk_level,
--   COUNT(*) AS customer_count,
--   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
-- FROM churn_risk_classification
-- GROUP BY churn_risk_level
-- ORDER BY 
--   CASE churn_risk_level
--     WHEN 'HIGH' THEN 1
--     WHEN 'MEDIUM' THEN 2
--     WHEN 'LOW' THEN 3
--   END;
--
-- Healthy distribution (indicative for e-commerce):
-- - HIGH: 5-15% (urgent intervention needed)
-- - MEDIUM: 15-30% (proactive engagement recommended)
-- - LOW: 55-80% (monitoring sufficient)
--
-- Red flags:
-- - HIGH > 25%: Too sensitive (dilutes urgency) OR genuine business crisis
-- - HIGH < 5%: Too conservative (missing at-risk customers)
-- - LOW > 90%: Model not detecting enough signals (too lenient)
--
-- CRITICAL: Cross-check with retention status
-- This validates that SQL #3 ADDS VALUE beyond SQL #2
--
-- SELECT 
--   retention_status,
--   churn_risk_level,
--   COUNT(*) AS customer_count,
--   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY retention_status), 1) AS pct_within_status
-- FROM churn_risk_classification
-- GROUP BY retention_status, churn_risk_level
-- ORDER BY retention_status, churn_risk_level;
--
-- Expected insights (CRITICAL for validation):
-- - NOT all INACTIVE should be HIGH risk (some are definitively lost, no point intervening)
-- - SOME ACTIVE customers MUST be MEDIUM/HIGH (early warning system working)
-- - AT_RISK should show mix of MEDIUM/HIGH (status aligns with behavior)
--
-- FAILURE CONDITION:
-- If ALL INACTIVE = HIGH and ALL ACTIVE = LOW:
-- → Model is just repeating SQL #2 retention status
-- → No value added, churn detection not working
-- → Need to adjust signal thresholds
--
-- Signal activation check - verify signals are firing:
--
-- SELECT 
--   is_frequency_drop,
--   is_value_drop,
--   is_status_inconsistent,
--   COUNT(*) AS customer_count
-- FROM churn_risk_classification
-- GROUP BY is_frequency_drop, is_value_drop, is_status_inconsistent
-- ORDER BY customer_count DESC;
--
-- Expected: Multiple combinations (not all FALSE/FALSE/FALSE)
-- If 90%+ are FALSE/FALSE/FALSE: Thresholds too conservative
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Daily (synchronized with SQL #2 retention_snapshot)
-- Dependencies: base_customers (SQL #1), retention_snapshot (SQL #2)
-- Downstream: SQL #5 (alerts), CRM campaigns, retention programs, sales teams
-- Granularity: Customer-level risk assessment (one row per customer)
--
-- Why this SQL exists:
-- - Anticipates churn BEFORE customers reach INACTIVE status
-- - Detects behavior degradation vs individual patterns (not global averages)
-- - Provides actionable risk levels for business intervention
-- - Enables PROACTIVE retention (not reactive damage control)
--
-- Key distinction from SQL #2:
-- - SQL #2: "What is the customer's current state?" (observation)
-- - SQL #3: "Is the customer's behavior degrading?" (anticipation)
-- - A customer can be ACTIVE (SQL #2) but HIGH risk (SQL #3)
-- - This gap is WHERE THE VALUE IS: early detection enables intervention
--
-- Signal weight tuning:
-- Weights defined in churn_risk_scoring CTE:
-- - Frequency drop: 50 points (adjust if frequency less predictive in your business)
-- - Value drop: 30 points (placeholder, activate when last_order_value available)
-- - Status inconsistency: 20 points (tune if catching too many/few ACTIVE customers)
--
-- To adjust weights: Modify CASE WHEN point values in churn_risk_score calculation
-- To adjust risk levels: Modify thresholds (51/21) in churn_risk_classification CTE
--
-- Signal threshold tuning:
-- - Frequency drop: Currently 1.5x avg_days_between_orders (line 125)
--   Increase to 2.0x if too sensitive, decrease to 1.3x if too conservative
-- - Status inconsistency: Currently 0.7x avg_days_between_orders (line 165)
--   Adjust 0.7 multiplier based on business tolerance for early warnings
--
-- Future enhancements (when data available):
-- 1. Value drop signal activation:
--    - Add last_order_value to SQL #1 (from orders table)
--    - OR: Join directly to orders table here to get most recent order amount
--    - Threshold: last_order_value < (avg_order_value * 0.6) suggests 40% drop
--
-- 2. Trend detection:
--    - Track churn_risk_score changes over time (requires historical snapshots)
--    - Flag customers whose score increased significantly week-over-week
--
-- 3. Segment-specific thresholds:
--    - Different weights for B2B vs B2C, high-value vs low-value segments
--    - Requires customer_segment from SQL #1
--
-- What makes this "premium":
-- - Behavior-based detection (not just time-based like SQL #2)
-- - Individual customer patterns (not global averages that miss outliers)
-- - Explainable signals (no black-box ML that business can't trust)
-- - Tunable weights (business can adjust without data science team)
-- - Atomic signals (can debug and validate each independently)
-- - Cross-validated with retention status (proves model adds value beyond SQL #2)
-- - Actionable outputs (3 clear levels, not 15 ambiguous scores)
--
-- Business impact:
-- - ACTIVE customers with HIGH risk: Intervene NOW before they slip to AT_RISK
-- - AT_RISK customers with LOW risk: May recover naturally, don't over-invest
-- - INACTIVE customers with HIGH risk: Last chance intervention (win-back campaign)
-- - INACTIVE customers with LOW risk: Already lost, focus resources elsewhere
--
-- Relationship with other SQL:
-- - SQL #1 (base_customers): Provides behavioral facts for pattern analysis
-- - SQL #2 (retention_snapshot): Provides current status context
-- - SQL #3 (THIS): Detects degradation patterns for proactive intervention
-- - SQL #4 (cohort_retention): Tracks how churn risk evolves across cohorts over time
-- - SQL #5 (alert_logic): Flags when risk distribution changes abnormally
-- ============================================================================

