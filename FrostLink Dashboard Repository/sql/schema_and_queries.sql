-- =====================================================================
-- FrostLink Solutions: Cold Storage Operations Dashboard
-- schema_and_queries.sql   (PostgreSQL / Supabase)
--
-- Contents
--   1. Schema          : six tables, keys, indexes
--   2. Views           : calculated columns used by the Power BI model
--   3. Analytical queries, grouped by dashboard page
--        Overview, Inbound, Putaway, Inventory, Outbound, Expiry
--   4. Data-quality checks
--
-- Notes
--   * Column names are snake_case. The Power BI model uses spaces in some
--     inbound columns ("inbound id", "dock clearance time", ...); map them
--     to the names below when loading.
--   * Time-of-day fields (arrival, clearance, scan, pick, departure) are
--     stored as TIME. They carry no date.
--   * Reference date for "latest" expiry queries = MAX(snapshot_date).
-- =====================================================================


-- =====================================================================
-- 1. SCHEMA
-- =====================================================================

DROP VIEW  IF EXISTS v_expiry, v_dcc, v_outbound, v_putaway, v_inbound CASCADE;
DROP TABLE IF EXISTS outbound, expiry_monitor, cycle_count, putaway, inbound, pallet CASCADE;

-- Pallet master ------------------------------------------------------
CREATE TABLE pallet (
    pallet_id       TEXT PRIMARY KEY,
    sku             TEXT NOT NULL,
    commodity       TEXT NOT NULL,
    category        TEXT NOT NULL,
    subcategory     TEXT,
    batch_number    TEXT,
    lot_number      TEXT,
    supplier_code   TEXT NOT NULL,
    mfg_date        DATE NOT NULL,
    exp_date        DATE NOT NULL,
    quantity_lb     NUMERIC(12,2) NOT NULL CHECK (quantity_lb > 0),
    storage_room    TEXT NOT NULL,
    location        TEXT NOT NULL,
    price_per_lb    NUMERIC(10,2) NOT NULL,          -- PHP
    inventory_value NUMERIC(14,2) GENERATED ALWAYS AS (quantity_lb * price_per_lb) STORED,
    CHECK (exp_date >= mfg_date)
);

-- Receiving events ----------------------------------------------------
CREATE TABLE inbound (
    inbound_id            TEXT PRIMARY KEY,
    pallet_id             TEXT NOT NULL REFERENCES pallet (pallet_id),
    receipt_date          DATE NOT NULL,
    commodity             TEXT NOT NULL,
    category              TEXT NOT NULL,
    supplier_code         TEXT NOT NULL,
    quantity_lb           NUMERIC(12,2) NOT NULL,
    truck_arrival_time    TIME NOT NULL,
    dock_clearance_time   TIME NOT NULL,
    putaway_complete_time TIME NOT NULL,
    receiving_dock        TEXT NOT NULL,
    temp_at_receipt_c     NUMERIC(5,1) NOT NULL,
    batch_number          TEXT,
    exp_date              DATE,
    storage_room          TEXT NOT NULL,
    employee_tag          TEXT,
    employee_id           TEXT,
    condition_on_arrival  TEXT NOT NULL,             -- Good / Damaged / Partial
    po_number             TEXT,
    shift                 TEXT
);

-- Dock-to-rack moves --------------------------------------------------
CREATE TABLE putaway (
    putaway_id          TEXT PRIMARY KEY,
    pallet_id           TEXT NOT NULL REFERENCES pallet (pallet_id),
    putaway_date        DATE NOT NULL,
    commodity           TEXT,
    employee_id         TEXT,
    employee_tag        TEXT,
    equipment_used      TEXT NOT NULL,
    scan_time_dock      TIME NOT NULL,
    scan_time_rack      TIME NOT NULL,
    travel_time_seconds INTEGER NOT NULL CHECK (travel_time_seconds >= 0),
    storage_room        TEXT NOT NULL,
    to_location         TEXT,
    inbound_id          TEXT NOT NULL REFERENCES inbound (inbound_id),
    shift               TEXT,
    from_location       TEXT
);

