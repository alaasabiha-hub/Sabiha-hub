-- Focused new owner command recovery/fence coverage; every fixture rolls back.
begin;
do $$
declare own uuid;customer uuid;other_owner uuid;br uuid:=gen_random_uuid();registration uuid:=gen_random_uuid();receipt jsonb;claim uuid:=gen_random_uuid();prep uuid:=gen_random_uuid();close_first uuid:=gen_random_uuid();close_prepared uuid:=gen_random_uuid();approval uuid:=gen_random_uuid();revocation uuid:=gen_random_uuid();legacy uuid:=gen_random_uuid();ambiguous uuid:=gen_random_uuid();unprepared uuid:=gen_random_uuid();payload jsonb;v jsonb;actual jsonb;link uuid;denied boolean;historical timestamptz:=clock_timestamp()-interval '1 day';
 phone text:='010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');consent jsonb;claim_consent jsonb;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict other_owner from public.staff_profiles where role='manager'and is_active limit 1;
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.deleted_at is null and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'اختبار استعادة مراجعة','Owner command recovery QA');
 consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','text',private.offline_registration_notice('en'),'language','en');
 claim_consent:=jsonb_build_object('accepted',true,'version','offline-claim-v1','text',private.offline_claim_notice('en'),'language','en');
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);
 receipt:=public.register_offline_customer(registration,br,'Owner command QA',phone,'EG',jsonb_build_object('plate_number','QA-CMD-'||left(registration::text,8)),consent);
 perform set_config('request.jwt.claim.sub',customer::text,true);
 perform public.request_offline_customer_claim(claim,(receipt->>'enrollment_receipt_id')::uuid,receipt->>'enrollment_secret','original_receipt',claim_consent);
 -- Authenticated customer + editable owner metadata never grants command access.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'user_metadata',jsonb_build_object('role','owner'))::text,true);
 denied:=false;begin perform public.get_offline_customer_claim_command(prep);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.close_offline_claim_command(prep);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_offline_claim_command(prep,'decide',jsonb_build_object('p_claim',claim,'p_decision','hold','p_reason','Actual owner review reason'));exception when insufficient_privilege then denied:=true;end;assert denied;
 perform set_config('request.jwt.claim.sub',own::text,true);
 payload:=jsonb_build_object('p_claim',claim,'p_decision','hold','p_reason','  Actual owner review reason  ');
 v:=public.get_offline_customer_claim_command(prep);assert v->>'state'='absent'and v->>'definitive_failure'='false';
 v:=public.prepare_offline_claim_command(prep,'decide',payload);assert v->>'state'='open'and v->'payload'->>'p_reason'='Actual owner review reason'and v->'payload'->'p_evidence_type'='null'::jsonb;
 assert public.get_offline_customer_claim_command(prep)=v;
 assert public.prepare_offline_claim_command(prep,'decide',payload)=v;
 denied:=false;begin perform public.prepare_offline_claim_command(prep,'decide',payload||'{"unexpected":"rejected"}');exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_offline_claim_command(prep,'revoke',jsonb_build_object('p_link',gen_random_uuid(),'p_reason','Actual owner review reason'));exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.decide_offline_customer_claim(prep,claim,'reject','Actual owner review reason');exception when invalid_parameter_value then denied:=true;end;assert denied,'Prepared fields silently changed';
 actual:=public.decide_offline_customer_claim(prep,claim,'hold','Actual owner review reason');
 v:=public.get_offline_customer_claim_command(prep);assert v->>'state'='succeeded'and v->'result'=actual;
 assert public.close_offline_claim_command(prep)=v,'Completed action must win close';
 -- Closed absent is a global tombstone across both owner command kinds.
 v:=public.close_offline_claim_command(close_first);assert v->>'state'='closed'and v->'kind'='null'::jsonb and v->'payload'='null'::jsonb;
 assert public.close_offline_claim_command(close_first)=v;
 assert public.prepare_offline_claim_command(close_first,'decide',payload)=v;
 denied:=false;begin perform public.decide_offline_customer_claim(close_first,claim,'hold','Closed owner review reason');exception when sqlstate '55000'then denied:=true;end;assert denied;
 denied:=false;begin perform public.revoke_offline_customer_link(close_first,gen_random_uuid(),'Closed owner review reason');exception when sqlstate '55000'then denied:=true;end;assert denied;
 -- An unprepared legacy-compatible action still records a recoverable receipt.
 perform public.decide_offline_customer_claim(unprepared,claim,'hold','Unprepared compatibility reason');
 v:=public.get_offline_customer_claim_command(unprepared);assert v->>'state'='succeeded'and v->>'kind'='decide';
 -- Actual approval and owner list expose only the actual link, then actual revoke.
 perform public.prepare_offline_claim_command(approval,'decide',jsonb_build_object('p_claim',claim,'p_decision','approve_with_secret','p_reason','Reviewed actual original receipt','p_evidence_type',null));
 actual:=public.decide_offline_customer_claim(approval,claim,'approve_with_secret','Reviewed actual original receipt');link:=(actual->>'link_id')::uuid;assert link is not null;
 assert exists(select 1 from jsonb_array_elements(public.list_offline_customer_claim_reviews(br))x where x->>'claim_id'=claim::text and x->>'link_id'=link::text and x->>'status'='approved_pending_reader_bridge');
 payload:=jsonb_build_object('p_link',link,'p_reason','  Reviewed actual revocation  ');
 perform public.prepare_offline_claim_command(close_prepared,'revoke',payload);
 v:=public.close_offline_claim_command(close_prepared);assert v->>'state'='closed'and v->>'kind'='revoke';
 denied:=false;begin perform public.revoke_offline_customer_link(close_prepared,link,'Reviewed actual revocation');exception when sqlstate '55000'then denied:=true;end;assert denied;
 perform public.prepare_offline_claim_command(revocation,'revoke',payload);
 denied:=false;begin perform public.decide_offline_customer_claim(revocation,claim,'hold','Reviewed actual revocation');exception when invalid_parameter_value then denied:=true;end;assert denied,'Global nonce allowed cross-kind execution';
 actual:=public.revoke_offline_customer_link(revocation,link,'Reviewed actual revocation');
 v:=public.get_offline_customer_claim_command(revocation);assert v->>'state'='succeeded'and v->'result'=actual;
 assert public.close_offline_claim_command(revocation)=v;
 assert exists(select 1 from jsonb_array_elements(public.list_offline_customer_claim_reviews(br))x where x->>'claim_id'=claim::text and x->>'link_id'=link::text and x->>'status'='revoked');
 execute 'reset role';
 assert not has_table_privilege('authenticated','private.offline_claim_owner_commands','SELECT');
 assert not has_function_privilege('anon','public.prepare_offline_claim_command(uuid,text,jsonb)','EXECUTE');
 assert not has_function_privilege('service_role','private.offline_claim_command_snapshot(uuid)','EXECUTE');
 assert (select finished_at from private.offline_claim_owner_commands where request_id=approval)=(select created_at from private.offline_claim_decisions where request_id=approval);
 assert (select finished_at from private.offline_claim_owner_commands where request_id=revocation)=(select created_at from private.offline_claim_revocations where request_id=revocation);
 denied:=false;begin update private.offline_claim_owner_commands set payload='{}'where request_id=prep;exception when sqlstate '55000'then denied:=true;end;assert denied;
 denied:=false;begin delete from private.offline_claim_owner_commands where request_id=close_first;exception when sqlstate '55000'then denied:=true;end;assert denied;
 -- Simulate pre-patch immutable business rows; reconcile metadata, never their time/result.
 insert into private.offline_claim_decisions(request_id,claim_id,owner_id,decision,reason,payload,result,created_at)values(legacy,claim,own,'hold','Historical review reason',jsonb_build_object('claim',claim,'decision','hold','reason','Historical review reason','evidence_type',null),jsonb_build_object('claim_id',claim,'decision','hold','link_id',null,'status','hold','capabilities',private.offline_claim_flags()),historical);
 insert into private.offline_claim_decisions(request_id,claim_id,owner_id,decision,reason,payload,result)select ambiguous,claim,own,'hold','Ambiguous old review reason',d.payload,d.result from private.offline_claim_decisions d where d.request_id=legacy;
 insert into private.offline_claim_revocations(request_id,link_id,owner_id,reason)values(ambiguous,link,own,'Ambiguous old revoke reason');
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);
 v:=public.get_offline_customer_claim_command(legacy);assert v->>'state'='succeeded'and(v->>'finished_at')::timestamptz=historical and(v->>'created_at')::timestamptz>historical;
 v:=public.get_offline_customer_claim_command(ambiguous);assert v->>'state'='manual_review_required'and v->'result'='null'::jsonb;
 assert public.close_offline_claim_command(ambiguous)=v;
 execute 'reset role';
 assert not exists(select 1 from private.offline_claim_owner_commands where request_id=ambiguous),'Ambiguous legacy actions silently reconciled';
 -- A second real active owner cannot recover another owner's payload/receipt.
 update public.staff_profiles set role='owner'where user_id=other_owner;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',other_owner::text,true);
 denied:=false;begin perform public.get_offline_customer_claim_command(prep);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.close_offline_claim_command(prep);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_offline_claim_command(prep,'decide',jsonb_build_object('p_claim',claim,'p_decision','hold','p_reason','Actual owner review reason'));exception when insufficient_privilege then denied:=true;end;assert denied;
 execute 'reset role';
 raise notice 'PASS exact owner command preparation/recovery, global close fencing, actual receipt wins, private owner scope, historical timestamps, link_id and legacy ambiguity';
end$$;
rollback;
