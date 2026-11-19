-- Only small published result tables. No raw ODS/period joins. Current business month (yesterday); do not fall back to an older month.
WITH latest AS(SELECT report_month,MAX(data_as_of) data_as_of FROM dm_tmp.maxyu_id_long_monitor_publish WHERE report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE) GROUP BY report_month),
ready AS(SELECT p.* FROM dm_tmp.maxyu_id_long_monitor_publish p JOIN latest l ON p.report_month=l.report_month AND p.data_as_of=l.data_as_of)
SELECT r.report_month,r.data_as_of,p.published_at,p.config_version,p.config_sha256,
r.`source_name`,r.`latest_business_time`,r.`latest_etl_time`,r.`rows_in_window`
FROM dm_tmp.maxyu_id_long_monitor_freshness r JOIN ready p ON r.report_month=p.report_month AND r.data_as_of=p.data_as_of AND r.run_id=p.run_id
WHERE r.report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE)