-- Daily cycle counts --------------------------------------------------
CREATE TABLE cycle_count (
    count_id             TEXT PRIMARY KEY,
    count_date           DATE NOT NULL,
    pallet_id            TEXT NOT NULL REFERENCES pallet (pallet_id),
    location             TEXT,
    storage_room         TEXT NOT NULL,
    commodity            TEXT,
    system_quantity_lb   NUMERIC(12,2) NOT NULL,
    physical_quantity_lb NUMERIC(12,2) NOT NULL,
    variance_lb          NUMERIC(12,2) NOT NULL,     -- physical - system
    variance_pct         NUMERIC(8,3),
    variance_reason      TEXT NOT NULL,              -- 'None' when counts agree
    employee_id          TEXT,
    employee_tag         TEXT,
    count_duration_min   INTEGER,
    recount_required     TEXT NOT NULL CHECK (recount_required IN ('Yes','No'))
);

-- Weekly expiry snapshots --------------------------------------------
CREATE TABLE expiry_monitor (
    monitor_id       TEXT PRIMARY KEY,
    snapshot_date    DATE NOT NULL,
    pallet_id        TEXT NOT NULL REFERENCES pallet (pallet_id),
    commodity        TEXT,
    category         TEXT,
    batch_number     TEXT,
    storage_room     TEXT,
    location         TEXT,
    quantity_lb      NUMERIC(12,2) NOT NULL,
    expiry_date      DATE NOT NULL,
    days_to_expiry   INTEGER NOT NULL,
    expiry_risk_flag TEXT NOT NULL CHECK (expiry_risk_flag IN ('OK','Watch','Warning','Critical')),
    action_taken     TEXT NOT NULL                   -- None / Priority Dispatch / Disposed
);

-- Dispatch events -----------------------------------------------------
CREATE TABLE outbound (
    outbound_id             TEXT PRIMARY KEY,
    dispatch_date           DATE NOT NULL,
    order_number            TEXT,
    pallet_id               TEXT NOT NULL UNIQUE REFERENCES pallet (pallet_id),
    commodity               TEXT,
    category                TEXT NOT NULL,
    customer_code           TEXT,
    quantity_lb             NUMERIC(12,2) NOT NULL,
    pick_start_time         TIME NOT NULL,
    pick_complete_time      TIME NOT NULL,
    truck_departure_time    TIME NOT NULL,
    employee_id             TEXT,
    employee_tag            TEXT,
    storage_room            TEXT,
    temp_at_dispatch_c      NUMERIC(5,1) NOT NULL,
    dispatch_dock           TEXT,
    order_fulfillment_status TEXT NOT NULL           -- Complete / Partial / Short-picked
);

CREATE INDEX idx_inbound_pallet   ON inbound (pallet_id);
CREATE INDEX idx_inbound_receipt  ON inbound (receipt_date);
CREATE INDEX idx_putaway_inbound  ON putaway (inbound_id);
CREATE INDEX idx_cc_pallet        ON cycle_count (pallet_id);
CREATE INDEX idx_cc_date          ON cycle_count (count_date);
CREATE INDEX idx_exp_pallet       ON expiry_monitor (pallet_id);
CREATE INDEX idx_exp_snapshot     ON expiry_monitor (snapshot_date);
CREATE INDEX idx_out_date         ON outbound (dispatch_date);

-- Loading (run from psql; adjust paths and make sure the CSV column order
-- matches the table definitions above, or load into a staging table first):
--   \copy pallet         FROM 'data/00_pallet.csv'   CSV HEADER
--   \copy inbound        FROM 'data/01_inbound.csv'  CSV HEADER
--   \copy putaway        FROM 'data/02_putaway.csv'  CSV HEADER
--   \copy cycle_count    FROM 'data/03_dcc.csv'      CSV HEADER
--   \copy expiry_monitor FROM 'data/04_expiry.csv'   CSV HEADER
--   \copy outbound       FROM 'data/05_outbound.csv' CSV HEADER
-- Load order matters because of foreign keys: pallet, inbound, putaway,
-- cycle_count, expiry_monitor, outbound.


-- =====================================================================
-- 2. VIEWS  (calculated columns that exist in the Power BI model)
-- =====================================================================

