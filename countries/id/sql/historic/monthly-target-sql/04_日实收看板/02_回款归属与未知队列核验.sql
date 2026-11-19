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
)
SELECT scope_status, stage, operation_mode, queue_name,
       COUNT(*) AS recovery_record_count,
       ROUND(SUM(receipt_idr),4) AS receipt_idr,
       MAX(p.fx_rate) AS fx_rate,
       ROUND(SUM(receipt_idr)/MAX(p.fx_rate),4) AS receipt_cny
FROM labeled CROSS JOIN params p
GROUP BY scope_status, stage, operation_mode, queue_name
ORDER BY scope_status, stage, operation_mode, queue_name;
