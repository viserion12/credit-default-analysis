/*
    Credit Card Default Analysis
    PostgreSQL

    Source table: uci_credit_card
    Clean view:   credit_clients_clean
    Feature view: credit_features
*/


/* ================================================================
   1. INITIAL DATA QUALITY CHECKS
   ================================================================ */

-- Row count, unique clients and missing key fields.
SELECT
    COUNT(*) AS rows_count,
    COUNT(DISTINCT id) AS unique_clients,
    COUNT(*) FILTER (WHERE id IS NULL) AS null_ids,
    COUNT(*) FILTER (
        WHERE "default.payment.next.month" IS NULL
    ) AS null_targets
FROM uci_credit_card;


-- Duplicate client identifiers.
SELECT
    id,
    COUNT(*) AS rows_per_id
FROM uci_credit_card
GROUP BY id
HAVING COUNT(*) > 1
ORDER BY rows_per_id DESC, id;


-- Target distribution.
SELECT
    "default.payment.next.month" AS default_next_month,
    COUNT(*) AS clients_count,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (),
        2
    ) AS clients_pct
FROM uci_credit_card
GROUP BY "default.payment.next.month"
ORDER BY default_next_month;


-- Raw categorical values.
SELECT sex, COUNT(*) AS clients_count
FROM uci_credit_card
GROUP BY sex
ORDER BY sex;

SELECT education, COUNT(*) AS clients_count
FROM uci_credit_card
GROUP BY education
ORDER BY education;

SELECT marriage, COUNT(*) AS clients_count
FROM uci_credit_card
GROUP BY marriage
ORDER BY marriage;


-- Repayment-status distribution across all six observed months.
SELECT
    repayment_status,
    COUNT(*) AS observations
FROM uci_credit_card
CROSS JOIN LATERAL (
    VALUES
        (pay_0),
        (pay_2),
        (pay_3),
        (pay_4),
        (pay_5),
        (pay_6)
) AS payment_history(repayment_status)
GROUP BY repayment_status
ORDER BY repayment_status;


-- Numeric ranges and potentially unusual negative values.
SELECT
    MIN(age) AS min_age,
    MAX(age) AS max_age,
    MIN(limit_bal) AS min_credit_limit,
    MAX(limit_bal) AS max_credit_limit,

    MIN(LEAST(
        bill_amt1, bill_amt2, bill_amt3,
        bill_amt4, bill_amt5, bill_amt6
    )) AS min_bill,

    MAX(GREATEST(
        bill_amt1, bill_amt2, bill_amt3,
        bill_amt4, bill_amt5, bill_amt6
    )) AS max_bill,

    MIN(LEAST(
        pay_amt1, pay_amt2, pay_amt3,
        pay_amt4, pay_amt5, pay_amt6
    )) AS min_payment,

    MAX(GREATEST(
        pay_amt1, pay_amt2, pay_amt3,
        pay_amt4, pay_amt5, pay_amt6
    )) AS max_payment,

    COUNT(*) FILTER (
        WHERE LEAST(
            bill_amt1, bill_amt2, bill_amt3,
            bill_amt4, bill_amt5, bill_amt6
        ) < 0
    ) AS clients_with_negative_bill,

    COUNT(*) FILTER (
        WHERE LEAST(
            pay_amt1, pay_amt2, pay_amt3,
            pay_amt4, pay_amt5, pay_amt6
        ) < 0
    ) AS clients_with_negative_payment
FROM uci_credit_card;


/* ================================================================
   2. CLEAN ANALYTICAL VIEW
   ================================================================ */

CREATE OR REPLACE VIEW credit_clients_clean AS
SELECT
    c.*,

    CASE
        WHEN sex = 1 THEN 'male'
        WHEN sex = 2 THEN 'female'
        ELSE 'unknown'
    END AS sex_name,

    CASE
        WHEN education = 1 THEN 'graduate_school'
        WHEN education = 2 THEN 'university'
        WHEN education = 3 THEN 'high_school'
        WHEN education = 4 THEN 'other'
        ELSE 'unknown'
    END AS education_name,

    CASE
        WHEN marriage = 1 THEN 'married'
        WHEN marriage = 2 THEN 'single'
        WHEN marriage = 3 THEN 'other'
        ELSE 'unknown'
    END AS marriage_name,

    "default.payment.next.month" AS default_next_month