-- Whole minutes between two TIME values, counting minute boundaries
-- crossed (same behaviour as DAX DATEDIFF(..., MINUTE)); +24h if the
-- interval crosses midnight.
CREATE OR REPLACE FUNCTION minutes_between(t_from TIME, t_to TIME)
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$
    SELECT CASE
        WHEN FLOOR(EXTRACT(EPOCH FROM t_to) / 60) - FLOOR(EXTRACT(EPOCH FROM t_from) / 60) < 0
            THEN (FLOOR(EXTRACT(EPOCH FROM t_to) / 60) - FLOOR(EXTRACT(EPOCH FROM t_from) / 60) + 1440)::INTEGER
        ELSE (FLOOR(EXTRACT(EPOCH FROM t_to) / 60) - FLOOR(EXTRACT(EPOCH FROM t_from) / 60))::INTEGER
    END
$$;

CREATE VIEW v_inbound AS
SELECT i.*,
       minutes_between(i.truck_arrival_time,  i.dock_clearance_time)   AS arrival_to_clearance_min,
       minutes_between(i.dock_clearance_time, i.putaway_complete_time) AS dock_to_rack_min,
       (i.condition_on_arrival <> 'Good')                              AS is_damaged_or_partial,
       -- Temperature rule from the Power BI measure:
       --   frozen categories  -18 to -16 C ; Dairy / Nuts / Other  -10 to -8 C
       CASE
         WHEN i.category IN ('Poultry','Red Meat','Frozen Veg','Frozen Fruit','Frozen Eggs')
              THEN i.temp_at_receipt_c BETWEEN -18 AND -16
         WHEN i.category IN ('Dairy','Nuts','Other')
              THEN i.temp_at_receipt_c BETWEEN -10 AND -8
         ELSE FALSE
       END AS temp_in_range
FROM inbound i;

CREATE VIEW v_putaway AS
SELECT p.*,
       p.travel_time_seconds / 60.0 AS travel_time_min
FROM putaway p;

CREATE VIEW v_outbound AS
SELECT o.*,
       minutes_between(o.pick_start_time,    o.pick_complete_time)  AS pick_duration_min,
       minutes_between(o.pick_complete_time, o.truck_departure_time) AS pick_to_departure_min,
       -- 'On Time' in the Power BI model = pick-to-departure of 60 minutes or less.
       -- (The 45-minute figure on the dashboard is the target for the average, not the on-time rule.)
       (minutes_between(o.pick_complete_time, o.truck_departure_time) <= 60) AS on_time,
       (o.order_fulfillment_status = 'Complete')                     AS is_complete,
       CASE
         WHEN o.category IN ('Poultry','Red Meat','Frozen Veg','Frozen Fruit','Frozen Eggs')
              THEN o.temp_at_dispatch_c BETWEEN -19 AND -15
         WHEN o.category IN ('Dairy','Nuts','Other')
              THEN o.temp_at_dispatch_c BETWEEN -11 AND -7
         ELSE FALSE
       END AS temp_in_range
FROM outbound o;

CREATE VIEW v_dcc AS
SELECT c.*,
       (c.variance_reason = 'None')                      AS is_accurate,
       ABS(c.variance_lb)                                AS abs_variance_lb,
       ABS(c.variance_lb) * p.price_per_lb               AS variance_value_php
FROM cycle_count c
JOIN pallet p USING (pallet_id);

-- Expiry snapshots with peso value and a flag for pallets that already
-- have a dispatch record on or before the snapshot date.
CREATE VIEW v_expiry AS
SELECT e.*,
       e.quantity_lb * p.price_per_lb AS value_php,
       (o.dispatch_date IS NOT NULL AND o.dispatch_date <= e.snapshot_date) AS already_dispatched
FROM expiry_monitor e
JOIN pallet p USING (pallet_id)
LEFT JOIN outbound o USING (pallet_id);


-- =====================================================================
-- 3. ANALYTICAL QUERIES BY DASHBOARD PAGE
-- =====================================================================

-- ---------------------------------------------------------------------
-- PAGE 1: OVERVIEW
-- ---------------------------------------------------------------------

-- Q1. Headline totals
SELECT COUNT(*)                         AS pallets,
       SUM(quantity_lb)                 AS total_lb,
       SUM(inventory_value)             AS total_value_php,
       COUNT(DISTINCT storage_room)     AS storage_rooms,
       COUNT(DISTINCT commodity)        AS commodities,
       COUNT(DISTINCT category)         AS categories,
       COUNT(DISTINCT supplier_code)    AS suppliers
