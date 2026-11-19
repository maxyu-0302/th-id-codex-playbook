WITH raw AS (
 SELECT d.debtor_id,d.mission_group_name,d.mission_log_create_at,d.unassign_create_at, CASE WHEN assign_debtor_late_days BETWEEN 31 AND 60 THEN 'M2'
 WHEN assign_debtor_late_days BETWEEN 61 AND 90 THEN 'M3'
 WHEN assign_debtor_late_days BETWEEN 91 AND 210 THEN 'M4-7'
 WHEN assign_debtor_late_days BETWEEN 211 AND 999 THEN 'M7+' END stage
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d
 WHERE pt_date='2026-09-08' AND mission_log_create_date>='2026-09-01' AND mission_log_create_date<'2026-09-09'
 AND assign_debtor_late_days BETWEEN 31 AND 999
 AND (yewuzu IN ('M2','M3','M4') OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%'
 OR LOWER(TRIM(mission_group_name)) LIKE 'm3-%' OR LOWER(TRIM(mission_group_name)) LIKE 'm4-%')
 AND LOWER(TRIM(mission_group_name)) NOT LIKE '%cultivate%'
), intervals AS (
 SELECT DISTINCT stage,debtor_id,mission_group_name,mission_log_create_at,
 LEAST(COALESCE(unassign_create_at,CAST('2026-09-09' AS DATETIME)),CAST('2026-09-09' AS DATETIME)) end_at
 FROM raw
), calls AS (
 SELECT domain,service,id,callback_id,debtor_id,call_start_at,talk_duration,connect_result,
 ROW_NUMBER() OVER(PARTITION BY domain,service,id,callback_id ORDER BY etl_time DESC) rn
 FROM dm_wd_decision.dwd_ivr_call_di WHERE pt_date>='2026-09-01' AND pt_date<'2026-09-09'
 AND call_start_at>='2026-09-01' AND call_start_at<'2026-09-09'
), candidates AS (
 SELECT c.domain,c.service,c.id,c.callback_id,c.talk_duration,c.connect_result,
 i.stage,i.mission_group_name,i.mission_log_create_at begin_at
 FROM calls c JOIN intervals i ON c.debtor_id=i.debtor_id
 AND c.call_start_at>=i.mission_log_create_at AND c.call_start_at<i.end_at
 WHERE c.rn=1
), latest_time AS (
 SELECT domain,service,id,callback_id,MAX(begin_at) latest_begin_at
 FROM candidates GROUP BY domain,service,id,callback_id
), events AS (
 SELECT c.domain,c.service,c.id,c.callback_id,
 CASE WHEN COUNT(DISTINCT c.stage)=1 THEN MAX(c.stage) ELSE 'AMBIGUOUS_STAGE' END stage,
 CASE WHEN COUNT(DISTINCT c.mission_group_name)=1 THEN MAX(c.mission_group_name) ELSE 'MULTIPLE_QUEUES' END queue_name,
 MAX(CASE WHEN c.talk_duration>0 THEN 1 ELSE 0 END) connected,
 MAX(CASE WHEN c.connect_result='VOICEMAIL' THEN 1 ELSE 0 END) voicemail,
 CASE WHEN COUNT(DISTINCT c.stage)>1 OR COUNT(DISTINCT c.mission_group_name)>1 THEN 1 ELSE 0 END ambiguous
 FROM candidates c JOIN latest_time l
 ON (c.domain=l.domain OR (c.domain IS NULL AND l.domain IS NULL))
 AND (c.service=l.service OR (c.service IS NULL AND l.service IS NULL))
 AND (c.id=l.id OR (c.id IS NULL AND l.id IS NULL))
 AND (c.callback_id=l.callback_id OR (c.callback_id IS NULL AND l.callback_id IS NULL))
 AND c.begin_at=l.latest_begin_at
 GROUP BY c.domain,c.service,c.id,c.callback_id
)
SELECT stage, -- AI发生时最近有效委案账龄；多账龄歧义单列
 queue_name, -- 最近有效委案队列；同刻多队列歧义单列
 COUNT(*) dial_n, -- 匹配委案后的去重AI拨打事件量
 SUM(connected) connect_n, -- 通时大于0的接通量
 SUM(voicemail) voicemail_n, -- 语音信箱量
 SUM(CASE WHEN connected=1 OR voicemail=1 THEN 1 ELSE 0 END) billed_n, -- 接通或语音信箱的并集计费量
 SUM(CASE WHEN connected=1 AND voicemail=1 THEN 1 ELSE 0 END) overlap_n, -- 接通与语音信箱交集量
 SUM(CASE WHEN connected=1 AND voicemail=0 THEN 1 ELSE 0 END) normal_connect_n, -- 排除语音信箱的普通接通量
 SUM(ambiguous) ambiguous_attribution_n -- 同刻多个队列或账龄归属歧义量，需单独核验
FROM events GROUP BY stage,queue_name ORDER BY stage,queue_name;
