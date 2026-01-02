# Customer Retention Ownership System - Technical Reference

> **About This README**  
> This is the **technical memory** of the system. Read this when: (1) returning to the project after months, (2) auditing implementation decisions, (3) extending the system, or (4) transmitting knowledge to another data engineer. This document assumes SQL proficiency and focuses on **conventions, parameters, constraints, and rationale**—not tutorials.

---

## System Overview

**Architecture:** 5-layer SQL pipeline  
**Database:** SQL-compatible (BigQuery, Snowflake, PostgreSQL, Redshift)  
**Refresh:** Daily incremental (SQL #1-3, #5) + Monthly batch (SQL #4)  
**Parameters:** All queries use `@reference_date` for reproducibility  
**Dependencies:** `orders` table → SQL #1 → SQL #2-5 (no circular dependencies)

---

## File Structure

```
/sql/
  01_base_customers.sql       # Facts layer (IMMUTABLE)
  02_retention_status.sql     # Status layer (TIME-DEPENDENT)
  03_churn_detection.sql      # Risk layer (BEHAVIORAL)
  04_cohort_retention.sql     # Trend layer (STRATEGIC)
  05_alert_logic.sql          # Action layer (DECISIONAL)

/docs/
  customer_retention_definition.pdf  # Business metric definition
```

---

## Critical Design Principles

### 1. Facts vs Derived Metrics

**Rule:** If a value changes when you re-run the query at a different time → NOT a fact.

**SQL #1 contains:**
- ✅ `last_order_date` (fact - immutable historical date)
- ✅ `total_orders` (fact - count at time of calculation)

**SQL #1 does NOT contain:**
- ❌ `days_since_last_order` (derived - changes daily)
- ❌ `customer_lifetime_months` (snapshot - changes as time passes)

**Why:** Facts tables must be stable. Business logic belongs in downstream queries.

---

### 2. Parameterization

**Every SQL uses `@reference_date`:**
```sql
DATEDIFF('day', last_order_date, @reference_date)
```

**Never:**
```sql
DATEDIFF('day', last_order_date, CURRENT_DATE)  -- ❌ Non-reproducible
```

**Benefit:** Run query for any historical date. Test logic. Audit decisions.

---

### 3. CTE Naming Convention

**Pattern:** `<purpose>_<type>`

Examples:
- `cohort_assignment` (assigns cohort to customers)
- `retention_snapshot` (calculates retention status)
- `churn_signals` (detects churn signals)

**NOT:**
- `temp_table_1` (meaningless)
- `data` (too generic)

---

### 4. Immutable Cohorts

**SQL #4 Rule:** A customer's cohort NEVER changes.

```sql
DATE_TRUNC('month', first_order_date) AS cohort_month
```

**Why:** Cohort analysis requires stable groups. Recalculating cohorts breaks historical comparisons.

---

## SQL Modules: Technical Details

### SQL #1: base_customers

**Input:** `orders` table  
**Output:** One row per customer  
**Grain:** `customer_id` (unique)  
**Refresh:** Daily incremental (only new/updated customers)

**Key logic:**
- Aggregates orders table by `customer_id`
- Calculates `first_order_date` (MIN), `last_order_date` (MAX)
- Computes `total_orders`, `total_revenue`, `avg_order_value`

**Critical constraint:**
- No temporal calculations (no `days_since_last_order`)
- All columns are **snapshot facts** at time of calculation

**Performance:**
- Index on `customer_id`, `first_order_date`, `last_order_date`
- Partition by `first_order_date` if > 10M customers

---

### SQL #2: retention_status

**Input:** `base_customers` (SQL #1)  
**Output:** One row per customer at `@reference_date`  
**Grain:** `customer_id` + `snapshot_date`  
**Refresh:** Daily (must align with SQL #1 refresh)

**Parameters:**
- `@reference_date` (REQUIRED): Date for status calculation

**Thresholds (externalized in CTE):**
```sql
WITH retention_thresholds AS (
  SELECT 30 AS active_days, 90 AS at_risk_days
)
```

**Key logic:**
- Calculates `days_since_last_order` = DATEDIFF(last_order_date, @reference_date)
- Assigns status: ACTIVE (0-30d), AT_RISK (31-90d), INACTIVE (90+d)
- Includes data quality guard: `DATA_QUALITY_ISSUE` if days < 0

**Naming rationale:**
- `INACTIVE` (not `CHURNED`): State vs probability distinction
- SQL #3 calculates churn probability (behavioral risk)

**Production notes:**
- Store as materialized view `retention_snapshot`
- Partition by `snapshot_date` (query performance)
- Retention policy: Keep 90 days history minimum (for SQL #5 baseline)

---

### SQL #3: churn_detection

**Input:** `base_customers` (SQL #1) + `retention_snapshot` (SQL #2)  
**Output:** One row per customer with risk assessment  
**Grain:** `customer_id`  
**Refresh:** Daily (after SQL #2 refresh)

**Signal weights (tunable):**
```sql
CASE WHEN is_frequency_drop THEN 50 ELSE 0 END +
CASE WHEN is_value_drop THEN 30 ELSE 0 END +
CASE WHEN is_status_inconsistent THEN 20 ELSE 0 END
```

**Key thresholds:**
- Frequency drop: `1.5x avg_days_between_orders`
- Status inconsistency: `0.7x avg_days_between_orders` (70% toward break)
- Risk levels: LOW (0-20), MEDIUM (21-50), HIGH (51-100)

**Signal: is_value_drop**
- Status: Placeholder (currently `FALSE`)
- Requires: `last_order_value` from orders table
- Logic: `last_order_value < (avg_order_value * 0.6)`
- To activate: Add last order join or enhance SQL #1

**Noise filter:**
- Excludes customers with only 1 order (cannot estimate frequency)

**Production notes:**
- Cross-validate with SQL #2: Some ACTIVE should be HIGH risk (early warning working)
- If all INACTIVE = HIGH: Model just repeats SQL #2 (not adding value)

---

### SQL #4: cohort_retention

**Input:** `base_customers` (SQL #1) + `orders` table  
**Output:** One row per cohort per maturity month  
**Grain:** `cohort_month` + `months_since_acquisition`  
**Refresh:** Monthly (or when historical data updates)

**Critical principle:**
- NO `@reference_date` parameter (pure historical analysis)
- NO `CURRENT_DATE` anywhere (agnostic of present)

**Cohort definition:**
```sql
DATE_TRUNC('month', first_order_date) AS cohort_month
```

**Maturity calculation:**
```sql
DATEDIFF('month', cohort_month, activity_month) AS months_since_acquisition
```

**Retention rate formula:**
```sql
(active_customers * 100.0 / cohort_size)
```

**Where:**
- `cohort_size` = initial customers in cohort (constant)
- `active_customers` = customers active at M+N (variable)

**Frozen window option:**
```sql
WHERE months_since_acquisition <= 12  -- For comparability
```

**Data quality assumptions:**
- `orders.order_date` in consistent timezone (UTC recommended)
- Orders table contains completed/validated orders only (no cancelled/pending)

**Production notes:**
- Output naming: `cohort_retention_evolution` (materialized view)
- Visualization: Heatmap (cohort_month × months_since_acquisition)

---

### SQL #5: alert_logic

**Input:** `retention_snapshot` (SQL #2)  
**Output:** One row per `@reference_date` with alert decision  
**Grain:** `alert_date` (one decision per day)  
**Refresh:** Daily (after SQL #2 refresh)

**Scope:** Single metric (AT_RISK percentage)

**Baseline:** 7-day rolling average
```sql
AVG(status_pct) OVER (
  ORDER BY snapshot_date 
  ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
)
```

**Thresholds:**
```sql
15.0 AS threshold_warning   -- +15% relative increase
25.0 AS threshold_critical  -- +25% relative increase
```

**Severity logic:**
```sql
CASE
  WHEN delta_relative_pct >= 25.0 THEN 'CRITICAL'
  WHEN delta_relative_pct >= 15.0 THEN 'WARNING'
  ELSE 'INFO'
END
```

**Anti-noise filters:**
```sql
sample_size >= 100  -- Minimum customers
AND baseline_value IS NOT NULL  -- Requires 7-day history
AND severity IN ('WARNING', 'CRITICAL')  -- Only actionable
```

**Alert flag:**
```sql
alert_flag = TRUE  -- Only if all filters pass
```

**Consumption:**
- Slack webhook: POST when `alert_flag = TRUE`
- Email: Daily digest of WARNING+ alerts
- Jira: Create ticket for CRITICAL

**Warmup period:** First 7 days have NULL baseline (expected, document in runbook)

---

## Parameter Reference

### @reference_date

**Type:** DATE  
**Required:** All queries except SQL #4  
**Format:** 'YYYY-MM-DD' or CURRENT_DATE  

**Usage:**
```sql
-- Historical analysis
SET @reference_date = '2025-12-15';

-- Live monitoring
SET @reference_date = CURRENT_DATE;
```

**Why required:** Ensures reproducibility. Same date = same results.

---

## Threshold Tuning Guide

### SQL #2: Retention Status

**Current:** 30/90 days (e-commerce)

**Adjust for:**
- Fast fashion: 15/45 days
- Luxury retail: 60/180 days
- B2B SaaS: 30/90 days (align with billing)

**Location:** `retention_thresholds` CTE (lines 70-72)

---

### SQL #3: Churn Detection

**Current:** 1.5x frequency multiplier

**Increase to 2.0x if:** Too many false positives (HIGH risk not converting)  
**Decrease to 1.3x if:** Missing real churn (HIGH risk too late)

**Location:** `churn_signals` CTE (line 125)

---

### SQL #5: Alert Logic

**Current:** +15% WARNING, +25% CRITICAL

**Increase thresholds if:** Too many alerts (alert fatigue)  
**Decrease thresholds if:** Missing real issues (degradation undetected)

**Location:** `threshold_evaluation` CTE (lines 161-162)

---

## Performance Considerations

### Indexing Strategy

**SQL #1:**
```sql
CREATE INDEX idx_customer_id ON base_customers(customer_id);
CREATE INDEX idx_first_order ON base_customers(first_order_date);
```

**SQL #2:**
```sql
CREATE INDEX idx_snapshot_date ON retention_snapshot(snapshot_date);
CREATE INDEX idx_retention_status ON retention_snapshot(retention_status);
```

**SQL #4:**
```sql
CREATE INDEX idx_cohort_month ON cohort_retention_evolution(cohort_month);
CREATE INDEX idx_maturity ON cohort_retention_evolution(months_since_acquisition);
```

---

### Partitioning

**For > 10M customers:**

```sql
-- SQL #1
PARTITION BY RANGE(first_order_date)

-- SQL #2
PARTITION BY snapshot_date

-- SQL #4
PARTITION BY cohort_month
```

---

## Quality Checks (Production Validation)

### SQL #1: Base Customers

```sql
-- No duplicate customers
SELECT customer_id, COUNT(*) 
FROM base_customers 
GROUP BY customer_id 
HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- No negative values
SELECT * FROM base_customers 
WHERE total_orders < 0 OR total_revenue < 0;
-- Expected: 0 rows
```

---

### SQL #2: Retention Status

```sql
-- All customers have exactly 1 status
SELECT customer_id, COUNT(DISTINCT retention_status)
FROM retention_snapshot
WHERE snapshot_date = @reference_date
GROUP BY customer_id
HAVING COUNT(DISTINCT retention_status) > 1;
-- Expected: 0 rows

-- M+0 should be ~100%
SELECT cohort_month, retention_rate
FROM cohort_retention_evolution
WHERE months_since_acquisition = 0 AND retention_rate < 95;
-- Expected: 0 rows
```

---

### SQL #3: Churn Detection

```sql
-- Risk score in valid range
SELECT * FROM churn_detection
WHERE churn_risk_score < 0 OR churn_risk_score > 100;
-- Expected: 0 rows

-- Cross-validation with SQL #2
SELECT 
  retention_status,
  churn_risk_level,
  COUNT(*)
FROM churn_detection
GROUP BY retention_status, churn_risk_level;
-- Expected: Some ACTIVE with HIGH risk (model working)
```

---

### SQL #5: Alert Logic

```sql
-- Baseline exists after warmup
SELECT * FROM alert_logic
WHERE alert_date > DATE_ADD(@reference_date, -8)
  AND baseline_value IS NULL;
-- Expected: 0 rows (except first 7 days)
```

---

## Extension Points

### Adding New Signals (SQL #3)

**To add engagement score:**

1. Compute metric in `customer_behavior` CTE
2. Create signal in `churn_signals` CTE
3. Add weight in `churn_risk_scoring` CTE (e.g., 15 points)
4. Document in SQL comments

---

### Adding Revenue Metrics (SQL #4)

**To track revenue retention:**

```sql
-- Add to cohort_retention_aggregation CTE
SUM(revenue) AS cohort_revenue,
SUM(revenue) / cohort_size AS revenue_per_customer
```

---

### Multi-Metric Alerts (SQL #5)

**To monitor INACTIVE percentage:**

1. Duplicate SQL #5
2. Rename to `06_alert_logic_inactive.sql`
3. Change filter: `WHERE retention_status = 'INACTIVE'`
4. Adjust thresholds (INACTIVE rising = different severity)

---

## Deployment Checklist

- [ ] Create `orders` table with indexes
- [ ] Run SQL #1 (base_customers) → validate row count
- [ ] Run SQL #2 (retention_status) with @reference_date = CURRENT_DATE
- [ ] Validate retention distribution (ACTIVE 20-40%, AT_RISK 15-25%)
- [ ] Run SQL #3 (churn_detection) → validate signal activation
- [ ] Run SQL #4 (cohort_retention) → validate M+0 ≈ 100%
- [ ] Run SQL #5 (alert_logic) → wait 7 days for baseline
- [ ] Schedule daily refresh (SQL #1-3, #5)
- [ ] Schedule monthly refresh (SQL #4)
- [ ] Configure Slack webhook for alert_flag = TRUE
- [ ] Document runbook for alert response

---

## Troubleshooting

### "Alert not triggering despite visual spike"

**Check:**
1. Sample size >= 100? (noise filter)
2. Baseline exists? (requires 7-day history)
3. Delta >= threshold? (15% or 25%)

---

### "Cohort retention rate > 100%"

**Cause:** Cohort size denominator incorrect

**Fix:** Validate `cohort_size_baseline` CTE in SQL #4

---

### "SQL #3 all customers LOW risk"

**Cause:** Thresholds too conservative OR all customers stable

**Fix:** Decrease frequency multiplier (1.5x → 1.3x)

---

## Conventions Summary

| Convention | Rule |
|------------|------|
| **Naming** | snake_case (SQL), PascalCase (avoid) |
| **CTEs** | Named by purpose_type pattern |
| **Comments** | Explain WHY, not WHAT |
| **Parameters** | Prefix with @ symbol |
| **Thresholds** | Externalize in CTE or constants |
| **Dates** | ISO format (YYYY-MM-DD) |
| **Grain** | Always document in header |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-01-02 | Initial system (SQL #1-5) |
| v2.0 | TBD | Add value_drop signal (SQL #3) |
| v2.1 | TBD | Multi-segment cohorts (SQL #4) |

---

## Maintenance Notes

**Annual review:**
- Validate thresholds with current business cycle
- Check cohort maturity windows (SQL #4)
- Review alert frequency (SQL #5)
- Update business model assumptions

**When to rebuild:**
- Business model changes (e.g., subscription → transactional)
- Acquisition channel shift (B2C → B2B)
- Retention definition changes (regulatory, strategic)

---

**Last Updated:** January 2026  
**Maintainer:** François Tilkin  
**Next Review:** January 2027
