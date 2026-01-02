# Customer Retention Ownership System - Business Documentation

> **About This README**  
> This business-focused documentation is designed for **Analytics Managers, Product Managers, and Data Consultants** who need to understand **how the retention metric is structured, what business logic drives each layer, and how decisions are made**. Reading time: **10-15 minutes**. This document explains the "why" and "what" without diving into SQL implementation details. For executive overview, see `README.md`. For technical implementation, see `README_technical.md`.

---

## Table of Contents

1. [Business Definition of Customer Retention](#business-definition-of-customer-retention)
2. [The Retention Ownership Framework](#the-retention-ownership-framework)
3. [Five-Layer Architecture Explained](#five-layer-architecture-explained)
4. [Decision Logic & Thresholds](#decision-logic--thresholds)
5. [Business Use Cases & Workflows](#business-use-cases--workflows)
6. [How to Read & Interpret Outputs](#how-to-read--interpret-outputs)
7. [Assumptions & Business Model Adaptations](#assumptions--business-model-adaptations)

---

## Business Definition of Customer Retention

### What Retention Is (And Isn't)

**Retention is NOT:**
- A marketing vanity metric ("90% of customers stay!")
- A single percentage calculated once per quarter
- A dashboard KPI that nobody owns

**Retention IS:**
- **Revenue stability indicator:** Retained customers generate predictable recurring revenue
- **Product-market fit signal:** High retention = customers find sustained value
- **Operational efficiency driver:** Retention costs 5-7x less than new acquisition
- **Early warning system:** Degrading retention predicts revenue decline before it happens

### Our Premium Definition

In this system, **Customer Retention** is measured across three dimensions:

1. **State** (SQL #2): What is the customer's current engagement level?
2. **Risk** (SQL #3): Is the customer's behavior degrading toward churn?
3. **Trend** (SQL #4): How does retention quality evolve across customer cohorts?

This multi-dimensional view enables **proactive intervention** (act before customers churn) instead of **reactive reporting** (count customers after they left).

---

## The Retention Ownership Framework

### Core Principle: Separation of Concerns

Most analytics systems mix everything together: facts, business rules, calculations, decisions. When business rules change (e.g., "let's define churn as 120 days instead of 90"), the entire system breaks.

**Our architecture separates:**

```
FACTS (immutable)
  ↓
LOGIC (time-dependent)
  ↓
RISK (behavioral)
  ↓
TRENDS (strategic)
  ↓
ACTIONS (decisional)
```

**Why this matters:**
- **Maintainability:** Change retention definition without touching raw data
- **Auditability:** Every layer is testable and explainable independently
- **Scalability:** Add new metrics (LTV, NPS) without breaking retention
- **Trust:** Business can validate logic without reading SQL

---

## Five-Layer Architecture Explained

### Layer 1: Base Customers (SQL #1) - The Foundation

**What it does:**  
Establishes the **single source of truth** for customer facts.

**Key outputs:**
- `customer_id`: Unique identifier
- `first_order_date`: When did this customer first purchase?
- `last_order_date`: When was their most recent purchase?
- `total_orders`: Lifetime order count
- `total_revenue`: Lifetime spending
- `avg_order_value`: Average spend per order

**Critical principle:**  
This layer contains **FACTS ONLY**. No calculations that change over time (e.g., "days since last order" is NOT here because it changes daily).

**Business value:**  
Provides stable foundation for all downstream analysis. If a customer had 5 orders totaling €500, this will NEVER change regardless of when you run the query.

---

### Layer 2: Retention Status (SQL #2) - Current State

**What it does:**  
Applies **time-dependent business logic** to classify customers into retention states.

**Key outputs:**
- `retention_status`: ACTIVE | AT_RISK | INACTIVE
- `days_since_last_order`: Recency metric (changes with reference date)

**Business logic:**
```
ACTIVE:     Last order within 30 days   → High engagement, no action needed
AT_RISK:    Last order 31-90 days ago   → Intervention window, campaigns recommended
INACTIVE:   Last order 90+ days ago     → Dormant, win-back required
```

**Why INACTIVE instead of "CHURNED":**  
- INACTIVE = current state (can reactivate with new purchase)
- CHURNED = predicted permanent loss (calculated in SQL #3)
- This distinction is critical for marketing: inactive customers can still be saved

**Business value:**  
Enables **segmented campaigns**: send retention emails to AT_RISK, win-back offers to INACTIVE, loyalty rewards to ACTIVE.

**Adjustable thresholds:**  
The 30/90-day boundaries are **industry-dependent**:
- Fast fashion: 15/45 days
- Luxury retail: 60/180 days
- B2B SaaS: 30/90 days (aligned with billing cycles)

---

### Layer 3: Churn Detection (SQL #3) - Behavioral Risk

**What it does:**  
Detects customers **sliding toward churn BEFORE they reach INACTIVE status**.

**The problem SQL #2 doesn't solve:**  
A customer who normally orders every 10 days but is now at day 25 is technically ACTIVE (under 30 days), but their behavior is degrading. Fixed thresholds miss this.

**Key innovation:**  
Risk is based on **individual behavior patterns**, not global averages.

**Risk signals:**
1. **Frequency Drop:** Customer orders less often than their personal historical pattern
   - Logic: Time since last order > 1.5x their average frequency
   - Example: Monthly buyer (30-day pattern) at day 45 = HIGH RISK
   
2. **Value Drop:** Customer spends significantly less than their average *(placeholder for future)*
   - Logic: Recent order < 60% of historical average order value
   - Requires: Last order amount (future enhancement)

3. **Status Inconsistency:** Customer is ACTIVE but shows weak engagement
   - Logic: ACTIVE status BUT (low order count OR close to pattern break)
   - Example: Customer with only 3 orders who is at day 25 = MEDIUM RISK

**Risk scoring:**
- Frequency drop: 50 points (primary signal)
- Value drop: 30 points (secondary signal)
- Status inconsistency: 20 points (early warning)
- **Total: 0-100 points**

**Risk levels:**
- HIGH (51-100): Frequency drop triggered → urgent intervention
- MEDIUM (21-50): One meaningful signal → proactive engagement
- LOW (0-20): Normal behavior → monitoring only

**Business value:**  
Enables **early intervention**: Marketing can target HIGH-risk ACTIVE customers (hidden risk) instead of waiting until they become AT_RISK (obvious risk).

**Real-world example:**  
E-commerce company identifies 200 ACTIVE customers with HIGH churn risk. Sends personalized offers. Prevents 40% from moving to AT_RISK. Saves €50K revenue that quarter.

---

### Layer 4: Cohort Retention Evolution (SQL #4) - Strategic Trends

**What it does:**  
Tracks **how retention patterns evolve across customer acquisition cohorts**.

**What is a cohort:**  
A cohort = all customers who made their first purchase in the same month.
- Example: January 2024 cohort = customers whose `first_order_date` was in Jan 2024

**What is cohort maturity:**  
Maturity = months since acquisition.
- M+0: Acquisition month (retention should be ~100%)
- M+1: First month after acquisition
- M+6: Six months into customer lifetime
- M+12: One year retention benchmark

**Key metric:**  
`retention_rate` = % of cohort customers active at M+N

**Example cohort analysis:**

| Cohort | M+0 | M+3 | M+6 | M+12 |
|--------|-----|-----|-----|------|
| Jan 2024 | 100% | 65% | 45% | 35% |
| Feb 2024 | 100% | 68% | 48% | 38% |
| Mar 2024 | 100% | 70% | 52% | 42% |

**What this tells you:**
- **Horizontal reading:** Jan 2024 cohort loses 65% of customers by M+12
- **Vertical reading:** Recent cohorts (Feb, Mar) retain better at same maturity
- **Diagonal reading:** Retention quality is improving over time (42% vs 35%)

**Business implications:**
- **Improving retention:** Product improvements or better acquisition quality
- **Declining retention:** Product-market fit issues or increased competition
- **Stable retention:** Mature business with predictable customer lifetime

**Why this is strategic (not operational):**  
SQL #4 answers "Are we getting better at retention long-term?" not "Which customers should we target this week?" (that's SQL #3).

**Business value:**  
Informs **investment decisions**: If retention improves, justify increased marketing spend. If retention declines, investigate product/experience issues.

---

### Layer 5: Alert Logic (SQL #5) - Automated Decisions

**What it does:**  
Monitors retention metrics and **triggers actions** when abnormal deviations occur.

**The problem it solves:**  
Dashboards are passive. Someone must manually check them daily and decide if a metric requires action. Most companies miss critical changes until too late.

**Alert scope:**  
SQL #5 monitors **ONE metric**: Percentage of AT_RISK customers.

**Why AT_RISK (not ACTIVE or INACTIVE):**
- ACTIVE: No action needed (customers are engaged)
- INACTIVE: Often too late (customer already disengaged)
- **AT_RISK: Maximum intervention impact** (still engaged, but slipping)

**Alert logic:**

1. **Baseline:** 7-day rolling average of AT_RISK percentage
   - Why 7 days: Smooths daily noise, captures weekly patterns
   - Alternative: 14-day (more stable) or 28-day (monthly patterns)

2. **Current value:** Today's AT_RISK percentage

3. **Delta calculation:**
   - Absolute delta: Current - Baseline (percentage points)
   - Relative delta: (Current / Baseline - 1) × 100 (percentage change)

4. **Thresholds:**
   - WARNING: +15% relative increase vs baseline
   - CRITICAL: +25% relative increase vs baseline
   - Example: Baseline 20% → WARNING at 23% → CRITICAL at 25%

5. **Anti-noise filters:**
   - Minimum 100 customers (prevents alerts on tiny samples)
   - Valid baseline exists (requires 7 days of history)
   - Severity > INFO (only WARNING or CRITICAL trigger alerts)

**Alert output:**

```
alert_flag: TRUE
severity: CRITICAL
metric_name: at_risk_pct
current_value: 25.3%
baseline_value: 20.1%
delta_pct: +5.2 percentage points
delta_relative_pct: +25.9%
sample_size: 1,847 customers
```

**What happens next:**
- Slack notification: "@marketing-team CRITICAL: AT_RISK customers up 26% vs baseline"
- Email automation: Send alert details to retention team
- Ticketing: Create Jira ticket for campaign launch
- CRM trigger: Activate win-back automation

**Why only one metric:**  
Monitoring 15 metrics generates 40 alerts/day. Teams ignore them. Monitoring 1 critical metric generates 2-3 alerts/month. Teams act on them.

**Business value:**  
Converts **reactive firefighting** (noticing problems after revenue drops) into **proactive intervention** (acting when risk is detected).

**Real-world example:**  
AT_RISK percentage spikes from 20% to 26% over 3 days. Alert triggers. Marketing launches flash campaign targeting 450 AT_RISK customers. 35% convert back to ACTIVE. Prevents €75K revenue loss.

---

## Decision Logic & Thresholds

### Why Thresholds Are Explicit (Not Hidden)

Every threshold in this system is **documented and justified**:

**SQL #2 - Retention Status:**
- 30 days ACTIVE threshold: Standard e-commerce monthly purchase cycle
- 90 days INACTIVE threshold: Industry benchmark for customer dormancy
- Adjustable per business model (documented in SQL comments)

**SQL #3 - Churn Detection:**
- 1.5x frequency multiplier: Indicates pattern break (not random delay)
- 50/30/20 point weights: Frequency > Value > Status (tunable)
- 51% HIGH threshold: Ensures frequency drop = HIGH risk

**SQL #5 - Alert Logic:**
- +15% WARNING: Meaningful deviation requiring attention
- +25% CRITICAL: Urgent intervention needed
- 7-day baseline: Weekly pattern stability
- 100 customer minimum: Statistical significance

**Why this matters:**  
When a business stakeholder asks "Why did this alert trigger?", you can point to exact thresholds and explain the reasoning. No black-box ML. No "the algorithm decided."

---

## Business Use Cases & Workflows

### Use Case 1: Marketing Retention Campaign

**Scenario:** Marketing wants to prevent Q4 churn spike.

**Workflow:**
1. Query SQL #3 (churn_detection) for HIGH-risk customers
2. Filter by retention_status = 'ACTIVE' (hidden risk segment)
3. Export customer_id list to CRM
4. Launch personalized offers targeting 300 customers
5. Track conversion back to LOW risk in SQL #3
6. Measure ROI: Campaign cost vs prevented churn revenue

**Expected outcome:**  
30-40% of targeted customers remain ACTIVE instead of sliding to AT_RISK.

---

### Use Case 2: Product-Market Fit Validation

**Scenario:** Product team launched new feature in March 2024. Did it improve retention?

**Workflow:**
1. Query SQL #4 (cohort_retention) for Feb, Mar, Apr 2024 cohorts
2. Compare retention_rate at M+3, M+6 across cohorts
3. Check if Mar/Apr cohorts retain better than Feb at same maturity
4. If yes: Feature improved retention → expand feature
5. If no: Feature didn't impact retention → investigate why

**Expected outcome:**  
Data-driven decision on feature investment vs sunsetting.

---

### Use Case 3: Executive Revenue Forecasting

**Scenario:** CFO needs Q1 2026 revenue forecast with retention inputs.

**Workflow:**
1. Query SQL #4 for latest cohorts (Oct-Dec 2025)
2. Extract retention_rate at M+3 (most recent predictive data)
3. Apply retention curve to new customer acquisition forecast
4. Calculate expected recurring revenue: New customers × Retention curve × AOV
5. Present range: Best case (retention improves), Base case (stable), Worst case (declines)

**Expected outcome:**  
Revenue forecast with retention-driven confidence intervals.

---

### Use Case 4: Automated Operations Alert

**Scenario:** Operations wants automated alerts without daily dashboard checks.

**Workflow:**
1. Schedule SQL #5 (alert_logic) to run daily at 6 AM
2. Configure Slack webhook to post when alert_flag = TRUE
3. Set severity-based routing:
   - WARNING → #retention-monitoring channel
   - CRITICAL → #executive-alerts channel + email
4. Include alert context: current_value, delta_pct, sample_size
5. Link to SQL #3 for drill-down (which customers are HIGH risk?)

**Expected outcome:**  
Team acts on 2-3 critical alerts per month instead of missing gradual degradation.

---

## How to Read & Interpret Outputs

### SQL #2 Output: Retention Status Distribution

**Sample output:**

| retention_status | customer_count | status_pct |
|------------------|----------------|------------|
| ACTIVE | 1,245 | 28.5% |
| AT_RISK | 982 | 22.5% |
| INACTIVE | 2,140 | 49.0% |

**Interpretation:**
- **Healthy e-commerce:** ACTIVE 25-35%, AT_RISK 15-25%, INACTIVE 40-60%
- **Problem:** AT_RISK > 30% = too many customers slipping
- **Action:** If AT_RISK rising, investigate recent product/service changes

---

### SQL #3 Output: Churn Risk Levels

**Sample output:**

| churn_risk_level | customer_count |
|------------------|----------------|
| HIGH | 287 |
| MEDIUM | 645 |
| LOW | 3,435 |

**Interpretation:**
- **HIGH risk (287):** Immediate intervention candidates
- **Cross-reference with SQL #2:** How many HIGH-risk are still ACTIVE? (hidden risk)
- **Campaign priority:** Target HIGH first, then MEDIUM if capacity allows

---

### SQL #4 Output: Cohort Retention Heatmap

**Sample output:**

| cohort_month | months_since | retention_rate |
|--------------|--------------|----------------|
| 2024-01 | M+0 | 100.0% |
| 2024-01 | M+3 | 65.0% |
| 2024-01 | M+6 | 45.0% |
| 2024-02 | M+0 | 100.0% |
| 2024-02 | M+3 | 68.0% |

**Interpretation:**
- **Diagonal reading:** Feb cohort (68%) retains better than Jan (65%) at M+3
- **Trend:** Retention quality improving (good sign)
- **Benchmark:** Industry average M+6 retention = 40-50% (we're at 45% = on target)

---

### SQL #5 Output: Alert Decision

**Sample output:**

| alert_flag | severity | current_value | baseline_value | delta_pct |
|------------|----------|---------------|----------------|-----------|
| TRUE | CRITICAL | 25.3% | 20.1% | +25.9% |

**Interpretation:**
- **Alert triggered:** AT_RISK percentage spiked 26% above baseline
- **Action required:** Launch retention campaign within 24-48 hours
- **Sample size:** 1,847 customers (statistically significant)

---

## Assumptions & Business Model Adaptations

### E-Commerce Assumptions (Default)

This system is built on **e-commerce monthly purchase cycle assumptions**:

**SQL #2 thresholds:**
- ACTIVE: 30 days (assumes monthly purchases)
- INACTIVE: 90 days (3 months without purchase = dormant)

**SQL #3 behavior patterns:**
- Frequency drop: 1.5x individual average (monthly buyers detected at 45 days)

**SQL #4 cohort maturity:**
- Analyzed up to M+12 (one year customer lifetime)

**SQL #5 baseline:**
- 7-day rolling average (weekly pattern stability)

---

### Adaptations for Other Business Models

#### B2B SaaS (Annual Contracts)

**Changes required:**
- **SQL #2:** ACTIVE = 30 days, AT_RISK = 60 days (align with billing)
- **SQL #3:** Focus on usage metrics (logins, feature adoption) instead of purchase frequency
- **SQL #4:** Cohort maturity up to M+36 (3-year contracts)
- **SQL #5:** Monitor contract renewal risk, not purchase frequency

---

#### Luxury Retail (6-12 Month Purchase Cycles)

**Changes required:**
- **SQL #2:** ACTIVE = 90 days, AT_RISK = 180 days, INACTIVE = 365 days
- **SQL #3:** 1.5x multiplier on 6-month baseline = 9 months before alert
- **SQL #4:** M+24 analysis window (2-year customer maturity)
- **SQL #5:** 28-day baseline (monthly patterns too noisy)

---

#### Fast Fashion (High Frequency)

**Changes required:**
- **SQL #2:** ACTIVE = 15 days, AT_RISK = 30 days, INACTIVE = 60 days
- **SQL #3:** 1.5x multiplier on weekly baseline = 10 days before alert
- **SQL #4:** M+6 analysis window (6-month customer lifetime)
- **SQL #5:** 7-day baseline (weekly promotions drive patterns)

---

#### Subscription Services (Explicit Renewal)

**Changes required:**
- **SQL #2:** ACTIVE = subscription active, AT_RISK = 30 days before renewal, INACTIVE = subscription cancelled
- **SQL #3:** Monitor engagement metrics (usage drops) instead of purchase frequency
- **SQL #4:** Track retention by subscription tier (basic vs premium)
- **SQL #5:** Alert on cancellation rate spikes, not purchase frequency

---

### How to Adjust Thresholds

All thresholds are **externalized and documented** in SQL comments:

**Example from SQL #2:**
```sql
-- RETENTION THRESHOLDS (business configuration)
-- ACTIVE_THRESHOLD    = 30 days (recent buyer, high engagement)
-- AT_RISK_THRESHOLD   = 90 days (silent period, intervention needed)
-- INACTIVE_THRESHOLD  = 90+ days (dormant, win-back required)
--
-- To adjust: modify CASE logic in 'retention_snapshot' CTE
```

**Process to adapt:**
1. Identify your business model (e-commerce, SaaS, luxury, etc.)
2. Review threshold recommendations above
3. Update threshold values in SQL comments
4. Modify CASE logic to use new thresholds
5. Test on historical data (run with past reference_dates)
6. Validate with business stakeholders
7. Deploy to production

---

## Summary: The Value of Ownership

This system doesn't just calculate retention metrics.

It **owns the retention metric end-to-end**:

- **SQL #1:** Ensures data quality (facts never drift)
- **SQL #2:** Provides current state (operational segmentation)
- **SQL #3:** Predicts future risk (early intervention)
- **SQL #4:** Tracks strategic trends (investment decisions)
- **SQL #5:** Triggers automated action (closes the loop)

**The result:**  
Retention becomes a **decision-triggering asset**, not a passive dashboard number.

Marketing acts on alerts instead of guessing when to intervene.  
Product validates features with cohort data instead of anecdotal feedback.  
Finance forecasts revenue with retention curves instead of gut feel.  
Executives monitor health via automated alerts instead of weekly dashboard reviews.

**This is what metric ownership looks like.**

---

## Next Steps

**For operational implementation:**  
See `README_technical.md` for SQL deployment, refresh schedules, and data pipeline integration.

**For executive alignment:**  
See `README.md` for strategic positioning and business case justification.

**For questions or consulting:**  
Contact for retention metric implementation, audit, or optimization engagements.

---

**Last Updated:** January 2026  
**Version:** 1.0
