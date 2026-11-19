-- Customer reviews and support. Original ratings and attachments are never publicly mutable.
create table public.employee_public_profiles (
 user_id uuid primary key references public.staff_profiles(user_id),display_name text not null check(length(trim(display_name)) between 2 and 100),
 job_title text not null default '',branch_id uuid not null references public.business_branches(branch_id),
 is_published boolean not null default false,photo_path text,pending_photo_path text,
 photo_consent boolean not null default false,photo_approved_by uuid,updated_at timestamptz not null default now()
);
create table public.employee_service_reviews (
 review_id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.bookings(id),
 customer_id uuid not null references public.customers(id),employee_id uuid not null references public.staff_profiles(user_id),branch_id uuid not null references public.business_branches(branch_id),
 stars integer not null check(stars between 1 and 5),comment text not null default '' check(length(comment)<=1000),
 comment_published boolean not null default false,moderation_reason text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(booking_id,employee_id,customer_id)
);
create index employee_reviews_branch_idx on public.employee_service_reviews(branch_id,employee_id,created_at desc);
create table public.customer_complaints (
 complaint_id uuid primary key default gen_random_uuid(),reference text not null unique,
 request_id uuid not null,customer_id uuid not null references public.customers(id),booking_id uuid references public.bookings(id),order_id uuid references public.business_orders(order_id),
 branch_id uuid not null references public.business_branches(branch_id),details text not null check(length(trim(details)) between 10 and 4000),
 status text not null default 'new' check(status in ('new','under_review','in_progress','resolved','closed')),
 assigned_to uuid references public.staff_profiles(user_id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(customer_id,request_id),check(num_nonnulls(booking_id,order_id)=1)
);
create index complaints_customer_idx on public.customer_complaints(customer_id,created_at desc);
create index complaints_branch_status_idx on public.customer_complaints(branch_id,status,created_at);
create table public.customer_complaint_events (
 event_id uuid primary key default gen_random_uuid(),complaint_id uuid not null references public.customer_complaints(complaint_id),
 actor_id uuid not null,status text not null,note text not null default '' check(length(note)<=2000),is_internal boolean not null default false,created_at timestamptz not null default now()
);
create index complaint_events_complaint_idx on public.customer_complaint_events(complaint_id,created_at);
alter table public.employee_public_profiles enable row level security;
alter table public.employee_service_reviews enable row level security;
alter table public.customer_complaints enable row level security;
alter table public.customer_complaint_events enable row level security;
revoke all on public.employee_public_profiles,public.employee_service_reviews,public.customer_complaints,public.customer_complaint_events from anon,authenticated;
grant select on public.employee_public_profiles,public.employee_service_reviews,public.customer_complaints,public.customer_complaint_events to authenticated;
grant all on public.employee_public_profiles,public.employee_service_reviews,public.customer_complaints,public.customer_complaint_events to service_role;
create policy "Private employee profile management reads" on public.employee_public_profiles for select to authenticated using(user_id=(select auth.uid()) or (select private.active_staff_role())='owner');
create policy "Customer own and owner review reads" on public.employee_service_reviews for select to authenticated using(customer_id=(select auth.uid()) or (select private.active_staff_role())='owner');
create function private.can_manage_complaint(p_branch uuid,p_assigned uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select private.active_staff_role()='owner' or (private.can_access_branch(p_branch) and (private.active_staff_role()='manager' or private.active_staff_role()='employee' and p_assigned=auth.uid()));
$$;
revoke all on function private.can_manage_complaint(uuid,uuid) from public,anon;
grant execute on function private.can_manage_complaint(uuid,uuid) to authenticated;
create policy "Complaint access" on public.customer_complaints for select to authenticated using(customer_id=(select auth.uid()) or (select private.can_manage_complaint(branch_id,assigned_to)));
create policy "Complaint events access" on public.customer_complaint_events for select to authenticated using(exists(select 1 from public.customer_complaints c where c.complaint_id=customer_complaint_events.complaint_id and
 ((c.customer_id=(select auth.uid()) and not customer_complaint_events.is_internal) or (select private.can_manage_complaint(c.branch_id,c.assigned_to)))));

create function private.save_service_review(p_booking uuid,p_employee uuid,p_stars integer,p_comment text)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare b public.bookings%rowtype;r public.employee_service_reviews%rowtype;v_id uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select * into b from public.bookings where id=p_booking and customer_id=auth.uid();
 if not found or b.status<>'completed' or not(p_employee=any(b.assigned_staff_ids)) then raise exception 'Only rate staff assigned to your completed service';end if;
 if p_stars is null or p_stars not between 1 and 5 or length(coalesce(p_comment,''))>1000 then raise exception 'Invalid review';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_booking::text||p_employee::text||auth.uid()::text,0));
 select * into r from public.employee_service_reviews where booking_id=p_booking and employee_id=p_employee and customer_id=auth.uid();
 if found and r.created_at<now()-interval '7 days' then raise exception 'Reviews can be edited for seven days';end if;
 insert into public.employee_service_reviews(booking_id,customer_id,employee_id,branch_id,stars,comment)
 values(p_booking,auth.uid(),p_employee,b.branch_id,p_stars,trim(coalesce(p_comment,''))) on conflict(booking_id,employee_id,customer_id)
 do update set stars=excluded.stars,comment=excluded.comment,comment_published=false,moderation_reason=null,updated_at=now() returning review_id into v_id;return v_id;
