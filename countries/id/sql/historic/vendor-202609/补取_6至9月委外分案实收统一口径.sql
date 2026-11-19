/* 印尼，只读；尚未在线执行。用于统一6—9月各委外队列本金、实收、案件量。
 每月只取月底一个分区，分案本金按队列×资产×期次首次去重。
 实收不能跟随本金排名筛掉；本查询沿用二层表回款字段，不代表已经财务对平。
 stage按队列命名归类，保留实际DPD最小/最大用于检查M4覆盖范围变化。
 金额保留IDR元，不/100；换汇应由财务确认各月汇率后统一处理。
*/
WITH snapshots AS (
 SELECT '2026-06-30' pt,'2026-06-01' start_date,'2026-07-01' end_date
 UNION ALL SELECT '2026-07-31','2026-07-01','2026-08-01'
 UNION ALL SELECT '2026-08-31','2026-08-01','2026-09-01'
 UNION ALL SELECT '2026-09-30','2026-09-01','2026-10-01'
), r AS (
 SELECT m.pt_date,m.debtor_id,m.mission_group_name,m.assign_debtor_late_days,
 m.assign_principal_amount,m.repaid_total_amount,
 ROW_NUMBER() OVER(PARTITION BY m.pt_date,m.mission_group_name,m.mission_log_asset_id,m.overdue_period
 ORDER BY m.mission_log_create_at,m.mission_log_id) principal_rn
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer m
 JOIN snapshots s ON m.pt_date=s.pt
 WHERE m.mission_log_create_date>=s.start_date AND m.mission_log_create_date<s.end_date
 AND UPPER(TRIM(m.mission_group_name)) IN
 ('M2-CPU','M2-EDN','M3-EDN','M3-QIN','M4-CPU','M4-EDN','M4-QIN','M4-KAT','M4-DEBITO')
)
SELECT SUBSTR(pt_date,1,7) month, -- 月份
 mission_group_name queue_name, -- 委外队列
 COUNT(DISTINCT debtor_id) queue_cases, -- 队列内独立案件量，跨队列不可作为唯一人数相加
 ROUND(SUM(CASE WHEN principal_rn=1 THEN COALESCE(assign_principal_amount,0) ELSE 0 END),4) principal_idr, -- 分案本金IDR元
 ROUND(SUM(COALESCE(repaid_total_amount,0)),4) receipts_idr, -- 分案表归属实收IDR元
 MIN(assign_debtor_late_days) min_dpd, -- 实际分案DPD最小值
 MAX(assign_debtor_late_days) max_dpd, -- 实际分案DPD最大值
 COUNT(*) records -- 来源记录数量，空月份需单独查分区
FROM r GROUP BY SUBSTR(pt_date,1,7),mission_group_name
ORDER BY month,queue_name;
