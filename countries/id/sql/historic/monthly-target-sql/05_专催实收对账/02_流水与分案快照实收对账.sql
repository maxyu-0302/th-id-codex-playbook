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
, ledger AS (
 SELECT mission_log_id,MAX(stage) stage,
 SUM(COALESCE(receipt_idr,0)) receipt_idr
 FROM cash GROUP BY mission_log_id
), snapshot AS (
 SELECT d.mission_log_id,COUNT(*) snapshot_rows,
 SUM(COALESCE(d.repaid_total_amount,0)) snapshot_receipt_idr
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d CROSS JOIN params p
 WHERE d.pt_date=CAST(DATE_SUB(p.end_exclusive,INTERVAL 1 DAY) AS VARCHAR)
   AND d.mission_log_create_date>=p.month_start
   AND d.mission_log_create_date<p.end_exclusive
   AND LOWER(TRIM(d.mission_group_name))='m2-scq'
 GROUP BY d.mission_log_id
), compared AS (
 SELECT COALESCE(l.mission_log_id,s.mission_log_id) mission_log_id,
 COALESCE(l.receipt_idr,0) ledger_receipt_idr,
 COALESCE(s.snapshot_receipt_idr,0) snapshot_receipt_idr,
 COALESCE(s.snapshot_rows,0) snapshot_rows,
 CASE WHEN s.mission_log_id IS NULL THEN '仅流水有记录（检查跨月分案或快照缺失）'
      WHEN l.mission_log_id IS NULL THEN '仅快照有记录（可能无回款或归属差异）'
      WHEN ABS(COALESCE(l.receipt_idr,0)-COALESCE(s.snapshot_receipt_idr,0))>0.01 THEN '两源金额不一致'
      ELSE '两源一致' END check_status
 FROM ledger l FULL OUTER JOIN snapshot s ON l.mission_log_id=s.mission_log_id
)
SELECT c.check_status,COUNT(*) assignment_records,
 ROUND(SUM(c.ledger_receipt_idr),4) ledger_receipt_idr,
 ROUND(SUM(c.snapshot_receipt_idr),4) snapshot_receipt_idr,
 ROUND(SUM(c.ledger_receipt_idr-c.snapshot_receipt_idr),4) difference_idr,
 ROUND(SUM(c.ledger_receipt_idr)/MAX(p.fx_rate),4) ledger_receipt_cny,
 ROUND(SUM(c.snapshot_receipt_idr)/MAX(p.fx_rate),4) snapshot_receipt_cny,
 SUM(CASE WHEN c.snapshot_rows>1 THEN 1 ELSE 0 END) multirow_snapshot_missions
FROM compared c CROSS JOIN params p GROUP BY c.check_status ORDER BY c.check_status;
