-- Only small published result tables. No raw ODS/period joins. Current business month (yesterday); do not fall back to an older month.
WITH latest AS(SELECT report_month,MAX(data_as_of) data_as_of FROM dm_tmp.maxyu_id_long_monitor_publish WHERE report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE) GROUP BY report_month),
ready AS(SELECT p.* FROM dm_tmp.maxyu_id_long_monitor_publish p JOIN latest l ON p.report_month=l.report_month AND p.data_as_of=l.data_as_of)
SELECT r.report_month,r.data_as_of,p.published_at,p.config_version,p.config_sha256,
r.`月份`,r.`日期`,r.`账龄`,r.`首分PK组`,r.`当日新增入组案件量`,r.`当日后补分入资产数`,r.`累计分案量`,r.`当日新增分案金额_人民币`,r.`当日新增分案剩本_人民币`,r.`当日实收_人民币`,r.`累计实收_人民币`,r.`累计分案金额_人民币`,r.`累计分案剩本_人民币`,r.`MTD实收率`,r.`MTD剩本实收率`
FROM dm_tmp.maxyu_id_long_monitor_pkdaily r JOIN ready p ON r.report_month=p.report_month AND r.data_as_of=p.data_as_of AND r.run_id=p.run_id
WHERE r.report_month=CAST(DATE_TRUNC('month',DATE_SUB(CURRENT_DATE(),INTERVAL 1 DAY)) AS DATE)