FROM pallet;

-- Q2. Inventory value by category
SELECT category,
       SUM(inventory_value)                                         AS value_php,
       ROUND(100 * SUM(inventory_value) / SUM(SUM(inventory_value)) OVER (), 1) AS pct_of_value
FROM pallet
GROUP BY category
ORDER BY value_php DESC;

-- Q3. Top 5 commodities and their combined share
WITH c AS (
    SELECT commodity, SUM(inventory_value) AS value_php
    FROM pallet GROUP BY commodity
)
SELECT commodity,
       value_php,
       ROUND(100 * value_php / SUM(value_php) OVER (), 1) AS pct_of_value,
       ROUND(100 * SUM(value_php) OVER (ORDER BY value_php DESC)
                 / SUM(value_php) OVER (), 1)               AS cumulative_pct
FROM c
ORDER BY value_php DESC
LIMIT 5;

-- Q4. Monthly inbound vs outbound volume and net flow
WITH i AS (
    SELECT DATE_TRUNC('month', receipt_date)::DATE AS month, SUM(quantity_lb) AS inbound_lb
    FROM inbound GROUP BY 1
), o AS (
    SELECT DATE_TRUNC('month', dispatch_date)::DATE AS month, SUM(quantity_lb) AS outbound_lb
    FROM outbound GROUP BY 1
)
SELECT COALESCE(i.month, o.month)                         AS month,
       COALESCE(inbound_lb, 0)                            AS inbound_lb,
       COALESCE(outbound_lb, 0)                           AS outbound_lb,
       COALESCE(inbound_lb, 0) - COALESCE(outbound_lb, 0) AS net_flow_lb
FROM i FULL OUTER JOIN o ON i.month = o.month
ORDER BY month;

-- ---------------------------------------------------------------------
-- PAGE 2: INBOUND
-- ---------------------------------------------------------------------

-- Q5. Dock-to-rack time vs the 60-minute target
SELECT ROUND(AVG(dock_to_rack_min), 1)                                        AS avg_min,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY dock_to_rack_min)          AS median_min,
       PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY dock_to_rack_min)          AS p90_min,
       ROUND(100.0 * AVG((dock_to_rack_min > 60)::INT), 1)                    AS pct_over_60,
       ROUND(AVG(arrival_to_clearance_min), 1)                                AS avg_arrival_to_clearance_min
FROM v_inbound;

-- Q6. Dock-to-rack by receiving dock and by shift
SELECT 'dock' AS dimension, receiving_dock AS value,
       COUNT(*) AS pallets, ROUND(AVG(dock_to_rack_min), 1) AS avg_min
FROM v_inbound GROUP BY receiving_dock
UNION ALL
SELECT 'shift', shift, COUNT(*), ROUND(AVG(dock_to_rack_min), 1)
FROM v_inbound GROUP BY shift
ORDER BY dimension, value;

-- Q7. Damage / partial rate by supplier
SELECT supplier_code,
       COUNT(*)                                                    AS pallets,
       SUM(is_damaged_or_partial::INT)                             AS damaged_or_partial,
       ROUND(100.0 * AVG(is_damaged_or_partial::INT), 1)           AS rate_pct
FROM v_inbound
GROUP BY supplier_code
ORDER BY rate_pct DESC;

-- Q8. Receiving temperature compliance and where the misses sit
SELECT ROUND(100.0 * AVG(temp_in_range::INT), 2) AS compliance_pct,
       SUM((NOT temp_in_range)::INT)             AS out_of_range
FROM v_inbound;

SELECT category, COUNT(*) AS out_of_range
FROM v_inbound WHERE NOT temp_in_range
GROUP BY category ORDER BY out_of_range DESC;

-- ---------------------------------------------------------------------
-- PAGE 3: PUTAWAY
-- ---------------------------------------------------------------------

-- Q9. Putaway summary: average travel, implied pallets/hour, within 10 min
SELECT ROUND(AVG(travel_time_seconds), 0)                        AS avg_travel_sec,
       ROUND(3600.0 / AVG(travel_time_seconds), 2)               AS pallets_per_hour,   -- target 8
       ROUND(100.0 * AVG((travel_time_seconds <= 600)::INT), 1)  AS pct_within_10_min,
       PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY travel_time_seconds) AS p90_sec,
       MAX(travel_time_seconds)                                  AS max_sec
