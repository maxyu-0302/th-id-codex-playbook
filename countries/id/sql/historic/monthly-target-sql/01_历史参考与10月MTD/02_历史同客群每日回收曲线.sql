WITH params AS (SELECT CAST('2026-08-31' AS DATE) month_end UNION ALL SELECT CAST('2026-09-30' AS DATE) UNION ALL SELECT CAST('2026-10-08' AS DATE)),
-- 运行阶段参数：默认同时查询M2、M3、M4；如需单阶段运行，仅保留对应一行。
stage_params AS (SELECT 'M2' target_stage UNION ALL SELECT 'M3' UNION ALL SELECT 'M4' UNION ALL SELECT 'M7+'),
-- 1 月末MTD快照：先修补有明确队列证据的空业务组，再按修补后业务组重排分案本金去重序号。
-- 原is_yewuzu是按原始yewuzu（含NULL）分区的ROW_NUMBER；补值后直接沿用会对同一资产期次重复计本金。
raw_stage AS (
 SELECT r.*,
 CASE WHEN r.assign_debtor_late_days BETWEEN 211 AND 999 AND (r.yewuzu='M4' OR LOWER(TRIM(r.mission_group_name)) LIKE 'm4-%') THEN 'M7+'
 WHEN LOWER(TRIM(r.mission_group_name))='m2-scq' THEN
 CASE WHEN r.assign_debtor_late_days BETWEEN 31 AND 60 THEN 'M2' WHEN r.assign_debtor_late_days BETWEEN 61 AND 90 THEN 'M3' WHEN r.assign_debtor_late_days BETWEEN 91 AND 210 THEN 'M4' ELSE NULL END
 WHEN r.yewuzu IS NOT NULL AND TRIM(r.yewuzu)<>'' THEN TRIM(r.yewuzu)
      WHEN LOWER(TRIM(r.mission_group_name))='m3-pure' THEN 'M3'
      WHEN LOWER(TRIM(r.mission_group_name)) IN ('m4-pure','m4-pure-91-210') THEN 'M4'
      ELSE NULL END corrected_yewuzu,
 CASE WHEN r.yewuzu IS NOT NULL AND TRIM(r.yewuzu)<>'' THEN 'original'
      WHEN LOWER(TRIM(r.mission_group_name))='m3-pure' THEN 'M3-Pure_imputed'
      WHEN LOWER(TRIM(r.mission_group_name)) IN ('m4-pure','m4-pure-91-210') THEN 'M4-Pure_imputed'
      ELSE 'unmapped' END yewuzu_source
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer r
 JOIN params p ON r.pt_date=p.month_end
),
raw AS (
 SELECT pt_date,mission_log_create_at,mission_log_create_date,mission_group_name,
 assign_principal_amount,repaid_principal_amount_without_pre,mission_log_asset_id,overdue_period,
 asset_item_number,debtor_id,is_asset_new,mission_log_id,assign_debtor_late_days,
 unassign_create_at,repaid_total_amount,corrected_yewuzu yewuzu,yewuzu_source,
 ROW_NUMBER() OVER (
  PARTITION BY pt_date,DATE_TRUNC('month',mission_log_create_date),mission_log_asset_id,overdue_period,corrected_yewuzu
  ORDER BY mission_log_create_date,mission_log_create_at DESC,mission_log_id DESC
 ) is_yewuzu
 FROM raw_stage WHERE corrected_yewuzu IN (SELECT target_stage FROM stage_params)
 AND mission_log_create_date>=DATE_TRUNC('month',CAST(pt_date AS DATE)) AND mission_log_create_date<DATE_ADD(CAST(pt_date AS DATE),INTERVAL 1 DAY)
),
monthly AS (
 SELECT pt_date,yewuzu,debtor_id,CASE WHEN yewuzu='M2' THEN 31 WHEN yewuzu='M3' THEN 61 ELSE 91 END stage_dpd,
 SUM(CASE WHEN is_yewuzu=1 THEN assign_principal_amount ELSE 0 END) assigned_principal,
 SUM(COALESCE(repaid_total_amount,0)) receipts,
 SUM(COALESCE(repaid_principal_amount_without_pre,0)) overdue_principal_receipts,
 MIN(CASE WHEN is_yewuzu=1 THEN mission_log_create_date END) first_assign_date,
 COUNT(*) source_rows,COUNT(DISTINCT mission_group_name) queue_count,
 SUM(CASE WHEN yewuzu_source='M4-Pure_imputed' THEN 1 ELSE 0 END) imputed_m4_pure_rows,
 SUM(CASE WHEN yewuzu_source='M4-Pure_imputed' AND is_yewuzu=1 THEN 1 ELSE 0 END) imputed_m4_pure_rank1_rows
 FROM raw GROUP BY pt_date,yewuzu,debtor_id
),
-- 2 首次有效分案日金额冻结分群；全月追加本金仍计入全月回收率分母。
entry_all AS (
 SELECT m.pt_date,m.yewuzu,m.debtor_id,m.stage_dpd,m.assigned_principal,m.receipts,
 m.overdue_principal_receipts,m.first_assign_date,m.source_rows,m.queue_count,m.imputed_m4_pure_rows,m.imputed_m4_pure_rank1_rows,SUM(r.assign_principal_amount) entry_principal,
 MAX(r.assign_debtor_late_days) entry_dpd,MIN(r.mission_log_create_at) first_assign_at,
 MAX(CASE WHEN r.is_asset_new='1' THEN 1 ELSE 0 END) first_day_has_new
 FROM monthly m LEFT JOIN raw r ON m.pt_date=r.pt_date AND m.yewuzu=r.yewuzu
 AND m.debtor_id=r.debtor_id AND r.is_yewuzu=1 AND r.mission_log_create_date=m.first_assign_date
 GROUP BY m.pt_date,m.yewuzu,m.debtor_id,m.stage_dpd,m.assigned_principal,m.receipts,
 m.overdue_principal_receipts,m.first_assign_date,m.source_rows,m.queue_count,m.imputed_m4_pure_rows,m.imputed_m4_pure_rank1_rows
),
-- M4仅分析首次有效分案日债务人最大逾期天数D91-210的样本；M2/M3保持原口径。
entry AS (
 SELECT * FROM entry_all
 WHERE yewuzu IN ('M2','M3') OR (yewuzu='M4' AND entry_dpd BETWEEN 91 AND 210) OR (yewuzu='M7+' AND entry_dpd BETWEEN 211 AND 999)
),
-- 3 从C卡模型结果回溯D31/D61/D91评分记录节点，不依赖当前分案记录的is_asset_new。
-- 老案、撤案重分仍可通过“当月样本资产 + 历史评分日期”找回进入账龄段时的节点。
card_source AS (
 SELECT asset_item_no asset_item_number,STR_TO_DATE(dt,'%Y%m%d') score_date,
 CAST(due_diff_days AS INT) node_dpd,CAST(CAST(cscore_level AS DECIMAL(10,2)) AS INT) c_level,
 'v4' version_status
 FROM hive.rpt.rpt_w_cscore_model_result_v4
 WHERE dt>='20260501' AND dt<'20261009' AND due_diff_days IN ('31','61','91')
 AND asset_item_no IN (SELECT DISTINCT CAST(r.asset_item_number AS VARCHAR) FROM raw r JOIN entry e ON r.pt_date=e.pt_date AND r.yewuzu=e.yewuzu AND r.debtor_id=e.debtor_id WHERE r.asset_item_number IS NOT NULL)
),
cohort_assets AS (
 SELECT DISTINCT r.pt_date,r.yewuzu,r.debtor_id,CAST(r.asset_item_number AS VARCHAR) asset_item_number
 FROM raw r JOIN entry e ON r.pt_date=e.pt_date AND r.yewuzu=e.yewuzu AND r.debtor_id=e.debtor_id
 WHERE r.asset_item_number IS NOT NULL
),
anchor AS (
 SELECT e.pt_date,e.yewuzu,e.debtor_id,MAX(c.score_date) stage_entry_date
 FROM entry e LEFT JOIN cohort_assets a ON e.pt_date=a.pt_date AND e.yewuzu=a.yewuzu AND e.debtor_id=a.debtor_id
 LEFT JOIN card_source c ON c.asset_item_number=a.asset_item_number
 AND c.node_dpd=e.stage_dpd AND c.score_date<=e.first_assign_date
 AND c.score_date>=DATE_SUB(e.first_assign_date,INTERVAL 90 DAY)
 GROUP BY e.pt_date,e.yewuzu,e.debtor_id
),
card_ranked AS (
 SELECT a.pt_date,a.yewuzu,a.debtor_id,c.*,
 ROW_NUMBER() OVER(PARTITION BY a.pt_date,a.yewuzu,a.debtor_id,c.asset_item_number,c.version_status
 ORDER BY c.score_date DESC,c.c_level DESC) rn
 FROM anchor a JOIN cohort_assets n ON a.pt_date=n.pt_date AND a.yewuzu=n.yewuzu AND a.debtor_id=n.debtor_id
 JOIN card_source c ON c.asset_item_number=n.asset_item_number AND c.score_date=a.stage_entry_date
 AND c.node_dpd=CASE WHEN a.yewuzu='M2' THEN 31 WHEN a.yewuzu='M3' THEN 61 ELSE 91 END
),
card AS (
 SELECT pt_date,yewuzu,debtor_id,
 COUNT(DISTINCT CASE WHEN version_status='v4' AND c_level BETWEEN 1 AND 10 THEN c_level END) v3_levels,
 MAX(CASE WHEN version_status='v4' AND c_level BETWEEN 1 AND 10 THEN c_level END) v3_level,
 COUNT(DISTINCT asset_item_number) scored_assets
 FROM card_ranked WHERE rn=1 GROUP BY pt_date,yewuzu,debtor_id
),
first_queue_rows AS (
 SELECT DISTINCT e.pt_date,e.yewuzu,e.debtor_id,r.mission_group_name,
 CASE WHEN LOWER(TRIM(r.mission_group_name))='m2-scq' THEN 'specialist'
 WHEN LOWER(r.mission_group_name) LIKE '%pure%' THEN 'pure'
      WHEN LOWER(r.mission_group_name) LIKE '%ai%' THEN 'ai'
      WHEN r.mission_group_name=e.yewuzu OR r.mission_group_name LIKE CONCAT(e.yewuzu,'-%') THEN 'manual'
      ELSE 'unknown' END mode_name
 FROM entry e JOIN raw r ON e.pt_date=r.pt_date AND e.yewuzu=r.yewuzu
 AND e.debtor_id=r.debtor_id AND r.is_yewuzu=1 AND r.mission_log_create_at=e.first_assign_at
),
first_queue AS (
 SELECT pt_date,yewuzu,debtor_id,
 CASE WHEN COUNT(DISTINCT mission_group_name)=1 THEN MAX(mission_group_name) ELSE 'MULTIPLE_OR_UNKNOWN' END first_assign_queue,
 COUNT(DISTINCT mission_group_name) first_assign_queue_count,
 CASE WHEN COUNT(DISTINCT mode_name)=1 THEN MAX(mode_name) ELSE 'mixed' END first_assign_mode
 FROM first_queue_rows GROUP BY pt_date,yewuzu,debtor_id
),
labeled AS (
 SELECT e.*,q.first_assign_queue,q.first_assign_mode,c.v3_level,c.v3_levels,
 a.stage_entry_date,
 CASE WHEN c.v3_level BETWEEN 1 AND 10 THEN CONCAT('C',CAST(c.v3_level AS VARCHAR)) ELSE '缺失' END c_card,
 CASE WHEN e.entry_principal IS NULL OR e.entry_principal<=0 THEN '00_金额异常'
 WHEN e.entry_principal<=200000 THEN '01_0-20万'
 WHEN e.entry_principal<=300000 THEN '02_20-30万'
 WHEN e.entry_principal<=400000 THEN '03_30-40万'
 WHEN e.entry_principal<=600000 THEN '04_40-60万'
 WHEN e.entry_principal<=800000 THEN '05_60-80万'
 WHEN e.entry_principal<=1000000 THEN '06_80-100万'
 WHEN e.entry_principal<=1500000 THEN '07_100-150万'
 WHEN e.entry_principal<=2000000 THEN '08_150-200万'
 WHEN e.entry_principal<=4000000 THEN '09_200-400万'
 WHEN e.entry_principal<=5000000 THEN '10_400-500万'
 WHEN e.entry_principal<=6000000 THEN '11_500-600万'
 WHEN e.entry_principal<=8000000 THEN '12_600-800万'
 WHEN e.entry_principal<=10000000 THEN '13_800-1000万'
 ELSE '14_1000万以上' END amount_band
 FROM entry e
 LEFT JOIN card c ON e.pt_date=c.pt_date AND e.yewuzu=c.yewuzu AND e.debtor_id=c.debtor_id
 LEFT JOIN anchor a ON e.pt_date=a.pt_date AND e.yewuzu=a.yewuzu AND e.debtor_id=a.debtor_id
 LEFT JOIN first_queue q ON e.pt_date=q.pt_date AND e.yewuzu=q.yewuzu AND e.debtor_id=q.debtor_id
)
, recovery_rank AS (
 SELECT id,mission_log_id,repay_date,repaid_total_amount,
 ROW_NUMBER() OVER(PARTITION BY id ORDER BY update_at DESC,etl_time DESC) rn
 FROM fox_ods.ods_fox_collect_recovery
 WHERE repay_date>='2026-08-01' AND repay_date<'2026-10-09'
), mission_keys AS (
 SELECT DISTINCT pt_date,yewuzu,debtor_id,mission_log_id FROM raw
), daily AS (
 SELECT l.pt_date,l.yewuzu,l.first_assign_queue,l.first_assign_mode,l.amount_band,l.c_card,
 CASE WHEN DAY(l.first_assign_date)=1 AND l.entry_dpd NOT IN (31,61,91) THEN '月初非节点'
 WHEN l.entry_dpd IN (31,61,91) THEN '节点新案' ELSE '其他分案' END entry_type,
 DATE(r.repay_date) repay_day,DAY(r.repay_date) month_day,
 DATEDIFF(DATE(r.repay_date),l.first_assign_date) days_since_assign,
 SUM(r.repaid_total_amount)/100.0 receipts_idr
 FROM labeled l JOIN mission_keys k ON k.pt_date=l.pt_date AND k.yewuzu=l.yewuzu AND k.debtor_id=l.debtor_id
 JOIN recovery_rank r ON r.mission_log_id=k.mission_log_id AND r.rn=1
 AND r.repay_date>=DATE_TRUNC('month',CAST(l.pt_date AS DATE))
 AND r.repay_date<DATE_ADD(CAST(l.pt_date AS DATE),INTERVAL 1 DAY)
 GROUP BY l.pt_date,l.yewuzu,l.first_assign_queue,l.first_assign_mode,l.amount_band,l.c_card,
 CASE WHEN DAY(l.first_assign_date)=1 AND l.entry_dpd NOT IN (31,61,91) THEN '月初非节点'
 WHEN l.entry_dpd IN (31,61,91) THEN '节点新案' ELSE '其他分案' END,
 DATE(r.repay_date),DAY(r.repay_date),DATEDIFF(DATE(r.repay_date),l.first_assign_date)
)
SELECT pt_date snapshot_date, -- 8月31日、9月30日及10月8日
 yewuzu business_stage, -- 分账龄曲线
 first_assign_queue, -- 首分归因队列；用于匹配历史同模式，不能当专催历史实绩
 first_assign_mode, -- 历史作业模式
 amount_band, -- 首分本金档位
 c_card, -- 节点C卡
 entry_type, -- 月初非节点、节点新案、其他分案；月初非节点尚未证明上月留存
 repay_day, -- 实际回款日
 month_day, -- 月内日序号
 days_since_assign, -- 首分后经过天数；负数为异常需核验
 ROUND(receipts_idr,4) receipts_idr -- 归属本月本账龄客群当日实收，含负向调整
FROM daily ORDER BY pt_date,yewuzu,first_assign_queue,amount_band,c_card,repay_day,days_since_assign;
