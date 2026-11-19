begin;
-- Keep the existing offline identity ledger; add class-aware walk-in pricing only.
create or replace function private.register_offline_customer(p_request uuid,p_branch uuid,p_name text,p_phone text,p_country text,p_car jsonb,p_consent jsonb,p_duplicate_action text default null,p_review_reason text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid();v_phone text;v_name text;v_name_key text;v_plate text;v_car jsonb;v_consent jsonb;v_payload jsonb;v_prior private.offline_customer_registration_requests;v_profile private.offline_customer_profiles;v_candidate private.offline_customer_car_refs;
 v_profiles bigint;v_legacy_match boolean;v_pid uuid;v_cid uuid;v_eid uuid;v_secret text;v_outcome text;v_result jsonb;v_owner_separate boolean;v_year integer;v_masked text;v_closed private.offline_registration_closed_requests;
begin
 if v_actor is null or not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Active branch cashier or owner required' using errcode='42501';end if;
 v_phone:=private.offline_phone_key(p_phone,p_country);v_name:=regexp_replace(trim(p_name),'[[:space:]]+',' ','g');v_name_key:=lower(v_name);
 if p_request is null or p_branch is null or v_phone is null or v_name is null or length(v_name) not between 2 and 120 then raise exception 'Actual name, explicit EG phone context and valid phone format required' using errcode='22023';end if;
 if p_car is null or jsonb_typeof(p_car)<>'object' or not p_car?'plate_number' or not p_car?'vehicle_class_code' or p_car-array['plate_number','brand','model','year','color','vehicle_class_code','odometer_km']<>'{}'::jsonb or jsonb_typeof(p_car->'plate_number')<>'string' then raise exception 'Actual plate and supported car fields required' using errcode='22023';end if;
 if exists(select 1 from jsonb_each(p_car) f where f.key in('brand','model','color','vehicle_class_code') and jsonb_typeof(f.value)not in('string','null'))then raise exception 'Car details must be actual text or absent' using errcode='22023';end if;
 if p_car?'odometer_km' and p_car->'odometer_km'<>'null'::jsonb and (jsonb_typeof(p_car->'odometer_km')<>'number' or p_car->>'odometer_km'!~'^[0-9]{1,7}$' or (p_car->>'odometer_km')::integer not between 0 and 9999999)then raise exception 'Supported odometer reading required'using errcode='22023';end if;
 if jsonb_typeof(p_car->'vehicle_class_code')<>'string' or not exists(select 1 from private.business_vehicle_classes where class_code=p_car->>'vehicle_class_code' and is_active)then raise exception 'Active vehicle class is required'using errcode='22023';end if;
 if length(coalesce(p_car->>'plate_number',''))>40 or length(coalesce(p_car->>'brand',''))>80 or length(coalesce(p_car->>'model',''))>80 or length(coalesce(p_car->>'color',''))>40 then raise exception 'Car details exceed supported length' using errcode='22023';end if;
 v_plate:=upper(regexp_replace(translate(trim(p_car->>'plate_number'),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[[:space:]-]','','g'));
 if length(v_plate)not between 2 and 32 or v_plate ~ '[[:cntrl:]]' then raise exception 'Actual plate required' using errcode='22023';end if;
 if p_car?'year' and p_car->'year'<>'null'::jsonb then
  if jsonb_typeof(p_car->'year')<>'number' or p_car->>'year'!~'^[0-9]{4}$' then raise exception 'Supported car year required' using errcode='22023';end if;
  v_year:=(p_car->>'year')::integer;if v_year not between 1950 and 2100 then raise exception 'Supported car year required' using errcode='22023';end if;
 end if;
 v_car:=jsonb_build_object('plate_number',v_plate,'brand',nullif(lower(trim(p_car->>'brand')),''),'model',nullif(lower(trim(p_car->>'model')),''),'year',v_year,'color',nullif(lower(trim(p_car->>'color')),''),'vehicle_class_code',p_car->>'vehicle_class_code','odometer_km',case when p_car->'odometer_km'='null'::jsonb then null else p_car->'odometer_km' end);
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
   if not exists(select 1 from private.business_offline_vehicle_classes where car_ref_id=v_cid)then insert into private.business_offline_vehicle_classes(car_ref_id,branch_id,class_code,updated_by)values(v_cid,p_branch,p_car->>'vehicle_class_code',v_actor);end if;
  else v_outcome:='review_required';end if;
 elsif (v_profiles>0 or v_legacy_match)and not coalesce(v_owner_separate,false)then v_outcome:='review_required';
 else
  v_pid:=gen_random_uuid();v_cid:=gen_random_uuid();v_eid:=gen_random_uuid();v_secret:=encode(extensions.gen_random_bytes(32),'hex');v_outcome:='created_unverified';
  insert into private.offline_customer_profiles(profile_id,full_name,name_key,created_branch_id,created_by) values(v_pid,v_name,v_name_key,p_branch,v_actor);
  insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values(v_pid,v_phone,'EG');
  insert into private.offline_customer_car_refs(car_ref_id,profile_id,plate_key,car_snapshot)values(v_cid,v_pid,v_plate,v_car);
  insert into private.business_offline_vehicle_classes(car_ref_id,branch_id,class_code,updated_by)values(v_cid,p_branch,p_car->>'vehicle_class_code',v_actor)on conflict(car_ref_id)do nothing;
 end if;
 v_masked:='+'||repeat('*',greatest(length(v_phone)-5,1))||right(v_phone,4);
 v_result:=jsonb_build_object('request_id',p_request,'status',v_outcome,'offline_profile_id',v_pid,'car_ref_id',v_cid,'phone_masked',v_masked,'identity_verified',false,'review_reason_code',case when v_outcome='review_required'then 'contact_review_required' else null end,'enrollment_receipt_id',v_eid,'enrollment_secret_issued',v_eid is not null,'enrollment_secret_recoverable',false,'enrollment_receipt_status',case when v_eid is not null then 'issued_not_recoverable'else 'not_issued'end,'capabilities',private.offline_registration_capabilities());
 insert into private.offline_customer_registration_requests(request_id,actor_id,branch_id,payload,consent,consent_hash,result)values(p_request,v_actor,p_branch,v_payload,v_consent,encode(extensions.digest(v_consent::text,'sha256'),'hex'),v_result);
 if v_secret is not null then insert into private.offline_customer_enrollment_receipts(receipt_id,profile_id,request_id,secret_hash,issued_by,issued_branch_id)values(v_eid,v_pid,p_request,extensions.digest(v_secret,'sha256'),v_actor,p_branch);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(v_actor::text,v_actor,'offline_customer_registration','offline_registration',p_request::text,p_branch,v_result);
 return v_result||jsonb_build_object('enrollment_secret',v_secret);
end $$;
create or replace function private.get_offline_walk_in_context(p_registration uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare r private.offline_customer_registration_requests;p private.offline_customer_profiles;c private.offline_customer_car_refs;b public.business_branches;role text:=private.active_staff_role();can_prepare boolean;cashier_name text;today date:=(clock_timestamp()at time zone'Africa/Cairo')::date;v_class_code text;class_row private.business_vehicle_classes;unpriced integer;
begin
 if auth.uid()is null or role is null or role not in('owner','manager','employee')or p_registration is null then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 select * into r from private.offline_customer_registration_requests where request_id=p_registration;
 if not found or r.result->>'status'not in('created_unverified','reused_unverified')or not coalesce(private.can_cashier_branch(r.branch_id),false)or not coalesce(private.can_access_branch(r.branch_id),false)or not private.offline_walk_in_cashier(r.actor_id,r.branch_id)or(role='employee'and r.actor_id<>auth.uid())then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 select * into b from public.business_branches where branch_id=r.branch_id and is_active;
 select * into p from private.offline_customer_profiles where profile_id=(r.result->>'offline_profile_id')::uuid and created_branch_id=r.branch_id;
 select * into c from private.offline_customer_car_refs where car_ref_id=(r.result->>'car_ref_id')::uuid and profile_id=p.profile_id;
 if b.branch_id is null or p.profile_id is null or c.car_ref_id is null then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 v_class_code:=private.cashier_vehicle_class_code(c.car_ref_id);
 select * into class_row from private.business_vehicle_classes where business_vehicle_classes.class_code=v_class_code and is_active;
 select full_name into cashier_name from public.staff_profiles where user_id=r.actor_id and is_active;
 can_prepare:=role in('owner','manager') or(role='employee'and r.actor_id=auth.uid()and exists(select 1 from public.staff_profiles s where s.user_id=auth.uid()and s.is_active and s.role='employee'and s.permissions->>'cashier'='true'));
 select count(*) into unpriced from public.business_catalog_items s where s.branch_id=b.branch_id and s.item_type='service'and s.is_active and s.is_public and not exists(select 1 from private.business_service_vehicle_prices vp where vp.branch_id=b.branch_id and vp.item_id=s.item_id and vp.class_code=v_class_code);
 return jsonb_build_object('registration_request_id',r.request_id,'branch',jsonb_build_object('id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en,'currency',b.currency),
 'subject',jsonb_build_object('profile_id',p.profile_id,'name',p.full_name,'car_ref_id',c.car_ref_id,'plate_number',c.plate_key,'brand',c.car_snapshot->>'brand','model',c.car_snapshot->>'model','vehicle_class_code',v_class_code,'vehicle_class_name_ar',class_row.name_ar,'vehicle_class_name_en',class_row.name_en,'identity_verified',false),
 'bound_cashier',jsonb_build_object('id',r.actor_id,'name',cashier_name),'can_prepare',can_prepare,
 'services',case when can_prepare and v_class_code is not null then(select coalesce(jsonb_agg(jsonb_build_object('id',s.item_id,'name',s.name,'name_en',s.name_en,'vehicle_type',v_class_code,'vehicle_class_code',v_class_code,'price',vp.price,'duration_minutes',s.duration_minutes)order by s.name,s.item_id),'[]')from public.business_catalog_items s join private.business_service_vehicle_prices vp on vp.branch_id=s.branch_id and vp.item_id=s.item_id and vp.class_code=v_class_code where s.branch_id=b.branch_id and s.item_type='service'and s.is_active and s.is_public and vp.price>0 and vp.price::text not in('NaN','Infinity','-Infinity')and s.name!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)')else'[]'::jsonb end,
 'unpriced_services_count',unpriced,
 'workers',case when can_prepare then(select coalesce(jsonb_agg(jsonb_build_object('id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and e.currency='EGP'and e.starts_on<=today and(e.ends_on is null or e.ends_on>=today)and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=b.branch_id))else'[]'::jsonb end,
 'capabilities',private.offline_walk_in_flags());
end$$;
create or replace function private.walk_in_service_facts(p_registration uuid,p_service uuid,p_expected_price numeric,p_staff_ids uuid[],p_cashier uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_r private.offline_customer_registration_requests;v_p private.offline_customer_profiles;v_car private.offline_customer_car_refs;v_service public.business_catalog_items;v_b public.business_branches;v_h public.business_branch_hours;v_e public.business_branch_exceptions;v_class text;v_price numeric;v_now timestamp:=clock_timestamp()at time zone'Africa/Cairo';v_open time;v_close time;v_staff uuid[];v_lines jsonb;v_n integer;begin
 select * into v_r from private.offline_customer_registration_requests where request_id=p_registration;
 if not found or v_r.actor_id<>p_cashier or v_r.result->>'status'not in('created_unverified','reused_unverified')or not coalesce(private.can_access_branch(v_r.branch_id),false)or not private.offline_walk_in_cashier(p_cashier,v_r.branch_id)then raise exception 'Authorized same-cashier branch intake receipt required'using errcode='42501';end if;
 select * into v_p from private.offline_customer_profiles where profile_id=(v_r.result->>'offline_profile_id')::uuid and created_branch_id=v_r.branch_id;
 select * into v_car from private.offline_customer_car_refs where car_ref_id=(v_r.result->>'car_ref_id')::uuid and profile_id=v_p.profile_id;
 if v_p.profile_id is null or v_car.car_ref_id is null then raise exception 'Actual intake profile and car binding required'using errcode='55000';end if;
 select * into v_b from public.business_branches where branch_id=v_r.branch_id for share;
 if not v_b.is_active or v_b.temporarily_closed or v_b.currency<>'EGP'then raise exception 'Active EGP branch required'using errcode='55000';end if;
 select * into v_service from public.business_catalog_items where item_id=p_service and branch_id=v_b.branch_id and item_type='service'and is_active and is_public and name!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'for share;
 if not found then raise exception 'Supported active service required'using errcode='22023';end if;
 v_class:=private.cashier_vehicle_class_code(v_car.car_ref_id);
 if v_class is null then raise exception 'An active Sedan/SUV classification is required'using errcode='55000';end if;
 select price into v_price from private.business_service_vehicle_prices where branch_id=v_b.branch_id and item_id=v_service.item_id and class_code=v_class;
 if v_price is null or v_price<=0 or v_price::text in('NaN','Infinity','-Infinity')then raise exception 'An explicit positive price for this vehicle class is required'using errcode='55000';end if;
 if v_price is distinct from p_expected_price then raise exception 'Vehicle-class price changed; close this preparation and refresh'using errcode='40001';end if;
 select * into v_h from public.business_branch_hours where branch_id=v_b.branch_id and weekday=extract(dow from v_now)::integer;
 if not found then raise exception 'Configured branch hours required'using errcode='55000';end if;
 v_open:=v_h.opens_at;v_close:=v_h.closes_at;
 select * into v_e from public.business_branch_exceptions where branch_id=v_b.branch_id and exception_date=v_now::date;
 if found then if v_e.is_closed then raise exception 'Branch closed today'using errcode='55000';end if;v_open:=v_e.opens_at;v_close:=v_e.closes_at;
 elsif not v_h.is_open then raise exception 'Branch closed today'using errcode='55000';end if;
 if v_now::time<v_open or v_now+make_interval(mins=>v_service.duration_minutes)>v_now::date+v_close then raise exception 'Reception service outside configured hours'using errcode='55000';end if;
 if p_staff_ids is null or cardinality(p_staff_ids)not between 1 and 20 or array_position(p_staff_ids,null)is not null then raise exception 'Explicit assigned workers required'using errcode='22023';end if;
 select array_agg(x order by x),count(*)into v_staff,v_n from(select distinct unnest(p_staff_ids)x)s;
 if v_n<>cardinality(p_staff_ids)then raise exception 'Duplicate assigned worker'using errcode='22023';end if;
 perform 1 from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.user_id=any(v_staff)order by s.user_id for share of s,e;
 select jsonb_agg(jsonb_build_object('staff_id',s.user_id,'staff_name',s.full_name,'rate_percent',e.commission_percent,'assigned_count',v_n,'gross',v_price,'amount',round(v_price*e.commission_percent/100/v_n,2),'employment_snapshot',to_jsonb(e))order by s.user_id)into v_lines
 from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.user_id=any(v_staff)and s.is_active and e.currency='EGP'and e.starts_on<=v_now::date and(e.ends_on is null or e.ends_on>=v_now::date)and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=v_b.branch_id);
 if coalesce(jsonb_array_length(v_lines),0)<>v_n then raise exception 'Every assigned branch worker needs actual current EGP employment'using errcode='55000';end if;
 return jsonb_build_object('branch_id',v_b.branch_id,'profile_id',v_p.profile_id,'car_ref_id',v_car.car_ref_id,'customer_name',v_p.full_name,'customer_phone',v_r.payload->>'phone','plate_number',v_car.plate_key,'consent_hash',v_r.consent_hash,'service_id',v_service.item_id,'service_name',v_service.name,'vehicle_type',v_class,'gross',v_price,'vehicle_class_code',v_class,'duration_minutes',v_service.duration_minutes,'resource_key',v_service.resource_key,'staff_ids',to_jsonb(v_staff),'lines',v_lines);
end$$;

create or replace function private.list_offline_walk_in_reception(p_branch uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null or not coalesce(private.can_access_branch(p_branch),false)
    or private.active_staff_role() not in('owner','manager','employee')
    or private.active_staff_role() is null then
  raise exception 'Active branch staff required' using errcode='42501';
 end if;
 return coalesce((
  select jsonb_agg(v.item order by v.arrived_at)
  from (
   select r.arrived_at,jsonb_build_object(
    'source_kind','walk_in','order_id',o.order_id,'work_reference',i.display_number,
    'invoice_id',i.invoice_id,
    'invoice_token',case when private.can_cashier_branch(p_branch) then i.document_token end,
    'branch_id',s.branch_id,'service_name',o.service_name,'plate_number',o.plate_number,
    'vehicle_class_code',o.vehicle_type,'odometer_km',c.car_snapshot->>'odometer_km',
    'brand',c.car_snapshot->>'brand','model',c.car_snapshot->>'model',
    'customer_name',p.full_name,'status',o.status,'arrived_at',r.arrived_at,
    'priority',r.priority,'amount_due',i.total,'assigned_staff_ids',to_jsonb(o.assigned_staff_ids),
    'capabilities',private.offline_walk_in_flags()) item
   from private.offline_walk_in_subjects s
   join public.business_orders o using(order_id)
   join private.offline_walk_in_reception r using(order_id)
   join public.business_invoices i on i.invoice_id=s.invoice_id
   join private.offline_customer_profiles p on p.profile_id=s.profile_id and p.created_branch_id=s.branch_id
   join private.offline_customer_car_refs c on c.car_ref_id=s.car_ref_id and c.profile_id=s.profile_id
   where s.branch_id=p_branch and o.status='received'
    and (r.arrived_at at time zone 'Africa/Cairo')::date=(clock_timestamp() at time zone 'Africa/Cairo')::date
    and (private.active_staff_role() in('owner','manager') or auth.uid()=any(o.assigned_staff_ids) or private.can_cashier_branch(p_branch))
  ) v
 ),'[]'::jsonb);
end$$;

notify pgrst,'reload schema';
commit;