FROM putaway;

-- Q10. By equipment and by shift
SELECT 'equipment' AS dimension, equipment_used AS value,
       COUNT(*) AS moves, ROUND(AVG(travel_time_seconds), 0) AS avg_sec
FROM putaway GROUP BY equipment_used
UNION ALL
SELECT 'shift', shift, COUNT(*), ROUND(AVG(travel_time_seconds), 0)
FROM putaway GROUP BY shift
ORDER BY dimension, value;

-- Q11. By operator, fastest to slowest
SELECT employee_tag,
       COUNT(*)                            AS moves,
       ROUND(AVG(travel_time_seconds), 0)  AS avg_sec
FROM putaway
GROUP BY employee_tag
ORDER BY avg_sec;

-- ---------------------------------------------------------------------
-- PAGE 4: INVENTORY (cycle counts)
-- ---------------------------------------------------------------------

-- Q12. Accuracy, recount rate, absolute variance and its peso value
SELECT COUNT(*)                                                       AS counts,
       ROUND(100.0 * AVG(is_accurate::INT), 2)                        AS accuracy_pct,       -- target 99
       SUM((recount_required = 'Yes')::INT)                           AS recounts,
       ROUND(100.0 * AVG((recount_required = 'Yes')::INT), 2)         AS recount_rate_pct,
       ROUND(SUM(abs_variance_lb), 0)                                 AS abs_variance_lb,
       ROUND(SUM(variance_lb), 0)                                     AS net_variance_lb,
       ROUND(SUM(variance_value_php), 0)                              AS variance_value_php
FROM v_dcc;

-- Q13. Pareto of variance reasons (share of absolute variance)
WITH r AS (
    SELECT variance_reason, SUM(abs_variance_lb) AS abs_lb
    FROM v_dcc
    WHERE variance_reason <> 'None'
    GROUP BY variance_reason
)
SELECT variance_reason,
       ROUND(abs_lb, 0)                                              AS abs_variance_lb,
       ROUND(100 * abs_lb / SUM(abs_lb) OVER (), 1)                  AS pct,
       ROUND(100 * SUM(abs_lb) OVER (ORDER BY abs_lb DESC)
                 / SUM(abs_lb) OVER (), 1)                           AS cumulative_pct
FROM r
ORDER BY abs_lb DESC;

-- Q14. Net vs absolute variance by storage room (net hides the error)
SELECT storage_room,
       ROUND(SUM(variance_lb), 0)                                    AS net_variance_lb,
       ROUND(SUM(abs_variance_lb), 0)                                AS abs_variance_lb,
       ROUND(100 * SUM(abs_variance_lb) / SUM(SUM(abs_variance_lb)) OVER (), 1) AS pct_of_abs
FROM v_dcc
GROUP BY storage_room
ORDER BY abs_variance_lb DESC;

-- Q15. Monthly count volume, accuracy and variance value
SELECT DATE_TRUNC('month', count_date)::DATE                         AS month,
       COUNT(*)                                                      AS counts,
       ROUND(100.0 * AVG(is_accurate::INT), 1)                       AS accuracy_pct,
       ROUND(SUM(variance_value_php), 0)                             AS variance_value_php
FROM v_dcc
GROUP BY 1
ORDER BY 1;

-- Q16. Recounted vs first-pass locations: average absolute variance %
SELECT recount_required, ROUND(AVG(ABS(variance_pct)), 2) AS avg_abs_variance_pct
FROM cycle_count GROUP BY recount_required;

-- ---------------------------------------------------------------------
-- PAGE 5: OUTBOUND
-- ---------------------------------------------------------------------

-- Q17. Fulfillment, on-time, OTIF and pick-to-departure vs targets
SELECT COUNT(*)                                                       AS dispatched_pallets,
       ROUND(100.0 * AVG(is_complete::INT), 2)                        AS fulfillment_pct,    -- target 95
       ROUND(100.0 * AVG(on_time::INT), 2)                            AS on_time_pct,       -- <= 60 min
       ROUND(100.0 * AVG((is_complete AND on_time)::INT), 2)          AS otif_pct,
       ROUND(AVG(pick_to_departure_min), 1)                           AS avg_pick_to_departure_min, -- target 45
       ROUND(AVG(pick_duration_min), 1)                               AS avg_pick_duration_min