end; $$;
revoke all on function private.save_service_review(uuid,uuid,integer,text) from public,anon;
grant execute on function private.save_service_review(uuid,uuid,integer,text) to authenticated;
create function public.save_service_review(p_booking uuid,p_employee uuid,p_stars integer,p_comment text default '') returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.save_service_review(p_booking,p_employee,p_stars,p_comment); $$;
revoke all on function public.save_service_review(uuid,uuid,integer,text) from public,anon;
grant execute on function public.save_service_review(uuid,uuid,integer,text) to authenticated;
create function private.moderate_service_review(p_review uuid,p_publish boolean,p_reason text) returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is distinct from 'owner' or length(trim(coalesce(p_reason,'')))<5 then raise exception 'Owner and moderation reason required';end if;
 update public.employee_service_reviews set comment_published=p_publish,moderation_reason=p_reason where review_id=p_review;
 if not found then raise exception 'Review not found';end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,reason) values(auth.uid()::text,auth.uid(),'moderate_comment','employee_service_reviews',p_review::text,p_reason);
end; $$;
revoke all on function private.moderate_service_review(uuid,boolean,text) from public,anon;
grant execute on function private.moderate_service_review(uuid,boolean,text) to authenticated;
create function public.moderate_service_review(p_review uuid,p_publish boolean,p_reason text) returns void language sql security invoker set search_path=pg_catalog as $$ select private.moderate_service_review(p_review,p_publish,p_reason); $$;
revoke all on function public.moderate_service_review(uuid,boolean,text) from public,anon;
grant execute on function public.moderate_service_review(uuid,boolean,text) to authenticated;
create function private.employee_directory(p_branch uuid) returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select coalesce(jsonb_agg(jsonb_build_object('employee_id',p.user_id,'display_name',p.display_name,'job_title',p.job_title,'branch_id',p.branch_id,
 'photo_path',case when p.photo_consent and p.photo_approved_by is not null then p.photo_path end,
 'average_stars',(select round(avg(stars),2) from public.employee_service_reviews r where r.employee_id=p.user_id),
 'review_count',(select count(*) from public.employee_service_reviews r where r.employee_id=p.user_id),
 'comments',(select coalesce(jsonb_agg(jsonb_build_object('stars',r.stars,'comment',r.comment,'created_at',r.created_at)),'[]') from public.employee_service_reviews r where r.employee_id=p.user_id and r.comment_published and r.comment<>''))),'[]')
 from public.employee_public_profiles p join public.staff_profiles s on s.user_id=p.user_id and s.is_active
 where p.is_published and (p_branch is null or p.branch_id=p_branch);
