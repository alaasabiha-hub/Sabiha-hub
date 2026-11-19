-- Source-only acceptance for root's local runner. Every fixture rolls back.
begin;
do $$
<<qa>>
declare own uuid;cashier uuid;employee uuid;customer uuid;br uuid:=gen_random_uuid();foreign_br uuid:=gen_random_uuid();req uuid:=gen_random_uuid();receipt jsonb;retry jsonb;recovered jsonb;reused jsonb;review jsonb;separate jsonb;
 car jsonb:='{"plate_number":"س ص ع ١٢٣٤","brand":"Actual QA","model":"Intake","year":2020}';consent jsonb;phone text:='+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0');denied boolean;private_count bigint;secret_value text;legacy_hash text;unchanged_hash text;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict cashier from public.staff_profiles where role='employee'and is_active limit 1;
 select user_id into employee from public.staff_profiles where role='employee'and is_active and user_id<>cashier limit 1;
 select c.id into strict customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id) limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en) values(br,'اختبار سجل الاستقبال','Private intake QA'),(foreign_br,'فرع آخر','Other intake QA');
 insert into public.staff_branch_access(user_id,branch_id)values(cashier,br);
 update public.staff_profiles set permissions=permissions||'{"cashier":true}'::jsonb where user_id=cashier;
 consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','text',private.offline_registration_notice('en'),'language','en');
 assert private.offline_phone_key('٠١٠ ٠٠٠٠ ٠٠٠١','EG')='+201000000001';
 assert private.offline_phone_key('+٢٠ (١٠٠) ٠٠٠-٠٠٠١','EG')='+201000000001';
 assert private.offline_phone_key('0020 1000000001','EG')='+201000000001';
 assert private.offline_phone_key('02 1234 5678','EG')='+20212345678';
 assert private.offline_phone_key('01000000001','')is null;
 assert private.offline_phone_key('not a phone','EG')is null and private.offline_phone_key('+00012345','EG')is null;
 assert not has_table_privilege('authenticated','private.offline_customer_profiles','SELECT');
 assert not has_table_privilege('service_role','private.offline_customer_enrollment_receipts','SELECT');
 assert not has_function_privilege('authenticated','private.offline_registration_notice(text)','EXECUTE');
 select md5(string_agg(x::text,''order by x::text))into unchanged_hash from(
 select to_jsonb(t)x from public.customers t union all select to_jsonb(t)from auth.users t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_invoices t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 execute 'set local role anon';denied:=false;begin perform public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent);exception when insufficient_privilege then denied:=true;end;assert denied;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'user_metadata',jsonb_build_object('role','owner','cashier',true))::text,true);
 denied:=false;begin perform public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent);exception when insufficient_privilege then denied:=true;end;assert denied,'Editable metadata granted cashier authority';
 perform set_config('request.jwt.claim.sub',cashier::text,true);
 denied:=false;begin perform public.register_offline_customer(req,foreign_br,'Actual customer',phone,'EG',car,consent);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent||'{"accepted":false}');exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent||'{"text":"Other unapproved notice"}');exception when invalid_parameter_value then denied:=true;end;assert denied;
 receipt:=public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent);
 assert receipt->>'status'='created_unverified' and receipt->>'identity_verified'='false';
 secret_value:=receipt->>'enrollment_secret';assert length(secret_value)=64,'First receipt must have a 32-byte random secret';
 retry:=public.register_offline_customer(req,br,'Actual customer',phone,'EG',car,consent);recovered:=public.get_offline_customer_registration(req);
 assert (receipt-'enrollment_secret')=(retry-'enrollment_secret') and retry=recovered;
 assert retry->'enrollment_secret'='null'::jsonb and retry->>'enrollment_receipt_status'='issued_not_recoverable';
 assert retry->'capabilities' @> '{"offline_registration":true,"phone_verification":false,"guest_redemption":false,"auth_linking":false,"walk_in_loyalty_accrual":false}';
 reused:=public.register_offline_customer(gen_random_uuid(),br,'Actual customer',phone,'EG',car,consent);
 assert reused->>'status'='reused_unverified'and reused->>'offline_profile_id'=receipt->>'offline_profile_id'and reused->>'car_ref_id'=receipt->>'car_ref_id'and reused->'enrollment_secret'='null'::jsonb;
 denied:=false;begin perform public.register_offline_customer(req,br,'Changed customer',phone,'EG',car,consent);exception when invalid_parameter_value then denied:=true;end;assert denied;
 review:=public.register_offline_customer(gen_random_uuid(),br,'Different person',phone,'EG',car,consent);
 assert review->>'status'='review_required'and review->'offline_profile_id'='null'::jsonb and review->'car_ref_id'='null'::jsonb and review->'enrollment_secret'='null'::jsonb;
 denied:=false;begin perform public.register_offline_customer(gen_random_uuid(),br,'Different person',phone,'EG',car,consent,'create_separate','Distinct person shares contact');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform set_config('request.jwt.claim.sub',own::text,true);denied:=false;begin perform public.get_offline_customer_registration(req);exception when insufficient_privilege then denied:=true;end;assert denied,'Another actor read private intake receipt';
 separate:=public.register_offline_customer(gen_random_uuid(),br,'Different person',phone,'EG',car,consent,'create_separate','Owner reviewed distinct person sharing contact');assert separate->>'status'='created_unverified'and separate->>'offline_profile_id'<>receipt->>'offline_profile_id';
 perform set_config('request.jwt.claim.sub',cashier::text,true);review:=public.register_offline_customer(gen_random_uuid(),br,'Actual customer',phone,'EG',car,consent);assert review->>'status'='review_required','Ambiguous shared phone silently merged';
 recovered:=public.get_offline_customer_registration(gen_random_uuid());assert recovered->>'status'='absent'and recovered->>'definitive_failure'='false';
 execute 'reset role';
 assert(select count(*)from private.offline_customer_profiles where created_branch_id=br)=2;
 assert(select count(*)from private.offline_customer_enrollment_receipts where issued_branch_id=br)=2;
 assert exists(select 1 from private.offline_customer_enrollment_receipts where profile_id=(receipt->>'offline_profile_id')::uuid and secret_hash=extensions.digest(secret_value,'sha256'));
 assert not exists(select 1 from private.offline_customer_registration_requests where payload::text like '%'||secret_value||'%'or result::text like '%'||secret_value||'%');
 assert not exists(select 1 from public.business_audit_log where action='offline_customer_registration'and(after_data::text like '%'||secret_value||'%'));
 denied:=false;begin update private.offline_customer_contacts set verification='verified'where profile_id=(receipt->>'offline_profile_id')::uuid;exception when raise_exception then denied:=true;end;assert denied;
 -- Existing Auth contact collision is a candidate only. A nested rollback removes
 -- the temporary legacy-contact fixture and its private review receipt without deletes.
 begin
  update public.customers set phone='+201099999998'where id=customer;
  select count(*)into private_count from private.offline_customer_profiles;
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',cashier::text,true);
  review:=public.register_offline_customer(gen_random_uuid(),br,'Untrusted legacy match','01099999998','EG',car,consent);execute 'reset role';
  assert review->>'status'='review_required'and review->'offline_profile_id'='null'::jsonb and not(review?'email');
  assert(select count(*)from private.offline_customer_profiles)=private_count;
  raise exception 'Rollback legacy contact fixture'using errcode='PZ002';
 exception when sqlstate 'PZ002'then null;
 end;
 update public.staff_profiles set is_active=false where user_id=cashier;execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',cashier::text,true);
 denied:=false;begin perform public.get_offline_customer_registration(req);exception when insufficient_privilege then denied:=true;end;assert denied,'Inactive staff recovered intake';execute 'reset role';
 select md5(string_agg(x::text,''order by x::text))into legacy_hash from(
 select to_jsonb(t)x from public.customers t union all select to_jsonb(t)from auth.users t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.bookings t union all select to_jsonb(t)from public.business_invoices t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 assert legacy_hash=unchanged_hash,'Intake changed existing Auth/customer/car/business/loyalty rows';
 raise notice 'PASS private intake roles, EG normalization, exact retry, dedupe/review, owner-only separation, one-time hash-only secret, immutable consent and no Auth/finance/identity transfer';
end;$$;
rollback;
