-- SOURCE ONLY: root applies migration and executes this rollback fixture serially.
begin;
do $$
declare v_owner uuid;v_cashier uuid;v_customer uuid;v_other uuid;v_branch uuid:=gen_random_uuid();v_intake jsonb;v_intake2 jsonb;v_consent jsonb;v_reg_consent jsonb;v_secret text;v_secret2 text;v_receipt uuid;v_receipt2 uuid;v_claim uuid:=gen_random_uuid();v_lost uuid:=gen_random_uuid();v_decision uuid:=gen_random_uuid();v_revoke uuid:=gen_random_uuid();v_result jsonb;v_retry jsonb;v_wrong jsonb;v_unknown jsonb;v_link uuid;v_denied boolean;v_n integer;v_before text;v_after text;v_pending uuid;v_contact_hash bytea;v_revoked_at timestamptz;v_new_revoke uuid:=gen_random_uuid();
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_cashier from public.staff_profiles where role='employee'and is_active limit 1;
 select c.id into strict v_customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.email is not null and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select c.id into strict v_other from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.email is not null and c.id<>v_customer and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select md5(string_agg(x::text,''order by x::text))into v_before from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.business_invoices t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار الربط','Claim rollback QA');
 v_reg_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 v_consent:=jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en'));
 assert private.offline_claim_digest_matches(extensions.digest('a','sha256'),extensions.digest('a','sha256'));
 assert not private.offline_claim_digest_matches(extensions.digest('a','sha256'),extensions.digest('b','sha256'));
 assert not private.offline_claim_digest_matches(null,extensions.digest('b','sha256'));
 assert not has_table_privilege('authenticated','private.offline_claim_requests','SELECT');
 assert not has_table_privilege('service_role','private.offline_customer_trusted_links','SELECT');
 assert not has_function_privilege('authenticated','private.offline_claim_digest_matches(bytea,bytea)','EXECUTE');
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'Claim original QA','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA CLAIM1"}',v_reg_consent);
 v_intake2:=public.register_offline_customer(gen_random_uuid(),v_branch,'Claim exception QA','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA CLAIM2"}',v_reg_consent);
 v_secret:=v_intake->>'enrollment_secret';v_secret2:=v_intake2->>'enrollment_secret';v_receipt:=(v_intake->>'enrollment_receipt_id')::uuid;v_receipt2:=(v_intake2->>'enrollment_receipt_id')::uuid;
 assert length(v_secret)=64 and length(v_secret2)=64;
 perform set_config('request.jwt.claim.sub',v_customer::text,true);
 v_denied:=false;begin perform public.request_offline_customer_claim(v_claim,v_receipt,v_secret,'original_receipt',v_reg_consent);exception when invalid_parameter_value then v_denied:=true;end;assert v_denied,'Registration consent is not claim consent';
 v_result:=public.request_offline_customer_claim(v_claim,v_receipt,v_secret,'original_receipt',v_consent);
 assert v_result->>'status'='pending_owner_review';
 assert v_result->'capabilities' @> '{"history_visible":false,"wallet_access":false,"guest_redemption":false,"reader_bridge_implemented":false}';
 v_retry:=public.request_offline_customer_claim(v_claim,v_receipt,v_secret,'original_receipt',v_consent);assert v_retry=v_result;
 v_denied:=false;begin perform public.request_offline_customer_claim(v_claim,v_receipt,repeat('0',64),'original_receipt',v_consent);exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 v_wrong:=public.request_offline_customer_claim(gen_random_uuid(),v_receipt,repeat('0',64),'original_receipt',v_consent);
 v_unknown:=public.request_offline_customer_claim(gen_random_uuid(),gen_random_uuid(),repeat('0',64),'original_receipt',v_consent);
 assert v_wrong->>'status'='verification_failed'and v_unknown->>'status'='verification_failed';
 assert not(v_wrong?'profile_id')and not(v_wrong?'email')and not(v_wrong?'enrollment_secret');
 v_denied:=false;begin perform public.list_offline_customer_claim_reviews();exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.decide_offline_customer_claim(v_decision,v_claim,'approve_with_secret','Customer cannot self approve');exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_other::text,true);
 v_result:=public.get_my_offline_customer_claim(v_claim);assert v_result->>'status'='unavailable';
 v_denied:=false;begin perform public.request_offline_customer_claim(v_claim,v_receipt,v_secret,'original_receipt',v_consent);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_cashier::text,true);
 v_denied:=false;begin perform public.decide_offline_customer_claim(v_decision,v_claim,'approve_with_secret','Cashier cannot approve captured secret');exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.list_offline_customer_claim_reviews(v_branch);assert jsonb_array_length(v_result)=1 and v_result->0->>'status'='pending_owner_review';
 assert not(v_result->0?'email')and not(v_result->0?'secret_hash')and not(v_result->0?'phone');
 v_result:=public.decide_offline_customer_claim(v_decision,v_claim,'approve_with_secret','Owner checked original receipt and customer consent');v_link:=(v_result->>'link_id')::uuid;assert v_link is not null and v_result->>'status'='approved_pending_reader_bridge';
 assert public.decide_offline_customer_claim(v_decision,v_claim,'approve_with_secret','Owner checked original receipt and customer consent')=v_result;
 perform set_config('request.jwt.claim.sub',v_customer::text,true);v_result:=public.get_my_offline_customer_claim(v_claim);assert v_result->>'status'='approved_pending_reader_bridge'and v_result->'capabilities'->>'history_visible'='false';
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.revoke_offline_customer_link(v_revoke,v_link,'Customer requested removal of reviewed link');assert v_result->>'status'='revoked';assert public.revoke_offline_customer_link(v_revoke,v_link,'Customer requested removal of reviewed link')=v_result;
 perform set_config('request.jwt.claim.sub',v_customer::text,true);assert public.get_my_offline_customer_claim(v_claim)->>'status'='revoked';
 v_result:=public.request_offline_customer_claim(gen_random_uuid(),v_receipt,v_secret,'original_receipt',v_consent);assert v_result->>'status'='verification_failed','Revocation must not make a consumed secret reusable';
 -- Four actor requests already committed inside this TX; fifth proof fails, sixth is capped.
 perform public.request_offline_customer_claim(gen_random_uuid(),gen_random_uuid(),repeat('0',64),'original_receipt',v_consent);
 v_result:=public.request_offline_customer_claim(gen_random_uuid(),v_receipt2,v_secret2,'original_receipt',v_consent);assert v_result->>'status'='verification_failed','Actor cap failed';
 -- Receipt limit also binds a different confirmed Auth account, not only its actor.
 begin
  for v_n in 1..5 loop perform public.request_offline_customer_claim(gen_random_uuid(),v_receipt2,repeat('0',64),'original_receipt',v_consent);end loop;
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  v_result:=public.request_offline_customer_claim(gen_random_uuid(),v_receipt2,v_secret2,'original_receipt',v_consent);assert v_result->>'status'='verification_failed','Cross-account receipt rate cap failed';
  raise exception 'rollback receipt cap fixture'using errcode='PZ006';
 exception when sqlstate 'PZ006'then null;end;
 -- Lost secret can only reach trusted owner exception, never normal proof approval.
 perform set_config('request.jwt.claim.sub',v_other::text,true);
 v_result:=public.request_offline_customer_claim(v_lost,v_receipt2,null,'lost_secret_review',v_consent);assert v_result->>'status'='pending_owner_review';
 v_unknown:=public.request_offline_customer_claim(gen_random_uuid(),gen_random_uuid(),null,'lost_secret_review',v_consent);assert v_unknown->>'status'=v_result->>'status'and not(v_unknown?'profile_id'),'Lost-secret receipt discovery leaked existence';
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),v_lost,'approve_with_secret','Owner cannot fabricate original receipt proof');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),v_lost,'approve_exception','Same phone is not evidence','same_phone');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 -- Newly appended observed contact invalidates the complete set, not just old UUID.
 execute 'reset role';
 begin
  v_pending:=gen_random_uuid();
  insert into private.offline_claim_requests(request_id,actor_id,receipt_key,profile_id,mode,payload_hash,consent,email_hash,email_confirmed_at,contact_hash,secret_proved,outcome,created_at,expires_at)
  select v_pending,actor_id,receipt_key,profile_id,mode,payload_hash,consent,email_hash,email_confirmed_at,contact_hash,secret_proved,outcome,created_at,clock_timestamp()-interval '1 second'from private.offline_claim_requests where request_id=v_lost;
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_other::text,true);assert public.get_my_offline_customer_claim(v_pending)->>'status'='expired';
  perform set_config('request.jwt.claim.sub',v_owner::text,true);v_denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),v_pending,'approve_exception','Actual service paperwork checked in person','in_person_original_service_documents');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback expired fixture'using errcode='PZ005';
 exception when sqlstate 'PZ005'then null;end;
 v_contact_hash:=private.offline_claim_contact_hash((v_intake2->>'offline_profile_id')::uuid);
 begin
  insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values((v_intake2->>'offline_profile_id')::uuid,'+201099999997','EG');
  assert private.offline_claim_contact_hash((v_intake2->>'offline_profile_id')::uuid)<>v_contact_hash;
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_other::text,true);assert public.get_my_offline_customer_claim(v_lost)->>'status'='stale_identity_review_required';
  perform set_config('request.jwt.claim.sub',v_owner::text,true);v_denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),v_lost,'approve_exception','Actual service paperwork checked in person','in_person_original_service_documents');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback appended contact fixture'using errcode='PZ003';
 exception when sqlstate 'PZ003'then null;end;
 -- Public email_verified/user metadata cannot substitute actual Auth confirmation.
 begin
  update auth.users set email_confirmed_at=null where id=v_other;
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_other::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other,'user_metadata',jsonb_build_object('email_verified',true,'role','owner'))::text,true);
  assert public.get_my_offline_customer_claim(v_lost)->>'status'='stale_identity_review_required';
  perform set_config('request.jwt.claim.sub',v_owner::text,true);v_denied:=false;begin perform public.decide_offline_customer_claim(gen_random_uuid(),v_lost,'approve_exception','Actual service paperwork checked in person','in_person_original_service_documents');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback Auth fixture'using errcode='PZ004';
 exception when sqlstate 'PZ004'then null;end;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.decide_offline_customer_claim(gen_random_uuid(),v_lost,'approve_exception','Actual service paperwork checked in person','in_person_original_service_documents');assert v_result->>'status'='approved_pending_reader_bridge';
 execute 'reset role';
 assert not exists(select 1 from private.offline_claim_requests where consent::text like '%'||v_secret||'%'or encode(payload_hash,'hex')=v_secret);
 assert(select count(*)from private.offline_claim_requests where actor_id=v_customer and created_at>transaction_timestamp()-interval '1 minute')>=6,'Generic failures rolled back rate evidence';
 assert(select count(*)from private.offline_customer_trusted_links where claim_id in(v_claim,v_lost))=2;
 select revoked_at into v_revoked_at from private.offline_customer_trusted_links where link_id=v_link;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.revoke_offline_customer_link(v_new_revoke,v_link,'Owner confirms the already revoked link remains revoked');assert v_result->>'status'='revoked';
 assert public.revoke_offline_customer_link(v_new_revoke,v_link,'Owner confirms the already revoked link remains revoked')=v_result;
 execute 'reset role';
 assert(select revoked_at from private.offline_customer_trusted_links where link_id=v_link)=v_revoked_at,'New revoke nonce changed first revocation time';
 assert exists(select 1 from private.offline_claim_revocations where request_id=v_new_revoke and link_id=v_link),'New revoke nonce lost decision audit';
 v_denied:=false;begin update private.offline_customer_trusted_links set auth_user_id=v_other where link_id=v_link;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin update private.offline_customer_trusted_links set revoked_at=null where link_id=v_link;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin delete from private.offline_customer_trusted_links where link_id=v_link;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;

 select md5(string_agg(x::text,''order by x::text))into v_after from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.business_invoices t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 assert v_before=v_after,'Claim changed existing identity/history/financial rows';
 raise notice 'PASS claim source fixture: proof/consent/isolation, committed generic failures, caps, owner exception, full contact/Auth rechecks, one-use revoke and disabled bridge';
end$$;
rollback;
