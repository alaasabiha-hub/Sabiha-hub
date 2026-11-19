-- SOURCE ONLY; helpers for genuine original-receipt link + actual earning fixture.
create function pg_temp.record_actual_reward_assent(p_customer uuid,p_proposal uuid)returns uuid language plpgsql as $$
declare v_claims text:=current_setting('request.jwt.claims',true);v_sub text:=current_setting('request.jwt.claim.sub',true);v_session uuid;v_view jsonb;v_nonce uuid:=gen_random_uuid();v_consent jsonb;
begin
 select id into strict v_session from auth.sessions where user_id=p_customer and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_customer,'session_id',v_session)::text,true);perform set_config('request.jwt.claim.sub',p_customer::text,true);
 execute 'set local role authenticated';v_view:=public.get_my_offline_reward_financial_proposal(p_proposal);assert v_view->>'state'='proposal';
 v_consent:=jsonb_build_object('accepted',true,'version','offline-reward-financial-v1','language','ar','text',v_view#>>'{consent,notice_ar}');
 assert public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent)->>'state'='consent_recorded';execute 'reset role';
 perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);return v_nonce;
end$$;
create function pg_temp.make_actual_offline_source(p_registration uuid,p_service uuid,p_worker uuid,p_shift uuid,p_reconcile boolean default true)returns jsonb language plpgsql as $$
declare v_nonce uuid:=gen_random_uuid();v_result jsonb;v_order uuid;v_invoice text;v_stage text;v_work uuid;v_earning uuid;
begin
 execute 'set local role authenticated';perform public.prepare_offline_walk_in(v_nonce,p_registration,p_service,120,auth.uid(),array[p_worker]);
 v_result:=public.place_offline_walk_in(v_nonce);perform public.ack_offline_walk_in_command(v_nonce);v_order:=(v_result#>>'{result,order_id}')::uuid;v_invoice:=v_result#>>'{result,invoice_id}';
 perform public.record_shift_payment(gen_random_uuid(),p_shift,v_invoice,'sale','cash');
 foreach v_stage in array array['in_progress','quality_check','completed']loop v_work:=gen_random_uuid();
 perform public.prepare_service_work(v_work,v_order,case v_stage when'in_progress'then'received'when'quality_check'then'in_progress'else'quality_check'end,v_stage,'QA genuine issuer source work');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);end loop;execute 'reset role';
 if p_reconcile then assert private.reconcile_loyalty_visit(v_order)='earned';select id into strict v_earning from private.canonical_loyalty_visits where order_id=v_order and kind='earn';end if;
 return jsonb_build_object('order_id',v_order,'invoice_id',v_invoice,'earning_id',v_earning);
end$$;

