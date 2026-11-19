begin;
-- Additive recovery fence. No existing registrations, secrets or historical rows change.
create table private.offline_registration_closed_requests(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),
 branch_id uuid not null references public.business_branches(branch_id),closed_at timestamptz not null default clock_timestamp());
alter table private.offline_registration_closed_requests enable row level security;
revoke all on private.offline_registration_closed_requests from public,anon,authenticated,service_role;
create trigger immutable_offline_registration_close before update or delete on private.offline_registration_closed_requests for each row execute function private.immutable_loyalty_policy();
create or replace function private.register_offline_customer(p_request uuid,p_branch uuid,p_name text,p_phone text,p_country text,p_car jsonb,p_consent jsonb,p_duplicate_action text default null,p_review_reason text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid();v_phone text;v_name text;v_name_key text;v_plate text;v_car jsonb;v_consent jsonb;v_payload jsonb;v_prior private.offline_customer_registration_requests;v_profile private.offline_customer_profiles;v_candidate private.offline_customer_car_refs;
 v_profiles bigint;v_legacy_match boolean;v_pid uuid;v_cid uuid;v_eid uuid;v_secret text;v_outcome text;v_result jsonb;v_owner_separate boolean;v_year integer;v_masked text;v_closed private.offline_registration_closed_requests;
begin
 if v_actor is null or not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Active branch cashier or owner required' using errcode='42501';end if;
 v_phone:=private.offline_phone_key(p_phone,p_country);v_name:=regexp_replace(trim(p_name),'[[:space:]]+',' ','g');v_name_key:=lower(v_name);
 if p_request is null or p_branch is null or v_phone is null or v_name is null or length(v_name) not between 2 and 120 then raise exception 'Actual name, explicit EG phone context and valid phone format required' using errcode='22023';end if;
 if p_car is null or jsonb_typeof(p_car)<>'object' or not p_car?'plate_number' or p_car-array['plate_number','brand','model','year','color']<>'{}'::jsonb or jsonb_typeof(p_car->'plate_number')<>'string' then raise exception 'Actual plate and supported car fields required' using errcode='22023';end if;
 if exists(select 1 from jsonb_each(p_car) f where f.key in('brand','model','color') and jsonb_typeof(f.value)not in('string','null'))then raise exception 'Car details must be actual text or absent' using errcode='22023';end if;
 if length(coalesce(p_car->>'plate_number',''))>40 or length(coalesce(p_car->>'brand',''))>80 or length(coalesce(p_car->>'model',''))>80 or length(coalesce(p_car->>'color',''))>40 then raise exception 'Car details exceed supported length' using errcode='22023';end if;
 v_plate:=upper(regexp_replace(translate(trim(p_car->>'plate_number'),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[[:space:]-]','','g'));
 if length(v_plate)not between 2 and 32 or v_plate ~ '[[:cntrl:]]' then raise exception 'Actual plate required' using errcode='22023';end if;
 if p_car?'year' and p_car->'year'<>'null'::jsonb then
  if jsonb_typeof(p_car->'year')<>'number' or p_car->>'year'!~'^[0-9]{4}$' then raise exception 'Supported car year required' using errcode='22023';end if;
  v_year:=(p_car->>'year')::integer;if v_year not between 1950 and 2100 then raise exception 'Supported car year required' using errcode='22023';end if;
 end if;
 v_car:=jsonb_build_object('plate_number',v_plate,'brand',nullif(lower(trim(p_car->>'brand')),''),'model',nullif(lower(trim(p_car->>'model')),''),'year',v_year,'color',nullif(lower(trim(p_car->>'color')),''));
 if p_consent is null or jsonb_typeof(p_consent)<>'object' or not p_consent?&array['accepted','version','text','language'] or p_consent-array['accepted','version','text','language']<>'{}'::jsonb or p_consent->'accepted' is distinct from 'true'::jsonb or jsonb_typeof(p_consent->'version')<>'string' or jsonb_typeof(p_consent->'text')<>'string' or not coalesce(p_consent->>'language' in('ar','en'),false) or length(trim(coalesce(p_consent->>'version','')))not between 1 and 80 or length(trim(coalesce(p_consent->>'text','')))not between 10 and 4000 then raise exception 'Explicit actual registration consent text, version, language and acceptance required' using errcode='22023';end if;
 if p_consent->>'version'<>'offline-registration-v1' or p_consent->>'text' is distinct from private.offline_registration_notice(p_consent->>'language')then raise exception 'Display and accept the current operational registration notice'using errcode='22023';end if;
 v_consent:=jsonb_build_object('purpose','offline_registration','accepted',true,'version',trim(p_consent->>'version'),'text',trim(p_consent->>'text'),'language',p_consent->>'language');
 v_owner_separate:=p_duplicate_action='create_separate';
 if p_duplicate_action is not null and p_duplicate_action<>'create_separate' or p_duplicate_action is null and p_review_reason is not null then raise exception 'Unsupported duplicate decision' using errcode='22023';end if;
 if coalesce(v_owner_separate,false) and(private.active_staff_role() is distinct from 'owner' or length(trim(coalesce(p_review_reason,'')))not between 10 and 500)then raise exception 'Only an active owner may explicitly create a separate reviewed profile with a reason' using errcode='42501';end if;
 v_payload:=jsonb_build_object('branch',p_branch,'name_key',v_name_key,'phone',v_phone,'country','EG','car',v_car,'consent',v_consent,'duplicate_action',p_duplicate_action,'review_reason',nullif(trim(p_review_reason),''));
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Registration requires READ COMMITTED'using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-registration:'||p_request::text,0));
 select * into v_closed from private.offline_registration_closed_requests where request_id=p_request;
 if found then
  if v_closed.actor_id<>v_actor or v_closed.branch_id<>p_branch then raise exception 'Registration request access denied' using errcode='42501';end if;
  raise exception 'Registration request permanently closed; use a new request only after reviewing the closed result' using errcode='55000';
 end if;
 select * into v_prior from private.offline_customer_registration_requests where request_id=p_request;
 if found then
  if v_prior.actor_id<>v_actor or v_prior.branch_id<>p_branch then raise exception 'Registration receipt access denied' using errcode='42501';end if;
  if v_prior.payload<>v_payload then raise exception 'Registration request payload changed' using errcode='22023';end if;
  return v_prior.result||jsonb_build_object('enrollment_secret',null);
 end if;
 if not exists(select 1 from public.business_branches where branch_id=p_branch and is_active)then raise exception 'Active branch required' using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-phone:'||v_phone,0));
 select count(distinct c.profile_id) into v_profiles from private.offline_customer_contacts c where c.phone_e164=v_phone;
 select exists(select 1 from public.customers c where private.offline_phone_key(c.phone,'EG')=v_phone)into v_legacy_match;
 if v_profiles=1 and not v_legacy_match and not coalesce(v_owner_separate,false)then
  select p.* into v_profile from private.offline_customer_profiles p join private.offline_customer_contacts c on c.profile_id=p.profile_id where c.phone_e164=v_phone;
  select * into v_candidate from private.offline_customer_car_refs c where c.profile_id=v_profile.profile_id and c.plate_key=v_plate;
  if v_profile.created_branch_id=p_branch and v_profile.name_key=v_name_key and v_candidate.car_snapshot=v_car then
   v_pid:=v_profile.profile_id;v_cid:=v_candidate.car_ref_id;v_outcome:='reused_unverified';select receipt_id into v_eid from private.offline_customer_enrollment_receipts where profile_id=v_pid;
  else v_outcome:='review_required';end if;
 elsif (v_profiles>0 or v_legacy_match)and not coalesce(v_owner_separate,false)then v_outcome:='review_required';
 else
  v_pid:=gen_random_uuid();v_cid:=gen_random_uuid();v_eid:=gen_random_uuid();v_secret:=encode(extensions.gen_random_bytes(32),'hex');v_outcome:='created_unverified';
  insert into private.offline_customer_profiles(profile_id,full_name,name_key,created_branch_id,created_by) values(v_pid,v_name,v_name_key,p_branch,v_actor);
  insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values(v_pid,v_phone,'EG');
  insert into private.offline_customer_car_refs(car_ref_id,profile_id,plate_key,car_snapshot)values(v_cid,v_pid,v_plate,v_car);
 end if;
 v_masked:='+'||repeat('*',greatest(length(v_phone)-5,1))||right(v_phone,4);
 v_result:=jsonb_build_object('request_id',p_request,'status',v_outcome,'offline_profile_id',v_pid,'car_ref_id',v_cid,'phone_masked',v_masked,'identity_verified',false,'review_reason_code',case when v_outcome='review_required'then 'contact_review_required' else null end,'enrollment_receipt_id',v_eid,'enrollment_secret_issued',v_eid is not null,'enrollment_secret_recoverable',false,'enrollment_receipt_status',case when v_eid is not null then 'issued_not_recoverable'else 'not_issued'end,'capabilities',private.offline_registration_capabilities());
 insert into private.offline_customer_registration_requests(request_id,actor_id,branch_id,payload,consent,consent_hash,result)values(p_request,v_actor,p_branch,v_payload,v_consent,encode(extensions.digest(v_consent::text,'sha256'),'hex'),v_result);
 if v_secret is not null then insert into private.offline_customer_enrollment_receipts(receipt_id,profile_id,request_id,secret_hash,issued_by,issued_branch_id)values(v_eid,v_pid,p_request,extensions.digest(v_secret,'sha256'),v_actor,p_branch);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(v_actor::text,v_actor,'offline_customer_registration','offline_registration',p_request::text,p_branch,v_result);
 return v_result||jsonb_build_object('enrollment_secret',v_secret);
end $$;

create function private.close_offline_customer_registration(p_request uuid,p_branch uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid();r private.offline_customer_registration_requests;c private.offline_registration_closed_requests;result jsonb;
begin
 if actor is null or not coalesce(private.can_cashier_branch(p_branch),false) or not exists(select 1 from public.business_branches where branch_id=p_branch and is_active) then raise exception 'Active branch cashier or owner required' using errcode='42501';end if;
 if p_request is null then raise exception 'Stable registration request required' using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Registration close requires READ COMMITTED' using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-registration:'||p_request::text,0));
 select * into r from private.offline_customer_registration_requests where request_id=p_request;
 if found then
  if r.actor_id<>actor or r.branch_id<>p_branch then raise exception 'Registration receipt access denied' using errcode='42501';end if;
  -- Creation won. Return the actual stored receipt, never cancel or reissue its secret.
  return jsonb_build_object('state','succeeded','request_id',p_request,'branch_id',p_branch,'result',r.result||jsonb_build_object('enrollment_secret',null));
 end if;
 select * into c from private.offline_registration_closed_requests where request_id=p_request;
 if found then
  if c.actor_id<>actor or c.branch_id<>p_branch then raise exception 'Registration request access denied' using errcode='42501';end if;
 else
  insert into private.offline_registration_closed_requests(request_id,actor_id,branch_id) values(p_request,actor,p_branch) returning * into c;
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)
   values(actor::text,actor,'offline_registration_closed','offline_registration',p_request::text,p_branch,jsonb_build_object('state','closed','registration_created',false));
 end if;
 return jsonb_build_object('state','closed','request_id',p_request,'branch_id',p_branch,'registration_created',false,'may_retry_same_request',false,'definitive_failure',true,'enrollment_secret',null);
