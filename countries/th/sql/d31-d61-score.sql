-- 10月月初候选：9月20日D21-49 -> D32-60；D50-79 -> D61-90。
-- 在手账龄是源表线性估算；未认定为实际剩余债务状态。
WITH sa0 AS (
 SELECT o.*,ROW_NUMBER() OVER(PARTITION BY debtor_id,asset_id ORDER BY mission_ctime DESC,mission_log_id DESC) rn
 FROM dm_wd_decision.dwd_tc_full_mission_onhand_di o
 WHERE pt_date='2026-09-20' AND if_not_in_hand_rule_flg=0 AND is_last_onhand_today=1
),sa AS (SELECT *,ROW_NUMBER() OVER(PARTITION BY debtor_id ORDER BY assign_overdue_principal_amount DESC,mission_ctime DESC,mission_log_id DESC) queue_rn FROM sa0 WHERE rn=1),
sd AS (
 SELECT debtor_id,MAX(assign_debtor_late_days_today) dpd,
 SUM(assign_overdue_principal_amount) p,
 SUM(repaid_principal_amount) repaid_p,
 SUM(GREATEST(assign_overdue_principal_amount-COALESCE(repaid_principal_amount,0),0)) remaining_p,
 MIN(mission_group_name) min_queue,MAX(mission_group_name) max_queue,
 COUNT(DISTINCT mission_group_name) queues,MAX(CASE WHEN queue_rn=1 THEN mission_group_name END) primary_queue,MAX(overdue_period_c_level) current_c
 FROM sa GROUP BY debtor_id
),scores AS (
 SELECT sa.debtor_id,TRIM(c.due_diff_days) node,c.d3_level,c.data_generate_date,
 ROW_NUMBER() OVER(PARTITION BY sa.debtor_id,TRIM(c.due_diff_days) ORDER BY c.data_generate_date DESC,c.create_at DESC,c.id DESC) rn
 FROM sa JOIN sd ON sa.debtor_id=sd.debtor_id
 JOIN fox_ods.ods_fox_c_card_log c ON sa.asset_item_number=c.asset_item_number
 WHERE sd.dpd BETWEEN 50 AND 79 AND c.version='v3'
 AND ((TRIM(c.due_diff_days)='31' AND c.data_generate_date BETWEEN '2026-01-01' AND '2026-09-20')
 OR (TRIM(c.due_diff_days)='61' AND c.data_generate_date BETWEEN '2026-08-01' AND '2026-09-23')))
 SELECT sd.dpd,COALESCE(c31.d3_level,'missing') c31,
 COALESCE(c61.d3_level,'missing') c61,
 CASE WHEN c61.data_generate_date IS NULL THEN 'missing'
 WHEN c61.data_generate_date<c31.data_generate_date THEN 'before_d31'
 WHEN sd.dpd+3<61 THEN 'not_reached_but_score' ELSE 'available' END score_status,
 CASE WHEN p<=2000 THEN '0-2000' WHEN p<=4000 THEN '2000-4000' WHEN p<=10000 THEN '4000-10000' ELSE '10000+' END band,
 COUNT(*) n,SUM(p) p,MIN(c61.data_generate_date) min_score_date,MAX(c61.data_generate_date) max_score_date
 FROM sd LEFT JOIN scores c31 ON sd.debtor_id=c31.debtor_id AND c31.node='31' AND c31.rn=1
 LEFT JOIN scores c61 ON sd.debtor_id=c61.debtor_id AND c61.node='61' AND c61.rn=1
 WHERE sd.dpd BETWEEN 50 AND 79
 GROUP BY sd.dpd,c31,c61,score_status,band
