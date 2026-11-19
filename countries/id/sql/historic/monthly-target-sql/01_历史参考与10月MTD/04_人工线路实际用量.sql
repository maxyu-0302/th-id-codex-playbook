WITH raw AS (
 SELECT d.*, CASE WHEN assign_debtor_late_days BETWEEN 31 AND 60 THEN 'M2'
 WHEN assign_debtor_late_days BETWEEN 61 AND 90 THEN 'M3'
 WHEN assign_debtor_late_days BETWEEN 91 AND 210 THEN 'M4-7'
 WHEN assign_debtor_late_days BETWEEN 211 AND 999 THEN 'M7+' END stage
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d
 WHERE pt_date='2026-10-08' AND mission_log_create_date>='2026-10-01' AND mission_log_create_date<'2026-10-09'
 AND assign_debtor_late_days BETWEEN 31 AND 999
 AND (yewuzu IN ('M2','M3','M4') OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%'
 OR LOWER(TRIM(mission_group_name)) LIKE 'm3-%' OR LOWER(TRIM(mission_group_name)) LIKE 'm4-%')
 AND LOWER(TRIM(mission_group_name)) NOT LIKE '%cultivate%'
), intervals AS (
 SELECT DISTINCT stage,debtor_id,mission_group_name,mission_log_create_at,
 LEAST(COALESCE(unassign_create_at,CAST('2026-10-09' AS DATETIME)),CAST('2026-10-09' AS DATETIME)) end_at
 FROM raw
), calls AS (
 SELECT id,debtor_id,call_at,is_connect,dial_time,call_time,source_type,
 ROW_NUMBER() OVER(PARTITION BY id ORDER BY call_at DESC) rn
 FROM dm_wd_decision.dwd_employee_call_di
 WHERE pt_date>='2026-10-01' AND pt_date<'2026-10-09'
 AND call_at>='2026-10-01' AND call_at<'2026-10-09'
 AND call_channel=1 AND call_type IN (1,2)
), attributed AS (
 SELECT c.*,i.stage,i.mission_group_name,
 ROW_NUMBER() OVER(PARTITION BY c.id ORDER BY i.mission_log_create_at DESC,i.stage DESC,i.mission_group_name) seq
 FROM calls c JOIN intervals i ON i.debtor_id=c.debtor_id
 AND c.call_at>=i.mission_log_create_at AND c.call_at<i.end_at WHERE c.rn=1
)
SELECT stage, -- 工具发生时的委案账龄
 mission_group_name queue_name, -- 工具发生时所属队列
 source_type, -- 线路类型，需核对是否均按既有分钟单价覆盖
 COUNT(*) dial_n, -- 去重拨打次数
 SUM(CASE WHEN is_connect=1 THEN 1 ELSE 0 END) one_side_connect_n, -- 单边接通次数
 SUM(COALESCE(dial_time,0)) ring_seconds, -- 振铃秒数，不再乘历史人工秒成本
 SUM(COALESCE(call_time,0)) talk_seconds, -- 通话秒数
 SUM(CASE WHEN is_connect=1 THEN CEILING(COALESCE(call_time,0)/60.0) ELSE 0 END) billed_minutes -- 沿用既有每通向上取整接通分钟口径，若按holdtime结算需另核实
FROM attributed WHERE seq=1 GROUP BY stage,mission_group_name,source_type ORDER BY stage,mission_group_name,source_type;