$$;
revoke all on function private.employee_directory(uuid) from public;
grant usage on schema private to anon;
grant execute on function private.employee_directory(uuid) to anon,authenticated;
create function public.employee_directory(p_branch uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.employee_directory(p_branch); $$;
revoke all on function public.employee_directory(uuid) from public;
grant execute on function public.employee_directory(uuid) to anon,authenticated;

create function private.create_customer_complaint(p_request uuid,p_booking uuid,p_order uuid,p_details text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_branch uuid;c public.customer_complaints%rowtype;v_id uuid:=gen_random_uuid();v_reference text;
begin
 if auth.uid() is null or p_request is null or num_nonnulls(p_booking,p_order)<>1 or length(trim(coalesce(p_details,''))) not between 10 and 4000 then raise exception 'Choose your booking or order and enter complaint details';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request::text,0));
 select * into c from public.customer_complaints where customer_id=auth.uid() and request_id=p_request;
 if found then if c.booking_id is distinct from p_booking or c.order_id is distinct from p_order or c.details<>trim(p_details) then raise exception 'Request already used for another complaint';end if;return jsonb_build_object('complaint_id',c.complaint_id,'reference',c.reference);end if;
 if p_booking is not null then select branch_id into v_branch from public.bookings where id=p_booking and customer_id=auth.uid();else select branch_id into v_branch from public.business_orders where order_id=p_order and customer_id=auth.uid();end if;
 if v_branch is null then raise exception 'This visit or order is not yours';end if;
 if (select count(*) from public.customer_complaints where customer_id=auth.uid() and created_at>now()-interval '1 day')>=10 then raise exception 'Daily complaint limit reached';end if;
 v_reference:='SUP-'||upper(replace(v_id::text,'-',''));
 insert into public.customer_complaints(complaint_id,reference,request_id,customer_id,booking_id,order_id,branch_id,details) values(v_id,v_reference,p_request,auth.uid(),p_booking,p_order,v_branch,trim(p_details));
 insert into public.customer_complaint_events(complaint_id,actor_id,status,note) values(v_id,auth.uid(),'new','تم استلام الشكوى');
 return jsonb_build_object('complaint_id',v_id,'reference',v_reference);
