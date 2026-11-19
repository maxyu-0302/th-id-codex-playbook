-- Only small published result tables. No raw ODS/period joins. Current business month (yesterday); do not fall back to an older month.
WITH latest AS(SELECT report_month,MAX(data_as_of) data_as_of FROM dm_tmp.maxyu_id_long_monitor_publish WHERE report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE) GROUP BY report_month),
ready AS(SELECT p.* FROM dm_tmp.maxyu_id_long_monitor_publish p JOIN latest l ON p.report_month=l.report_month AND p.data_as_of=l.data_as_of)
SELECT r.report_month,r.data_as_of,p.published_at,p.config_version,p.config_sha256,
r.`stat_date`,r.`day_index`,r.`stage`,r.`mode`,r.`is_workday`,r.`is_observed`,r.`baseline_day_target_cny`,r.`uplift_day_target_cny`,r.`cash_day_cny`,r.`baseline_mtd_target_cny`,r.`uplift_mtd_target_cny`,r.`mtd_cash_cny`,r.`baseline_pace_attainment`,r.`uplift_pace_attainment`,r.`uplift_pace_gap_cny`
FROM dm_tmp.maxyu_id_long_monitor_daytargets r JOIN ready p ON r.report_month=p.report_month AND r.data_as_of=p.data_as_of AND r.run_id=p.run_id
WHERE r.report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE)
