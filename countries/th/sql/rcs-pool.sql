WITH hand_ranked AS (
 SELECT pt_date,asset_item_number,debtor_id,mission_group_name,assign_overdue_principal_amount,assign_debtor_late_days_today,
 ROW_NUMBER() OVER(PARTITION BY pt_date,asset_item_number ORDER BY mission_ctime DESC,mission_log_id DESC) rn
 FROM dm_wd_decision.dwd_tc_full_mission_onhand_di
 WHERE pt_date IN ('2026-11-15','2026-11-16','2026-11-17','2026-11-18')
 AND if_not_in_hand_rule_flg=0 AND is_last_onhand_today=1
 AND (unassign_time IS NULL OR unassign_time>=DATE_ADD(pt_date,INTERVAL 1 DAY))
), stock AS (
 SELECT pt_date snap,debtor_id,MAX(assign_debtor_late_days_today) dpd
 FROM hand_ranked WHERE rn=1 AND debtor_id IS NOT NULL GROUP BY 1,2
 HAVING MIN(LOWER(TRIM(mission_group_name)))='m2-pure'
 AND MAX(LOWER(TRIM(mission_group_name)))='m2-pure'
 AND COUNT(DISTINCT LOWER(TRIM(mission_group_name)))=1
 AND COUNT(assign_overdue_principal_amount)=COUNT(*)
 AND SUM(assign_overdue_principal_amount)>=10000
), caps AS (
 SELECT 47 hi UNION ALL SELECT 48 UNION ALL SELECT 49
)
SELECT hi,COUNT(DISTINCT CASE WHEN snap='2026-11-15' THEN debtor_id END) n15,
 COUNT(DISTINCT CASE WHEN snap='2026-11-16' THEN debtor_id END) n16,
 COUNT(DISTINCT CASE WHEN snap='2026-11-17' THEN debtor_id END) n17,
 COUNT(DISTINCT CASE WHEN snap='2026-11-18' THEN debtor_id END) n18,
 COUNT(DISTINCT CASE WHEN snap<='2026-11-17' THEN debtor_id END) n15_17,
 COUNT(DISTINCT CASE WHEN snap>='2026-11-16' THEN debtor_id END) n16_18
FROM caps JOIN stock ON dpd BETWEEN 31 AND hi GROUP BY hi ORDER BY hi
