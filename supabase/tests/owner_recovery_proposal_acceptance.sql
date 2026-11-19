-- SOURCE ONLY owner proposal / actual-customer acceptance integration; outer rollback.
begin;
create function pg_temp.investigation_actor(p_actor uuid,p_session uuid)returns void language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'session_id',p_session,'user_metadata',jsonb_build_object('role','owner'))::text,true);
end$$;
do $$
declare own uuid;own_session uuid;manager uuid;manager_session uuid;customer uuid;customer_session uuid;br uuid:=gen_random_uuid();case_ref uuid;
 phone_a text:='011'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');phone_b text:='012'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');
 intake_a jsonb;intake_b jsonb;reg_notice text:=private.offline_registration_notice('en');case_notice text:=private.visit_recovery_request_notice('en');profile_a uuid;profile_b uuid;
 query_a uuid:=gen_random_uuid();query_b uuid:=gen_random_uuid();detail_a uuid:=gen_random_uuid();review uuid:=gen_random_uuid();value jsonb;replay jsonb;denied boolean;
 proposal uuid:=gen_random_uuid();closed_proposal uuid:=gen_random_uuid();closed_accept uuid:=gen_random_uuid();accept_id uuid:=gen_random_uuid();approve_id uuid:=gen_random_uuid();revoke_id uuid:=gen_random_uuid();link_id uuid;
 proposal_consent jsonb;claim_consent jsonb;accepted jsonb;quota_proposal uuid:=gen_random_uuid();quota_accept uuid:=gen_random_uuid();fresh_proposal uuid:=gen_random_uuid();quota_case uuid;quota_query uuid:=gen_random_uuid();quota_before bigint;fill_count integer:=0;copied private.visit_recovery_owner_proposals;
 claims_before bigint;links_before bigint;credits_before bigint;begin
 select s.user_id,a.id into strict own,own_session from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id where s.role='owner'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 select s.user_id,a.id into strict manager,manager_session from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id where s.role='manager'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 -- Dedicated existing LOCAL QA account; never create Auth or reset a quota.
 select c.id,a.id into strict customer,customer_session from public.customers c join auth.users u on u.id=c.id join auth.sessions a on a.user_id=c.id
 where c.full_name like'QA-%'and u.email like'%@example.invalid'and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())
 and(select count(*)from private.offline_claim_requests z where z.actor_id=c.id and z.created_at>clock_timestamp()-interval'1 hour')<4 and(select count(*)from private.offline_claim_requests z where z.actor_id=c.id and z.created_at>clock_timestamp()-interval'1 day')<19 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))order by a.created_at desc limit 1;
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
 perform pg_temp.investigation_actor(own,own_session);execute 'set local role authenticated';
 value:=public.search_visit_recovery_candidates(query_a,case_ref,'QA owner proposal investigation');
 value:=public.prepare_visit_recovery_proposal(proposal,query_a,profile_a,'in_person_original_service_documents','QA actual independent evidence attestation',true);
 assert value->>'state'='open'and value->>'link_created'='false';
 assert public.prepare_visit_recovery_proposal(proposal,query_a,profile_a,'in_person_original_service_documents','QA actual independent evidence attestation',true)=value;
 denied:=false;begin perform public.prepare_visit_recovery_proposal(proposal,query_a,profile_a,'in_person_original_service_documents','QA changed immutable reason',true);exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_visit_recovery_proposal(gen_random_uuid(),query_a,profile_a,'phone_match','QA phone alone must never prove identity',true);exception when invalid_parameter_value then denied:=true;end;assert denied;
 value:=public.close_visit_recovery_proposal(closed_proposal);assert value->>'state'='closed';
 value:=public.prepare_visit_recovery_proposal(closed_proposal,query_a,profile_a,'in_person_original_service_documents','QA exact late prepare permanently fenced',true);assert value->>'state'='closed';
 execute 'reset role';
 -- Synthetic expiry copy tests classification only, without rewriting issued terms.
 select *into copied from private.visit_recovery_owner_proposals where proposal_id=proposal;copied.expires_at:=clock_timestamp()-interval'1 second';assert private.visit_recovery_proposal_state(copied)='expired';
 perform pg_temp.investigation_actor(customer,customer_session);execute 'set local role authenticated';
 value:=public.get_my_visit_recovery_proposal(case_ref);assert value->>'state'='open'and value#>>'{proposal,proposal_id}'=proposal::text;
 assert not(value::text~'(profile_reference|receipt_id|contact_hash|private_reason|QA exact|secret_hash)');
 proposal_consent:=jsonb_build_object('accepted',true,'version',value->>'consent_version','language','en','text',value->>'notice_en');
 claim_consent:=jsonb_build_object('accepted',true,'version',value->>'canonical_consent_version','language','en','text',value->>'canonical_notice_en');
 value:=public.close_my_visit_recovery_acceptance(closed_accept);assert value->>'state'='closed'and value->>'definitive_failure'='true';
 denied:=false;begin perform public.accept_my_visit_recovery_proposal(closed_accept,proposal,proposal_consent,claim_consent);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 denied:=false;begin perform public.accept_my_visit_recovery_proposal(gen_random_uuid(),proposal,proposal_consent||'{"text":"Fake notice"}',claim_consent);exception when invalid_parameter_value then denied:=true;end;assert denied;
 execute 'reset role';
 -- New-contact drift invalidates selection; only NEW test contacts in nested rollback.
 begin insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values(profile_a,'+20212345678','EG');
 denied:=false;begin perform public.accept_my_visit_recovery_proposal(gen_random_uuid(),proposal,proposal_consent,claim_consent);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 raise exception 'Restore isolated contact append'using errcode='P9901';exception when sqlstate'P9901'then null;end;
 begin update public.customers set phone=phone_b where id=customer;
 denied:=false;begin perform public.accept_my_visit_recovery_proposal(gen_random_uuid(),proposal,proposal_consent,claim_consent);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 raise exception 'Restore isolated identity drift'using errcode='P9901';exception when sqlstate'P9901'then null;end;
 perform pg_temp.investigation_actor(manager,manager_session);denied:=false;begin perform public.get_my_visit_recovery_proposal(case_ref);exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.investigation_actor(customer,customer_session);execute 'set local role authenticated';
 accepted:=public.accept_my_visit_recovery_proposal(accept_id,proposal,proposal_consent,claim_consent);assert accepted->>'state'='accepted'and accepted->>'attached'='true'and accepted->>'link_created'='false';
 assert public.accept_my_visit_recovery_proposal(accept_id,proposal,proposal_consent,claim_consent)=accepted;
 assert public.get_my_visit_recovery_acceptance(accept_id)=accepted;assert public.close_my_visit_recovery_acceptance(accept_id)=accepted;
 denied:=false;begin perform public.accept_my_visit_recovery_proposal(gen_random_uuid(),proposal,proposal_consent,claim_consent);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 execute 'reset role';
 assert exists(select 1 from private.offline_claim_requests where request_id=accept_id and actor_id=customer and profile_id=profile_a and mode='lost_secret_review'and not secret_proved);
 assert exists(select 1 from private.visit_recovery_case_claims where case_id=case_ref and claim_id=accept_id);
 assert exists(select 1 from private.visit_recovery_proposal_acceptances acceptance join private.visit_recovery_attachment_requests witness on witness.request_id=acceptance.attachment_id where acceptance.request_id=accept_id and acceptance.actor_id=customer and witness.actor_id=customer and witness.case_id=case_ref and witness.claim_id=accept_id);
 assert(select count(*)from private.offline_claim_requests)=claims_before+1;
 assert(select count(*)from private.offline_customer_trusted_links)=links_before;assert(select count(*)from private.canonical_loyalty_visits)=credits_before;
 -- ONLY existing prepared canonical owner writer creates the actual link.
 perform pg_temp.investigation_actor(own,own_session);execute 'set local role authenticated';
 perform public.prepare_offline_claim_command(approve_id,'decide',jsonb_build_object('p_claim',accept_id,'p_decision','approve_exception','p_reason','QA final independent continuity review','p_evidence_type','in_person_original_service_documents'));
 value:=public.decide_offline_customer_claim(approve_id,accept_id,'approve_exception','QA final independent continuity review','in_person_original_service_documents');link_id:=(value->>'link_id')::uuid;assert link_id is not null;
 value:=public.close_visit_recovery_proposal(proposal);assert value->>'state'='accepted';
 perform public.revoke_offline_customer_link(revoke_id,link_id,'QA canonical owner revocation after proposal');execute 'reset role';
 assert(select status from private.visit_recovery_customer_requests where case_id=case_ref)='revoked';
 assert(select count(*)from private.visit_recovery_canonical_events where case_id=case_ref and new_status='linked')=1;
 assert(select count(*)from private.app_inbox_events where source_event_id=approve_id and template_code='recovery_approved')=1;
 assert(select count(*)from private.visit_recovery_proposal_acceptances where proposal_id=proposal)=1;
 -- Real canonical actor budget, filled ONLY with real ordinary request calls in
 -- this outer rollback. No counter reset/backdating/bypass or Auth change.
 perform pg_temp.investigation_actor(customer,customer_session);execute 'set local role authenticated';
 value:=public.submit_visit_recovery_request(gen_random_uuid(),jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',case_notice));quota_case:=(value#>>'{case,case_id}')::uuid;execute 'reset role';
 perform pg_temp.investigation_actor(own,own_session);execute 'set local role authenticated';
 value:=public.search_visit_recovery_candidates(quota_query,quota_case,'QA independent separate file review','AB12',5);
 perform public.prepare_visit_recovery_proposal(quota_proposal,quota_query,profile_b,'in_person_independent_continuity_witness','QA independent separate file attestation',true,'AB12');execute 'reset role';
 perform pg_temp.investigation_actor(customer,customer_session);execute 'set local role authenticated';
 value:=public.get_my_visit_recovery_proposal(quota_case);
 proposal_consent:=jsonb_build_object('accepted',true,'version',value->>'consent_version','language','en','text',value->>'notice_en');
 claim_consent:=jsonb_build_object('accepted',true,'version',value->>'canonical_consent_version','language','en','text',value->>'canonical_notice_en');execute 'reset role';
 while(select count(*)from private.offline_claim_requests where actor_id=customer and created_at>clock_timestamp()-interval'1 hour')<5 loop
  assert fill_count<5;fill_count:=fill_count+1;perform public.request_offline_customer_claim(gen_random_uuid(),gen_random_uuid(),null,'lost_secret_review',claim_consent);
 end loop;
 select count(*)into quota_before from private.offline_claim_requests where actor_id=customer;
 execute 'set local role authenticated';value:=public.accept_my_visit_recovery_proposal(quota_accept,quota_proposal,proposal_consent,claim_consent);
 assert value->>'state'='review_required'and value->>'attached'='false';assert public.accept_my_visit_recovery_proposal(quota_accept,quota_proposal,proposal_consent,claim_consent)=value;
 value:=public.get_my_visit_recovery_proposal(quota_case);assert value->>'state'='review_required';execute 'reset role';
 assert(select count(*)from private.offline_claim_requests where actor_id=customer)=quota_before+1;
 assert exists(select 1 from private.offline_claim_requests where request_id=quota_accept and outcome='verification_failed'and profile_id is null);
 assert not exists(select 1 from private.visit_recovery_case_claims where case_id=quota_case);
 assert exists(select 1 from private.visit_recovery_proposal_acceptances where request_id=quota_accept and attachment_id is null and result->>'state'='review_required');
 -- The exhausted attempt cannot become a stuck accepted binding. Owner may
 -- prepare a NEW audited proposal for later review; old attempt never reissues.
 perform pg_temp.investigation_actor(own,own_session);execute 'set local role authenticated';
 value:=public.prepare_visit_recovery_proposal(fresh_proposal,quota_query,profile_b,'in_person_independent_continuity_witness','QA new review after recorded failed attempt',true,'AB12');assert value->>'state'='open';
 perform public.close_visit_recovery_proposal(fresh_proposal);execute 'reset role';
 assert not has_table_privilege('authenticated','private.visit_recovery_owner_proposals','SELECT');
 assert not has_function_privilege('anon','public.accept_my_visit_recovery_proposal(uuid,uuid,jsonb,jsonb)','EXECUTE');
 assert not has_function_privilege('service_role','public.prepare_visit_recovery_proposal(uuid,uuid,uuid,text,text,boolean,text)','EXECUTE');
end$$;
rollback;
