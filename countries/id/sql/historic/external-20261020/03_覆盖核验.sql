-- 印尼StarRocks连接执行，外部报告通过hive.dw_tmp读取。
-- 本轮截至2026-10-20；已实际执行成功，查询ID 318269。
-- 不输出用户证件、手机号或个人明细，仅返回聚合统计。
WITH external_raw AS (
 SELECT 'B1' batch,TRIM(user_uuid) user_uuid,CAST(inquiry_date AS DATE) query_date,status,
 pinjaman_id,refference_id,pinjaman_id_penyelenggara lender,
 CAST(pinjaman_tgl_penyaluran_dana AS DATE) disb_date,
 CAST(pinjaman_tgl_pelaporan_data AS DATE) report_date,
 CAST(REPLACE(pinjaman_sisa_pinjaman_berjalan,',','') AS DECIMAL(24,4)) balance,
 CAST(pinjaman_dpd_terakhir AS DECIMAL(18,4)) dpd,
 CAST(pinjaman_kualitas_pinjaman AS DECIMAL(18,4)) quality,
 UPPER(TRIM(pinjaman_status_pinjaman)) loan_status
 FROM hive.dw_tmp.fdc_union_all_0924_report_data
 UNION ALL
SELECT 'B2' batch,TRIM(user_uuid) user_uuid,CAST(inquiry_date AS DATE) query_date,status,
 pinjaman_id,refference_id,pinjaman_id_penyelenggara lender,
 CAST(pinjaman_tgl_penyaluran_dana AS DATE) disb_date,
 CAST(pinjaman_tgl_pelaporan_data AS DATE) report_date,
 CAST(REPLACE(pinjaman_sisa_pinjaman_berjalan,',','') AS DECIMAL(24,4)) balance,
 CAST(pinjaman_dpd_terakhir AS DECIMAL(18,4)) dpd,
 CAST(pinjaman_kualitas_pinjaman AS DECIMAL(18,4)) quality,
 UPPER(TRIM(pinjaman_status_pinjaman)) loan_status
 FROM hive.dw_tmp.batch2_500w_800w_20260929_report_data
 UNION ALL
SELECT 'B3' batch,TRIM(user_uuid) user_uuid,CAST(inquiry_date AS DATE) query_date,status,
 pinjaman_id,refference_id,pinjaman_id_penyelenggara lender,
 CAST(pinjaman_tgl_penyaluran_dana AS DATE) disb_date,
 CAST(pinjaman_tgl_pelaporan_data AS DATE) report_date,
 CAST(REPLACE(pinjaman_sisa_pinjaman_berjalan,',','') AS DECIMAL(24,4)) balance,
 CAST(pinjaman_dpd_terakhir AS DECIMAL(18,4)) dpd,
 CAST(pinjaman_kualitas_pinjaman AS DECIMAL(18,4)) quality,
 UPPER(TRIM(pinjaman_status_pinjaman)) loan_status
 FROM hive.dw_tmp.batch3_200w_500w_20260929_report_data
), query_times AS (
 SELECT batch,user_uuid,MAX(COALESCE(query_date,CAST('1900-01-01' AS DATE))) query_date
 FROM external_raw WHERE query_date<'2026-10-01' OR query_date IS NULL
 GROUP BY batch,user_uuid
), latest_reports AS (
 SELECT e.*,
 CASE WHEN LOWER(TRIM(e.status))='found' AND e.pinjaman_id IS NOT NULL AND TRIM(e.pinjaman_id) NOT IN ('','null','NULL') THEN 1 ELSE 0 END valid_loan
 FROM external_raw e JOIN query_times q ON e.batch=q.batch AND e.user_uuid=q.user_uuid
 AND COALESCE(e.query_date,CAST('1900-01-01' AS DATE))=q.query_date
), user_batch_features AS (
 SELECT batch,user_uuid,MAX(query_date) query_date,
 COUNT(DISTINCT refference_id) same_day_queries,COUNT(*) report_rows,
 MAX(CASE WHEN query_date IS NOT NULL THEN valid_loan ELSE 0 END) valid_report,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,disb_date) BETWEEN 0 AND 6 THEN 1 ELSE 0 END) loan7,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,disb_date) BETWEEN 0 AND 29 THEN 1 ELSE 0 END) loan30,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 THEN 1 ELSE 0 END) recent_report,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 AND loan_status='O' AND balance>0 AND dpd=0 AND quality=1 THEN 1 ELSE 0 END) normal30,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 AND loan_status='O' AND balance>0 AND dpd>0 THEN 1 ELSE 0 END) overdue30,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 AND loan_status='O' AND balance>0 AND dpd>=90 THEN 1 ELSE 0 END) severe30,
 MAX(CASE WHEN valid_loan=1 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 AND loan_status='W' THEN 1 ELSE 0 END) writeoff30,
 MAX(CASE WHEN valid_loan=1 AND (report_date IS NULL OR (loan_status='O' AND (balance IS NULL OR dpd IS NULL))) THEN 1 ELSE 0 END) bad_fields,
 COUNT(DISTINCT CASE WHEN valid_loan=1 AND loan_status='O' AND balance>0 AND DATEDIFF(query_date,report_date) BETWEEN 0 AND 29 THEN lender END) active_lenders
 FROM latest_reports GROUP BY batch,user_uuid
), user_features_ranked AS (
 SELECT *,COUNT(*) OVER(PARTITION BY user_uuid) batch_overlap,
 ROW_NUMBER() OVER(PARTITION BY user_uuid ORDER BY query_date DESC,batch) rn
 FROM user_batch_features
), user_features AS (
 SELECT * FROM user_features_ranked WHERE rn=1
), mission_raw AS (
 SELECT d.*,MIN(d.mission_log_create_at) OVER(PARTITION BY d.debtor_id) case_entry_at,ROW_NUMBER() OVER(PARTITION BY d.debtor_id,d.mission_log_asset_id,d.overdue_period
 ORDER BY d.mission_log_create_at,d.mission_log_id) asset_rn,
 ROW_NUMBER() OVER(PARTITION BY d.debtor_id ORDER BY d.mission_log_create_at,d.mission_log_id) case_rn
 FROM dm_wd_decision.dwd_mission_log_valid_2_layer d
 WHERE d.pt_date='2026-10-20' AND d.mission_log_create_at>='2026-10-01' AND d.mission_log_create_at<'2026-10-21'
 AND d.assign_debtor_late_days BETWEEN 31 AND 999
 AND (d.yewuzu IN ('M2','M3','M4') OR LOWER(TRIM(d.mission_group_name)) LIKE 'm2-%' OR LOWER(TRIM(d.mission_group_name)) LIKE 'm3-%' OR LOWER(TRIM(d.mission_group_name)) LIKE 'm4-%')
 AND LOWER(TRIM(d.mission_group_name)) NOT LIKE '%cultivate%'
), case_base AS (
 SELECT debtor_id,MIN(mission_log_create_at) first_assign_at,
 MAX(CASE WHEN case_rn=1 THEN mission_group_name END) first_queue,
 MAX(CASE WHEN case_rn=1 THEN assign_debtor_late_days END) first_dpd,
 SUM(CASE WHEN asset_rn=1 THEN assign_principal_amount ELSE 0 END) mtd_principal_idr,
 SUM(CASE WHEN asset_rn=1 AND DATE(mission_log_create_at)=DATE(case_entry_at) THEN assign_principal_amount ELSE 0 END) entry_principal_idr,
 SUM(CASE WHEN asset_rn=1 AND mission_log_create_at<'2026-10-02' THEN assign_principal_amount ELSE 0 END) day1_principal_idr
 FROM mission_raw GROUP BY debtor_id
), recovery_r AS (
 SELECT r.id,r.mission_log_id,r.repay_date,r.repaid_total_amount,
 ROW_NUMBER() OVER(PARTITION BY r.id ORDER BY r.update_at DESC,r.etl_time DESC) rn
 FROM fox_ods.ods_fox_collect_recovery r
 WHERE r.repay_date>='2026-10-01' AND r.repay_date<'2026-10-21'
), recovery_ids AS (
 SELECT DISTINCT mission_log_id FROM recovery_r WHERE rn=1
), recovery_mission AS (
 SELECT m.mission_log_id,MAX(m.debtor_id) debtor_id,
 MIN(m.assign_debtor_late_days) assign_dpd,
 MAX(m.mission_group_name) queue_name,
 COUNT(DISTINCT m.debtor_id) debtors,COUNT(DISTINCT m.mission_group_name) queues
 FROM fox_ods.ods_fox_mission_log m JOIN recovery_ids r ON r.mission_log_id=m.mission_log_id
 WHERE m.mission_log_operator='assign' GROUP BY m.mission_log_id
), recovery AS (
 SELECT m.debtor_id,SUM(r.repaid_total_amount/100.0) receipts_idr,
 SUM(CASE WHEN r.repaid_total_amount>0 THEN r.repaid_total_amount/100.0 ELSE 0 END) positive_receipts_idr,
 SUM(CASE WHEN r.repay_date<DATE_ADD(CAST(c.first_assign_at AS DATE),INTERVAL 7 DAY) THEN r.repaid_total_amount/100.0 ELSE 0 END) receipts7_idr,
 SUM(CASE WHEN r.repay_date<DATE_ADD(CAST(c.first_assign_at AS DATE),INTERVAL 14 DAY) THEN r.repaid_total_amount/100.0 ELSE 0 END) receipts14_idr,
 COUNT(*) receipt_records,
 SUM(CASE WHEN m.debtors<>1 OR m.queues<>1 THEN 1 ELSE 0 END) ambiguous_receipts
 FROM recovery_r r JOIN recovery_mission m ON m.mission_log_id=r.mission_log_id
 JOIN case_base c ON c.debtor_id=m.debtor_id
 WHERE r.rn=1 AND m.assign_dpd BETWEEN 31 AND 999
 AND LOWER(TRIM(m.queue_name)) NOT LIKE '%cultivate%'
 AND r.repay_date>=c.first_assign_at
 GROUP BY m.debtor_id
), sample_mapping_raw AS (
 SELECT 'B1' sample_batch,debtor_id,user_uuid FROM dm_tmp.debtor_m2plus_onhand_800w_plus
 UNION ALL SELECT 'B2',debtor_id,user_uuid FROM dm_tmp.debtor_m2plus_onhand_500w_800w
 UNION ALL SELECT 'B3',debtor_id,user_uuid FROM dm_tmp.debtor_m2plus_onhand_200w_500w
), sample_mapping AS (
 SELECT debtor_id,CASE WHEN COUNT(DISTINCT user_uuid)=1 THEN MAX(user_uuid) ELSE NULL END user_uuid,
 CASE WHEN COUNT(DISTINCT sample_batch)=1 THEN MAX(sample_batch) ELSE NULL END sample_batch
 FROM sample_mapping_raw GROUP BY debtor_id
), case_features AS (
 SELECT c.debtor_id,CAST(d.user_uuid AS VARCHAR) user_uuid,c.first_assign_at,c.first_queue,c.first_dpd,
 CASE WHEN c.first_dpd<=60 THEN 'M2' WHEN c.first_dpd<=90 THEN 'M3' WHEN c.first_dpd<=210 THEN 'M4-7' ELSE 'M7+' END stage,
 CASE WHEN LOWER(TRIM(c.first_queue))='m2-scq' THEN '专催' WHEN LOWER(c.first_queue) LIKE '%pure%' THEN '纯净' WHEN LOWER(c.first_queue) LIKE '%ai%' THEN 'AI' WHEN LOWER(TRIM(c.first_queue)) IN ('m2-cpu','m2-edn','m3-edn','m3-qin','m4-edn','m4-qin') THEN '委外' ELSE '其他' END mode,
 c.mtd_principal_idr,c.day1_principal_idr,c.entry_principal_idr,
 COALESCE(d.sample_batch,'未匹配三批') batch,f.query_date,COALESCE(f.valid_report,0) valid_report,
 f.loan7,f.loan30,f.normal30,f.overdue30,f.severe30,f.writeoff30,f.recent_report,f.bad_fields,f.active_lenders,
 f.batch_overlap,f.same_day_queries,
 COALESCE(r.receipts_idr,0) receipts_idr,COALESCE(r.positive_receipts_idr,0) positive_receipts_idr,
 COALESCE(r.receipts7_idr,0) receipts7_idr,COALESCE(r.receipts14_idr,0) receipts14_idr,
 COALESCE(r.receipt_records,0) receipt_records,COALESCE(r.ambiguous_receipts,0) ambiguous_receipts
 FROM case_base c LEFT JOIN sample_mapping d ON d.debtor_id=c.debtor_id
 LEFT JOIN user_features_ranked f ON f.user_uuid=CAST(d.user_uuid AS VARCHAR) AND f.batch=d.sample_batch
 LEFT JOIN recovery r ON r.debtor_id=c.debtor_id
)
SELECT batch,stage,mode,
 COUNT(*) cases,COUNT(DISTINCT user_uuid) users,
 SUM(CASE WHEN valid_report=1 THEN 1 ELSE 0 END) valid_cases,
 SUM(CASE WHEN first_assign_at<'2026-10-02' THEN 1 ELSE 0 END) day1_cases,
 SUM(CASE WHEN batch_overlap>1 THEN 1 ELSE 0 END) batch_overlap_cases,
 SUM(CASE WHEN same_day_queries>1 THEN 1 ELSE 0 END) multiple_query_cases,
 SUM(mtd_principal_idr) mtd_principal_idr,SUM(day1_principal_idr) day1_principal_idr,
 SUM(receipts_idr) receipts_idr,SUM(receipt_records) receipt_records,SUM(ambiguous_receipts) ambiguous_receipts,
 MIN(query_date) min_query_date,MAX(query_date) max_query_date
FROM case_features GROUP BY batch,stage,mode ORDER BY batch,stage,mode;
