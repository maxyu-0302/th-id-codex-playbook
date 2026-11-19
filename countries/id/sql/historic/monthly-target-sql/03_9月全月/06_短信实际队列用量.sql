WITH raw AS (
 SELECT d.*, CASE WHEN assign_debtor_late_days BETWEEN 31 AND 60 THEN 'M2'
 WHEN assign_debtor_late_days BETWEEN 61 AND 90 THEN 'M3'
 WHEN assign_debtor_late_days BETWEEN 91 AND 210 THEN 'M4-7'
 WHEN assign_debtor_late_days BETWEEN 211 AND 999 THEN 'M7+' END stage
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d
 WHERE pt_date='2026-09-30' AND mission_log_create_date>='2026-09-01' AND mission_log_create_date<'2026-10-01'
 AND assign_debtor_late_days BETWEEN 31 AND 999
 AND (yewuzu IN ('M2','M3','M4') OR LOWER(TRIM(mission_group_name)) LIKE 'm2-%'
 OR LOWER(TRIM(mission_group_name)) LIKE 'm3-%' OR LOWER(TRIM(mission_group_name)) LIKE 'm4-%')
 AND LOWER(TRIM(mission_group_name)) NOT LIKE '%cultivate%'
), intervals AS (
 SELECT DISTINCT stage,debtor_id,mission_group_name,mission_log_create_at,
 LEAST(COALESCE(unassign_create_at,CAST('2026-10-01' AS DATETIME)),CAST('2026-10-01' AS DATETIME)) end_at
 FROM raw
), history AS (
 SELECT id,debtor_id,sms_at,origin_sms_record_id,status,
 ROW_NUMBER() OVER(PARTITION BY id ORDER BY update_at DESC) rn
 FROM dwd.dwd_fox_sms_history
 WHERE sms_at>='2026-09-01' AND sms_at<'2026-10-01' AND status<>3
), attributed AS (
 SELECT h.*,i.stage,i.mission_group_name,ROW_NUMBER() OVER(PARTITION BY h.id ORDER BY i.mission_log_create_at DESC,i.stage DESC,i.mission_group_name) seq
 FROM history h JOIN intervals i ON h.debtor_id=i.debtor_id
 AND h.sms_at>=i.mission_log_create_at AND h.sms_at<i.end_at WHERE h.rn=1
), records AS (
 SELECT sms_record_id,sms_record_ticket,ROW_NUMBER() OVER(PARTITION BY sms_record_id ORDER BY sms_record_update_at DESC) rn
 FROM dwd.dwd_fox_sms_record WHERE sms_record_create_at>='2026-08-31' AND sms_record_create_at<'2026-10-02'
), bill_events AS (
 SELECT sms_id,sms_request_id,sms_count,sms_product,sms_status,
 ROW_NUMBER() OVER(PARTITION BY sms_id ORDER BY sms_updated_at DESC,etl_create_time DESC) rn
 FROM dm_aifox.dwd_mkt_sms_sharding WHERE sms_created_at>='2026-08-31' AND sms_created_at<'2026-10-02'
), billing AS (
 SELECT sms_request_id,SUM(sms_count) billed_parts,COUNT(*) bill_events,COUNT(DISTINCT sms_product) products
 FROM bill_events WHERE rn=1 GROUP BY sms_request_id
)
 , links AS (
 SELECT a.*,r.sms_record_ticket,b.sms_request_id,b.billed_parts,b.products,
 ROW_NUMBER() OVER(PARTITION BY COALESCE(CAST(b.sms_request_id AS VARCHAR),CONCAT('missing-',CAST(a.id AS VARCHAR))) ORDER BY a.sms_at,a.id) bill_rn
 FROM attributed a 
 LEFT JOIN records r ON a.origin_sms_record_id=r.sms_record_id AND r.rn=1
 LEFT JOIN billing b ON CAST(r.sms_record_ticket AS VARCHAR)=CAST(b.sms_request_id AS VARCHAR)
 WHERE a.seq=1
 )
SELECT a.stage,a.mission_group_name queue_name,COUNT(*) send_n,
 SUM(CASE WHEN a.sms_request_id IS NULL THEN 1 ELSE 0 END) missing_billing,
 SUM(CASE WHEN bill_rn=1 THEN COALESCE(a.billed_parts,0) ELSE 0 END) billed_parts,
 SUM(CASE WHEN bill_rn=1 THEN COALESCE(a.billed_parts,0) ELSE 0 END)*0.033648 sms_cost_cny,
 COUNT(DISTINCT a.sms_record_ticket) tickets,
 SUM(CASE WHEN a.products>1 THEN 1 ELSE 0 END) multi_product_requests,
 SUM(CASE WHEN bill_rn>1 AND a.sms_request_id IS NOT NULL THEN 1 ELSE 0 END) duplicate_billing_links
FROM links a GROUP BY a.stage,a.mission_group_name ORDER BY a.stage,a.mission_group_name;
