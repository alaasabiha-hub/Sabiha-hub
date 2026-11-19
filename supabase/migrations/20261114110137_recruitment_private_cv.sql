begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('recruitment-cv-quarantine','recruitment-cv-quarantine',false,2097152,array['application/pdf']);
-- No anon/authenticated object policies: only the capability-checking Edge service writes.
create table private.recruitment_cv (
 application_id uuid primary key references private.recruitment_applications(id),capability_hash text not null check(capability_hash ~ '^[0-9a-f]{64}$'),expires_at timestamptz not null default now()+interval '15 minutes',
 state text not null default 'pending' check(state in ('pending','uploading','quarantined_unscanned')),object_path text unique,size_bytes integer check(size_bytes between 8 and 2097152),sha256 text check(sha256 ~ '^[0-9a-f]{64}$'),claimed_at timestamptz,uploaded_at timestamptz);
alter table private.recruitment_cv enable row level security;
revoke all on private.recruitment_cv from public,anon,authenticated;
create index recruitment_cv_claimed on private.recruitment_cv(claimed_at) where claimed_at is not null;
create function private.claim_recruitment_cv(p_application uuid,p_capability_hash text,p_size integer,p_sha256 text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c private.recruitment_cv;path text;
begin
 select * into c from private.recruitment_cv where application_id=p_application for update;
 if c.application_id is null or c.capability_hash is distinct from p_capability_hash or p_size is null or p_size not between 8 and 2097152 or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'Invalid upload capability';end if;
 if c.state<>'pending' then
 if c.sha256 is distinct from p_sha256 or c.size_bytes is distinct from p_size then raise exception 'Application already bound to another attachment';end if;
 if c.state='uploading' and c.expires_at<clock_timestamp() then raise exception 'Upload capability expired';end if;
 return jsonb_build_object('path',c.object_path,'state',c.state);end if;
 if c.expires_at<clock_timestamp() then raise exception 'Upload capability expired';end if;
 perform pg_advisory_xact_lock(hashtextextended('recruitment-cv-daily',0));
 if (select count(*) from private.recruitment_cv where claimed_at>=date_trunc('day',now()))>=100 then raise exception 'Daily attachment capacity reached';end if;
 path:=p_application::text||'/'||p_sha256||'.pdf';
 update private.recruitment_cv set state='uploading',object_path=path,size_bytes=p_size,sha256=p_sha256,claimed_at=now() where application_id=p_application;
 return jsonb_build_object('path',path,'state','uploading');
end $$;
revoke all on function private.claim_recruitment_cv(uuid,text,integer,text) from public,anon,authenticated;
grant execute on function private.claim_recruitment_cv(uuid,text,integer,text) to service_role;
create function public.claim_recruitment_cv(p_application uuid,p_capability_hash text,p_size integer,p_sha256 text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.claim_recruitment_cv(p_application,p_capability_hash,p_size,p_sha256)$$;
revoke all on function public.claim_recruitment_cv(uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.claim_recruitment_cv(uuid,text,integer,text) to service_role;
create function private.finalize_recruitment_cv(p_application uuid,p_sha256 text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c private.recruitment_cv;
begin
 select * into c from private.recruitment_cv where application_id=p_application for update;
 if c.application_id is null or c.sha256 is distinct from p_sha256 or c.state not in ('uploading','quarantined_unscanned') or not exists(select 1 from storage.objects where bucket_id='recruitment-cv-quarantine' and name=c.object_path and (metadata->>'size')::integer=c.size_bytes and metadata->>'mimetype'='application/pdf') then raise exception 'Matching private PDF object required';end if;
 update private.recruitment_cv set state='quarantined_unscanned',uploaded_at=coalesce(uploaded_at,now()) where application_id=p_application;
 return jsonb_build_object('state','quarantined_unscanned','sha256',c.sha256,'size_bytes',c.size_bytes);
end $$;
revoke all on function private.finalize_recruitment_cv(uuid,text) from public,anon,authenticated;
grant execute on function private.finalize_recruitment_cv(uuid,text) to service_role;
create function public.finalize_recruitment_cv(p_application uuid,p_sha256 text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.finalize_recruitment_cv(p_application,p_sha256)$$;
revoke all on function public.finalize_recruitment_cv(uuid,text) from public,anon,authenticated;
grant execute on function public.finalize_recruitment_cv(uuid,text) to service_role;
create function private.owner_recruitment_cv(p_application uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 return (select jsonb_build_object('state',state,'path',object_path,'sha256',sha256,'size_bytes',size_bytes) from private.recruitment_cv where application_id=p_application and state='quarantined_unscanned');
end $$;
revoke all on function private.owner_recruitment_cv(uuid) from public,anon;
grant execute on function private.owner_recruitment_cv(uuid) to authenticated;
create function public.owner_recruitment_cv(p_application uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.owner_recruitment_cv(p_application)$$;
revoke all on function public.owner_recruitment_cv(uuid) from public,anon;
grant execute on function public.owner_recruitment_cv(uuid) to authenticated;

create or replace function private.recruitment_api(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog set timezone='UTC' as $$
declare uid uuid:=auth.uid();owner_access boolean:=coalesce(private.active_staff_role()='owner',false);rid uuid;jid uuid;aid uuid;target uuid;bid uuid;
 nm text;em text;ph text;msg text;st text;prior private.recruitment_requests;app private.recruitment_applications;v jsonb;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or pg_column_size(p_data)>16000 then raise exception 'Invalid recruitment request';end if;
 if p_action='jobs' then
 return jsonb_build_object('jobs',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'title_ar',j.title_ar,'title_en',j.title_en,'details_ar',j.details_ar,'details_en',j.details_en,'branch_ar',b.name_ar,'branch_en',b.name_en)) from private.recruitment_jobs j join public.business_branches b on b.branch_id=j.branch_id where j.published and b.is_active),'[]'));
 end if;
 if p_action not in ('submit','jobs') and not owner_access then raise exception 'Active owner required' using errcode='42501';end if;
 if p_action='owner_read' then
 return jsonb_build_object('jobs',(select coalesce(jsonb_agg(to_jsonb(j) order by created_at desc),'[]') from private.recruitment_jobs j),
 'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',branch_id,'name_ar',name_ar,'name_en',name_en)),'[]') from public.business_branches where is_active),
 'applications',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('title_ar',j.title_ar,'title_en',j.title_en,'cv',(select jsonb_build_object('state',state,'size_bytes',size_bytes,'sha256',sha256) from private.recruitment_cv where application_id=a.id),'verified_accounts',coalesce((select jsonb_agg(jsonb_build_object('id',u.id)) from auth.users u where u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and ((a.email is not null and u.email_confirmed_at is not null and lower(u.email)=a.email) or (a.phone is not null and u.phone_confirmed_at is not null and '+'||regexp_replace(u.phone,'[^0-9]','','g')=a.phone))),'[]')) order by a.submitted_at desc),'[]') from private.recruitment_applications a join private.recruitment_jobs j on j.id=a.job_id));
 end if;
 rid:=(p_data->>'request_id')::uuid;if rid is null then raise exception 'Request identity required';end if;
 perform pg_advisory_xact_lock(hashtextextended('recruitment-request:'||rid::text,0));
 select * into prior from private.recruitment_requests where id=rid;
 if prior.id is not null then if prior.actor is distinct from uid or prior.action<>p_action or prior.payload_hash<>encode(extensions.digest(p_data::text,'sha256'),'hex') then raise exception 'Request identity reused with different inputs';end if;return prior.result;end if;
 if p_action='submit' then
 jid:=(p_data->>'job_id')::uuid;nm:=trim(p_data->>'name');em:=nullif(lower(trim(p_data->>'email')),'');ph:=nullif(trim(p_data->>'phone'),'');msg:=coalesce(trim(p_data->>'message'),'');
 if nm is null or length(nm) not between 2 and 100 or length(msg)>3000 or (em is null and ph is null) or (em is not null and (length(em)>254 or em !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) or (ph is not null and ph !~ '^\+[1-9][0-9]{7,14}$') then raise exception 'Enter name and valid email or international phone; respect field length limits';end if;
 perform pg_advisory_xact_lock(hashtextextended('recruitment-job:'||jid::text,0));
 if not exists(select 1 from private.recruitment_jobs j join public.business_branches b on b.branch_id=j.branch_id where j.id=jid and j.published and b.is_active) then raise exception 'Published vacancy required';end if;
 -- Bounded abuse control without retaining IP addresses or user-agent fingerprints.
 if em is not null then perform pg_advisory_xact_lock(hashtextextended('recruitment-email:'||em,0));end if;
 if ph is not null then perform pg_advisory_xact_lock(hashtextextended('recruitment-phone:'||ph,0));end if;
 if (select count(*) from private.recruitment_applications where job_id=jid and submitted_at>now()-interval '1 hour')>=100 or
 (select count(*) from private.recruitment_applications where submitted_at>now()-interval '1 day' and ((em is not null and email=em) or (ph is not null and phone=ph)))>=5 then raise exception 'Application limit reached; try later';end if;
 insert into private.recruitment_applications(job_id,name,email,phone,message) values(jid,nm,em,ph,msg) returning id into aid;
 if p_data ? 'cv_capability_hash' then
 if p_data->>'cv_capability_hash' is null or p_data->>'cv_capability_hash' !~ '^[0-9a-f]{64}$' then raise exception 'Invalid attachment capability hash';end if;
 insert into private.recruitment_cv(application_id,capability_hash) values(aid,p_data->>'cv_capability_hash');end if;
 v:=jsonb_build_object('application_id',aid,'status','received');
 elsif p_action='save_job' then
 jid:=coalesce((p_data->>'id')::uuid,gen_random_uuid());bid:=(p_data->>'branch_id')::uuid;
 if not exists(select 1 from public.business_branches where branch_id=bid and is_active) then raise exception 'Active branch required';end if;
 insert into private.recruitment_jobs(id,title_ar,title_en,details_ar,details_en,branch_id,published,created_by) values(jid,trim(p_data->>'title_ar'),trim(p_data->>'title_en'),trim(p_data->>'details_ar'),trim(p_data->>'details_en'),bid,(p_data->>'published')::boolean,uid)
 on conflict(id) do update set title_ar=excluded.title_ar,title_en=excluded.title_en,details_ar=excluded.details_ar,details_en=excluded.details_en,branch_id=excluded.branch_id,published=excluded.published;
 v:=jsonb_build_object('job_id',jid);
 else
 aid:=(p_data->>'application_id')::uuid;select * into app from private.recruitment_applications where id=aid for update;
 if app.id is null then raise exception 'Application not found';end if;
 if p_action='review' then
 st:=p_data->>'status';if st not in ('interview','accepted','rejected') or st is null or app.status in ('prepared','activated') then raise exception 'Choose interview, accepted or rejected before employee preparation';end if;
 if st='interview' and ((p_data->>'interview_at')::timestamptz is null or (p_data->>'interview_at')::timestamptz<now()) then raise exception 'Future interview time required';end if;
 update private.recruitment_applications set status=st,owner_note=coalesce(p_data->>'owner_note',owner_note),interview_at=case when st='interview' then (p_data->>'interview_at')::timestamptz else interview_at end,reviewed_by=uid,reviewed_at=now() where id=aid;
 elsif p_action='prepare_employee' then
 if app.status<>'accepted' or app.linked_user is not null then raise exception 'Accepted unlinked application required';end if;
 target:=(p_data->>'user_id')::uuid;bid:=(p_data->>'branch_id')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('recruitment-account:'||target::text,0));
 perform 1 from auth.users where id=target for share;
 if not exists(select 1 from auth.users u where u.id=target and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and ((app.email is not null and u.email_confirmed_at is not null and lower(u.email)=app.email) or (app.phone is not null and u.phone_confirmed_at is not null and '+'||regexp_replace(u.phone,'[^0-9]','','g')=app.phone))) then raise exception 'Existing account must match a verified application contact';end if;
 if exists(select 1 from public.staff_profiles where user_id=target) then raise exception 'Existing staff account cannot be overwritten';end if;
 if not exists(select 1 from public.business_branches where branch_id=bid and is_active) then raise exception 'Active branch required';end if;
 if p_data->>'currency' is distinct from 'EGP' then raise exception 'Explicit EGP compensation required';end if;
 insert into public.staff_profiles(user_id,full_name,role,permissions,is_active) values(target,app.name,'employee','{}'::jsonb,false);
 insert into public.staff_branch_access(user_id,branch_id) values(target,bid);
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on) values(target,(p_data->>'salary')::numeric,(p_data->>'commission_percent')::numeric,p_data->>'currency',(p_data->>'starts_on')::date);
 update private.recruitment_applications set linked_user=target,status='prepared',reviewed_by=uid,reviewed_at=now() where id=aid;
 elsif p_action='activate_employee' then
 if app.status<>'prepared' or app.linked_user is null then raise exception 'Prepared employee required';end if;
 perform 1 from auth.users where id=app.linked_user for share;
 if not exists(select 1 from auth.users u where u.id=app.linked_user and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and ((app.email is not null and u.email_confirmed_at is not null and lower(u.email)=app.email) or (app.phone is not null and u.phone_confirmed_at is not null and '+'||regexp_replace(u.phone,'[^0-9]','','g')=app.phone))) then raise exception 'Verified application contact must still match';end if;
 if not exists(select 1 from private.hr_employment where staff_id=app.linked_user and currency='EGP' and starts_on<=current_date and (ends_on is null or ends_on>=current_date)) or not exists(select 1 from public.staff_branch_access a join public.business_branches b using(branch_id) where a.user_id=app.linked_user and b.is_active) then raise exception 'Current explicit employment and active branch required';end if;
 update public.staff_profiles set is_active=true where user_id=app.linked_user and role='employee' and not is_active and permissions='{}'::jsonb;
 if not found then raise exception 'Inactive employee with no privileged permissions required';end if;
 update private.recruitment_applications set status='activated',reviewed_by=uid,reviewed_at=now() where id=aid;
 else raise exception 'Unknown recruitment action';end if;
 insert into private.recruitment_events(application_id,actor,action,status_after) values(aid,uid,p_action,(select status from private.recruitment_applications where id=aid));
 v:=jsonb_build_object('application_id',aid,'status',(select status from private.recruitment_applications where id=aid));
 end if;
 insert into private.recruitment_requests(id,actor,action,payload_hash,result) values(rid,uid,p_action,encode(extensions.digest(p_data::text,'sha256'),'hex'),v);return v;
end $$;
commit;
