WITH clock AS (
 SELECT CAST('__CUT__' AS DATE) AS report_end
 -- 本次锁定截至__CUT__；日常更新时两份SQL同步改为：
 -- CAST('__CUT__' AS DATE)
 -- 两份SQL必须使用同一天；跨月前重核目标、队列、标签、休息日与费率。
), report_params AS (
 SELECT report_end,CAST(DATE_TRUNC('month',report_end) AS DATE) report_month_start,
 DATE_ADD(report_end,INTERVAL 1 DAY) end_exclusive FROM clock
),
q01_params AS (
SELECT report_month_start month_start,end_exclusive FROM report_params
),
q01_fx AS (
SELECT CAST(month_start AS DATE) month_start,CASE WHEN COUNT(DISTINCT cny_per_currency)=1 AND MAX(cny_per_currency)>0 THEN MAX(cny_per_currency) END fx_rate
 FROM dm_aifox.maxyu_manual_fx_rate WHERE country='印尼' AND currency='IDR' AND month_start<'2026-11-01' GROUP BY 1
 UNION ALL SELECT CAST(month AS DATE),CASE WHEN COUNT(DISTINCT exchange_rate)=1 AND MAX(exchange_rate)>0 THEN MAX(exchange_rate) END
 FROM dm_wd_finance.dwb_exchange_rate WHERE country='印尼' AND currency='IDR' AND month='2026-11-01' GROUP BY 1
),
q01_recovery_ranked AS (
SELECT r.id,r.asset_item_number,r.serial_num,r.batch_num, r.mission_log_id, r.repay_date, r.repaid_total_amount,
           ROW_NUMBER() OVER (
               PARTITION BY r.id ORDER BY r.update_at DESC, r.etl_time DESC
           ) AS rn
    FROM fox_ods.ods_fox_collect_recovery r
    CROSS JOIN q01_params p
    WHERE r.repay_date >= p.month_start
      AND r.repay_date < p.end_exclusive
),
q01_recovery AS (
SELECT id,asset_item_number,serial_num,batch_num,repay_date,mission_log_id,DATE(repay_date) AS receipt_date,
           COALESCE(repaid_total_amount, 0) / 100.0 AS receipt_idr
    FROM q01_recovery_ranked
    WHERE rn = 1
),
q01_mission_ids AS (
SELECT DISTINCT mission_log_id FROM q01_recovery
),
q01_mission_keys AS (
SELECT ml.mission_log_id,MAX(ml.debtor_id) debtor_id,
           MIN(ml.assign_debtor_late_days) AS entry_dpd,
           MAX(ml.mission_group_name) AS queue_name,
           COUNT(DISTINCT ml.assign_debtor_late_days) AS dpd_versions,
           COUNT(DISTINCT ml.mission_group_name) AS queue_versions
    FROM fox_ods.ods_fox_mission_log ml
    JOIN q01_mission_ids k ON ml.mission_log_id = k.mission_log_id
    WHERE ml.mission_log_operator = 'assign'
    GROUP BY ml.mission_log_id
),
scq_events AS (
 SELECT r.*,m.debtor_id,MIN(r.repay_date) OVER(PARTITION BY r.asset_item_number,COALESCE(NULLIF(r.serial_num,''),CAST(r.id AS VARCHAR))) repayment_at
 FROM q01_recovery r JOIN q01_mission_keys m ON m.mission_log_id=r.mission_log_id WHERE LOWER(TRIM(m.queue_name))='m2-scq'
), scq_owners AS (
 SELECT a.asset_item_number,MIN(a.debtor_id) debtor_id,COUNT(DISTINCT a.debtor_id) owners
 FROM fox_ods.ods_fox_debtor_asset a JOIN (SELECT DISTINCT debtor_id FROM scq_events) t ON t.debtor_id=a.debtor_id GROUP BY 1
), scq_period0 AS (
 SELECT d.*,o.debtor_id,ROW_NUMBER() OVER(PARTITION BY d.asset_item_no,d.period_seq ORDER BY d.etl_update_time DESC,d.grant_time DESC) rn
 FROM dwb.dwb_asset_period_info d JOIN scq_owners o ON o.asset_item_number=d.asset_item_no
 WHERE d.grant_time<'__END__' AND d.asset_period_create_time<'__END__' AND o.owners=1
), scq_settlement AS (
 SELECT r.asset_item_number,r.repaid_period,MIN(r.repay_date) payoff_at
 FROM fox_ods.ods_fox_asset_period_recovery r JOIN scq_owners o ON o.asset_item_number=r.asset_item_number
 WHERE r.repay_date>='__LOOKBACK__' AND r.repay_date<'__END__' AND r.period_status='payoff' GROUP BY 1,2
), scq_periods AS (
 SELECT d.*,CASE WHEN DATE(d.finish_time)=DATE(r.payoff_at) THEN r.payoff_at ELSE d.finish_time END effective_finish
 FROM scq_period0 d LEFT JOIN scq_settlement r ON r.asset_item_number=d.asset_item_no AND r.repaid_period=d.period_seq WHERE d.rn=1
), scq_dpd AS (
 SELECT e.debtor_id,e.repayment_at,MAX(CASE WHEN d.grant_time<=e.repayment_at AND d.asset_period_create_time<=e.repayment_at
 AND (d.effective_finish IS NULL OR d.effective_finish>=e.repayment_at) THEN DATEDIFF(e.repayment_at,d.due_time) END) dpd
 FROM (SELECT DISTINCT debtor_id,repayment_at FROM scq_events) e LEFT JOIN scq_periods d ON d.debtor_id=e.debtor_id GROUP BY 1,2
), scq_receipt_age AS (
 SELECT e.id,d.dpd FROM scq_events e LEFT JOIN scq_dpd d ON e.debtor_id=d.debtor_id AND e.repayment_at=d.repayment_at
),
q01_labeled AS (
SELECT r.id,r.asset_item_number,r.serial_num,r.batch_num, r.receipt_date, r.receipt_idr,
           m.queue_name, m.entry_dpd,
           CASE WHEN LOWER(TRIM(m.queue_name))='m2-scq' THEN CASE WHEN a.dpd IS NULL THEN '资产账龄缺失' WHEN a.dpd<=60 THEN 'M2' WHEN a.dpd<=90 THEN 'M3' ELSE 'M4-7' END
                WHEN r.receipt_date>='2026-11-01' AND LOWER(TRIM(m.queue_name)) LIKE 'm2-%' THEN 'M2'
                WHEN r.receipt_date>='2026-11-01' AND LOWER(TRIM(m.queue_name)) LIKE 'm3-%' AND LOWER(TRIM(m.queue_name))<>'m33-pure' THEN 'M3'
                WHEN m.entry_dpd BETWEEN 31 AND 60 THEN 'M2'
                WHEN m.entry_dpd BETWEEN 61 AND 90 THEN 'M3'
                WHEN m.entry_dpd BETWEEN 91 AND 210 THEN 'M4-7'
                WHEN m.entry_dpd BETWEEN 211 AND 999 THEN 'M7+'
                ELSE '账龄未匹配' END AS stage,
           CASE WHEN m.queue_versions <> 1 OR m.dpd_versions <> 1 THEN '其他待核验'
                WHEN LOWER(TRIM(m.queue_name)) = 'm2-frz-rel' THEN '纯净'
                WHEN LOWER(TRIM(m.queue_name)) = 'm2-scq' THEN '专催'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%pure%' THEN '纯净'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%ai%' THEN 'AI'
                WHEN LOWER(TRIM(m.queue_name)) IN
                     ('m2-cpu','m2-edn','m3-edn','m3-qin','m4-edn','m4-qin') THEN '委外'
                ELSE '其他待核验' END AS operation_mode,
           CASE WHEN m.mission_log_id IS NULL THEN '未关联分案'
                WHEN m.queue_versions <> 1 OR m.dpd_versions <> 1 THEN '分案归属冲突'
                WHEN LOWER(TRIM(m.queue_name)) LIKE '%cultivate%' THEN 'cultivate不纳入'
                WHEN LOWER(TRIM(m.queue_name)) = 'm2-frz-rel' THEN '冻结组本月不纳入'
                WHEN LOWER(TRIM(m.queue_name))='m33-pure' THEN '扩账龄单列'
                WHEN LOWER(TRIM(m.queue_name))='m2-scq' THEN CASE WHEN a.dpd IS NULL THEN '资产账龄缺失' ELSE '纳入长账' END
                WHEN r.receipt_date>='2026-11-01' AND (LOWER(TRIM(m.queue_name)) LIKE 'm2-%' OR LOWER(TRIM(m.queue_name)) LIKE 'm3-%') THEN '纳入长账'
                WHEN m.entry_dpd NOT BETWEEN 31 AND 999 OR m.entry_dpd IS NULL THEN '非长账或账龄缺失'
                WHEN LOWER(TRIM(m.queue_name)) LIKE 'm2-%'
                  OR LOWER(TRIM(m.queue_name)) LIKE 'm3-%'
                  OR LOWER(TRIM(m.queue_name)) LIKE 'm4-%'
                  OR LOWER(TRIM(m.queue_name)) IN ('m2','m3','m4') THEN '纳入长账'
                ELSE '其他队列不纳入' END AS scope_status
    FROM q01_recovery r
    LEFT JOIN q01_mission_keys m ON r.mission_log_id = m.mission_log_id LEFT JOIN scq_receipt_age a ON a.id=r.id
),
q52_labeled AS (
SELECT * FROM q01_labeled WHERE receipt_date>='2026-11-01'
),
q52_rec_keys AS (
SELECT asset_item_number,receipt_date,serial_num,batch_num,
 MAX(scope_status) scope_status,MAX(stage) stage,MAX(queue_name) queue_name,
 COUNT(DISTINCT CONCAT(scope_status,'|',stage,'|',COALESCE(queue_name,''))) mappings,
 SUM(receipt_idr) source_idr
 FROM q52_labeled GROUP BY asset_item_number,receipt_date,serial_num,batch_num
),
q52_tagged AS (
SELECT asset_item_number,repay_date,repaid_period,bd_tag,SUM(repaid_total_amount) tag_idr,COUNT(*) tag_rows
 FROM dm_wd_decision.dwd_asset_repay_tag_tmp2
 WHERE repay_date BETWEEN (SELECT report_month_start FROM report_params) AND (SELECT report_end FROM report_params) AND bd_tag='__TAG__'
 GROUP BY asset_item_number,repay_date,repaid_period,bd_tag
),
q52_assets AS (
SELECT DISTINCT asset_item_number FROM q52_tagged
),
q52_periods_rank AS (
SELECT p.*,ROW_NUMBER() OVER(PARTITION BY p.id ORDER BY p.update_at DESC,p.etl_time DESC) rn
 FROM fox_ods.ods_fox_asset_period_recovery p JOIN q52_assets a ON p.asset_item_number=a.asset_item_number
 WHERE p.repay_date>=(SELECT report_month_start FROM report_params) AND p.repay_date<(SELECT end_exclusive FROM report_params)
),
q52_period_cash AS (
SELECT p.asset_item_number,DATE(p.repay_date) receipt_date,p.repaid_period,
 SUM(p.repaid_total_amount/100.0) all_idr,
 SUM(CASE WHEN r.scope_status='纳入长账' THEN p.repaid_total_amount/100.0 ELSE 0 END) base_idr,
 SUM(CASE WHEN r.scope_status='纳入长账' AND r.stage='M2' THEN p.repaid_total_amount/100.0 ELSE 0 END) base_m2,
 SUM(CASE WHEN r.scope_status='纳入长账' AND r.stage='M3' THEN p.repaid_total_amount/100.0 ELSE 0 END) base_m3,
 SUM(CASE WHEN r.scope_status='纳入长账' AND r.stage IN ('M4-7','M7+') THEN p.repaid_total_amount/100.0 ELSE 0 END) base_90,
 SUM(CASE WHEN r.scope_status IN ('冻结组本月不纳入','扩账龄单列') THEN p.repaid_total_amount/100.0 ELSE 0 END) frozen_idr,
 SUM(CASE WHEN r.mappings>1 THEN 1 ELSE 0 END) mapping_issues
 FROM q52_periods_rank p LEFT JOIN q52_rec_keys r ON p.asset_item_number=r.asset_item_number AND DATE(p.repay_date)=r.receipt_date
 AND p.serial_num=r.serial_num AND (p.batch_num=r.batch_num OR (p.batch_num IS NULL AND r.batch_num IS NULL))
 WHERE p.rn=1 GROUP BY p.asset_item_number,DATE(p.repay_date),p.repaid_period
),
q52_checked AS (
SELECT t.*,COALESCE(p.all_idr,0) all_idr,COALESCE(p.base_idr,0) base_idr,
 COALESCE(p.base_m2,0) base_m2,COALESCE(p.base_m3,0) base_m3,COALESCE(p.base_90,0) base_90,
 COALESCE(p.frozen_idr,0) frozen_idr,COALESCE(p.mapping_issues,0) mapping_issues
 FROM q52_tagged t LEFT JOIN q52_period_cash p ON t.asset_item_number=p.asset_item_number AND t.repay_date=p.receipt_date AND t.repaid_period=p.repaid_period
),
q52_allocated AS (
 SELECT q52_checked.*,
 CASE WHEN ABS(tag_idr-all_idr)<.01 THEN tag_idr-base_idr-frozen_idr
 WHEN ABS(tag_idr-(all_idr-base_idr-frozen_idr))<.01 THEN tag_idr
 WHEN ABS(all_idr-base_idr-frozen_idr)<.01 AND base_idr+frozen_idr>=tag_idr THEN 0 ELSE NULL END new_idr,
 CASE WHEN ABS(tag_idr-all_idr)<.01 THEN frozen_idr
 WHEN ABS(tag_idr-(all_idr-base_idr-frozen_idr))<.01 THEN 0
 WHEN ABS(all_idr-base_idr-frozen_idr)<.01 AND frozen_idr>=tag_idr THEN tag_idr
 WHEN ABS(all_idr-base_idr-frozen_idr)<.01 AND frozen_idr=0 AND base_idr>=tag_idr THEN 0 ELSE NULL END frozen_overlap
 FROM q52_checked
)
SELECT MD5(CONCAT(asset_item_number,'|',CAST(repay_date AS VARCHAR),'|',CAST(repaid_period AS VARCHAR))) id,
 repay_date cash_date,tag_rows,tag_idr,base_idr,frozen_overlap,new_idr cash_idr,mapping_issues,
 CASE WHEN new_idr IS NULL OR frozen_overlap IS NULL OR new_idr<0 OR mapping_issues<>0 OR asset_item_number IS NULL OR asset_item_number='' OR repaid_period IS NULL THEN 1 ELSE 0 END issue
 FROM q52_allocated ORDER BY repay_date,id