end $$;
revoke all on function private.close_offline_customer_registration(uuid,uuid) from public,anon,service_role;
grant execute on function private.close_offline_customer_registration(uuid,uuid) to authenticated;
create function public.close_offline_customer_registration(p_request uuid,p_branch uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_offline_customer_registration(p_request,p_branch)$$;
revoke all on function public.close_offline_customer_registration(uuid,uuid) from public,anon,service_role;
grant execute on function public.close_offline_customer_registration(uuid,uuid) to authenticated;

create or replace function private.get_offline_customer_registration(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r private.offline_customer_registration_requests;c private.offline_registration_closed_requests;begin
 if auth.uid() is null or not exists(select 1 from public.business_branches b where private.can_cashier_branch(b.branch_id)) then raise exception 'Active branch cashier or owner required' using errcode='42501';end if;
 if p_request is null then raise exception 'Stable registration request required' using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Registration recovery requires READ COMMITTED' using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-registration:'||p_request::text,0));
 select * into r from private.offline_customer_registration_requests where request_id=p_request;
 if found then
  if r.actor_id<>auth.uid() or not coalesce(private.can_cashier_branch(r.branch_id),false) then raise exception 'Registration receipt access denied' using errcode='42501';end if;
  return r.result||jsonb_build_object('enrollment_secret',null);
 end if;
 select * into c from private.offline_registration_closed_requests where request_id=p_request;
 if found then
  if c.actor_id<>auth.uid() or not coalesce(private.can_cashier_branch(c.branch_id),false) then raise exception 'Registration request access denied' using errcode='42501';end if;
  return jsonb_build_object('request_id',p_request,'branch_id',c.branch_id,'status','closed','registration_created',false,'may_retry_same_request',false,'definitive_failure',true,'enrollment_secret',null,'capabilities',private.offline_registration_capabilities());
 end if;
 -- Still uncertainty: a late creator may arrive until authoritative close wins.
 return jsonb_build_object('request_id',p_request,'status','absent','may_retry_same_request',true,'definitive_failure',false,'capabilities',private.offline_registration_capabilities());
end $$;
notify pgrst,'reload schema';
commit;
