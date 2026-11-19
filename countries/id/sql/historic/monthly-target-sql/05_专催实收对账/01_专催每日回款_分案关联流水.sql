WITH params AS (
 SELECT CAST('2026-10-01' AS DATE) month_start,
        CURRENT_DATE() end_exclusive,
        CAST(2645.5027 AS DECIMAL(18,6)) fx_rate
), missions AS (
 SELECT mission_log_id, MAX(debtor_id) debtor_id,
        MIN(assign_debtor_late_days) entry_dpd,
        MIN(mission_log_create_at) assign_at,
        COUNT(*) source_rows,
        COUNT(DISTINCT assign_debtor_late_days) dpd_versions
 FROM fox_ods.ods_fox_mission_log
 WHERE mission_log_operator='assign'
   AND LOWER(TRIM(mission_group_name))='m2-scq'
 GROUP BY mission_log_id
), rr AS (
 SELECT r.id,r.mission_log_id,r.repay_date,r.repaid_total_amount,
 ROW_NUMBER() OVER(PARTITION BY r.id ORDER BY r.update_at DESC,r.etl_time DESC) rn
 FROM fox_ods.ods_fox_collect_recovery r CROSS JOIN params p
 WHERE r.repay_date>=p.month_start AND r.repay_date<p.end_exclusive
), cash AS (
 SELECT r.id,r.mission_log_id,DATE(r.repay_date) repay_day,
        r.repaid_total_amount/100.0 receipt_idr,
        m.debtor_id,m.assign_at,m.entry_dpd,m.source_rows,m.dpd_versions,
        CASE WHEN m.dpd_versions<>1 THEN '账龄冲突'
             WHEN m.entry_dpd BETWEEN 31 AND 60 THEN 'M2'
             WHEN m.entry_dpd BETWEEN 61 AND 90 THEN 'M3'
             WHEN m.entry_dpd BETWEEN 91 AND 210 THEN 'M4-7'
             WHEN m.entry_dpd BETWEEN 211 AND 999 THEN 'M7+'
             ELSE '其他账龄' END stage
 FROM rr r JOIN missions m ON r.mission_log_id=m.mission_log_id
 WHERE r.rn=1
)
, daily AS (
 SELECT repay_day,stage,COUNT(*) recovery_records,COUNT(DISTINCT debtor_id) repaid_debtors,
 SUM(COALESCE(receipt_idr,0)) daily_receipt_idr,
 SUM(CASE WHEN receipt_idr<0 THEN receipt_idr ELSE 0 END) negative_receipt_idr,
 SUM(CASE WHEN receipt_idr IS NULL THEN 1 ELSE 0 END) null_amount_records,
 SUM(CASE WHEN source_rows>1 THEN 1 ELSE 0 END) duplicate_assignment_source_records
 FROM cash GROUP BY repay_day,stage
)
SELECT 'M2-SCQ' queue_name,d.repay_day,d.stage,d.recovery_records,d.repaid_debtors,
 ROUND(d.daily_receipt_idr,4) daily_receipt_idr,
 ROUND(d.daily_receipt_idr/p.fx_rate,4) daily_receipt_cny,
 ROUND(SUM(d.daily_receipt_idr) OVER(PARTITION BY d.stage ORDER BY d.repay_day
 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),4) stage_mtd_receipt_idr,
 ROUND(SUM(d.daily_receipt_idr) OVER(PARTITION BY d.stage ORDER BY d.repay_day
 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)/p.fx_rate,4) stage_mtd_receipt_cny,
 ROUND(d.negative_receipt_idr,4) negative_receipt_idr,
 d.null_amount_records,d.duplicate_assignment_source_records
FROM daily d CROSS JOIN params p ORDER BY d.repay_day,d.stage;
