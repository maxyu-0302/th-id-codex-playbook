WITH
params AS (
    SELECT CAST(DATE_TRUNC('month', CURRENT_DATE()) AS DATE) AS month_start,
           CURRENT_DATE() AS end_exclusive,
           CAST(2645.5027 AS DECIMAL(18, 6)) AS fx_rate
),
recovery_ranked AS (
    SELECT r.id, r.mission_log_id, r.repay_date, r.repaid_total_amount,
           ROW_NUMBER() OVER (
               PARTITION BY r.id ORDER BY r.update_at DESC, r.etl_time DESC
           ) AS rn
    FROM fox_ods.ods_fox_collect_recovery r
    CROSS JOIN params p
    WHERE r.repay_date >= p.month_start
      AND r.repay_date < p.end_exclusive
),
recovery AS (
    SELECT id, mission_log_id, DATE(repay_date) AS receipt_date,
           COALESCE(repaid_total_amount, 0) / 100.0 AS receipt_idr
    FROM recovery_ranked
    WHERE rn = 1
),
mission_ids AS (
    SELECT DISTINCT mission_log_id FROM recovery
),
mission_keys AS (
    SELECT ml.mission_log_id,
           MIN(ml.assign_debtor_late_days) AS entry_dpd,
           MAX(ml.mission_group_name) AS queue_name,
           COUNT(DISTINCT ml.assign_debtor_late_days) AS dpd_versions,
           COUNT(DISTINCT ml.mission_group_name) AS queue_versions
    FROM fox_ods.ods_fox_mission_log ml
    JOIN mission_ids k ON ml.mission_log_id = k.mission_log_id
    WHERE ml.mission_log_operator = 'assign'
    GROUP BY ml.mission_log_id
),
labeled AS (
    SELECT r.id, r.receipt_date, r.receipt_idr,
           m.queue_name, m.entry_dpd,
           CASE WHEN m.entry_dpd BETWEEN 31 AND 60 THEN 'M2'
                WHEN m.entry_dpd BETWEEN 61 AND 90 THEN 'M3'
                WHEN m.entry_dpd BETWEEN 91 AND 210 THEN 'M4-7'
                WHEN m.entry_dpd BETWEEN 211 AND 999 THEN 'M7+'
                ELSE '账龄未匹配' END AS stage,
           CASE WHEN m.queue_versions <> 1 OR m.dpd_versions <> 1 THEN '其他待核验'
                WHEN LOWER(TRIM(m.queue_name)) = 'm2-scq' THEN '专催'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%pure%' THEN '纯净'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%ai%' THEN 'AI'
                WHEN LOWER(TRIM(m.queue_name)) IN
                     ('m2-cpu','m2-edn','m3-edn','m3-qin','m4-edn','m4-qin') THEN '委外'
                ELSE '其他待核验' END AS operation_mode,
           CASE WHEN m.mission_log_id IS NULL THEN '未关联分案'
                WHEN m.queue_versions <> 1 OR m.dpd_versions <> 1 THEN '分案归属冲突'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%cultivate%' THEN 'cultivate不纳入'
                WHEN m.entry_dpd NOT BETWEEN 31 AND 999 OR m.entry_dpd IS NULL THEN '非长账或账龄缺失'
                WHEN LOWER(TRIM(m.queue_name)) LIKE 'm2-%'
                  OR LOWER(TRIM(m.queue_name)) LIKE 'm3-%'
                  OR LOWER(TRIM(m.queue_name)) LIKE 'm4-%'
                  OR LOWER(TRIM(m.queue_name)) IN ('m2','m3','m4') THEN '纳入长账'
                ELSE '其他队列不纳入' END AS scope_status
    FROM recovery r
    LEFT JOIN mission_keys m ON r.mission_log_id = m.mission_log_id
),
daily AS (
    SELECT receipt_date, stage, operation_mode,
           SUM(receipt_idr) AS daily_receipt_idr,
           COUNT(*) AS recovery_record_count
    FROM labeled
    WHERE scope_status = '纳入长账'
    GROUP BY receipt_date, stage, operation_mode
),
digits AS (
    SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
    UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
    UNION ALL SELECT 8 UNION ALL SELECT 9
),
date_candidates AS (
    SELECT DATE_ADD(p.month_start, INTERVAL (a.n + b.n * 10) DAY) AS receipt_date,
           p.month_start, p.end_exclusive, p.fx_rate
    FROM params p CROSS JOIN digits a CROSS JOIN digits b
    WHERE a.n + b.n * 10 < 31
),
calendar AS (
    SELECT receipt_date, month_start, fx_rate
    FROM date_candidates
    WHERE receipt_date < end_exclusive
      AND receipt_date < DATE_ADD(month_start, INTERVAL 1 MONTH)
),
stages AS (
    SELECT 'M2' AS stage UNION ALL SELECT 'M3'
    UNION ALL SELECT 'M4-7' UNION ALL SELECT 'M7+'
),
modes AS (
    SELECT '专催' AS operation_mode UNION ALL SELECT '委外'
    UNION ALL SELECT 'AI' UNION ALL SELECT '纯净' UNION ALL SELECT '其他待核验'
),
filled AS (
    SELECT c.receipt_date, c.month_start, c.fx_rate, s.stage, m.operation_mode,
           COALESCE(d.daily_receipt_idr, 0) AS daily_receipt_idr,
           COALESCE(d.recovery_record_count, 0) AS recovery_record_count
    FROM calendar c CROSS JOIN stages s CROSS JOIN modes m
    LEFT JOIN daily d ON c.receipt_date = d.receipt_date
                    AND s.stage = d.stage AND m.operation_mode = d.operation_mode
)
SELECT receipt_date,
       month_start,
       stage,
       operation_mode,
       fx_rate,
       ROUND(daily_receipt_idr, 4) AS daily_receipt_idr,
       ROUND(SUM(daily_receipt_idr) OVER (
           PARTITION BY month_start, stage, operation_mode
           ORDER BY receipt_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ), 4) AS mtd_receipt_idr,
       ROUND(daily_receipt_idr / fx_rate, 4) AS daily_receipt_cny,
       ROUND(SUM(daily_receipt_idr) OVER (
           PARTITION BY month_start, stage, operation_mode
           ORDER BY receipt_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) / fx_rate, 4) AS mtd_receipt_cny,
       recovery_record_count
FROM filled
ORDER BY receipt_date, stage, operation_mode;
