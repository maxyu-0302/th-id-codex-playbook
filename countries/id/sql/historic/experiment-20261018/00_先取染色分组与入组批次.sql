-- 印尼库执行；仅核验日志，不把全部type直接视作有效入组。截止2026-10-18。
SELECT DATE(r.create_at) AS color_date, -- 染色日志日期
       r.color AS experiment_color, -- 实际实验组名
       CAST(r.type AS VARCHAR) AS log_type, -- 新增/撤销类型，需确认语义
       COUNT(*) AS log_rows, -- 日志行数
       COUNT(DISTINCT r.debtor_id) AS debtor_count, -- 当日去重案件量，跨日不能求和
       COUNT(DISTINCT r.asset_item_number) AS asset_count, -- 当日去重资产数
       COUNT(DISTINCT r.batch_num) AS batch_count, -- 批次数
       MIN(r.create_at) AS first_log_at, -- 最早日志时间
       MAX(r.create_at) AS last_log_at -- 最晚日志时间
FROM fox_ods.ods_fox_asset_ranse_log r
WHERE r.create_at >= '2026-10-01'
  AND r.create_at < '2026-10-19'
  AND LOWER(r.color) LIKE '%txn%'
GROUP BY DATE(r.create_at),r.color,CAST(r.type AS VARCHAR)
ORDER BY color_date,experiment_color,log_type;
