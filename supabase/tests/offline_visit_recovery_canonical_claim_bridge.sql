-- SOURCE ONLY. Real existing sessions/accounts, legitimate quota; rollback all fixtures.
begin;
create function pg_temp.bridge_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
create function pg_temp.bridge_case(p_customer uuid)returns uuid language plpgsql as $$declare value jsonb;begin
 perform pg_temp.bridge_actor(p_customer);
 value:=public.submit_visit_recovery_request(gen_random_uuid(),jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',private.visit_recovery_request_notice('en')));
 return(value#>>'{case,case_id}')::uuid;
end$$;
create function pg_temp.bridge_claim(p_customer uuid,p_manager uuid,p_branch uuid,p_mode text)returns uuid language plpgsql as $$
declare value jsonb;claim uuid:=gen_random_uuid();begin
 perform pg_temp.bridge_actor(p_manager);
 value:=public.register_offline_customer(gen_random_uuid(),p_branch,'Isolated claim bridge fixture','011'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0'),'EG',
 jsonb_build_object('plate_number','CB'||left(replace(gen_random_uuid()::text,'-',''),10)),
 jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en')));
 assert value->>'status'='created_unverified';
 perform pg_temp.bridge_actor(p_customer);
 perform public.request_offline_customer_claim(claim,(value->>'enrollment_receipt_id')::uuid,case when p_mode='original_receipt'then value->>'enrollment_secret'else null end,p_mode,
 jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en')));
 -- Secrets stay only in this transaction's local memory and are never emitted.
 return claim;
end$$;
create function pg_temp.fail_bridge_approved_notice()returns trigger language plpgsql as $$begin raise exception 'Isolated approved-notice failure'using errcode='55000';end$$;
do $$
declare customer uuid;other_customer uuid;own uuid;manager uuid;br uuid:=gen_random_uuid();case1 uuid;case2 uuid;case3 uuid;case4 uuid;claim1 uuid;claim2 uuid;claim3 uuid;claim4 uuid;unknown_claim uuid;
 attach1 uuid:=gen_random_uuid();attach2 uuid:=gen_random_uuid();approval1 uuid:=gen_random_uuid();approval2 uuid:=gen_random_uuid();revoke1 uuid:=gen_random_uuid();reject4 uuid:=gen_random_uuid();hold1 uuid:=gen_random_uuid();
 value jsonb;before_value jsonb;receipt jsonb;link1 uuid;link2 uuid;link3 uuid;denied boolean;review_nonce uuid:=gen_random_uuid();
begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.deleted_at is null
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))
 and not exists(select 1 from private.offline_customer_trusted_links l where l.auth_user_id=c.id and l.revoked_at is null)
 and(select count(*)from private.offline_claim_requests q where q.actor_id=c.id and q.created_at>clock_timestamp()-interval'1 hour')<=1
 and(select count(*)from private.offline_claim_requests q where q.actor_id=c.id and q.created_at>clock_timestamp()-interval'1 day')<=16 order by c.id limit 1;
 select c.id into strict other_customer from public.customers c join auth.users u on u.id=c.id where c.id<>customer and u.email_confirmed_at is not null and u.deleted_at is null
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))
 and not exists(select 1 from private.offline_customer_trusted_links l where l.auth_user_id=c.id and l.revoked_at is null)
 and(select count(*)from private.offline_claim_requests q where q.actor_id=c.id and q.created_at>clock_timestamp()-interval'1 hour')<=4
 and(select count(*)from private.offline_claim_requests q where q.actor_id=c.id and q.created_at>clock_timestamp()-interval'1 day')<=19 order by c.id limit 1;
 select user_id into strict own from public.staff_profiles s where role='owner'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 select user_id into strict manager from public.staff_profiles s where role='manager'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 -- Registered Auth-customer phone deliberately differs from all legacy profile
 -- phones below: phone equality is NOT the approval/proof criterion.
 update public.customers set phone='010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0')where id in(customer,other_customer);
 perform pg_temp.bridge_actor(own);
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'Isolated canonical bridge','Isolated canonical bridge');
 insert into public.staff_branch_access(branch_id,user_id)values(br,manager);
 case1:=pg_temp.bridge_case(customer);case2:=pg_temp.bridge_case(other_customer);
 claim1:=pg_temp.bridge_claim(customer,manager,br,'original_receipt');claim2:=pg_temp.bridge_claim(other_customer,manager,br,'lost_secret_review');
 perform pg_temp.bridge_actor(customer);
 denied:=false;begin perform public.attach_my_visit_recovery_claim(gen_random_uuid(),case1,claim2);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.attach_my_visit_recovery_claim(gen_random_uuid(),case2,claim1);exception when insufficient_privilege then denied:=true;end;assert denied;
 -- Snapshot drift must not be cured by an old canonical claim.
 begin
  update public.customers set phone='012'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0')where id=customer;
  denied:=false;begin perform public.attach_my_visit_recovery_claim(gen_random_uuid(),case1,claim1);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
  raise exception 'Restore temporary phone drift'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 value:=public.attach_my_visit_recovery_claim(attach1,case1,claim1);assert value#>>'{case,status}'='awaiting_matching';
 assert not(value?'canonical_claim_attached')and not(value?'profile_id')and not(value?'canonical_claim_reference');
 assert public.attach_my_visit_recovery_claim(attach1,case1,claim1)=value;
 assert exists(select 1 from private.visit_recovery_case_claims m where m.case_id=case1 and m.claim_id=claim1);
 perform pg_temp.bridge_actor(own);
 -- Existing direct HOLD writer projects and notifies atomically exactly once.
 receipt:=public.decide_offline_customer_claim(hold1,claim1,'hold','Actual request needs independent review');
 assert public.decide_offline_customer_claim(hold1,claim1,'hold','Actual request needs independent review')=receipt;
 assert(select count(*)from private.visit_recovery_canonical_events where source_request_id=hold1)=1;
 assert(select count(*)from private.app_inbox_events where source_event_id=hold1)=1;
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case1)='more_info';
 denied:=false;begin perform public.prepare_visit_recovery_review(review_nonce,case1,'more_info','reject','Mapped case must use canonical review');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 -- Existing PREPARED approval path: forced notice failure rolls back canonical
 -- link/decision/case/event, leaving the original prepared owner command open.
 perform public.prepare_offline_claim_command(approval1,'decide',jsonb_build_object('p_claim',claim1,'p_decision','approve_with_secret','p_reason','Actual original secret proof approval','p_evidence_type',null));
 execute 'create trigger qa_bridge_notice_failure before insert on private.app_inbox_events for each row when(new.template_code=''recovery_approved'')execute function pg_temp.fail_bridge_approved_notice()';
 denied:=false;begin perform public.decide_offline_customer_claim(approval1,claim1,'approve_with_secret','Actual original secret proof approval');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not exists(select 1 from private.offline_claim_decisions where request_id=approval1);
 assert not exists(select 1 from private.offline_customer_trusted_links where claim_id=claim1);
 assert public.get_offline_customer_claim_command(approval1)->>'state'='open';
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case1)='more_info';
 execute 'drop trigger qa_bridge_notice_failure on private.app_inbox_events';
 value:=public.decide_offline_customer_claim(approval1,claim1,'approve_with_secret','Actual original secret proof approval');link1:=(value->>'link_id')::uuid;
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case1)='linked';
 assert(select count(*)from private.app_inbox_events where source_event_id=approval1)=1;
 assert public.decide_offline_customer_claim(approval1,claim1,'approve_with_secret','Actual original secret proof approval')=value;
 -- Decision BEFORE attach: legacy unmapped writer remains untouched, no guessed event.
 value:=public.decide_offline_customer_claim(approval2,claim2,'approve_exception','Actual independent continuity evidence','in_person_original_service_documents');link2:=(value->>'link_id')::uuid;
 assert not exists(select 1 from private.visit_recovery_canonical_events where claim_id=claim2);
 perform pg_temp.bridge_actor(other_customer);value:=public.attach_my_visit_recovery_claim(attach2,case2,claim2);
 assert value#>>'{case,status}'='linked'and value->>'link_current'='true';
 assert exists(select 1 from private.visit_recovery_canonical_events e where e.source_kind='attach_existing'and e.source_request_id=attach2 and e.decision_request_id=approval2 and e.link_id=link2);
 assert not exists(select 1 from private.visit_recovery_canonical_events where source_request_id=approval2);
 -- Revocation must still work after registered-phone drift; it grants no access.
 update public.customers set phone='012'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0')where id=customer;
 perform pg_temp.bridge_actor(own);perform public.revoke_offline_customer_link(revoke1,link1,'Actual owner revocation after changed details');
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case1)='revoked';
 assert(select count(*)from private.app_inbox_events where source_event_id=revoke1 and template_code='recovery_access_ended')=1;
 perform public.revoke_offline_customer_link(revoke1,link1,'Actual owner revocation after changed details');
 assert(select count(*)from private.visit_recovery_canonical_events where source_request_id=revoke1)=1;
 -- A revoked existing link cannot be imported into a NEW case.
 case3:=pg_temp.bridge_case(customer);
 denied:=false;begin perform public.attach_my_visit_recovery_claim(gen_random_uuid(),case3,claim1);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 -- The global one-to-one map blocks reuse rather than transferring old ownership.
 claim3:=pg_temp.bridge_claim(customer,manager,br,'original_receipt');
 perform pg_temp.bridge_actor(own);value:=public.decide_offline_customer_claim(gen_random_uuid(),claim3,'approve_with_secret','Actual independent existing claim approval');link3:=(value->>'link_id')::uuid;
 perform public.revoke_offline_customer_link(gen_random_uuid(),link3,'Actual revocation before any case attachment');
 perform pg_temp.bridge_actor(customer);before_value:=public.get_my_visit_recovery_request(case3);value:=public.attach_my_visit_recovery_claim(gen_random_uuid(),case3,claim3);
 assert value=before_value and not exists(select 1 from private.visit_recovery_case_claims m where m.case_id=case3);
 claim4:=pg_temp.bridge_claim(customer,manager,br,'original_receipt');
 perform pg_temp.bridge_actor(customer);perform public.attach_my_visit_recovery_claim(gen_random_uuid(),case3,claim4);
 perform pg_temp.bridge_actor(own);perform public.decide_offline_customer_claim(reject4,claim4,'reject','Actual canonical rejection of attached claim');
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case3)='rejected';
 denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),claim4,'approve_with_secret','Rejected proof must not later approve');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not exists(select 1 from private.offline_customer_trusted_links where claim_id=claim4);
 -- Unknown lost-secret shell remains indistinguishable pending/unmapped and
 -- therefore cannot create a stuck approvable mapped claim.
 case4:=pg_temp.bridge_case(customer);unknown_claim:=gen_random_uuid();
 perform public.request_offline_customer_claim(unknown_claim,gen_random_uuid(),null,'lost_secret_review',
 jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en')));
 before_value:=public.get_my_visit_recovery_request(case4);value:=public.attach_my_visit_recovery_claim(gen_random_uuid(),case4,unknown_claim);
 assert value=before_value and not exists(select 1 from private.visit_recovery_case_claims m where m.case_id=case4);
 perform pg_temp.bridge_actor(own);
 perform public.prepare_visit_recovery_review(review_nonce,case4,'awaiting_matching','reject','Unknown receipt still needs independent evidence');
 perform public.apply_visit_recovery_review(review_nonce);
 assert(select r.status from private.visit_recovery_customer_requests r where r.case_id=case4)='rejected';
 denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),unknown_claim,'approve_exception','Unknown receipt cannot be approved','in_person_original_service_documents');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not has_table_privilege('authenticated','private.visit_recovery_case_claims','INSERT');
 assert not has_function_privilege('authenticated','private.emit_visit_recovery_canonical_event(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz)','EXECUTE');
 assert(select count(*)from private.visit_recovery_canonical_events where source_request_id=approval1)=1;
 assert(select count(*)from private.app_inbox_events where source_event_id=approval1)=1;
 assert not exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=unknown_claim);
 raise notice 'PASS source canonical bridge ordering/rollback fixture';
end$$;
rollback;