end; $$;
revoke all on function private.create_customer_complaint(uuid,uuid,uuid,text) from public,anon;
grant execute on function private.create_customer_complaint(uuid,uuid,uuid,text) to authenticated;
create function public.create_customer_complaint(p_request uuid,p_booking uuid,p_order uuid,p_details text) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.create_customer_complaint(p_request,p_booking,p_order,p_details); $$;
revoke all on function public.create_customer_complaint(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.create_customer_complaint(uuid,uuid,uuid,text) to authenticated;
create function private.update_customer_complaint(p_complaint uuid,p_expected text,p_status text,p_assigned uuid,p_note text,p_internal boolean) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare c public.customer_complaints%rowtype;begin
 select * into strict c from public.customer_complaints where complaint_id=p_complaint for update;
 if not coalesce(private.can_manage_complaint(c.branch_id,c.assigned_to),false) then raise exception 'Complaint management denied';end if;
 if c.status<>p_expected then raise exception 'Complaint changed; refresh';end if;
 if p_status not in ('new','under_review','in_progress','resolved','closed') or p_status is null or length(trim(coalesce(p_note,''))) not between 5 and 2000 then raise exception 'Status and action note required';end if;
 if c.status<>p_status and not ((c.status='new' and p_status='under_review') or (c.status='under_review' and p_status='in_progress') or (c.status='in_progress' and p_status='resolved') or (c.status='resolved' and p_status in ('in_progress','closed'))) then raise exception 'Invalid complaint transition';end if;
 if p_assigned is distinct from c.assigned_to and private.active_staff_role() not in ('owner','manager') then raise exception 'Only management can assign complaints';end if;
 if p_assigned is not null and not exists(select 1 from public.staff_profiles s join public.staff_branch_access a on a.user_id=s.user_id where s.user_id=p_assigned and s.is_active and a.branch_id=c.branch_id) then raise exception 'Active branch staff required';end if;
 update public.customer_complaints set status=p_status,assigned_to=p_assigned,updated_at=now() where complaint_id=p_complaint;
 insert into public.customer_complaint_events(complaint_id,actor_id,status,note,is_internal) values(p_complaint,auth.uid(),p_status,trim(p_note),coalesce(p_internal,false));
end; $$;
revoke all on function private.update_customer_complaint(uuid,text,text,uuid,text,boolean) from public,anon;
grant execute on function private.update_customer_complaint(uuid,text,text,uuid,text,boolean) to authenticated;
create function public.update_customer_complaint(p_complaint uuid,p_expected text,p_status text,p_assigned uuid,p_note text,p_internal boolean default false) returns void language sql security invoker set search_path=pg_catalog as $$ select private.update_customer_complaint(p_complaint,p_expected,p_status,p_assigned,p_note,p_internal); $$;
revoke all on function public.update_customer_complaint(uuid,text,text,uuid,text,boolean) from public,anon;
grant execute on function public.update_customer_complaint(uuid,text,text,uuid,text,boolean) to authenticated;

insert into storage.buckets(id,name,public) values('complaint-files','complaint-files',false),('staff-photos','staff-photos',false);
create function private.can_read_complaint_object(p_name text) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid() is not null and exists(select 1 from public.customer_complaints c where c.complaint_id::text=split_part(p_name,'/',2) and c.customer_id::text=split_part(p_name,'/',1) and (c.customer_id=auth.uid() or private.can_manage_complaint(c.branch_id,c.assigned_to)));
$$;
revoke all on function private.can_read_complaint_object(text) from public,anon;
grant execute on function private.can_read_complaint_object(text) to authenticated;
create policy "Private complaint attachments read" on storage.objects for select to authenticated using(bucket_id='complaint-files' and (select private.can_read_complaint_object(name)));
create policy "Customer uploads own complaint attachments" on storage.objects for insert to authenticated with check(bucket_id='complaint-files' and split_part(name,'/',1)=(select auth.uid())::text and (select private.can_read_complaint_object(name)));
create policy "Approved employee photo read" on storage.objects for select to anon,authenticated using(bucket_id='staff-photos' and exists(select 1 from public.employee_public_profiles p where p.photo_path=name and p.is_published and p.photo_consent and p.photo_approved_by is not null));
notify pgrst,'reload schema';
create function private.manage_employee_profile(p_user uuid,p_name text,p_title text,p_branch uuid,p_publish boolean,p_photo text,p_consent boolean)
returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Owner required';end if;
 if not exists(select 1 from public.staff_profiles where user_id=p_user and is_active) or not exists(select 1 from public.staff_branch_access where user_id=p_user and branch_id=p_branch) then raise exception 'Active employee branch required';end if;
 if p_photo is not null and not exists(select 1 from storage.objects where bucket_id='staff-photos' and name=p_photo and split_part(name,'/',1)=p_user::text) then raise exception 'Employee photo not found';end if;
 insert into public.employee_public_profiles(user_id,display_name,job_title,branch_id,is_published,photo_path,photo_consent,photo_approved_by)
 values(p_user,trim(p_name),trim(p_title),p_branch,p_publish,p_photo,coalesce(p_consent,false),case when p_photo is not null and p_consent then auth.uid() end)
 on conflict(user_id) do update set display_name=excluded.display_name,job_title=excluded.job_title,branch_id=excluded.branch_id,is_published=excluded.is_published,photo_path=excluded.photo_path,photo_consent=excluded.photo_consent,photo_approved_by=excluded.photo_approved_by,pending_photo_path=null,updated_at=now();
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id) values(auth.uid()::text,auth.uid(),'approve_public_profile','employee_public_profiles',p_user::text,p_branch);
end; $$;
revoke all on function private.manage_employee_profile(uuid,text,text,uuid,boolean,text,boolean) from public,anon;
grant execute on function private.manage_employee_profile(uuid,text,text,uuid,boolean,text,boolean) to authenticated;
create function public.manage_employee_profile(p_user uuid,p_name text,p_title text,p_branch uuid,p_publish boolean,p_photo text default null,p_consent boolean default false) returns void language sql security invoker set search_path=pg_catalog as $$ select private.manage_employee_profile(p_user,p_name,p_title,p_branch,p_publish,p_photo,p_consent); $$;
revoke all on function public.manage_employee_profile(uuid,text,text,uuid,boolean,text,boolean) from public,anon;
grant execute on function public.manage_employee_profile(uuid,text,text,uuid,boolean,text,boolean) to authenticated;
create function private.propose_employee_photo(p_path text,p_consent boolean) returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is null or not p_consent then raise exception 'Active staff and explicit photo consent required';end if;
 if not exists(select 1 from storage.objects where bucket_id='staff-photos' and name=p_path and split_part(name,'/',1)=auth.uid()::text) then raise exception 'Upload your own photo first';end if;
 update public.employee_public_profiles set pending_photo_path=p_path where user_id=auth.uid();if not found then raise exception 'Management must create your public profile first';end if;
