-- AML pipeline (PostgreSQL)
-- Create the database first (CREATE DATABASE aml_project;) and connect to it.
-- Run the steps one at a time.


-- STEP 1: Create tables (star schema)

DROP TABLE IF EXISTS ground_truth;
DROP TABLE IF EXISTS fact_transactions;
DROP TABLE IF EXISTS dim_accounts;
DROP TABLE IF EXISTS dim_customers;
DROP TABLE IF EXISTS dim_date;

CREATE TABLE dim_customers (
    Customer_ID           INT PRIMARY KEY,
    Full_Name             TEXT,
    Occupation            TEXT,
    Risk_Rating           TEXT,
    Country_of_Residence  TEXT,
    Is_PEP                INT      -- 1 = PEP, 0 = normal
);

CREATE TABLE dim_accounts (
    Account_ID       INT PRIMARY KEY,
    Customer_ID      INT REFERENCES dim_customers(Customer_ID),
    Account_Type     TEXT,
    Open_Date        DATE,
    Current_Balance  NUMERIC(14,2)
);

CREATE TABLE fact_transactions (
    Transaction_ID           INT PRIMARY KEY,
    Account_ID               INT REFERENCES dim_accounts(account_id),
    Transaction_Date         DATE,
    Transaction_Type         TEXT,
    Amount                   NUMERIC(14,2),
    Destination_Country      TEXT,
    Channel                  TEXT,
    Counterparty_Account_ID  INT     -- other account in a wire transfer
);

-- Planted suspicious accounts (answer key)
CREATE TABLE ground_truth (
    account_id  INT,
    typology    TEXT,
    case_id     INT
);


-- STEP 2: Load the CSV files (run these in psql)
-- \copy dim_customers     FROM 'data/customers.csv'     CSV HEADER
-- \copy dim_accounts      FROM 'data/accounts.csv'      CSV HEADER
-- \copy fact_transactions FROM 'data/transactions.csv'  CSV HEADER
-- \copy ground_truth      FROM 'data/ground_truth.csv'  CSV HEADER

CREATE INDEX idx_txn_account_date ON fact_transactions(account_id, transaction_date);
CREATE INDEX idx_txn_type         ON fact_transactions(transaction_type);

-- Calendar table for Power BI
CREATE TABLE dim_date AS
SELECT
    d::date                           AS date_key,
    EXTRACT(YEAR  FROM d)::int        AS year,
    EXTRACT(MONTH FROM d)::int        AS month,
    TO_CHAR(d, 'Mon')                 AS month_name,
    EXTRACT(ISODOW FROM d)::int >= 6  AS is_weekend
FROM generate_series('2025-01-01'::date, '2025-12-31'::date, '1 day') AS d;


-- STEP 3: Data quality checks (first three should return 0)

-- transactions with no matching account
SELECT COUNT(*) AS orphan_transactions
FROM fact_transactions t
LEFT JOIN dim_accounts a ON a.account_id = t.account_id
WHERE a.account_id IS NULL;

-- missing or non-positive amounts
SELECT COUNT(*) AS bad_amounts
FROM fact_transactions
WHERE amount IS NULL OR amount <= 0;

-- dates not in the calendar table
SELECT COUNT(*) AS dates_outside_calendar
FROM fact_transactions t
LEFT JOIN dim_date d ON d.date_key = t.transaction_date
WHERE d.date_key IS NULL;

-- average and max amount by transaction type
SELECT
    transaction_type,
    COUNT(*)            AS how_many,
    ROUND(AVG(amount))  AS average_amount,
    MAX(amount)         AS biggest_amount
FROM fact_transactions
GROUP BY transaction_type
ORDER BY how_many DESC;


-- STEP 4: Detection rules

-- Rule 1: Structuring
-- 3+ cash deposits between Rs 8L and Rs 10L within 3 days, total of Rs 10L or more
CREATE OR REPLACE VIEW vw_structuring AS
WITH cash_deposits AS (
    SELECT
        account_id,
        transaction_date,
        amount,
        CASE WHEN amount >= 800000 AND amount < 1000000 THEN 1 ELSE 0 END AS is_just_under
    FROM fact_transactions
    WHERE transaction_type = 'Cash Deposit'
),
rolling AS (
    SELECT
        account_id,
        SUM(amount)        OVER three_days AS total_3_days,
        SUM(is_just_under) OVER three_days AS just_under_count
    FROM cash_deposits
    WINDOW three_days AS (
        PARTITION BY account_id
        ORDER BY transaction_date
        RANGE BETWEEN INTERVAL '2 days' PRECEDING AND CURRENT ROW   -- today + 2 previous days
    )
)
SELECT DISTINCT account_id, 'Structuring' AS rule
FROM rolling
WHERE just_under_count >= 3
  AND total_3_days >= 1000000;


