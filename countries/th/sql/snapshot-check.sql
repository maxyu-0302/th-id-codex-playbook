SELECT pt_date, COUNT(*) AS snapshot_rows, COUNT(DISTINCT id) AS distinct_ids,
    COUNT(DISTINCT indicator_name) AS indicators, MAX(update_at) AS latest_update_at,
    MAX(etl_time) AS latest_etl_time
FROM dm_aifox.ods_fox_debtor_credit_record
WHERE pt_date = CAST(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', '+08:00') AS DATE)
GROUP BY pt_date;