end; $$;
revoke all on function private.propose_employee_photo(text,boolean) from public,anon;
grant execute on function private.propose_employee_photo(text,boolean) to authenticated;
create function public.propose_employee_photo(p_path text,p_consent boolean) returns void language sql security invoker set search_path=pg_catalog as $$ select private.propose_employee_photo(p_path,p_consent); $$;
revoke all on function public.propose_employee_photo(text,boolean) from public,anon;
grant execute on function public.propose_employee_photo(text,boolean) to authenticated;
create function private.can_read_employee_photo(p_path text) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select exists(select 1 from public.employee_public_profiles p join public.staff_profiles s on s.user_id=p.user_id and s.is_active where p.photo_path=p_path and p.is_published and p.photo_consent and p.photo_approved_by is not null)
 or auth.uid() is not null and (split_part(p_path,'/',1)=auth.uid()::text or private.active_staff_role()='owner');
$$;
revoke all on function private.can_read_employee_photo(text) from public;
grant execute on function private.can_read_employee_photo(text) to anon,authenticated;
drop policy "Approved employee photo read" on storage.objects;
create policy "Approved or authorized employee photo read" on storage.objects for select to anon,authenticated using(bucket_id='staff-photos' and (select private.can_read_employee_photo(name)));
create policy "Staff uploads candidate photo" on storage.objects for insert to authenticated with check(bucket_id='staff-photos' and ((split_part(name,'/',1)=(select auth.uid())::text and (select private.active_staff_role()) is not null) or (select private.active_staff_role())='owner'));
-- Enforce upload limits in the Storage service, independently of either UI.
update storage.buckets set file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png'] where id='complaint-files';
update storage.buckets set file_size_limit=3145728,allowed_mime_types=array['image/jpeg','image/png'] where id='staff-photos';
create function private.freeze_completed_staff_assignment() returns trigger language plpgsql set search_path=pg_catalog as $$ begin
 if old.status='completed' and (new.assigned_staff_ids is distinct from old.assigned_staff_ids or new.assigned_workers is distinct from old.assigned_workers) then raise exception 'Completed service staff assignments are immutable';end if;return new;end; $$;
revoke all on function private.freeze_completed_staff_assignment() from public;
create trigger freeze_completed_staff_assignment before update on public.bookings for each row execute function private.freeze_completed_staff_assignment();
notify pgrst,'reload schema';
create function private.review_targets(p_booking uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b public.bookings%rowtype;result jsonb;begin
 select * into b from public.bookings where id=p_booking and customer_id=auth.uid() and status='completed';if not found then raise exception 'Completed customer service required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('employee_id',s.user_id,'display_name',coalesce(p.display_name,s.full_name),'stars',r.stars,'comment',r.comment,'editable',r.created_at is null or r.created_at>now()-interval '7 days')),'[]') into result
 from public.staff_profiles s left join public.employee_public_profiles p on p.user_id=s.user_id
 left join public.employee_service_reviews r on r.employee_id=s.user_id and r.booking_id=p_booking and r.customer_id=auth.uid()
 where s.user_id=any(b.assigned_staff_ids);return result;
end; $$;
revoke all on function private.review_targets(uuid) from public,anon;
grant execute on function private.review_targets(uuid) to authenticated;
create function public.review_targets(p_booking uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.review_targets(p_booking); $$;
revoke all on function public.review_targets(uuid) from public,anon;
grant execute on function public.review_targets(uuid) to authenticated;
notify pgrst,'reload schema';