-- Rule 2: Rapid movement of funds
-- wire in of Rs 10L or more, then 70%+ sent to a high-risk country within 2 days
CREATE OR REPLACE VIEW vw_rapid_movement AS
SELECT DISTINCT
    money_in.account_id,
    'Rapid Movement' AS rule
FROM fact_transactions AS money_in
JOIN fact_transactions AS money_out
      ON money_out.account_id = money_in.account_id
WHERE money_in.transaction_type   = 'Wire Transfer In'
  AND money_in.amount            >= 1000000
  AND money_out.transaction_type  = 'Wire Transfer Out'
  AND money_out.destination_country IN ('Cayman Islands', 'Panama', 'Switzerland')
  AND money_out.transaction_date BETWEEN money_in.transaction_date
                                     AND money_in.transaction_date + 2
  AND money_out.amount >= 0.7 * money_in.amount;


-- Rule 3: Round tripping
-- A -> B -> C -> A, each hop within 7 days and 95-100% of the previous amount
CREATE OR REPLACE VIEW vw_round_trip AS
WITH loops AS (
    SELECT
        hop1.account_id AS account_a,
        hop2.account_id AS account_b,
        hop3.account_id AS account_c
    FROM fact_transactions AS hop1
    -- hop 2: B pays C
    JOIN fact_transactions AS hop2
          ON hop2.account_id = hop1.counterparty_account_id
         AND hop2.transaction_type = 'Wire Transfer Out'
         AND hop2.transaction_date BETWEEN hop1.transaction_date AND hop1.transaction_date + 7
         AND hop2.amount BETWEEN 0.95 * hop1.amount AND hop1.amount
    -- hop 3: C pays A back
    JOIN fact_transactions AS hop3
          ON hop3.account_id = hop2.counterparty_account_id
         AND hop3.counterparty_account_id = hop1.account_id
         AND hop3.transaction_type = 'Wire Transfer Out'
         AND hop3.transaction_date BETWEEN hop2.transaction_date AND hop2.transaction_date + 7
         AND hop3.amount BETWEEN 0.95 * hop2.amount AND hop2.amount
    WHERE hop1.transaction_type = 'Wire Transfer Out'
      AND hop1.amount >= 500000
)
SELECT account_a AS account_id, 'Round Tripping' AS rule FROM loops
UNION
SELECT account_b, 'Round Tripping' FROM loops
UNION
SELECT account_c, 'Round Tripping' FROM loops;


-- All alerts together
CREATE OR REPLACE VIEW vw_alerts AS
SELECT account_id, rule FROM vw_structuring
UNION ALL
SELECT account_id, rule FROM vw_rapid_movement
UNION ALL
SELECT account_id, rule FROM vw_round_trip;


-- Risk score per account
-- Rule points: Structuring 40, Rapid Movement 40, Round Tripping 30
-- Customer points: PEP +20, High risk +10, Medium risk +5
CREATE OR REPLACE VIEW vw_account_risk AS
WITH alert_points AS (
    SELECT
        account_id,
        COUNT(*) AS rules_triggered,
        SUM(CASE rule
                WHEN 'Structuring'    THEN 40
                WHEN 'Rapid Movement' THEN 40
                WHEN 'Round Tripping' THEN 30
            END) AS rule_points
    FROM vw_alerts
    GROUP BY account_id
)
SELECT
    a.account_id,
    c.customer_id,
    c.full_name,
    c.risk_rating,
    c.is_pep,
    COALESCE(ap.rules_triggered, 0) AS rules_triggered,
    COALESCE(ap.rule_points, 0)
        + CASE WHEN c.is_pep = 1 THEN 20 ELSE 0 END
        + CASE c.risk_rating WHEN 'High' THEN 10 WHEN 'Medium' THEN 5 ELSE 0 END
        AS risk_score
