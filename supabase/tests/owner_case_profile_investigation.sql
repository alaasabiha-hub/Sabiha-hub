-- Root-executed focused outer rollback. No persistent identity/role/Auth edits.
begin;
create function pg_temp.investigation_actor(p_actor uuid,p_session uuid)returns void language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'session_id',p_session,'user_metadata',jsonb_build_object('role','owner'))::text,true);
end$$;
do $$
declare own uuid;own_session uuid;manager uuid;manager_session uuid;customer uuid;customer_session uuid;br uuid:=gen_random_uuid();case_ref uuid;
 phone_a text:='011'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');phone_b text:='012'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');
 intake_a jsonb;intake_b jsonb;reg_notice text:=private.offline_registration_notice('en');case_notice text:=private.visit_recovery_request_notice('en');profile_a uuid;profile_b uuid;
 query_a uuid:=gen_random_uuid();query_b uuid:=gen_random_uuid();detail_a uuid:=gen_random_uuid();review uuid:=gen_random_uuid();value jsonb;replay jsonb;denied boolean;
 claims_before bigint;links_before bigint;credits_before bigint;begin
 select s.user_id,a.id into strict own,own_session from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id where s.role='owner'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 select s.user_id,a.id into strict manager,manager_session from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id where s.role='manager'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 -- Dedicated existing LOCAL QA account; never create Auth or reset a quota.
 select c.id,a.id into strict customer,customer_session from public.customers c join auth.users u on u.id=c.id join auth.sessions a on a.user_id=c.id
 where c.full_name like'QA-%'and u.email like'%@example.invalid'and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))order by a.created_at desc limit 1;
 select count(*)into claims_before from private.offline_claim_requests;select count(*)into links_before from private.offline_customer_trusted_links;select count(*)into credits_before from private.canonical_loyalty_visits;
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'QA investigation rollback','QA investigation rollback');insert into public.staff_branch_access(user_id,branch_id)values(manager,br);
 perform pg_temp.investigation_actor(manager,manager_session);execute 'set local role authenticated';
 intake_a:=public.register_offline_customer(gen_random_uuid(),br,'QA exact phone candidate',phone_a,'EG','{"plate_number":"QA PHONE"}',jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',reg_notice));
 intake_b:=public.register_offline_customer(gen_random_uuid(),br,'QA exact plate candidate',phone_b,'EG','{"plate_number":" ab-١٢ "}',jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',reg_notice));execute 'reset role';
 assert intake_a->>'status'='created_unverified'and intake_b->>'status'='created_unverified';profile_a:=(intake_a->>'offline_profile_id')::uuid;profile_b:=(intake_b->>'offline_profile_id')::uuid;
 -- Existing accepted fixture pattern: temporary QA phone in this ROLLBACK only;
 -- actual registration and actual case identity must match. Never commit it.
 update public.customers set phone=phone_a where id=customer;
 perform pg_temp.investigation_actor(customer,customer_session);execute 'set local role authenticated';value:=public.submit_visit_recovery_request(gen_random_uuid(),jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',case_notice));execute 'reset role';case_ref:=(value#>>'{case,case_id}')::uuid;
 denied:=false;begin perform public.search_visit_recovery_candidates(gen_random_uuid(),case_ref,'QA unauthorized customer query');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.investigation_actor(manager,manager_session);denied:=false;begin perform public.search_visit_recovery_candidates(gen_random_uuid(),case_ref,'QA unauthorized manager query');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.investigation_actor(own,null);denied:=false;begin perform public.search_visit_recovery_candidates(gen_random_uuid(),case_ref,'QA missing owner session query');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.investigation_actor(own,own_session);execute 'set local role authenticated';
 value:=public.search_visit_recovery_candidates(query_a,case_ref,'QA independent phone investigation');
 assert value->>'criterion_kind'='registered_phone'and(value->>'candidate_count')::integer=1 and value#>>'{candidates,0,profile_reference}'=profile_a::text;
 assert value#>>'{candidates,0,real_receipt_available}'='true'and value#>>'{candidates,0,candidate_is_identity_proof}'='false';
 assert not(value::text~'(secret_hash|enrollment_secret|email_hash|contact_hash|receipt_key|document_token|balance|visits)');
 replay:=public.search_visit_recovery_candidates(query_a,case_ref,'QA independent phone investigation');assert(replay-'checked_at')=(value-'checked_at');
 denied:=false;begin perform public.search_visit_recovery_candidates(query_a,case_ref,'QA changed immutable purpose');exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.get_visit_recovery_candidate(gen_random_uuid(),query_a,profile_b,'QA unrelated profile must deny');exception when insufficient_privilege then denied:=true;end;assert denied;
 value:=public.get_visit_recovery_candidate(detail_a,query_a,profile_a,'QA actual candidate details');assert value#>>'{candidate,name}'='QA exact phone candidate';
 denied:=false;begin perform public.get_visit_recovery_candidate(detail_a,query_a,profile_a,'QA changed detail purpose');exception when invalid_parameter_value then denied:=true;end;assert denied;
 value:=public.search_visit_recovery_candidates(query_b,case_ref,'QA independent old phone plate evidence',' AB12 ',5);assert(value->>'candidate_count')::integer=1 and value#>>'{candidates,0,profile_reference}'=profile_b::text;
 value:=public.get_visit_recovery_candidate(gen_random_uuid(),query_b,profile_b,'QA same exact normalized plate','ab-١٢');assert value#>>'{candidate,name}'='QA exact plate candidate';
 -- Original recorded plate query cannot authorize a detail under a changed criterion.
 denied:=false;begin perform public.get_visit_recovery_candidate(gen_random_uuid(),query_b,profile_b,'QA wrong criterion must deny','QA PHONE');exception when insufficient_privilege then denied:=true;end;assert denied;
 value:=public.search_visit_recovery_candidates(gen_random_uuid(),case_ref,'QA literal wildcard never broadens','AB%',25);assert(value->>'candidate_count')::integer=0;
 denied:=false;begin perform public.search_visit_recovery_candidates(gen_random_uuid(),case_ref,'QA invalid bound',null,26);exception when invalid_parameter_value then denied:=true;end;assert denied;
 execute 'reset role';assert(select count(*)from private.visit_recovery_investigation_queries where query_id=query_a)=1;assert(select count(*)from private.visit_recovery_investigation_detail_reads where request_id=detail_a)=1;
 -- Identity drift cannot replay cached candidate lists or detail records.
 begin update public.customers set phone=phone_b where id=customer;
 denied:=false;begin perform public.search_visit_recovery_candidates(query_a,case_ref,'QA independent phone investigation');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 denied:=false;begin perform public.get_visit_recovery_candidate(detail_a,query_a,profile_a,'QA actual candidate details');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 raise exception 'Restore nested QA drift'using errcode='P9901';exception when sqlstate'P9901'then null;end;
 execute 'set local role authenticated';perform public.prepare_visit_recovery_review(review,case_ref,'awaiting_matching','reject','QA completed isolated review');perform public.apply_visit_recovery_review(review);execute 'reset role';
 denied:=false;begin perform public.search_visit_recovery_candidates(query_a,case_ref,'QA independent phone investigation');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not has_table_privilege('authenticated','private.visit_recovery_investigation_queries','SELECT');assert not has_table_privilege('authenticated','private.visit_recovery_investigation_detail_reads','INSERT');
 assert not has_function_privilege('anon','public.search_visit_recovery_candidates(uuid,uuid,text,text,integer)','EXECUTE');assert not has_function_privilege('service_role','public.get_visit_recovery_candidate(uuid,uuid,uuid,text,text)','EXECUTE');
 assert(select count(*)from private.offline_claim_requests)=claims_before;assert(select count(*)from private.offline_customer_trusted_links)=links_before;assert(select count(*)from private.canonical_loyalty_visits)=credits_before;
end$$;
rollback;
