# Data Dictionary

FrostLink Solutions: Cold Storage Operations Dashboard

All data is **synthetic**, generated to mirror cold storage warehouse management system records. Activity covers **January 2024 to May 2025**. Column names below follow the SQL schema (`sql/schema_and_queries.sql`); where the Power BI model uses a different name (spaces instead of underscores), it is shown in brackets.

## Contents
1. [Tables at a Glance](#tables-at-a-glance)
2. [00_pallet](#00_pallet)
3. [01_inbound](#01_inbound)
4. [02_putaway](#02_putaway)
5. [03_dcc (cycle counts)](#03_dcc-cycle-counts)
6. [04_expiry](#04_expiry)
7. [05_outbound](#05_outbound)
8. [Calculated Columns](#calculated-columns)
9. [KPI Targets and Rules](#kpi-targets-and-rules)
10. [Reference Values](#reference-values)
11. [Known Data Issues](#known-data-issues)

---

## Tables at a Glance

| Table | Rows | One row is | Primary key |
|---|---|---|---|
| `00_pallet` | 3,815 | One pallet in the master list | `pallet_id` |
| `01_inbound` | 3,815 | One receiving event | `inbound_id` |
| `02_putaway` | 3,815 | One dock-to-rack move | `putaway_id` |
| `03_dcc` | 13,303 | One cycle count of one location | `count_id` |
| `04_expiry` | 21,200 | One pallet in one weekly expiry snapshot | `monitor_id` |
| `05_outbound` | 2,683 | One pallet dispatched | `outbound_id` |

Joins that hold: `03_dcc`, `04_expiry`, and `05_outbound` all join to `00_pallet` on `pallet_id` and agree with it (same commodity, room, and quantity). See [Known Data Issues](#known-data-issues) for the links that do not hold.

---

## 00_pallet
Pallet master: what each pallet is, where it is stored, and what it is worth.

| Column | Type | Description | Values / range |
|---|---|---|---|
| `pallet_id` | text | Unique pallet identifier | PLT-00001 to PLT-03815 |
| `sku` | text | Stock keeping unit; the prefix is a commodity code | e.g. SKU-CHI-0001, 3,815 unique |
| `commodity` | text | Specific product | 23 values, e.g. Beef - Boneless |
| `category` | text | Product group | Dairy, Frozen Eggs, Frozen Fruit, Frozen Veg, Nuts, Other, Poultry, Red Meat |
| `subcategory` | text | Product type within the commodity | 23 values, e.g. Wings |
| `batch_number` | text | Production batch | BCH-xxxxxx, 3,815 unique |
| `lot_number` | text | Lot identifier | LOT-0001 to LOT-3815 |
| `supplier_code` | text | Supplier of the pallet | SUP-001 to SUP-010 |
| `mfg_date` | date | Manufacture date | 2023-12-04 to 2025-05-29 |
| `exp_date` | date | Expiry date | 2024-07-12 to 2027-03-22 |
| `quantity_lb` | decimal | Pallet weight in pounds | 800.2 to 2,199.5 |
| `storage_room` | text | Room where the pallet is stored | WAREHOUSE A to WAREHOUSE F |
| `location` | text | Storage location code | LOC-00001 to LOC-03815 |
| `price_per_lb` [`Price per Lb (PHP)`] | integer | Assumed price per pound in pesos (see Calculated Columns) | 55 to 400, 20 price points |
| `inventory_value` [`Inventory Value`] | decimal | `quantity_lb × price_per_lb`, in pesos | 44,572 to 878,720 |

---

## 01_inbound
Receiving events: when a truck arrived, how long clearing and putaway took, and the condition of the load.

| Column | Type | Description | Values / range |
|---|---|---|---|
| `inbound_id` [`inbound id`] | text | Unique receiving event | INB-00001 to INB-03815 |
| `pallet_id` [`pallet id`] | text | Pallet received | PLT-00001 to PLT-03815 |
| `receipt_date` [`receipt date`] | date | Date received | 2024-01-01 to 2025-05-01 |
| `commodity` | text | Product received | 23 values |
| `category` | text | Product group | 8 values (as in `00_pallet`) |
| `supplier_code` [`supplier code`] | text | Supplier | SUP-001 to SUP-010 |
| `quantity_lb` [`quantity lb`] | decimal | Weight received in pounds | 801.1 to 2,198.9 |
| `truck_arrival_time` [`truck arrival time`] | time | Time the truck arrived | 05:00 to 17:00 |
| `dock_clearance_time` [`dock clearance time`] | time | Time the load was cleared at the dock | 05:20 to 18:00 |
| `putaway_complete_time` [`putaway complete time`] | time | Time the pallet reached its rack | 05:59 to 19:50 |
| `receiving_dock` [`receiving dock`] | text | Dock used | DOCK-X, DOCK-Y, DOCK-Z |
| `temp_at_receipt_c` [`temp at receipt c`] | decimal | Product temperature on arrival, °C | -18.0 to -8.0 |
| `batch_number` [`batch number`] | text | Production batch | BCH-xxxxxx |
| `exp_date` [`exp date`] | date | Expiry date | 2024-07-06 to 2027-04-21 |
| `storage_room` [`storage room`] | text | Room assigned | WAREHOUSE A to F |
| `employee_tag` [`employee tag`] | text | Receiving operator tag | EMP-INB-1 to EMP-INB-7 |
| `employee_id` [`employee id`] | text | Operator ID | EMP-01 to EMP-07 |
| `condition_on_arrival` [`condition on arrival`] | text | State of the load | Good, Damaged, Partial |
| `po_number` [`po number`] | text | Purchase order | PO-001 to PO-999 |
| `shift` [`Shift`, `Inbound Shift`] | text | Shift, from the hour of dock clearance | Morning, Afternoon, Night |

---

## 02_putaway
Dock-to-rack moves: who moved the pallet, with what equipment, and how long the travel took.

| Column | Type | Description | Values / range |
|---|---|---|---|
| `putaway_id` | text | Unique putaway move | PUT-00001 to PUT-03815 |
| `pallet_id` | text | Pallet moved | PLT-00001 to PLT-03815 |
| `putaway_date` [`date`] | date | Date of the move | 2024-01-01 to 2025-05-31 |
| `commodity` | text | Product moved | 23 values |
| `employee_id` [`employee id`] | text | Operator ID | EMP-01 to EMP-12 |
| `employee_tag` [`employee tag`] | text | Operator tag | EMP-PUT-1 to EMP-PUT-12 |
| `equipment_used` | text | Equipment type | Counterbalance, Hand Pallet Jack, Reach Truck |
| `scan_time_dock` | time | Scan at the dock | 05:01 to 19:01 |
| `scan_time_rack` | time | Scan at the rack | 05:09 to 19:13 |
| `travel_time_seconds` | integer | Seconds from dock scan to rack scan | 180 to 720 |
| `storage_room` | text | Destination room | WAREHOUSE A to F |
| `to_location` | text | Destination location | LOC-00001 to LOC-03815 |
| `inbound_id` | text | Receiving event the move belongs to | INB-00001 to INB-03815 |
| `shift` | text | Shift of the move | Morning, Afternoon, Night |
| `from_location` | text | Origin dock | DOCK-X, DOCK-Y, DOCK-Z |

---

## 03_dcc (cycle counts)
Daily cycle counts: the system quantity against the physically counted quantity.

| Column | Type | Description | Values / range |
|---|---|---|---|
| `count_id` | text | Unique count | CC-000001 to CC-013303 |
| `count_date` | date | Date counted | 2024-01-03 to 2025-05-31 |
| `pallet_id` | text | Pallet counted (3,809 distinct) | PLT-00001 to PLT-03815 |
| `location` | text | Count location code; unique per count, so not a key to other tables | LOC-00001 to LOC-13303 |
| `storage_room` | text | Room counted | WAREHOUSE A to F |
| `commodity` | text | Product counted | 23 values |
| `system_quantity_lb` | decimal | Quantity the system holds, in pounds | 800.2 to 2,199.5 |
| `physical_quantity_lb` | decimal | Quantity actually counted, in pounds | 767.4 to 2,303.6 |
| `variance_lb` | decimal | `physical − system`; negative is a loss, positive a gain | -108.9 to +108.9 |
| `variance_pct` | decimal | Variance as a percent | -5.0 to +5.0 |
| `variance_reason` | text | Cause of the variance; `None` when counts agree | None, Miscount, System Lag, Damage, Breakage |
| `employee_id` [`employee id`] | text | Counter ID | EMP-01 to EMP-09 |
| `employee_tag` [`employee tag`] | text | Counter tag | EMP-DCC-1 to EMP-DCC-9 |
| `count_duration_minutes` | integer | Minutes the count took | 3 to 20 |
| `recount_required` | text | Whether a recount was triggered | Yes, No |

---

## 04_expiry
Weekly expiry monitoring. The same pallet appears in many snapshots (about 11 on average).

| Column | Type | Description | Values / range |
|---|---|---|---|
| `monitor_id` | text | Unique monitoring record | NEM-000001 to NEM-021200 |
| `snapshot_date` | date | Weekly snapshot date (59 snapshots) | 2024-04-15 to 2025-05-26 |
| `pallet_id` | text | Pallet monitored (1,946 distinct) | PLT-00001 to PLT-03815 |
| `commodity` | text | Product | 23 values |
| `category` | text | Product group | 8 values |
| `batch_number` | text | Production batch | BCH-xxxxxx |
| `storage_room` | text | Room | WAREHOUSE A to F |
| `location` | text | Record location code; unique per record, so not a key to other tables | LOC-00001 to LOC-21200 |
| `quantity_lb` | decimal | Quantity in pounds | 801.7 to 2,199.5 |
| `expiry_date` | date | Expiry date of the pallet | 2024-07-12 to 2025-08-24 |
| `days_to_expiry` | integer | `expiry_date − snapshot_date`, in days | 0 to 90 |
| `expiry_risk_flag` | text | Risk band from `days_to_expiry` | OK, Watch, Warning, Critical |
| `action_taken` | text | Action recorded | None, Priority Dispatch, Disposed |

**Risk bands**

| Flag | Days to expiry |
|---|---|
| Critical | 0 to 7 |
| Warning | 8 to 14 |
| Watch | 15 to 30 |
| OK | 31 to 90 |

---

## 05_outbound
Dispatch events: picking, truck departure, and whether the order was filled.

| Column | Type | Description | Values / range |
|---|---|---|---|
| `outbound_id` | text | Unique dispatch | OUT-00001 to OUT-02683 |
| `dispatch_date` | date | Date dispatched | 2024-01-09 to 2025-05-31 |
| `order_number` [`order number`] | text | Order reference, includes the date | ON-YYYYMMDD-nnnn |
| `pallet_id` | text | Pallet dispatched (one dispatch per pallet) | PLT-00001 to PLT-03815 |
| `commodity` | text | Product | 23 values |
| `category` | text | Product group | 8 values |
| `customer_code` | text | Customer | CST-001 to CST-015 |
| `quantity_lb` | decimal | Weight dispatched, equal to the pallet quantity | 800.2 to 2,199.5 |
| `pick_start_time` | time | Picking started | 06:00 to 18:00 |
| `pick_complete_time` | time | Picking finished | 06:23 to 18:56 |
| `truck_departure_time` | time | Truck left | 06:49 to 20:08 |
| `employee_id` [`employee id`] | text | Picker ID | EMP-01 to EMP-11 |
| `employee_tag` [`employee tag`] | text | Picker tag | EMP-OUT-1 to EMP-OUT-11 |
| `storage_room` | text | Room picked from | WAREHOUSE A to F |
| `temp_at_dispatch_c` | decimal | Product temperature at dispatch, °C | -18.9 to -7.1 |
| `dispatch_dock` | text | Dock used | DOCK-V, DOCK-W |
| `order_fulfillment_status` | text | Result of the pick | Complete, Partial, Short-picked |

---

## Calculated Columns

These are created in Power BI (DAX) and reproduced as views in SQL.

| Table | Column | Definition |
|---|---|---|
| `00_pallet` | `Price per Lb (PHP)` | Lookup by commodity from a fixed list of 20 prices, 55 to 400 pesos. Prices are assumptions in the model, not source data. |
| `00_pallet` | `Inventory Value` | `quantity_lb × Price per Lb (PHP)` |
| `01_inbound` | `Dock to Rack Min` | Minutes from `dock clearance time` to `putaway complete time` (DAX `DATEDIFF`, minute boundaries). Range 30 to 120. |
| `01_inbound` | `Shift` / `Inbound Shift` | From the hour of `dock clearance time`: 06:00 to 13:59 Morning, 14:00 to 21:59 Afternoon, otherwise Night. Both columns hold the same logic. |
| `05_outbound` | `Pick to Departure Min` | Minutes from `pick_complete_time` to `truck_departure_time`. Range 25 to 80. |
| `05_outbound` | `On Time` | 1 if `Pick to Departure Min` is 60 or less, otherwise 0. |

---

## KPI Targets and Rules

Targets are fixed values set in the Power BI model, not derived from the data.

| KPI | Definition | Target |
|---|---|---|
| Inventory Accuracy Rate | Cycle counts with `variance_reason = None` ÷ all counts | 99% |
| Avg Dock to Rack Time | Average `Dock to Rack Min` | 60 min |
| Pallets Putaway Per Hour | `3,600 ÷ average travel_time_seconds` | 8 |
| Avg Scan Dock to Rack Time | Average of `scan_time_rack − scan_time_dock` | 5 min |
| Inbound Temp Compliance | Share of receipts inside the range below | 99.54% |
| Order Fulfillment Rate | Dispatches with status Complete ÷ all dispatches | 95% |
| Avg Pick to Departure | Average `Pick to Departure Min` | 45 min |
| OTIF % | Dispatches that are Complete **and** On Time ÷ all dispatches | none set |
| Dispatch Temp Compliance | Share of dispatches inside the range below | 100% |
| Locations Counted (latest day) | Count rows on the latest `count_date` | 150 |

**Temperature ranges used for compliance**

| Category | Inbound range | Dispatch range |
|---|---|---|
| Poultry, Red Meat, Frozen Veg, Frozen Fruit, Frozen Eggs | -18 to -16 °C | -19 to -15 °C |
| Dairy, Nuts, Other | -10 to -8 °C | -11 to -7 °C |

---

## Reference Values

| Field | Values |
|---|---|
| Storage rooms | WAREHOUSE A, B, C, D, E, F |
| Receiving docks | DOCK-X, DOCK-Y, DOCK-Z |
| Dispatch docks | DOCK-V, DOCK-W |
| Suppliers | SUP-001 to SUP-010 |
| Customers | CST-001 to CST-015 |
| Categories | Dairy, Frozen Eggs, Frozen Fruit, Frozen Veg, Nuts, Other, Poultry, Red Meat |
| Putaway equipment | Counterbalance, Hand Pallet Jack, Reach Truck |
| Putaway operators | EMP-PUT-1 to EMP-PUT-12 |
| Variance reasons | None, Miscount, System Lag, Damage, Breakage |

---

## Known Data Issues

These affect how the tables can be combined. Each is tested by a query in section 4 of the SQL file.

| Issue | Detail |
|---|---|
| Inbound does not match the pallet master | For the same `pallet_id`, `quantity_lb` never matches, `storage_room` matches for about half, and 1,888 pallets have a receipt date before their `mfg_date`. |
| Putaway does not match inbound | No putaway row shares a `pallet_id` with the inbound row its `inbound_id` points to. |
| Dispatch before receipt | 1,191 of 2,683 pallets have a `dispatch_date` earlier than their `receipt_date`. |
| Expiry tracks dispatched pallets | 75.6% of pallets in the latest snapshot already have a dispatch record on or before the snapshot date. |
| Inbound ends early | `receipt_date` stops on 2025-05-01, while other tables run to 2025-05-31. |
| Employee IDs are shared across tables | `EMP-01` and similar IDs appear in all four event tables alongside different team tags (EMP-INB, EMP-PUT, EMP-DCC, EMP-OUT). Use `employee_tag` to tell people apart. |
| Location codes are not shared keys | `location` is unique per row in `03_dcc` and `04_expiry`, so it cannot be used to join to `00_pallet`. |
| Time columns | Time-of-day fields carry a placeholder date (1899) in Power BI. In SQL they are stored as `TIME`. |
