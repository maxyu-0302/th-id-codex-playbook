WITH d AS (
 SELECT pt_date,debtor_id,MAX(assign_debtor_late_days_today) dpd
 FROM dm_wd_decision.dwd_tc_full_mission_onhand_di
 WHERE pt_date BETWEEN '2026-08-22' AND '2026-10-21'
 AND if_not_in_hand_rule_flg=0 AND is_last_onhand_today=1
 GROUP BY pt_date,debtor_id
)
SELECT pt_date AS `快照日期`,COUNT(*) AS `在手案件量`,
SUM(CASE WHEN dpd=31 THEN 1 ELSE 0 END) AS `D31案件量`,
SUM(CASE WHEN dpd=61 THEN 1 ELSE 0 END) AS `D61案件量`,
SUM(CASE WHEN dpd=91 THEN 1 ELSE 0 END) AS `D91案件量`
FROM d GROUP BY pt_date ORDER BY pt_date DESC
