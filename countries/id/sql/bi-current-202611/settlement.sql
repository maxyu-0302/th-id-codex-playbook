-- Only small published result tables. No raw ODS/period joins. Current business month (yesterday); do not fall back to an older month.
WITH latest AS(SELECT report_month,MAX(data_as_of) data_as_of FROM dm_tmp.maxyu_id_long_monitor_publish WHERE report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE) GROUP BY report_month),
ready AS(SELECT p.* FROM dm_tmp.maxyu_id_long_monitor_publish p JOIN latest l ON p.report_month=l.report_month AND p.data_as_of=l.data_as_of)
SELECT r.report_month,r.data_as_of,p.published_at,p.config_version,p.config_sha256,
r.`month`,r.`observation_end`,r.`stage`,r.`mode`,r.`assigned_cases`,r.`eligible_cases`,r.`fully_settled_cases`,r.`no_overdue_cases`,r.`unknown_cases`,r.`pre_settled_cases`,r.`no_entry_assets_cases`,r.`avg_observation_days`,r.`latest_period_etl`,r.`fully_settled_rate`,r.`no_overdue_rate`,r.`no_overdue_but_unsettled_cases`,r.`scope_note`
FROM dm_tmp.maxyu_id_long_monitor_settlement r JOIN ready p ON r.report_month=p.report_month AND r.data_as_of=p.data_as_of AND r.run_id=p.run_id
WHERE r.report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE)
