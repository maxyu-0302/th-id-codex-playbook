WITH latest_collect AS (
 SELECT r.id,r.repay_date,r.serial_num,r.asset_item_number,r.batch_num,r.mission_log_id,r.sys_user_id,r.repaid_total_amount,
 ROW_NUMBER() OVER(PARTITION BY r.id ORDER BY r.update_at DESC,r.etl_time DESC) version_no
 FROM fox_ods.ods_fox_collect_recovery r WHERE r.repay_date>='__START__' AND r.repay_date<'__END__'
), receipts AS (
 SELECT * FROM latest_collect WHERE version_no=1
), keys_seen AS (
 SELECT asset_item_number,DATE(repay_date) dt,serial_num,repaid_total_amount,COUNT(*) copies,
 COUNT(DISTINCT NULLIF(batch_num,'')) batches,COUNT(DISTINCT mission_log_id) missions,
 COUNT(DISTINCT COALESCE(sys_user_id,'')) collectors
 FROM receipts WHERE NULLIF(serial_num,'') IS NOT NULL AND repaid_total_amount<>0
 GROUP BY 1,2,3,4 HAVING COUNT(DISTINCT NULLIF(batch_num,''))>1
), ranked AS (
 SELECT r.id,r.mission_log_id,r.asset_item_number,r.serial_num,r.batch_num,r.repay_date,r.repaid_total_amount,k.copies,k.batches,k.missions,k.collectors,
 ROW_NUMBER() OVER(PARTITION BY r.asset_item_number,DATE(r.repay_date),r.serial_num,r.repaid_total_amount ORDER BY r.repay_date,r.id) seq
 FROM receipts r JOIN keys_seen k ON r.asset_item_number=k.asset_item_number AND DATE(r.repay_date)=k.dt AND r.serial_num=k.serial_num AND r.repaid_total_amount=k.repaid_total_amount
), affected_days AS (
 SELECT DISTINCT asset_item_number, DATE(repay_date) dt FROM ranked
), period_versions AS (
 SELECT p.*,ROW_NUMBER() OVER(PARTITION BY p.id ORDER BY p.update_at DESC,p.etl_time DESC) version_no
 FROM fox_ods.ods_fox_asset_period_recovery p JOIN affected_days a ON p.asset_item_number=a.asset_item_number AND DATE(p.repay_date)=a.dt
 WHERE p.repay_date>='__START__' AND p.repay_date<'__END__'
), period_keys AS (
 SELECT asset_item_number,DATE(repay_date) dt,repaid_period,serial_num,repaid_total_amount,
 COUNT(*) records_n,COUNT(DISTINCT NULLIF(batch_num,'')) batches
 FROM period_versions WHERE version_no=1 AND repaid_total_amount<>0 GROUP BY 1,2,3,4,5
), amounts AS (
 SELECT asset_item_number,dt,repaid_period,SUM(repaid_total_amount*records_n)/100.0 raw_idr,
 SUM(repaid_total_amount*CASE WHEN NULLIF(serial_num,'') IS NOT NULL AND records_n=2 AND batches=2 THEN 1 ELSE records_n END)/100.0 corrected_idr
 FROM period_keys GROUP BY 1,2,3
), finance AS (
 SELECT t.asset_item_number,t.repay_date dt,t.repaid_period,SUM(t.repaid_total_amount) idr
 FROM dm_wd_decision.dwd_asset_repay_tag_tmp2 t JOIN affected_days a ON t.asset_item_number=a.asset_item_number AND t.repay_date=a.dt
 WHERE t.repay_date>='__START__' AND t.repay_date<'__END__' GROUP BY 1,2,3
), control AS (
 SELECT COALESCE(p.asset_item_number,f.asset_item_number) asset_item_number, COALESCE(p.dt,f.dt) dt,
 SUM(CASE WHEN ABS(COALESCE(p.corrected_idr,0)-COALESCE(f.idr,0))>.011 THEN 1 ELSE 0 END) mismatch,
 SUM(COALESCE(p.raw_idr,0)-COALESCE(p.corrected_idr,0)) removed_idr
 FROM amounts p FULL OUTER JOIN finance f ON p.asset_item_number=f.asset_item_number AND p.dt=f.dt AND p.repaid_period=f.repaid_period GROUP BY 1,2
)
, mission AS (
 SELECT m.mission_log_id,MAX(LOWER(TRIM(m.mission_group_name))) queue,COUNT(DISTINCT LOWER(TRIM(m.mission_group_name))) versions
 FROM fox_ods.ods_fox_mission_log m JOIN (SELECT DISTINCT mission_log_id FROM ranked) x ON x.mission_log_id=m.mission_log_id
 WHERE m.mission_log_operator='assign' GROUP BY 1
), scoped AS (
 SELECT r.*,m.queue,m.versions,MAX(CASE WHEN (m.queue LIKE 'm2-%' OR m.queue LIKE 'm3-%' OR m.queue LIKE 'm4-%') AND m.queue NOT LIKE '%cultivate%' THEN 1 ELSE 0 END)
 OVER(PARTITION BY r.asset_item_number,DATE(r.repay_date),r.serial_num,r.repaid_total_amount) in_scope
 FROM ranked r LEFT JOIN mission m ON m.mission_log_id=r.mission_log_id
)
SELECT r.id,r.repaid_total_amount/100.0 idr,DATE(r.repay_date) cash_date,MD5(r.asset_item_number) asset_key,r.copies,r.batches,r.missions,r.collectors,
 r.queue,r.versions,c.mismatch,c.removed_idr
FROM scoped r LEFT JOIN control c ON r.asset_item_number=c.asset_item_number AND DATE(r.repay_date)=c.dt WHERE r.seq>1 AND r.in_scope=1
