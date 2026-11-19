-- SOURCE ONLY: no runtime, no new Auth accounts; all existing-row changes roll back.
begin;
create function pg_temp.recovery_review_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
create function pg_temp.reject_review_notice()returns trigger language plpgsql as $$begin raise exception 'Isolated notification failure'using errcode='55000';end$$;
do $$
declare customer uuid;own uuid;manager uuid;actual_claim uuid;consent jsonb;case_ref uuid;new_case uuid;
 more_nonce uuid:=gen_random_uuid();reject_nonce uuid:=gen_random_uuid();close_nonce uuid:=gen_random_uuid();failure_nonce uuid:=gen_random_uuid();stale_nonce uuid:=gen_random_uuid();
 value jsonb;prepared jsonb;receipt jsonb;count_before bigint;links_before bigint;denied boolean;
begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.deleted_at is null
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))
 and exists(select 1 from private.offline_claim_requests claim where claim.actor_id=c.id)order by c.id limit 1;
 select request_id into strict actual_claim from private.offline_claim_requests where actor_id=customer order by created_at desc limit 1;
 select user_id into strict own from public.staff_profiles s where role='owner'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 select user_id into strict manager from public.staff_profiles s where role='manager'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 select count(*)into count_before from private.offline_claim_requests;select count(*)into links_before from private.offline_customer_trusted_links;
 -- Existing placeholder phones may be invalid. Temporary registered value is
 -- fixture-only and restored by the outer rollback, never an Auth/identity bridge.
 update public.customers set phone='010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0')where id=customer;
 consent:=jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',private.visit_recovery_request_notice('en'));
 perform pg_temp.recovery_review_actor(customer);value:=public.submit_visit_recovery_request(gen_random_uuid(),consent);case_ref:=(value#>>'{case,case_id}')::uuid;
 denied:=false;begin perform public.list_visit_recovery_requests();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_review_actor(manager);
 denied:=false;begin perform public.get_visit_recovery_request_for_review(case_ref);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_visit_recovery_review(more_nonce,case_ref,'awaiting_matching','more_info','Actual private review reason');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_review_actor(own);
 value:=public.get_visit_recovery_request_for_review(case_ref);assert length(value#>>'{case,requester_name}')>0 and length(value#>>'{case,registered_phone}')>0;
 assert not(value->'case'?'email')and not(value->'case'?'profile_id')and value->>'approval_available'='false';
 value:=public.list_visit_recovery_requests('awaiting_matching',null,null,1);assert jsonb_array_length(value->'items')=1;
 denied:=false;begin perform public.list_visit_recovery_requests(null,null,null,51);exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_visit_recovery_review(gen_random_uuid(),case_ref,'awaiting_matching','approve','No fake approval permitted');exception when invalid_parameter_value then denied:=true;end;assert denied;
 -- Closed-before-prepare permanently fences its nonce without changing the case.
 assert public.close_visit_recovery_review(close_nonce)->>'state'='closed';
 assert public.prepare_visit_recovery_review(close_nonce,case_ref,'awaiting_matching','reject','Exact late rejected review')->>'state'='closed';
 assert public.apply_visit_recovery_review(close_nonce)->>'state'='closed';
 prepared:=public.prepare_visit_recovery_review(more_nonce,case_ref,'awaiting_matching','more_info','Actual private review reason');assert prepared->>'state'='open';
 assert public.prepare_visit_recovery_review(more_nonce,case_ref,'awaiting_matching','more_info','Actual private review reason')=prepared;
 denied:=false;begin perform public.prepare_visit_recovery_review(more_nonce,case_ref,'awaiting_matching','reject','Actual private review reason');exception when invalid_parameter_value then denied:=true;end;assert denied;
 -- Also prepare a competing action: it must fail stale after more-info commits.
 perform public.prepare_visit_recovery_review(stale_nonce,case_ref,'awaiting_matching','reject','Actual competing review reason');
 receipt:=public.apply_visit_recovery_review(more_nonce);assert receipt->>'state'='succeeded'and receipt#>>'{result,case_status}'='more_info';
 assert public.apply_visit_recovery_review(more_nonce)=receipt and public.close_visit_recovery_review(more_nonce)=receipt;
 assert(select count(*)from private.app_inbox_events where source_event_id=more_nonce and source_case_id=case_ref)=1;
 denied:=false;begin perform public.apply_visit_recovery_review(stale_nonce);exception when serialization_failure then denied:=true;end;assert denied;
 perform public.close_visit_recovery_review(stale_nonce);
 perform pg_temp.recovery_review_actor(customer);
 value:=public.submit_visit_recovery_request(gen_random_uuid(),consent);assert value#>>'{case,case_id}'=case_ref::text and value#>>'{case,status}'='more_info';
 assert value->>'status_label_en'='More information needed';assert not(value?'private_reason');
 assert(select count(*)from private.visit_recovery_customer_requests where requester_id=customer and status in('awaiting_matching','more_info'))=1;
 perform pg_temp.recovery_review_actor(own);
 perform public.prepare_visit_recovery_review(failure_nonce,case_ref,'more_info','reject','Actual failure rollback review');
 execute 'create trigger qa_review_notice_failure before insert on private.app_inbox_events for each row when(new.template_code=''recovery_rejected'')execute function pg_temp.reject_review_notice()';
 denied:=false;begin perform public.apply_visit_recovery_review(failure_nonce);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert public.get_visit_recovery_review(failure_nonce)->>'state'='open';
 assert not exists(select 1 from private.visit_recovery_owner_decisions where request_id=failure_nonce);
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case_ref)='more_info';
 execute 'drop trigger qa_review_notice_failure on private.app_inbox_events';
 perform public.close_visit_recovery_review(failure_nonce);
 perform public.prepare_visit_recovery_review(reject_nonce,case_ref,'more_info','reject','Actual final rejection reason');
 receipt:=public.apply_visit_recovery_review(reject_nonce);assert receipt#>>'{result,case_status}'='rejected';
 assert(select count(*)from private.app_inbox_events where source_event_id=reject_nonce)=1;
 perform pg_temp.recovery_review_actor(customer);
 value:=public.submit_visit_recovery_request(gen_random_uuid(),consent);new_case:=(value#>>'{case,case_id}')::uuid;assert new_case<>case_ref;
 -- Reserved mappings have no public writer; test deliberately inserts an actual
 -- same-actor existing canonical claim solely to prove fail-closed case handling.
 insert into private.visit_recovery_case_claims(case_id,claim_id)values(new_case,actual_claim);
 perform pg_temp.recovery_review_actor(own);
 denied:=false;begin perform public.prepare_visit_recovery_review(gen_random_uuid(),new_case,'awaiting_matching','reject','Mapped case cannot bypass claim');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert public.get_visit_recovery_request_for_review(new_case)#>>'{case,reject_available}'='false';
 denied:=false;begin update private.visit_recovery_customer_requests r set status='linked'where r.case_id=new_case;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 denied:=false;begin update private.visit_recovery_customer_requests r set phone_hash=extensions.digest('altered','sha256')where r.case_id=new_case;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert(select count(*)from private.offline_claim_requests)=count_before;assert(select count(*)from private.offline_customer_trusted_links)=links_before;
 assert not has_table_privilege('authenticated','private.visit_recovery_owner_decisions','INSERT');
 assert not has_table_privilege('authenticated','private.visit_recovery_case_claims','INSERT');
 raise notice 'PASS source-only owner review rollback fixture';
end$$;
rollback;
