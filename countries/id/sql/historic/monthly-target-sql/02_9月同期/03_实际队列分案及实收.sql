WITH raw AS (
 SELECT d.*, CASE WHEN assign_debtor_late_days BETWEEN 31 AND 60 THEN 'M2'
 WHEN assign_debtor_late_days BETWEEN 61 AND 90 THEN 'M3'
 WHEN assign_debtor_late_days BETWEEN 91 AND 210 THEN 'M4-7'
 WHEN assign_debtor_late_days BETWEEN 211 AND 999 THEN 'M7+' END stage
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d
 WHERE pt_date='2026-09-08' AND mission_log_create_date>='2026-09-01' AND mission_log_create_date<'2026-09-09'
 AND assign_debtor_late_days BETWEEN 31 AND 999
 AND (yewuzu IN ('M2','M3','M4') OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%'
 OR LOWER(TRIM(mission_group_name)) LIKE 'm3-%' OR LOWER(TRIM(mission_group_name)) LIKE 'm4-%')
 AND LOWER(TRIM(mission_group_name)) NOT LIKE '%cultivate%'
), ranked AS (
 SELECT r.*,ROW_NUMBER() OVER(PARTITION BY stage,mission_group_name,mission_log_asset_id,overdue_period
 ORDER BY mission_log_create_at,mission_log_id) queue_asset_rn
 FROM raw r
)
SELECT stage, -- 分案时账龄；专催混合队列分开输出
 mission_group_name queue_name, -- 实际委案队列
 COUNT(DISTINCT debtor_id) queue_cases, -- 月内曾在此队列分案债务人数；跨队列不可直接相加去重
 ROUND(SUM(CASE WHEN queue_asset_rn=1 THEN assign_principal_amount ELSE 0 END),4) queue_principal_idr, -- 队列内资产期次本金；跨队列转案可能重复
 ROUND(SUM(COALESCE(repaid_total_amount,0)),4) queue_receipts_idr -- 此队列实际委案归属实收
FROM ranked GROUP BY stage,mission_group_name ORDER BY stage,mission_group_name;
