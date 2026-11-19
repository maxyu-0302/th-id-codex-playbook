WITH finance_raw AS (
 SELECT t.asset_item_number,t.repay_date dt,t.repaid_period,t.target_age_period_2 age,t.target_mission_group_name queue,
 COALESCE(t.bd_tag,'') bd_tag,COALESCE(t.target_group_name,'') target_group,
 COALESCE(t.repaid_total_amount,0) idr,
 CASE WHEN t.target_age_period_2 IN ('D31-60','D61-90','D90+') AND t.target_mission_group_name NOT LIKE '%CC%'
    AND t.target_mission_group_name NOT LIKE '%cultivate%'
    AND t.target_mission_group_name NOT LIKE '%©мн╛%' THEN 1 ELSE 0 END in_scope
 FROM dm_wd_decision.dwd_asset_repay_tag_tmp2 t WHERE t.repay_date>='__START__' AND t.repay_date<'__END__'
),
fin AS (SELECT * FROM finance_raw WHERE in_scope=1) SELECT COUNT(*) rows_n,SUM(idr) finance_idr FROM fin
