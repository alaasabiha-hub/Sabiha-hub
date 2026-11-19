begin;
-- Public applications are text-only. Optional CV upload is deliberately pending.
create table private.recruitment_jobs (
 id uuid primary key default gen_random_uuid(),title_ar text not null check(length(trim(title_ar)) between 2 and 160),title_en text not null check(length(trim(title_en)) between 2 and 160),
 details_ar text not null check(length(trim(details_ar)) between 2 and 6000),details_en text not null check(length(trim(details_en)) between 2 and 6000),
 branch_id uuid not null references public.business_branches(branch_id),published boolean not null default false,created_by uuid not null references public.staff_profiles(user_id),created_at timestamptz not null default now());
create table private.recruitment_applications (
 id uuid primary key default gen_random_uuid(),job_id uuid not null references private.recruitment_jobs(id),name text not null check(length(trim(name)) between 2 and 100),
 email text,phone text,message text not null check(length(message)<=3000),status text not null default 'submitted' check(status in ('submitted','interview','accepted','rejected','prepared','activated')),
 submitted_at timestamptz not null default now(),interview_at timestamptz,owner_note text not null default '' check(length(owner_note)<=2000),
 linked_user uuid unique references auth.users(id),reviewed_by uuid references public.staff_profiles(user_id),reviewed_at timestamptz,
 check(email is not null or phone is not null));
create table private.recruitment_events(id uuid primary key default gen_random_uuid(),application_id uuid not null references private.recruitment_applications(id),actor uuid not null references public.staff_profiles(user_id),action text not null,status_after text not null,at timestamptz not null default now());
create table private.recruitment_requests(id uuid primary key,actor uuid,action text not null,payload_hash text not null,result jsonb not null);
create index recruitment_applications_job_time on private.recruitment_applications(job_id,submitted_at);
create index recruitment_applications_email_time on private.recruitment_applications(email,submitted_at) where email is not null;
create index recruitment_applications_phone_time on private.recruitment_applications(phone,submitted_at) where phone is not null;
do $$declare t text;begin foreach t in array array['recruitment_jobs','recruitment_applications','recruitment_events','recruitment_requests'] loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated',t);end loop;end $$;
create function private.recruitment_api(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog set timezone='UTC' as $$
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
 'applications',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('title_ar',j.title_ar,'title_en',j.title_en,'verified_accounts',coalesce((select jsonb_agg(jsonb_build_object('id',u.id)) from auth.users u where u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and ((a.email is not null and u.email_confirmed_at is not null and lower(u.email)=a.email) or (a.phone is not null and u.phone_confirmed_at is not null and '+'||regexp_replace(u.phone,'[^0-9]','','g')=a.phone))),'[]')) order by a.submitted_at desc),'[]') from private.recruitment_applications a join private.recruitment_jobs j on j.id=a.job_id));
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
revoke all on function private.recruitment_api(text,jsonb) from public;
grant execute on function private.recruitment_api(text,jsonb) to anon,authenticated;
create function public.recruitment_action(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.recruitment_api(p_action,p_data)$$;
revoke all on function public.recruitment_action(text,jsonb) from public;
grant execute on function public.recruitment_action(text,jsonb) to anon,authenticated;
commit;
