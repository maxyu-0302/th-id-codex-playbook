-- 预测按成熟历史本金迁移矩阵分到目标金额档；D1单独校准，防止用D1-10幸存客群替代。
WITH owners AS (
 SELECT a.asset_item_number,MIN(a.debtor_id) debtor_id FROM fox_ods.ods_fox_debtor_asset a
 WHERE MOD(a.debtor_id,8)=0
 GROUP BY a.asset_item_number HAVING COUNT(DISTINCT a.debtor_id)=1
), p0 AS (
 SELECT d.*,o.debtor_id,ROW_NUMBER() OVER(PARTITION BY d.asset_item_no,d.period_seq ORDER BY d.etl_update_time DESC,d.grant_time DESC) rn
 FROM dwb.dwb_asset_period_info d JOIN owners o ON o.asset_item_number=d.asset_item_no
 WHERE d.grant_time<'2026-10-22' AND d.asset_period_create_time<'2026-10-22'
 AND d.due_time>='2018-01-01' AND d.due_time<'2026-10-22'
 AND (d.finish_time IS NULL OR d.finish_time>='2026-08-21')
), pp AS (SELECT * FROM p0 WHERE rn=1),
r0 AS (
 SELECT r.asset_item_number,r.repaid_period,r.repay_date,r.repaid_principal_amount/100.0 paid,
 ROW_NUMBER() OVER(PARTITION BY r.asset_item_number,r.repaid_period,COALESCE(NULLIF(r.serial_num,''),CAST(r.id AS VARCHAR)) ORDER BY r.update_at DESC,r.etl_time DESC,r.id DESC) rn
 FROM fox_ods.ods_fox_asset_period_recovery r
 WHERE r.repay_date>='2026-08-21'
), rr AS (SELECT * FROM r0 WHERE rn=1),
snap AS (SELECT CAST('2026-09-01' AS DATE) dt),
ps AS (
 SELECT s.dt,p.debtor_id,p.asset_item_no,p.period_seq,p.due_time,p.finish_time,
 p.contract_principal_period_amt-p.repaid_principal_period_amt+COALESCE(SUM(r.paid),0) balance
 FROM pp p JOIN snap s ON p.grant_time<DATE_ADD(s.dt,INTERVAL 1 DAY) AND p.asset_period_create_time<DATE_ADD(s.dt,INTERVAL 1 DAY)
 AND p.due_time<s.dt AND (p.finish_time IS NULL OR p.finish_time>=DATE_ADD(s.dt,INTERVAL 1 DAY))
 LEFT JOIN rr r ON r.asset_item_number=p.asset_item_no AND r.repaid_period=p.period_seq
 AND r.repay_date>=DATE_ADD(s.dt,INTERVAL 1 DAY) AND r.repay_date<=p.etl_update_time
 GROUP BY s.dt,p.debtor_id,p.asset_item_no,p.period_seq,p.due_time,p.finish_time,p.contract_principal_period_amt,p.repaid_principal_period_amt
), debt AS (
 SELECT dt,debtor_id,MIN(DATE(due_time)) oldest_due,SUM(GREATEST(balance,0)) principal_idr,
 SUM(CASE WHEN balance<0 THEN 1 ELSE 0 END) negative_periods
 FROM ps GROUP BY dt,debtor_id
), stock AS (
 SELECT d.dt,d.debtor_id,d.oldest_due,d.principal_idr,d.negative_periods,DATEDIFF(d.dt,d.oldest_due) dpd,
 MAX(CASE WHEN DATE(p.due_time)=d.oldest_due THEN COALESCE(DATE(p.finish_time),CAST('2099-01-01' AS DATE)) END) oldest_finish
 FROM debt d JOIN ps p ON p.dt=d.dt AND p.debtor_id=d.debtor_id
 GROUP BY d.dt,d.debtor_id,d.oldest_due,d.principal_idr,d.negative_periods
), labeled AS (
 SELECT *,CASE WHEN principal_idr<=200000 THEN 1 WHEN principal_idr<=300000 THEN 2 WHEN principal_idr<=800000 THEN 3 WHEN principal_idr<=1000000 THEN 4 WHEN principal_idr<=2000000 THEN 5 WHEN principal_idr<=3000000 THEN 6 WHEN principal_idr<=4000000 THEN 7 WHEN principal_idr<=5000000 THEN 8 WHEN principal_idr<=6000000 THEN 9 WHEN principal_idr<=8000000 THEN 10 WHEN principal_idr<=10000000 THEN 11 WHEN principal_idr<=15000000 THEN 12 WHEN principal_idr<=20000000 THEN 13 ELSE 14 END band FROM stock WHERE dpd BETWEEN 1 AND 3000 AND principal_idr>0
)
, horizons AS (SELECT 1 h UNION ALL SELECT 11 UNION ALL SELECT 20 UNION ALL SELECT 30 UNION ALL SELECT 40), cohort AS (
 SELECT l.*,h.h,DATE_ADD(l.dt,INTERVAL h.h DAY) target_date,
 CASE WHEN dpd=1 THEN 1 WHEN dpd<=10 THEN 2 WHEN dpd<=20 THEN 11 WHEN dpd<=30 THEN 21 WHEN dpd<=45 THEN 31 WHEN dpd<=60 THEN 46 WHEN dpd<=75 THEN 61 WHEN dpd<=90 THEN 76 WHEN dpd<=120 THEN 91 WHEN dpd<=150 THEN 121 WHEN dpd<=180 THEN 151 WHEN dpd<=210 THEN 181 WHEN dpd<=999 THEN 211 ELSE 1000 END dpd_group
 FROM labeled l CROSS JOIN horizons h
 WHERE l.dt='2026-09-01' AND DATE_ADD(l.dt,INTERVAL h.h DAY)<='2026-10-21'
), future_periods AS (
 SELECT c.dt,c.debtor_id,c.h,p.asset_item_no,p.period_seq,
 GREATEST(p.contract_principal_period_amt-p.repaid_principal_period_amt+COALESCE(SUM(r.paid),0),0) scheduled_balance,
 GREATEST(p.contract_principal_period_amt-p.repaid_principal_period_amt+COALESCE(SUM(CASE WHEN r.repay_date>=DATE_ADD(c.target_date,INTERVAL 1 DAY) THEN r.paid ELSE 0 END),0),0) target_balance
 FROM cohort c JOIN pp p ON p.debtor_id=c.debtor_id
 AND p.grant_time<DATE_ADD(c.dt,INTERVAL 1 DAY) AND p.asset_period_create_time<DATE_ADD(c.dt,INTERVAL 1 DAY)
 AND p.due_time<c.target_date AND (p.finish_time IS NULL OR p.finish_time>=DATE_ADD(c.dt,INTERVAL 1 DAY))
 LEFT JOIN rr r ON r.asset_item_number=p.asset_item_no AND r.repaid_period=p.period_seq
 AND r.repay_date>=DATE_ADD(c.dt,INTERVAL 1 DAY) AND r.repay_date<=p.etl_update_time
 GROUP BY c.dt,c.debtor_id,c.h,p.asset_item_no,p.period_seq,p.contract_principal_period_amt,p.repaid_principal_period_amt
), amounts AS (
 SELECT dt,debtor_id,h,SUM(scheduled_balance) scheduled_balance,SUM(target_balance) target_balance
 FROM future_periods GROUP BY dt,debtor_id,h
)
SELECT c.dpd_group,c.band,c.h,COUNT(*) origin_cases,
 SUM(a.scheduled_balance) scheduled_principal_idr, SUM(CASE WHEN a.target_balance>0 THEN 1 ELSE 0 END) open_cases,
 SUM(CASE WHEN c.oldest_finish>c.target_date AND a.target_balance>0 THEN 1 ELSE 0 END) retained_cases,
 SUM(CASE WHEN c.oldest_finish>c.target_date THEN a.target_balance ELSE 0 END) retained_principal_idr
FROM cohort c JOIN amounts a ON a.dt=c.dt AND a.debtor_id=c.debtor_id AND a.h=c.h
GROUP BY c.dpd_group,c.band,c.h ORDER BY c.dpd_group,c.band,c.h LIMIT 2000
