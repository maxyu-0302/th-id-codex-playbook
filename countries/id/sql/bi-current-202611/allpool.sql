-- Only small published result tables. No raw ODS/period joins. Current business month (yesterday); do not fall back to an older month.
WITH latest AS(SELECT report_month,MAX(data_as_of) data_as_of FROM dm_tmp.maxyu_id_long_monitor_publish WHERE report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE) GROUP BY report_month),
ready AS(SELECT p.* FROM dm_tmp.maxyu_id_long_monitor_publish p JOIN latest l ON p.report_month=l.report_month AND p.data_as_of=l.data_as_of)
SELECT r.report_month,r.data_as_of,p.published_at,p.config_version,p.config_sha256,
r.`report_date`,r.`stage`,r.`mode`,r.`first_queue`,r.`cases`,r.`od_cny`,r.`arr_cny`,r.`cohort_cash_cny`,r.`paid_cases`,r.`yesterday_cash_cny`,r.`avg_time_onhand`,r.`yesterday_onhand`,r.`arr_pending`,r.`cross_mode_cases`,r.`added_assets`,r.`cohort_cash_rate`,r.`cohort_arr_cash_rate`
FROM dm_tmp.maxyu_id_long_monitor_allpool r JOIN ready p ON r.report_month=p.report_month AND r.data_as_of=p.data_as_of AND r.run_id=p.run_id
WHERE r.report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE)
