WITH src AS (
 SELECT m.*,
 CASE WHEN LOWER(TRIM(mission_group_name))='b2' OR LOWER(TRIM(mission_group_name)) LIKE 'b2-%' THEN 'B2'
      WHEN LOWER(TRIM(mission_group_name))='m2' OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%' THEN 'M2'
      WHEN LOWER(TRIM(mission_group_name))='additional group' THEN 'Additional' ELSE yewuzu END AS stage,
 CASE WHEN LOWER(TRIM(mission_group_name))='additional group' THEN 'additional' WHEN LOWER(mission_group_name) LIKE '%pure%' THEN 'pure'
      WHEN LOWER(mission_group_name) LIKE '%ai%' THEN 'ai' ELSE 'manual' END AS work_mode
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer m
 WHERE pt_date IN ('2026-07-31','2026-08-31','2026-09-20')
 AND (yewuzu IN ('B2','M2') OR LOWER(TRIM(mission_group_name)) IN ('b2','m2')
      OR LOWER(TRIM(mission_group_name)) LIKE 'b2-%' OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%' OR LOWER(TRIM(mission_group_name))='additional group')
), ranked AS (
 SELECT s.*,
 ROW_NUMBER() OVER(PARTITION BY pt_date,stage,mission_log_asset_id,overdue_period
 ORDER BY mission_log_create_date,mission_log_create_at DESC,mission_log_id DESC) AS principal_rn,
 ROW_NUMBER() OVER(PARTITION BY pt_date,stage,debtor_id
 ORDER BY mission_log_create_at,mission_log_id) AS first_event_rn,
 MIN(mission_log_create_date) OVER(PARTITION BY pt_date,stage,debtor_id) AS first_day
 FROM src s
), finance AS (
 SELECT pt_date,stage,debtor_id,MIN(first_day) AS first_day,
 MAX(CASE WHEN first_event_rn=1 THEN mission_group_name END) AS first_queue,
 MAX(CASE WHEN first_event_rn=1 THEN work_mode END) AS first_mode,
 MAX(CASE WHEN first_event_rn=1 THEN assign_debtor_late_days END) AS first_dpd,
 MAX(CASE WHEN first_event_rn=1 THEN mission_start_late_days END) AS source_stage_start_dpd,
 COUNT(*) AS log_rows,COUNT(DISTINCT mission_log_id) AS unique_logs,
 COUNT(DISTINCT work_mode) AS mode_count,
 SUM(CASE WHEN yewuzu IS NULL OR TRIM(yewuzu)='' THEN 1 ELSE 0 END) AS missing_group_rows,
 SUM(CASE WHEN yewuzu IS NOT NULL AND TRIM(yewuzu)<>'' AND yewuzu<>stage THEN 1 ELSE 0 END) AS conflicting_group_rows,
 SUM(CASE WHEN principal_rn=1 THEN assign_principal_amount ELSE 0 END) AS principal,
 SUM(CASE WHEN principal_rn=1 AND mission_log_create_date=first_day THEN assign_principal_amount ELSE 0 END) AS first_day_principal,
 SUM(CASE WHEN principal_rn=1 AND assign_principal_amount IS NULL THEN 1 ELSE 0 END) AS missing_principal_rows,
 SUM(COALESCE(repaid_total_amount,0)) AS receipts,
 SUM(CASE WHEN work_mode='manual' THEN COALESCE(repaid_total_amount,0) ELSE 0 END) AS manual_receipts,
 SUM(CASE WHEN work_mode='ai' THEN COALESCE(repaid_total_amount,0) ELSE 0 END) AS ai_receipts,
 SUM(CASE WHEN work_mode='pure' THEN COALESCE(repaid_total_amount,0) ELSE 0 END) AS pure_receipts
 FROM ranked GROUP BY pt_date,stage,debtor_id
), cash_source AS (
 SELECT DISTINCT r.serial_num AS id,r.asset_item_number,r.batch_num,r.mission_log_id,r.repay_date,r.serial_num,r.repaid_total_amount
 FROM fox_dw.dwd_fox_collect_recovery_df r
 WHERE r.repay_date>='2026-07-01' AND r.repay_date<'2026-09-21'
 AND r.mission_log_id IN (SELECT mission_log_id FROM src)
), cash_marked AS (
 SELECT *,COUNT(*) OVER(PARTITION BY id,asset_item_number,batch_num,repay_date) id_versions FROM cash_source
)
SELECT s.pt_date,
CASE WHEN r.repay_date<s.mission_log_create_at THEN '分案前'
WHEN r.repay_date>=COALESCE(s.unassign_create_at,DATE_ADD(s.pt_date,INTERVAL 1 DAY)) THEN '撤案后'
ELSE '委案内' END timing,
CASE WHEN LEFT(r.serial_num,3) IN ('DC_','DS_') THEN LEFT(r.serial_num,3) ELSE 'cash' END kind,
COUNT(*) n,SUM(r.repaid_total_amount)/100.0 amount_thb
FROM (SELECT DISTINCT pt_date,stage,mission_log_id,mission_log_create_at,unassign_create_at FROM src) s
JOIN cash_marked r ON s.mission_log_id=r.mission_log_id
WHERE s.stage='Additional' AND r.id_versions=1
AND r.repay_date>=CAST(CONCAT(SUBSTR(CAST(s.pt_date AS VARCHAR),1,7),'-01') AS DATE)
AND r.repay_date<DATE_ADD(s.pt_date,INTERVAL 1 DAY)
GROUP BY s.pt_date,timing,kind ORDER BY s.pt_date,timing,kind