FROM uci_credit_card AS c;


-- The clean view must preserve the source grain: one row per client.
SELECT
    COUNT(*) AS rows_count,
    COUNT(DISTINCT id) AS unique_clients
FROM credit_clients_clean;


/* ================================================================
   3. EXPLORATORY SQL ANALYSIS
   ================================================================ */

-- Default rate by education.
SELECT
    education_name,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM credit_clients_clean
GROUP BY education_name
ORDER BY default_rate_pct DESC;


-- Default rate by sex.
SELECT
    sex_name,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM credit_clients_clean
GROUP BY sex_name
ORDER BY default_rate_pct DESC;


-- Default rate by marital status.
SELECT
    marriage_name,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM credit_clients_clean
GROUP BY marriage_name
ORDER BY default_rate_pct DESC;


-- Default rate by age group.
WITH age_segmented AS (
    SELECT
        CASE
            WHEN age < 30 THEN 'under_30'
            WHEN age < 40 THEN '30_39'
            WHEN age < 50 THEN '40_49'
            WHEN age < 60 THEN '50_59'
            ELSE '60_plus'
        END AS age_group,
        default_next_month
    FROM credit_clients_clean
)
SELECT
    age_group,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM age_segmented
GROUP BY age_group
ORDER BY default_rate_pct DESC;


-- Default rate by maximum repayment-delay status.
SELECT
    GREATEST(
        pay_0, pay_2, pay_3,
        pay_4, pay_5, pay_6
    ) AS max_delay_status,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM credit_clients_clean
GROUP BY max_delay_status
ORDER BY max_delay_status;


-- Maximum delay combined into stable business groups.
WITH delay_metrics AS (
    SELECT
        GREATEST(
            pay_0, pay_2, pay_3,
            pay_4, pay_5, pay_6
        ) AS max_delay_status,
        default_next_month
    FROM credit_clients_clean
),
delay_segmented AS (
    SELECT
        CASE
            WHEN max_delay_status <= 0 THEN 'no_delay'
            WHEN max_delay_status = 1 THEN 'delay_1_month'
            WHEN max_delay_status = 2 THEN 'delay_2_months'
            ELSE 'delay_3_plus'
        END AS delay_group,
        default_next_month
    FROM delay_metrics
)
SELECT
    delay_group,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM delay_segmented
GROUP BY delay_group
ORDER BY default_rate_pct;


-- Default rate by number of months in which a delay was observed.
SELECT
    (pay_0 > 0)::int +
    (pay_2 > 0)::int +
    (pay_3 > 0)::int +
    (pay_4 > 0)::int +
    (pay_5 > 0)::int +
    (pay_6 > 0)::int AS delayed_months_count,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(AVG(default_next_month) * 100, 2) AS default_rate_pct
FROM credit_clients_clean
GROUP BY delayed_months_count
ORDER BY delayed_months_count;


-- Default rate by current credit-limit utilization.
WITH utilization AS (
    SELECT
        id,
        default_next_month,
        bill_amt1::numeric
            / NULLIF(limit_bal::numeric, 0) AS utilization_ratio
    FROM credit_clients_clean
),
utilization_groups AS (
    SELECT
        id,
        default_next_month,
        utilization_ratio,

        CASE
            WHEN utilization_ratio <= 0 THEN 'zero_or_credit_balance'
            WHEN utilization_ratio < 0.30 THEN 'under_30_pct'
            WHEN utilization_ratio < 0.60 THEN '30_60_pct'
            WHEN utilization_ratio < 0.90 THEN '60_90_pct'
            WHEN utilization_ratio <= 1 THEN '90_100_pct'
            ELSE 'over_100_pct'
        END AS utilization_group,

        CASE
            WHEN utilization_ratio <= 0 THEN 1
            WHEN utilization_ratio < 0.30 THEN 2
            WHEN utilization_ratio < 0.60 THEN 3
            WHEN utilization_ratio < 0.90 THEN 4
            WHEN utilization_ratio <= 1 THEN 5
            ELSE 6
        END AS group_order

    FROM utilization
)
SELECT
    utilization_group,
    COUNT(*) AS clients_count,
    SUM(default_next_month) AS defaults_count,
    ROUND(
        (AVG(utilization_ratio) * 100)::numeric,
        2
    ) AS avg_utilization_pct,
    ROUND(
        (AVG(default_next_month) * 100)::numeric,
        2
    ) AS default_rate_pct
