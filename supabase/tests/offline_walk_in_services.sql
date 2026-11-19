-- Source-only, LOCAL runner after compatibility patch and migration review. All QA rolls back.
begin;
do $$
declare v_owner uuid;v_manager uuid;v_worker uuid;v_worker2 uuid;v_customer uuid;v_branch uuid:=gen_random_uuid();v_foreign uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_intake jsonb;v_consent jsonb;v_req uuid:=gen_random_uuid();v_req2 uuid:=gen_random_uuid();v_close uuid:=gen_random_uuid();v_result jsonb;v_prepared jsonb;v_again jsonb;v_oid uuid;v_iid text;v_invoice public.business_invoices;v_staff uuid[];v_denied boolean;v_before text;v_after text;v_count bigint;v_shift uuid:=gen_random_uuid();v_payment uuid:=gen_random_uuid();v_cancel uuid:=gen_random_uuid();v_first_order uuid;v_first_invoice text;v_rate numeric;v_now timestamp:=clock_timestamp()at time zone'Africa/Cairo';
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_manager from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active limit 1;
 select user_id into strict v_worker2 from public.staff_profiles where role='employee'and is_active and user_id<>v_worker limit 1;
 select id into strict v_customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select array_agg(x order by x)into v_staff from unnest(array[v_worker,v_worker2])x;
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار استقبال فعلي','Offline work QA'),(v_foreign,'فرع آخر','Other work QA');
 update public.business_branch_hours set opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 insert into public.staff_branch_access(user_id,branch_id)values(v_manager,v_branch),(v_worker,v_branch),(v_worker2,v_branch);
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on)values(v_worker,0,15,'EGP',v_now::date-365),(v_worker2,0,25,'EGP',v_now::date-365)on conflict(staff_id)do update set commission_percent=excluded.commission_percent,currency='EGP',starts_on=excluded.starts_on,ends_on=null,updated_at=clock_timestamp();
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_service,v_branch,'service','Actual QA reception service','sedan',120,5,'wash',true,true);
 v_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 select md5(string_agg(x::text,''order by x::text))into v_before from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 assert not has_table_privilege('authenticated','private.offline_walk_in_subjects','SELECT');assert not has_table_privilege('service_role','private.offline_walk_in_commissions','SELECT');
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'QA actual reception','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA OFFLINE1"}',v_consent);
 assert v_intake->>'status'='created_unverified';
 perform set_config('request.jwt.claim.sub',v_customer::text,true);v_denied:=false;begin perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_denied:=false;begin perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,119,v_manager,v_staff);exception when serialization_failure then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_owner,v_staff);exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Selected cashier must own intake receipt';
 v_prepared:=public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);
 assert v_prepared->>'status'='prepared'and not(v_prepared?'financial_snapshot')and not(v_prepared->'payload'?'lines');
 assert public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff)=v_prepared;
 v_denied:=false;begin perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff,'Changed notes');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_worker::text,true);v_denied:=false;begin perform public.place_offline_walk_in(v_req);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_result:=public.place_offline_walk_in(v_req);v_oid:=(v_result->'result'->>'order_id')::uuid;v_iid:=v_result->'result'->>'invoice_id';v_first_order:=v_oid;v_first_invoice:=v_iid;
 assert v_result->>'status'='succeeded'and v_result->'result'->>'work_reference'~'^SH-INV-[0-9]+$';
 assert public.place_offline_walk_in(v_req)=v_result and public.get_offline_walk_in_command(null)=v_result;
 assert v_result->'capabilities' @>'{"auth_customer_subject_supported":false,"walk_in_loyalty_accrual":false,"points_enabled":false,"redemption_enabled":false,"linked_history_visible":false,"work_start_supported":false}';
 execute 'reset role';select * into strict v_invoice from public.business_invoices where invoice_id=v_iid;
 assert v_invoice.total=120 and v_invoice.discount=0 and v_invoice.commission_model='walk_in_frozen_workers'and v_invoice.commission_total=24 and v_invoice.commission_share is null;
 assert exists(select 1 from public.business_orders where order_id=v_oid and booking_id is null and customer_id is null and status='received'and order_number=v_invoice.display_number and assigned_staff_ids=v_staff);
 assert(select count(*)from private.offline_walk_in_commissions where invoice_id=v_iid)=2;
 assert (v_invoice.document_snapshot->>'total')::numeric=120 and v_invoice.document_snapshot->'tax_amount'='null'::jsonb and v_invoice.document_snapshot->>'tax_configuration'='not_recorded_in_legacy_invoice';
 v_denied:=false;begin update public.business_orders set status='in_progress'where order_id=v_oid;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Work start must remain fenced before shared capacity';
 v_denied:=false;begin update public.business_invoices set commission_share=12 where invoice_id=v_iid;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Average share is false';
 v_denied:=false;begin update public.business_orders set assigned_staff_ids=array[v_worker]where order_id=v_oid;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total)values('QA-DUP-'||gen_random_uuid()::text,v_oid,v_branch,'Duplicate',120);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin delete from public.business_order_items where order_id=v_oid;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 update private.hr_employment set commission_percent=50 where staff_id=v_worker;
 assert(select amount from private.offline_walk_in_commissions where invoice_id=v_iid and staff_id=v_worker)=9,'Later rate edited issued earning';
 assert(select commission_total from public.business_invoices where invoice_id=v_iid)=24;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_again:=public.close_offline_walk_in_command(v_req);assert v_again->>'status'='succeeded','Close cannot downgrade actual committed work';perform public.ack_offline_walk_in_command(v_req);assert public.get_offline_walk_in_command(null)->>'status'='absent';
 -- Actual cash ledger reused: one sale and no automatic cancellation/refund.
 perform public.open_cashier_shift(v_shift,v_branch,0);perform public.record_shift_payment(v_payment,v_shift,v_iid,'sale','cash');assert public.record_shift_payment(v_payment,v_shift,v_iid,'sale','cash')=v_payment;
 v_again:=public.get_offline_walk_in_command(v_req);assert v_again->'result'->>'payment_status'='paid'and v_again->'result'->>'invoice_status'='active'and v_again->'result'->>'collectible'='false'and(v_again->'result'->>'collectible_amount')::numeric=0;assert public.place_offline_walk_in(v_req)->'result'->>'payment_status'='paid','Replay must not report original unpaid creation status';
 v_denied:=false;begin perform public.cancel_offline_walk_in(v_cancel,v_oid,'Paid work requires management refund route');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 -- Prepared command closes before a delayed placement. No order can appear later.
 perform set_config('request.jwt.claim.sub',v_owner::text,true);perform public.prepare_offline_walk_in(v_close,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);
 perform set_config('request.jwt.claim.sub',v_manager::text,true);assert public.close_offline_walk_in_command(v_close)->>'status'='closed';
 v_denied:=false;begin perform public.place_offline_walk_in(v_close);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;perform public.ack_offline_walk_in_command(v_close);
 -- An absent close writes a tombstone that fences even a delayed preparation.
 assert public.close_offline_walk_in_command(v_req2)->>'status'='closed';perform public.ack_offline_walk_in_command(v_req2);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v_denied:=false;begin perform public.prepare_offline_walk_in(v_req2,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);exception when insufficient_privilege or invalid_parameter_value then v_denied:=true;end;assert v_denied;
 -- Actual stale employment version rejects issuance; exact command survives for close.
 v_req2:=gen_random_uuid();perform public.prepare_offline_walk_in(v_req2,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);
 execute 'reset role';update private.hr_employment set commission_percent=51,updated_at=clock_timestamp()where staff_id=v_worker;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);v_denied:=false;begin perform public.place_offline_walk_in(v_req2);exception when serialization_failure then v_denied:=true;end;assert v_denied;perform public.close_offline_walk_in_command(v_req2);perform public.ack_offline_walk_in_command(v_req2);
 -- Second real unpaid order cancels atomically; original immutable references persist.
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v_req2:=gen_random_uuid();perform public.prepare_offline_walk_in(v_req2,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);
 perform set_config('request.jwt.claim.sub',v_manager::text,true);v_result:=public.place_offline_walk_in(v_req2);v_oid:=(v_result->'result'->>'order_id')::uuid;v_iid:=v_result->'result'->>'invoice_id';
 v_cancel:=gen_random_uuid();v_result:=public.cancel_offline_walk_in(v_cancel,v_oid,'Customer declined before work or collection');assert v_result->>'work_status'='cancelled'and v_result->>'invoice_status'='void';assert public.cancel_offline_walk_in(v_cancel,v_oid,'Customer declined before work or collection')=v_result;
 v_again:=public.get_offline_walk_in_command(v_req2);assert v_again->'result'->>'work_status'='cancelled'and v_again->'result'->>'invoice_status'='void'and v_again->'result'->>'payment_status'='cancelled'and v_again->'result'->>'collectible'='false';
 execute 'reset role';assert exists(select 1 from public.business_orders where order_id=v_oid and status='cancelled');assert exists(select 1 from public.business_invoices where invoice_id=v_iid and status='void'and commission_share is null);
 perform private.reconcile_loyalty_visit(v_first_order);
 v_denied:=false;begin perform public.finalize_service_loyalty(v_customer,v_first_order,v_first_invoice);exception when raise_exception then v_denied:=true;end;assert v_denied,'Offline order cannot borrow an Auth customer for legacy loyalty';
 v_denied:=false;begin insert into public.business_invoices(invoice_id,branch_id,service_name,total,commission_model,commission_share)values('QA-FORGED-'||gen_random_uuid()::text,v_branch,'Unsupported proof',120,'walk_in_frozen_workers',null);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 assert not exists(select 1 from private.canonical_loyalty_visits where order_id in(v_oid,v_first_order));assert not exists(select 1 from public.business_loyalty_transactions where order_id in(v_oid,v_first_order));
 -- Uniform configured rates retain the real equal scalar, never a fabricated average.
 update private.hr_employment set commission_percent=15,updated_at=clock_timestamp()where staff_id in(v_worker,v_worker2);
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);perform public.ack_offline_walk_in_command(v_req2);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v_req2:=gen_random_uuid();perform public.prepare_offline_walk_in(v_req2,(v_intake->>'request_id')::uuid,v_service,120,v_manager,v_staff);
 -- Owner executes the cashier-bound command; simulate loss of its response and local UUID.
 assert public.get_offline_walk_in_command(null)->>'status'='absent','Preparer alone cannot discover arbitrary cashier commands as own executions';
 v_result:=public.place_offline_walk_in(v_req2);v_iid:=v_result->'result'->>'invoice_id';
 v_again:=public.get_offline_walk_in_command(null);assert v_again->>'request_id'=v_req2::text and v_again->>'executed_by'=v_owner::text and v_again->'result'->>'invoice_id'=v_iid;
 perform public.ack_offline_walk_in_command(v_req2);assert public.get_offline_walk_in_command(null)->>'status'='absent';
 -- Owner acknowledgment releases bound cashier's unresolved command too.
 perform set_config('request.jwt.claim.sub',v_manager::text,true);assert public.get_offline_walk_in_command(null)->>'status'='absent';execute 'reset role';
 assert exists(select 1 from public.business_invoices where invoice_id=v_iid and commission_total=18 and commission_share=9);
 assert exists(select 1 from private.offline_walk_in_commands where request_id=v_req2 and executed_by=v_owner and acknowledged_at is not null);
 -- The original immutable creation receipt still records what was true at creation.
 assert exists(select 1 from private.offline_walk_in_commands where request_id=v_req and result->>'payment_status'='unpaid');
 select md5(string_agg(x::text,''order by x::text))into v_after from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 assert v_before=v_after,'Walk-in created or changed Auth/customer/vehicle/booking/loyalty rows';
 raise notice 'PASS offline received work: exact durable command/fence, actual typed invoice/heterogeneous frozen commissions, cash reuse, work-start fence, unpaid cancel, no Auth/booking/loyalty';
end$$;
rollback;