FROM v_outbound;

-- Q18. On-time rate by pick-to-departure bucket (45-min target, 60-min on-time rule)
SELECT CASE WHEN pick_to_departure_min <= 45 THEN '1. <= 45 min'
            WHEN pick_to_departure_min <= 60 THEN '2. 46-60 min'
            ELSE '3. > 60 min' END                                   AS bucket,
       COUNT(*)                                                      AS pallets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)            AS pct_of_dispatches,
       ROUND(100.0 * AVG(on_time::INT), 1)                           AS on_time_pct
FROM v_outbound
GROUP BY 1
ORDER BY 1;

-- Q19. Fulfillment by category and by status
SELECT category,
       COUNT(*)                                       AS pallets,
       ROUND(100.0 * AVG(is_complete::INT), 1)        AS fulfillment_pct
FROM v_outbound
GROUP BY category
ORDER BY fulfillment_pct;

SELECT order_fulfillment_status, COUNT(*) AS pallets
FROM outbound GROUP BY 1 ORDER BY 2 DESC;

-- Q20. Weakest commodities (at least 40 pallets dispatched)
SELECT commodity, COUNT(*) AS pallets,
       ROUND(100.0 * AVG(is_complete::INT), 1) AS fulfillment_pct
FROM v_outbound
GROUP BY commodity
HAVING COUNT(*) >= 40
ORDER BY fulfillment_pct
LIMIT 5;

-- Q21. Dispatch temperature compliance
SELECT ROUND(100.0 * AVG(temp_in_range::INT), 2) AS compliance_pct,   -- target 100
       SUM((NOT temp_in_range)::INT)             AS out_of_range
FROM v_outbound;

-- Q22. Monthly fulfillment and OTIF
SELECT DATE_TRUNC('month', dispatch_date)::DATE                       AS month,
       COUNT(*)                                                       AS pallets,
       ROUND(100.0 * AVG(is_complete::INT), 1)                        AS fulfillment_pct,
       ROUND(100.0 * AVG((is_complete AND on_time)::INT), 1)          AS otif_pct
FROM v_outbound
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- PAGE 6: EXPIRY
-- ---------------------------------------------------------------------

-- Q23. Latest snapshot, as recorded in the monitoring table
WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT expiry_risk_flag,
       COUNT(*)                         AS pallets,
       ROUND(SUM(quantity_lb), 0)       AS lb,
       ROUND(SUM(value_php), 0)         AS value_php
FROM v_expiry, latest
WHERE snapshot_date = latest.d
GROUP BY expiry_risk_flag
ORDER BY CASE expiry_risk_flag WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2
                               WHEN 'Watch' THEN 3 ELSE 4 END;

-- Q24. Share of tracked value at risk, latest snapshot
WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT ROUND(SUM(value_php) FILTER (WHERE expiry_risk_flag <> 'OK'), 0)  AS at_risk_value_php,
       ROUND(SUM(value_php), 0)                                          AS tracked_value_php,
       ROUND(100 * SUM(value_php) FILTER (WHERE expiry_risk_flag <> 'OK')
                 / SUM(value_php), 1)                                    AS pct_at_risk
FROM v_expiry, latest
WHERE snapshot_date = latest.d;

-- Q25. At-risk value by storage room, category and commodity (latest snapshot)
WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT storage_room, ROUND(SUM(value_php), 0) AS at_risk_value_php
FROM v_expiry, latest
WHERE snapshot_date = latest.d AND expiry_risk_flag <> 'OK'
GROUP BY storage_room ORDER BY 2 DESC;

WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT category, ROUND(SUM(value_php), 0) AS at_risk_value_php
FROM v_expiry, latest
WHERE snapshot_date = latest.d AND expiry_risk_flag <> 'OK'
GROUP BY category ORDER BY 2 DESC LIMIT 3;

-- Q26. Action taken by risk flag, all snapshots
SELECT expiry_risk_flag, action_taken, COUNT(*) AS records,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY expiry_risk_flag), 1) AS pct_of_flag
FROM expiry_monitor
GROUP BY expiry_risk_flag, action_taken
ORDER BY expiry_risk_flag, records DESC;