FROM dim_accounts a
JOIN dim_customers c       ON c.customer_id = a.customer_id
LEFT JOIN alert_points ap  ON ap.account_id = a.account_id;


-- STEP 5: Compare alerts with ground_truth (precision and recall)
WITH alert_check AS (
    SELECT
        al.rule,
        CASE WHEN gt.typology = al.rule THEN 1 ELSE 0 END AS is_correct
    FROM (SELECT DISTINCT account_id, rule FROM vw_alerts) AS al
    LEFT JOIN ground_truth AS gt ON gt.account_id = al.account_id
),
guilty_total AS (
    SELECT typology AS rule, COUNT(*) AS guilty_accounts
    FROM ground_truth
    GROUP BY typology
)
SELECT
    c.rule,
    COUNT(*)                                                 AS alerts_raised,
    SUM(c.is_correct)                                        AS correct_alerts,
    ROUND(100.0 * SUM(c.is_correct) / COUNT(*), 1)           AS precision_pct,
    ROUND(100.0 * SUM(c.is_correct) / g.guilty_accounts, 1)  AS recall_pct
FROM alert_check c
JOIN guilty_total g ON g.rule = c.rule
GROUP BY c.rule, g.guilty_accounts;


-- Same evaluation saved as a view
CREATE OR REPLACE VIEW vw_rule_performance AS
WITH alert_check AS (
    SELECT al.rule,
           CASE WHEN gt.typology = al.rule THEN 1 ELSE 0 END AS is_correct
    FROM (SELECT DISTINCT account_id, rule FROM vw_alerts) AS al
    LEFT JOIN ground_truth AS gt ON gt.account_id = al.account_id
),
guilty_total AS (
    SELECT typology AS rule, COUNT(*) AS guilty_accounts
    FROM ground_truth
    GROUP BY typology
)
SELECT
    g.rule,
    COUNT(c.rule)                                       AS alerts_raised,
    COALESCE(SUM(c.is_correct), 0)                      AS true_positives,
    COUNT(c.rule) - COALESCE(SUM(c.is_correct), 0)      AS false_positives,
    g.guilty_accounts - COALESCE(SUM(c.is_correct), 0)  AS false_negatives,
    g.guilty_accounts,
    ROUND(100.0 * COALESCE(SUM(c.is_correct), 0) / NULLIF(COUNT(c.rule), 0), 1) AS precision_pct,
    ROUND(100.0 * COALESCE(SUM(c.is_correct), 0) / g.guilty_accounts, 1)        AS recall_pct
FROM guilty_total g
LEFT JOIN alert_check c ON c.rule = g.rule
GROUP BY g.rule, g.guilty_accounts;


-- STEP 6: Extra window function examples

-- LAG: days since the previous cash deposit
WITH deposit_gaps AS (
    SELECT
        account_id,
        transaction_date,
        amount,
        LAG(transaction_date) OVER (PARTITION BY account_id
                                    ORDER BY transaction_date) AS previous_deposit_date
    FROM fact_transactions
    WHERE transaction_type = 'Cash Deposit'
)
SELECT
    account_id,
    previous_deposit_date,
    transaction_date,
    transaction_date - previous_deposit_date AS days_since_previous,
    amount
FROM deposit_gaps
WHERE amount >= 800000
  AND transaction_date - previous_deposit_date <= 2
ORDER BY account_id, transaction_date
LIMIT 20;


-- Running total of large cash deposits for accounts flagged for structuring
SELECT
    account_id,
    transaction_date,
    amount,
    SUM(amount) OVER (PARTITION BY account_id
                      ORDER BY transaction_date, transaction_id) AS running_total
FROM fact_transactions
WHERE transaction_type = 'Cash Deposit'
  AND amount >= 800000
  AND account_id IN (SELECT account_id FROM vw_structuring)
ORDER BY account_id, transaction_date
LIMIT 20;


-- ROW_NUMBER: top 3 riskiest accounts in each customer risk rating
WITH ranked AS (
    SELECT
        risk_rating,
        account_id,
        full_name,
        risk_score,
        ROW_NUMBER() OVER (PARTITION BY risk_rating
                           ORDER BY risk_score DESC, account_id) AS rank_in_group
    FROM vw_account_risk
)
SELECT *
FROM ranked
WHERE rank_in_group <= 3
ORDER BY risk_rating, rank_in_group;