create function pg_temp.issue_actual_offline_reward(p_profile uuid,p_car uuid,p_channel uuid,p_registration uuid,p_worker uuid,p_customer uuid,p_shift uuid)returns jsonb language plpgsql as $$
declare v_hold uuid:=gen_random_uuid();v_preparation uuid:=gen_random_uuid();v_proposal uuid:=gen_random_uuid();v_consent uuid;v_issue uuid:=gen_random_uuid();v_closed uuid:=gen_random_uuid();v_quote jsonb;v_result jsonb;v_again jsonb;v_invoice public.business_invoices;v_coverage jsonb;v_denied boolean;v_before bigint;v_commission numeric;v_share numeric;v_rates integer;v_customer_claims text;v_claims text:=current_setting('request.jwt.claims',true);v_sub text:=current_setting('request.jwt.claim.sub',true);v_source_ids uuid[];v_withdraw uuid:=gen_random_uuid();v_withdraw_result jsonb;
begin
 v_quote:=private.reserve_offline_reward_candidates(v_hold,p_profile,p_car,p_channel,120);
 perform private.prepare_offline_reward_consumption(v_preparation,v_hold,v_quote->>'fingerprint');
 perform private.propose_offline_reward_financial_consent(v_proposal,v_preparation);v_consent:=pg_temp.record_actual_reward_assent(p_customer,v_proposal);
 assert private.close_offline_reward_issue(v_closed)->>'state'='closed';
 assert private.prepare_offline_reward_issue(v_closed,v_preparation,v_consent,p_registration,array[p_worker])->>'state'='closed','Unknown issue close fences late prepare';
 v_result:=private.prepare_offline_reward_issue(v_issue,v_preparation,v_consent,p_registration,array[p_worker]);assert v_result->>'state'='prepared';
 v_denied:=false;begin perform private.place_offline_walk_in(v_issue);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Normal cash creator must reject reward-bound command';
 v_result:=private.place_offline_reward_issue(v_issue);assert v_result->>'state'='issued';
 v_again:=private.place_offline_reward_issue(v_issue);assert v_again=v_result,'Exact issuer replay canonical';
 assert private.get_offline_reward_issue(v_issue)=v_result;
 select *into strict v_invoice from public.business_invoices where invoice_id=v_result#>>'{result,invoice_id}';
 assert v_invoice.total=0 and v_invoice.discount=120 and v_invoice.payment_method='reward_coverage'and v_invoice.commission_model='walk_in_frozen_workers';
 assert v_invoice.document_snapshot->>'payment_status'='covered_by_reward'and v_invoice.document_snapshot#>>'{reward_coverage,state}'='covered_by_reward','Initial AFTER INSERT must freeze real covered state';
 assert v_invoice.document_snapshot->'reward'=v_invoice.reward_snapshot;
 assert v_invoice.display_number is not null and position(v_invoice.invoice_id in v_invoice.display_number)=0;
 assert exists(select 1 from public.business_orders where order_id=v_invoice.order_id and customer_id is null and booking_id is null and status='received');
 v_coverage:=private.reward_invoice_coverage(v_invoice.invoice_id);assert v_coverage->>'state'='covered_by_reward'and v_coverage->>'owner_kind'='offline_profile';
 assert not exists(select 1 from public.business_payment_events where invoice_id=v_invoice.invoice_id),'No zero cash/card event';
 assert(private.invoice_payment_quote(v_invoice.invoice_id)->>'collectible')::boolean=false;
 select sum(amount),count(distinct rate_percent),case when count(distinct rate_percent)=1 then min(amount)end into v_commission,v_rates,v_share from private.offline_walk_in_commissions where invoice_id=v_invoice.invoice_id;
 assert v_invoice.commission_total=v_commission and v_invoice.commission_share is not distinct from v_share;
 assert not exists(select 1 from private.offline_walk_in_commissions where invoice_id=v_invoice.invoice_id and(gross<>120 or amount<>round(gross*rate_percent/100/assigned_count,2)));
 select count(*)into v_before from public.business_payment_events;
 v_denied:=false;begin perform private.record_shift_payment(gen_random_uuid(),p_shift,v_invoice.invoice_id,'sale','cash');exception when others then v_denied:=true;end;assert v_denied;
 assert(select count(*)from public.business_payment_events)=v_before;
 assert private.close_offline_reward_issue(v_issue)->>'state'='issued','Close after commit must preserve issuance';
 assert private.get_offline_reward_consumption_preparation(v_preparation)->>'state'='consumed';
 assert private.close_offline_reward_consumption(v_preparation,'Closing cannot undo already issued consumption')->>'state'='consumed';
 v_denied:=false;begin
 perform private.cancel_offline_walk_in(gen_random_uuid(),v_invoice.order_id,'Raw normal cancellation must not bypass reward sync');set constraints all immediate;
 exception when object_not_in_prerequisite_state then v_denied:=true;end;set constraints all deferred;assert v_denied,'Unsynchronized normal cancel must fail deferred coherent receipt';
 assert(select status from public.business_orders where order_id=v_invoice.order_id)='received';
 select jsonb_build_object('sub',p_customer,'session_id',(select id from auth.sessions where user_id=p_customer and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1))::text into v_customer_claims;
 perform set_config('request.jwt.claims',v_customer_claims,true);perform set_config('request.jwt.claim.sub',p_customer::text,true);execute 'set local role authenticated';
 v_withdraw_result:=public.revoke_my_offline_reward_financial_consent(v_withdraw,v_consent);
 assert v_withdraw_result->>'state'='already_issued','Prospective withdrawal cannot change issued invoice';
 assert public.revoke_my_offline_reward_financial_consent(v_withdraw,v_consent)=v_withdraw_result;
 v_denied:=false;begin perform public.revoke_my_offline_reward_financial_consent(v_withdraw,gen_random_uuid());exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;execute 'reset role';
 perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);
 assert not exists(select 1 from private.offline_reward_financial_revocations where consent_request_id=v_consent);
 perform private.ack_offline_reward_issue(v_issue);
 select earning_ids into v_source_ids from private.service_reward_quotes where quote_id=(v_quote->>'quote_id')::uuid;
 set constraints all immediate;set constraints all deferred;
 return(v_result->'result')||jsonb_build_object('issue_request_id',v_issue,'source_earning_ids',v_source_ids,'source_quote_id',v_quote->>'quote_id');
end$$;