FROM utilization_groups
GROUP BY utilization_group, group_order
ORDER BY group_order;


/* ================================================================
   4. MODEL-READY FEATURE VIEW
   ================================================================ */

CREATE OR REPLACE VIEW credit_features AS
WITH metrics AS (
    SELECT
        id,
        limit_bal,
        age,
        sex_name,
        education_name,
        marriage_name,

        pay_0,
        pay_2,
        pay_3,
        pay_4,
        pay_5,
        pay_6,

        bill_amt1,
        bill_amt2,
        bill_amt3,
        bill_amt4,
        bill_amt5,
        bill_amt6,

        pay_amt1,
        pay_amt2,
        pay_amt3,
        pay_amt4,
        pay_amt5,
        pay_amt6,

        GREATEST(
            pay_0, pay_2, pay_3,
            pay_4, pay_5, pay_6
        ) AS max_delay_status,

        (pay_0 > 0)::int +
        (pay_2 > 0)::int +
        (pay_3 > 0)::int +
        (pay_4 > 0)::int +
        (pay_5 > 0)::int +
        (pay_6 > 0)::int AS delayed_months_count,

        (
            bill_amt1 + bill_amt2 + bill_amt3 +
            bill_amt4 + bill_amt5 + bill_amt6
        )::numeric / 6 AS avg_bill_amt,

        (
            pay_amt1 + pay_amt2 + pay_amt3 +
            pay_amt4 + pay_amt5 + pay_amt6
        )::numeric / 6 AS avg_payment_amt,

        bill_amt1::numeric
            / NULLIF(limit_bal::numeric, 0)
            * 100 AS current_utilization_pct,

        (
            (
                bill_amt1 + bill_amt2 + bill_amt3 +
                bill_amt4 + bill_amt5 + bill_amt6
            )::numeric / 6
        ) / NULLIF(limit_bal::numeric, 0)
            * 100 AS avg_utilization_pct,

        (bill_amt1 - bill_amt6)::numeric AS bill_change_amt,

        default_next_month

    FROM credit_clients_clean
)
SELECT
    id,
    limit_bal,
    age,

    CASE
        WHEN age < 30 THEN 'under_30'
        WHEN age < 40 THEN '30_39'
        WHEN age < 50 THEN '40_49'
        WHEN age < 60 THEN '50_59'
        ELSE '60_plus'
    END AS age_group,

    sex_name,
    education_name,
    marriage_name,

    pay_0,
    pay_2,
    pay_3,
    pay_4,
    pay_5,
    pay_6,

    bill_amt1,
    bill_amt2,
    bill_amt3,
    bill_amt4,
    bill_amt5,
    bill_amt6,

    pay_amt1,
    pay_amt2,
    pay_amt3,
    pay_amt4,
    pay_amt5,
    pay_amt6,

    max_delay_status,

    CASE
        WHEN max_delay_status <= 0 THEN 'no_delay'
        WHEN max_delay_status = 1 THEN 'delay_1_month'
        WHEN max_delay_status = 2 THEN 'delay_2_months'
        ELSE 'delay_3_plus'
    END AS delay_group,

    delayed_months_count,
    ROUND(avg_bill_amt, 2) AS avg_bill_amt,
    ROUND(avg_payment_amt, 2) AS avg_payment_amt,
    ROUND(current_utilization_pct, 2) AS current_utilization_pct,
    ROUND(avg_utilization_pct, 2) AS avg_utilization_pct,
    ROUND(bill_change_amt, 2) AS bill_change_amt,

    /*
        Approximate repayment intensity, not an exact share of debt repaid.
        Non-positive average bills are returned as NULL.
    */
    CASE
        WHEN avg_bill_amt > 0 THEN
            ROUND(avg_payment_amt / avg_bill_amt * 100, 2)
        ELSE NULL
    END AS payment_to_bill_pct,

    default_next_month

FROM metrics;


/* ================================================================
   5. FINAL FEATURE-VIEW VALIDATION
   ================================================================ */

SELECT
    COUNT(*) AS rows_count,
    COUNT(DISTINCT id) AS unique_clients,
    COUNT(*) FILTER (
        WHERE default_next_month IS NULL
    ) AS null_targets
FROM credit_features;


SELECT *
FROM credit_features
LIMIT 20;