-- Q27. Disposed volume by month
SELECT DATE_TRUNC('month', snapshot_date)::DATE AS month,
       ROUND(SUM(quantity_lb), 0)               AS disposed_lb
FROM expiry_monitor
WHERE action_taken = 'Disposed'
GROUP BY 1 ORDER BY 1;

-- Q28. Latest snapshot RECONCILED with dispatch records:
--      excludes pallets that were already dispatched on or before the snapshot date.
WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT expiry_risk_flag,
       COUNT(*)                   AS pallets,
       ROUND(SUM(value_php), 0)   AS value_php
FROM v_expiry, latest
WHERE snapshot_date = latest.d AND NOT already_dispatched
GROUP BY expiry_risk_flag
ORDER BY CASE expiry_risk_flag WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2
                               WHEN 'Watch' THEN 3 ELSE 4 END;


-- =====================================================================
-- 4. DATA-QUALITY CHECKS  (run after loading; each should be explained
--    or fixed before the dashboard figures are published)
-- =====================================================================

-- DQ1. Row counts
SELECT 'pallet' AS tbl, COUNT(*) FROM pallet
UNION ALL SELECT 'inbound', COUNT(*) FROM inbound
UNION ALL SELECT 'putaway', COUNT(*) FROM putaway
UNION ALL SELECT 'cycle_count', COUNT(*) FROM cycle_count
UNION ALL SELECT 'expiry_monitor', COUNT(*) FROM expiry_monitor
UNION ALL SELECT 'outbound', COUNT(*) FROM outbound;

-- DQ2. Does each inbound row agree with its pallet master record?
SELECT COUNT(*)                                                   AS inbound_rows,
       SUM((i.quantity_lb  = p.quantity_lb)::INT)                 AS same_quantity,
       SUM((i.storage_room = p.storage_room)::INT)                AS same_room,
       SUM((i.exp_date     = p.exp_date)::INT)                    AS same_exp_date,
       SUM((i.receipt_date < p.mfg_date)::INT)                    AS received_before_manufactured
FROM inbound i JOIN pallet p USING (pallet_id);

-- DQ3. Does each putaway row agree with the inbound row it points to?
SELECT COUNT(*)                                                   AS putaway_rows,
       SUM((u.pallet_id = i.pallet_id)::INT)                      AS same_pallet,
       SUM((u.commodity = i.commodity)::INT)                      AS same_commodity,
       SUM((u.storage_room = i.storage_room)::INT)                AS same_room
FROM putaway u JOIN inbound i USING (inbound_id);

-- DQ4. Dispatch recorded before the inbound receipt date for the same pallet
SELECT COUNT(*) AS dispatched_before_receipt
FROM outbound o JOIN inbound i USING (pallet_id)
WHERE o.dispatch_date < i.receipt_date;

-- DQ5. Expiry snapshots for pallets already dispatched
WITH latest AS (SELECT MAX(snapshot_date) AS d FROM expiry_monitor)
SELECT COUNT(*)                          AS rows_in_latest_snapshot,
       SUM(already_dispatched::INT)      AS already_dispatched,
       ROUND(100.0 * AVG(already_dispatched::INT), 1) AS pct_already_dispatched
FROM v_expiry, latest
WHERE snapshot_date = latest.d;

SELECT ROUND(100.0 * AVG(already_dispatched::INT), 1) AS pct_all_snapshot_rows_already_dispatched
FROM v_expiry;

-- DQ6. Cycle-count and expiry rows that agree with the pallet master (expected: all)
SELECT (SELECT COUNT(*) FROM cycle_count c JOIN pallet p USING (pallet_id)
         WHERE c.storage_room <> p.storage_room OR c.system_quantity_lb <> p.quantity_lb) AS cc_mismatch,
       (SELECT COUNT(*) FROM expiry_monitor e JOIN pallet p USING (pallet_id)
         WHERE e.commodity <> p.commodity OR e.expiry_date <> p.exp_date)                 AS expiry_mismatch,
       (SELECT COUNT(*) FROM outbound o JOIN pallet p USING (pallet_id)
         WHERE o.quantity_lb <> p.quantity_lb)                                            AS outbound_qty_mismatch;
