-- ============================================================================
-- Metric: Customer Retention
-- Owner: François Tilkin
-- Version: v2.0
-- Last update: 2026-01-02
-- Business definition aligned with: docs/customer_retention_definition.pdf
-- ============================================================================

-- ============================================================================
-- PURPOSE: Base Customer Table - Source of Truth
-- ============================================================================
-- This SQL creates a clean, stable foundation for all retention calculations.
-- One row = one unique customer with their core behavioral FACTS ONLY.
-- 
-- CRITICAL PRINCIPLE:
-- This table contains ONLY facts that do not change with reference date.
-- All time-dependent calculations (recency, lifetime, etc.) happen in downstream SQL.
-- 
-- Why: A source of truth must be stable. If it changes daily, it's not truth.
-- ============================================================================

-- ============================================================================
-- CUSTOMER DEFINITION (BUSINESS RULES)
-- ============================================================================
-- A customer EXISTS when: First order placed (first_order_date IS NOT NULL)
-- A customer is ACTIVE when: Has placed ≥1 order in lifetime
-- A customer can DISAPPEAR: No (remains in base with historical data)
-- A customer can REAPPEAR: Yes (dormant → active via new order)
-- Granularity: Day-level precision on all date fields
-- ============================================================================

-- ============================================================================
-- WHAT BELONGS IN BASE_CUSTOMERS (FACTS ONLY)
-- ============================================================================
-- ✅ FACTS (immutable or append-only):
--    - first_order_date (never changes)
--    - last_order_date (updates only when new order)
--    - total_orders (append-only counter)
--    - total_revenue (append-only sum)
--    - customer attributes (email, country, etc.)
--
-- ❌ NOT FACTS (time-dependent derived metrics):
--    - days_since_last_order (changes daily → calculate in SQL #2)
--    - customer_lifetime_months (changes monthly → calculate in SQL #4)
--    - retention_status (business logic → calculate in SQL #2)
--    - churn_risk (business logic → calculate in SQL #3)
-- ============================================================================

-- ============================================================================
-- COLUMN ROLES (what each fact enables in downstream SQL)
-- ============================================================================
-- first_order_date  → SQL #4 (cohort assignment)
-- last_order_date   → SQL #2 (recency calculation for retention status)
-- total_orders      → SQL #3 (baseline behavior for churn detection)
-- total_revenue     → SQL #5 (alert prioritization by customer value)
-- avg_order_value   → SQL #3 (basket behavior analysis)
-- ============================================================================

WITH customer_orders AS (
  -- =========================================================================
  -- STEP 1: Aggregate order-level data to customer level
  -- =========================================================================
  -- Why: One customer may have multiple orders
  -- Goal: Consolidate to one row per customer with factual order history
  -- =========================================================================
  SELECT
    customer_id,
    
    -- Temporal facts (dates, not durations)
    -- These are FACTS because they don't change with reference date
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    
    -- Volume facts (append-only counters)
    COUNT(DISTINCT order_id) AS total_orders,
    
    -- Revenue facts (append-only sums and averages)
    SUM(order_amount) AS total_revenue,
    AVG(order_amount) AS avg_order_value
    
  FROM orders
  GROUP BY customer_id
),

customer_attributes AS (
  -- =========================================================================
  -- STEP 2: Enrich with customer master data
  -- =========================================================================
  -- Why: Add customer profile context (not order-dependent)
  -- Goal: Enable segmentation and filtering in downstream analysis
  -- =========================================================================
  SELECT
    c.customer_id,
    c.customer_email,
    c.country,
    c.customer_segment,      -- Example: B2B/B2C, VIP tier
    c.acquisition_channel,   -- Example: Organic, Paid, Referral
    c.signup_date
    
  FROM customers c
)

-- ============================================================================
-- FINAL OUTPUT: Base Customer Table
-- ============================================================================
-- One row per customer who has placed at least one order
-- Contains ONLY factual data (dates, counts, sums - no time-dependent derivations)
-- All calculations (recency, lifetime, retention status, etc.) happen in downstream SQL
-- ============================================================================
SELECT
  -- Primary identifier
  co.customer_id,
  
  -- Customer profile attributes (facts from master data)
  ca.customer_email,
  ca.country,
  ca.customer_segment,
  ca.acquisition_channel,
  ca.signup_date,
  
  -- Temporal facts (dates only, not durations)
  -- Why dates and not durations: dates are immutable facts
  -- Durations (days_since, months_since) are calculated in downstream SQL
  co.first_order_date,
  co.last_order_date,
  
  -- Volume facts (append-only)
  co.total_orders,
  
  -- Revenue facts (append-only)
  co.total_revenue,
  co.avg_order_value

FROM customer_orders co
LEFT JOIN customer_attributes ca
  ON co.customer_id = ca.customer_id

-- Filter: Only customers with at least one completed order
-- Why: Cannot calculate retention for customers who never purchased
WHERE co.total_orders >= 1
  AND co.first_order_date IS NOT NULL

-- ============================================================================
-- QUALITY CHECKS (run separately after table creation)
-- ============================================================================
-- Uncomment to validate base customer table integrity:
--
-- SELECT 
--   COUNT(*) AS total_customers,
--   COUNT(DISTINCT customer_id) AS unique_customers,
--   MIN(first_order_date) AS earliest_customer,
--   MAX(last_order_date) AS most_recent_order,
--   AVG(total_orders) AS avg_orders_per_customer,
--   AVG(total_revenue) AS avg_revenue_per_customer,
--   -- Check for data quality issues
--   SUM(CASE WHEN first_order_date > last_order_date THEN 1 ELSE 0 END) AS invalid_date_order,
--   SUM(CASE WHEN total_revenue < 0 THEN 1 ELSE 0 END) AS negative_revenue,
--   SUM(CASE WHEN total_orders <= 0 THEN 1 ELSE 0 END) AS zero_orders
-- FROM base_customers;
--
-- Expected: total_customers = unique_customers (no duplicates)
-- Expected: invalid_date_order = 0 (dates are coherent)
-- Expected: negative_revenue = 0 (revenue is valid)
-- Expected: zero_orders = 0 (filtered by WHERE clause)
-- ============================================================================

-- ============================================================================
-- PRODUCTION NOTES
-- ============================================================================
-- Refresh frequency: Daily (or whenever new orders are processed)
-- Dependencies: Requires 'orders' and 'customers' tables
-- Downstream: All retention/churn/cohort/alert SQL depend on this foundation
-- Performance: Consider indexing on customer_id, first_order_date, last_order_date
-- 
-- Why this table exists:
-- - Separates factual data aggregation (here) from business logic (downstream SQL)
-- - Provides stable foundation that doesn't change when retention rules change
-- - Enables clear testing (facts don't change, logic does)
-- - Makes debugging easier (if retention is wrong, base_customers is not the issue)
-- - Respects the principle: "A source of truth must be stable over time"
-- 
-- What makes this "premium":
-- - Only contains facts (dates, counts, sums) that don't depend on reference date
-- - All time-dependent calculations (recency, lifetime) happen in SQL #2, #3, #4
-- - This table can be refreshed without changing historical customer facts
-- - Clear separation of concerns: facts here, logic elsewhere
-- ============================================================================
