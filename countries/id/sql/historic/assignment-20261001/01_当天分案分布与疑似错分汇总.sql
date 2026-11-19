-- 印尼只读候选核验SQL，未在线执行；先运行00核实字段与日志类型。
-- 分案快照=当天每资产最后一次assign，不等于当前在手；撤案事件另查04。
-- 债务人本金=该批资产分案本金合计/100；若任务用不同本金口径，错分标识仅作疑点。
-- 未拿任务前完整资产池作分母，不能据此断言没漏分；也不能据此核验坐席是否已经作业。
WITH params AS (
 SELECT CAST('2026-10-01' AS DATE) biz_date,
        CURRENT_TIMESTAMP() cutoff_at, -- 执行时点；历史重跑请改成当日明确截止时间
        CAST('2026-10-01 08:30:00' AS DATETIME) task_start_at, -- 按源库时区校准
        'TXN_test' test_color,'TXN_compare' compare_color, -- compare名称需与配置一致
        CAST(NULL AS VARCHAR) add_type -- 先查00的type；确认新增染色类型后填写，NULL仅探索
),
today_rank AS (
 SELECT m.*,ROW_NUMBER() OVER(PARTITION BY m.debtor_id,m.mission_log_asset_id
 ORDER BY m.mission_log_create_at DESC,m.mission_log_id DESC) rn
 FROM fox_ods.ods_fox_mission_log m CROSS JOIN params p
 WHERE m.mission_log_operator='assign'
 AND COALESCE(m.mission_strategy,'') NOT LIKE '%归户%'
 AND m.mission_log_create_at>=p.biz_date
 AND m.mission_log_create_at<DATE_ADD(p.biz_date,INTERVAL 1 DAY)
 AND m.mission_log_create_at<p.cutoff_at
),
assets AS (SELECT * FROM today_rank WHERE rn=1),
cases AS (
 SELECT debtor_id,MAX(assign_debtor_late_days) dpd,
 SUM(assign_principal_amount)/100.0 principal_idr,
 COUNT(DISTINCT mission_group_name) queue_n,
 MAX(mission_group_name) queue_name,
 MIN(mission_log_create_at) first_asset_assign_at,MAX(mission_log_create_at) last_asset_assign_at,
 COUNT(*) asset_n
 FROM assets GROUP BY debtor_id
),
classified AS (
 SELECT c.*,
 CASE WHEN dpd BETWEEN 31 AND 60 THEN 'M2' WHEN dpd BETWEEN 61 AND 90 THEN 'M3'
 WHEN dpd BETWEEN 91 AND 210 THEN 'M4-7' WHEN dpd BETWEEN 211 AND 999 THEN 'M7+' ELSE '其他' END stage,
 CASE WHEN queue_n>1 THEN '多队列需核验'
 WHEN LOWER(queue_name)='m2-scq' THEN '专催'
 WHEN LOWER(queue_name) LIKE '%pure%' THEN '静置'
 WHEN LOWER(queue_name) LIKE '%ai%' THEN 'AI'
 WHEN LOWER(queue_name) IN ('m2','m3','m4') OR LOWER(queue_name) LIKE 'm2-%'
 OR LOWER(queue_name) LIKE 'm3-%' OR LOWER(queue_name) LIKE 'm4-%' THEN '人工候选'
 ELSE '未识别' END actual_mode,
 CASE WHEN dpd BETWEEN 31 AND 60 THEN
   CASE WHEN principal_idr<=800000 THEN 'AI' WHEN principal_idr<=6000000 THEN '人工候选' ELSE '专催' END
 WHEN dpd BETWEEN 61 AND 90 THEN
   CASE WHEN principal_idr<=200000 THEN '静置' WHEN principal_idr<=1000000 THEN 'AI'
        WHEN principal_idr<=8000000 THEN '人工候选' ELSE '专催' END
 WHEN dpd BETWEEN 91 AND 210 THEN
   CASE WHEN principal_idr<=300000 THEN '静置' WHEN principal_idr<=8000000 THEN 'AI20%/静置80%' ELSE '专催' END
 ELSE '沿用M7+策略_单列观察' END expected_mode,
 CASE WHEN dpd BETWEEN 31 AND 60 THEN
   CASE WHEN principal_idr<=800000 THEN '0-80万' WHEN principal_idr<=2000000 THEN '80-200万'
        WHEN principal_idr<=6000000 THEN '200-600万' ELSE '600万+' END
 WHEN dpd BETWEEN 61 AND 90 THEN
   CASE WHEN principal_idr<=200000 THEN '0-20万' WHEN principal_idr<=1000000 THEN '20-100万'
        WHEN principal_idr<=5000000 THEN '100-500万' WHEN principal_idr<=8000000 THEN '500-800万' ELSE '800万+' END
 ELSE CASE WHEN principal_idr<=300000 THEN '0-30万' WHEN principal_idr<=8000000 THEN '30-800万' ELSE '800万+' END END amount_band
 FROM cases c WHERE dpd BETWEEN 31 AND 999
),
audited AS (
 SELECT *,CASE WHEN queue_n>1 THEN '需核验_同债务人多队列'
 WHEN principal_idr IS NULL OR principal_idr<=0 THEN '需核验_金额缺失或非正'
 WHEN dpd>=211 THEN 'M7+单列_不套M4-7新专催门槛'
 WHEN actual_mode='专催' AND expected_mode<>'专催' THEN '需交叉核验TXN_test_可能合法转催'
 WHEN expected_mode='AI20%/静置80%' AND actual_mode IN ('AI','静置') THEN '模式符合_再看总体20比80'
 WHEN actual_mode=expected_mode THEN '模式符合'
 ELSE '疑似偏离_核验任务及金额口径' END audit_result
 FROM classified
)
SELECT stage,amount_band,expected_mode,actual_mode,queue_name,audit_result,
 COUNT(*) debtor_n, -- 本表债务人去重案件量
 ROUND(SUM(principal_idr),4) principal_idr, -- 本币IDR，不是人民币
 MIN(first_asset_assign_at) first_assign_at,MAX(last_asset_assign_at) last_assign_at
FROM audited
GROUP BY stage,amount_band,expected_mode,actual_mode,queue_name,audit_result
ORDER BY stage,amount_band,actual_mode,queue_name;
