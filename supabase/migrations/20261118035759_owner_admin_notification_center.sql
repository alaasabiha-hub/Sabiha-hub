begin;

-- Durable staff-only inbox. It never sends push/email/SMS or reads customer text.
create table private.admin_notification_settings (
  category text primary key check (category in
    ('bookings','cashier','inventory','expenses','documents','complaints','reviews','recruitment','payroll')),
  enabled boolean not null default true,
  recipient_roles text[] not null default array['owner']::text[]
    check (recipient_roles <@ array['owner','manager','employee','cashier']::text[]
      and recipient_roles @> array['owner']::text[]),
  version integer not null default 1 check(version > 0),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default clock_timestamp()
);
insert into private.admin_notification_settings(category) values
 ('bookings'),('cashier'),('inventory'),('expenses'),('documents'),
 ('complaints'),('reviews'),('recruitment'),('payroll');
create table private.admin_notification_settings_audit (
  audit_id bigint generated always as identity primary key,
  category text not null,
  actor_id uuid not null references auth.users(id),
  previous jsonb not null,
  current jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
create table private.admin_notification_events (
  event_id uuid primary key default gen_random_uuid(),
  category text not null references private.admin_notification_settings(category),
  template_code text not null check(template_code in
    ('booking_created','booking_changed','cashier_payment_review','inventory_zero',
     'expense_recorded','document_expiry','complaint_new','complaint_changed',
     'review_new','recruitment_new','payroll_approved')),
  source_kind text not null,
  source_id uuid not null,
  source_revision text not null,
  branch_id uuid references public.business_branches(branch_id),
  created_at timestamptz not null default clock_timestamp(),
  unique(source_kind,source_id,template_code,source_revision)
);
create index admin_notification_events_page on private.admin_notification_events(created_at desc,event_id desc);
create index admin_notification_events_branch on private.admin_notification_events(branch_id,created_at desc);
create table private.admin_notification_reads (
  event_id uuid not null references private.admin_notification_events(event_id),
  actor_id uuid not null references auth.users(id),
  read_at timestamptz not null default clock_timestamp(),
  primary key(event_id,actor_id)
);
create table private.admin_notification_read_commands (
  actor_id uuid not null references auth.users(id), request_id uuid not null,
  event_id uuid not null references private.admin_notification_events(event_id),
  created_at timestamptz not null default clock_timestamp(), primary key(actor_id,request_id)
);
alter table private.admin_notification_settings enable row level security;
alter table private.admin_notification_settings_audit enable row level security;
alter table private.admin_notification_events enable row level security;
alter table private.admin_notification_reads enable row level security;
alter table private.admin_notification_read_commands enable row level security;
revoke all on private.admin_notification_settings,private.admin_notification_settings_audit,
  private.admin_notification_events,private.admin_notification_reads,
  private.admin_notification_read_commands from public,anon,authenticated,service_role;
revoke all on sequence private.admin_notification_settings_audit_audit_id_seq from public,anon,authenticated,service_role;

create function private.admin_notification_template(p_code text) returns jsonb
language sql immutable set search_path=pg_catalog as $$
 select case p_code
  when 'booking_created' then jsonb_build_object('title_ar','حجز جديد','title_en','New booking','body_ar','يوجد حجز جديد يحتاج مراجعة.','body_en','A new booking needs review.')
  when 'booking_changed' then jsonb_build_object('title_ar','تحديث حجز','title_en','Booking updated','body_ar','تغيرت حالة حجز وتحتاج المراجعة.','body_en','A booking status changed and needs review.')
  when 'cashier_payment_review' then jsonb_build_object('title_ar','فاتورة بانتظار التحصيل','title_en','Invoice awaiting collection','body_ar','توجد فاتورة تحتاج مراجعة أو تأكيد تحصيل من الكاشير.','body_en','An invoice needs cashier review or collection confirmation.')
  when 'inventory_zero' then jsonb_build_object('title_ar','نفاد مخزون','title_en','Stock depleted','body_ar','وصل مخزون أحد الأصناف إلى الصفر.','body_en','An item’s stock reached zero.')
  when 'expense_recorded' then jsonb_build_object('title_ar','مصروف جديد','title_en','Expense recorded','body_ar','تم تسجيل مصروف يحتاج مراجعة مالية.','body_en','An expense was recorded for financial review.')
  when 'document_expiry' then jsonb_build_object('title_ar','تنبيه مستند','title_en','Document alert','body_ar','يوجد مستند يحتاج متابعة بخصوص تاريخ الصلاحية.','body_en','A document expiry alert needs follow-up.')
  when 'complaint_new' then jsonb_build_object('title_ar','شكوى جديدة','title_en','New complaint','body_ar','وصلت شكوى جديدة تحتاج متابعة.','body_en','A new complaint needs follow-up.')
  when 'complaint_changed' then jsonb_build_object('title_ar','تحديث شكوى','title_en','Complaint updated','body_ar','تغيرت حالة شكوى تحتاج متابعة.','body_en','A complaint status changed and needs follow-up.')
  when 'review_new' then jsonb_build_object('title_ar','تقييم جديد','title_en','New review','body_ar','وصل تقييم جديد للخدمة.','body_en','A new service review was submitted.')
  when 'recruitment_new' then jsonb_build_object('title_ar','طلب توظيف جديد','title_en','New job application','body_ar','وصل طلب توظيف جديد يحتاج مراجعة.','body_en','A new job application needs review.')
  when 'payroll_approved' then jsonb_build_object('title_ar','تحديث رواتب','title_en','Payroll update','body_ar','تم اعتماد سجل رواتب جديد.','body_en','A payroll record was approved.')
  when 'payroll_adjustment' then jsonb_build_object('title_ar','تحديث مستحقات موظف','title_en','Employee compensation update','body_ar','تم تسجيل تعديل مستحقات يحتاج مراجعة المالك.','body_en','A compensation adjustment was recorded for owner review.')
  else null end
$$;
revoke all on function private.admin_notification_template(text) from public,anon,authenticated,service_role;

create function private.admin_notification_actor() returns uuid
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid(); v_sid uuid; v_role text;
begin
  begin v_sid:=(auth.jwt()->>'session_id')::uuid;
  exception when invalid_text_representation then raise exception 'Admin inbox unavailable' using errcode='42501'; end;
  if v_actor is null or v_sid is null then raise exception 'Admin inbox unavailable' using errcode='42501'; end if;
  perform 1 from auth.users u join auth.sessions s on s.user_id=u.id
   where u.id=v_actor and s.id=v_sid and u.deleted_at is null
    and (u.banned_until is null or u.banned_until<=clock_timestamp())
    and (s.not_after is null or s.not_after>clock_timestamp()) for share of u,s;
  if not found then raise exception 'Admin inbox unavailable' using errcode='42501'; end if;
  v_role:=private.active_staff_role();
  if v_role is null or v_role not in ('owner','manager','employee') then raise exception 'Admin inbox unavailable' using errcode='42501'; end if;
  return v_actor;
end$$;
revoke all on function private.admin_notification_actor() from public,anon,authenticated,service_role;

create function private.emit_admin_notification(p_category text,p_template text,p_source_kind text,
 p_source_id uuid,p_source_revision text,p_branch uuid default null) returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare cfg private.admin_notification_settings; t jsonb;
begin
 if p_source_id is null or p_source_revision is null or length(p_source_revision)>180 then
   raise exception 'Exact notification source required' using errcode='22023'; end if;
 t:=private.admin_notification_template(p_template);
 if t is null then raise exception 'Fixed notification template required' using errcode='22023'; end if;
 select * into cfg from private.admin_notification_settings where category=p_category;
 if not found or not cfg.enabled then return; end if;
 insert into private.admin_notification_events(category,template_code,source_kind,source_id,source_revision,branch_id)
 values(p_category,p_template,p_source_kind,p_source_id,p_source_revision,p_branch) on conflict do nothing;
end$$;
revoke all on function private.emit_admin_notification(text,text,text,uuid,text,uuid) from public,anon,authenticated,service_role;

create function private.list_admin_notifications(p_category text default null,p_unread_only boolean default false,p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.admin_notification_actor(); v_items jsonb; v_unread bigint; v_role text; v_permissions jsonb;
begin
 if p_limit not between 1 and 100 or (p_category is not null and p_category not in
  ('bookings','cashier','inventory','expenses','documents','complaints','reviews','recruitment','payroll')) then
   raise exception 'Valid notification filter required' using errcode='22023'; end if;
 select role,permissions into strict v_role,v_permissions from public.staff_profiles where user_id=v_actor and is_active;
 with visible as (
  select e.*, t->>'title_ar' title_ar,t->>'title_en' title_en,t->>'body_ar' body_ar,t->>'body_en' body_en,
   (r.event_id is not null) is_read,r.read_at
  from private.admin_notification_events e
  join private.admin_notification_settings s using(category)
  cross join lateral (select private.admin_notification_template(e.template_code) t) x
  left join private.admin_notification_reads r on r.event_id=e.event_id and r.actor_id=v_actor
  where s.enabled and (p_category is null or e.category=p_category)
   and ((v_role='owner' and s.recipient_roles @> array['owner']::text[])
     or (v_role='manager' and s.recipient_roles @> array['manager']::text[]
       and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
     or (v_role='employee' and s.recipient_roles @> array['employee']::text[]
       and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
     or (v_role in ('manager','employee') and coalesce(v_permissions->>'cashier','false')='true'
       and s.recipient_roles @> array['cashier']::text[] and e.category='cashier'
       and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id)))
   and (not p_unread_only or r.event_id is null)
 ), page as (select * from visible order by created_at desc,event_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('event_id',event_id,'category',category,'template_code',template_code,
    'title_ar',title_ar,'title_en',title_en,'body_ar',body_ar,'body_en',body_en,'created_at',created_at,
    'branch_id',branch_id,'read',is_read,'read_at',read_at) order by created_at desc,event_id desc),'[]'::jsonb)
 into v_items from page;
 with allowed as (
  select e.event_id from private.admin_notification_events e join private.admin_notification_settings s using(category)
  where s.enabled and ((v_role='owner' and s.recipient_roles @> array['owner']::text[])
   or (v_role in ('manager','employee') and s.recipient_roles @> array[v_role]::text[] and e.branch_id is not null
    and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
   or (v_role in ('manager','employee') and coalesce(v_permissions->>'cashier','false')='true'
    and s.recipient_roles @> array['cashier']::text[] and e.category='cashier' and e.branch_id is not null
    and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id)))
 ) select count(*) into v_unread from allowed a where not exists(select 1 from private.admin_notification_reads r where r.event_id=a.event_id and r.actor_id=v_actor);
 return jsonb_build_object('items',v_items,'unread_count',v_unread,'push_enabled',false);
end$$;

create function private.mark_admin_notification_read(p_request uuid,p_event uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid:=private.admin_notification_actor(); v_prior private.admin_notification_read_commands; v_stamp timestamptz; v_role text; v_permissions jsonb;
begin
 if p_request is null or p_event is null then raise exception 'Stable read request required' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-notification-read:'||v_actor::text||':'||p_request::text,0));
 perform private.admin_notification_actor();
 select role,permissions into strict v_role,v_permissions from public.staff_profiles where user_id=v_actor and is_active;
 if not exists(select 1 from private.admin_notification_events e join private.admin_notification_settings s using(category)
  where e.event_id=p_event and s.enabled and (
   (v_role='owner' and s.recipient_roles @> array['owner']::text[])
   or (v_role in ('manager','employee') and s.recipient_roles @> array[v_role]::text[]
     and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
   or (v_role in ('manager','employee') and coalesce(v_permissions->>'cashier','false')='true'
     and s.recipient_roles @> array['cashier']::text[] and e.category='cashier' and e.branch_id is not null
     and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
  )) then
   raise exception 'Notification unavailable' using errcode='42501'; end if;
 select * into v_prior from private.admin_notification_read_commands where actor_id=v_actor and request_id=p_request;
 if found and v_prior.event_id<>p_event then raise exception 'Read request reused' using errcode='22023'; end if;
 insert into private.admin_notification_reads(event_id,actor_id) values(p_event,v_actor) on conflict do nothing;
 insert into private.admin_notification_read_commands(actor_id,request_id,event_id) values(v_actor,p_request,p_event) on conflict do nothing;
 select read_at into strict v_stamp from private.admin_notification_reads where event_id=p_event and actor_id=v_actor;
 return jsonb_build_object('event_id',p_event,'read',true,'read_at',v_stamp);
end$$;

create function private.get_admin_notification_settings() returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.admin_notification_actor(); v_role text; v_result jsonb;
begin
 select role into strict v_role from public.staff_profiles where user_id=v_actor and is_active;
 if v_role<>'owner' then raise exception 'Owner required' using errcode='42501'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('category',category,'enabled',enabled,'recipient_roles',recipient_roles,'version',version,'updated_at',updated_at) order by category),'[]'::jsonb)
 into v_result from private.admin_notification_settings;
 return jsonb_build_object('settings',v_result);
end$$;

create function private.save_admin_notification_setting(p_category text,p_enabled boolean,p_roles text[],p_expected_version integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid:=private.admin_notification_actor(); v_old private.admin_notification_settings;
begin
 if (select role from public.staff_profiles where user_id=v_actor and is_active) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501'; end if;
 if p_category not in ('bookings','cashier','inventory','expenses','documents','complaints','reviews','recruitment','payroll')
   or p_enabled is null or p_roles is null or p_expected_version is null
   or not (p_roles <@ array['owner','manager','employee','cashier']::text[]) or not ('owner'=any(p_roles)) then
   raise exception 'Valid owner notification policy required' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-notification-policy:'||p_category,0));
 select * into strict v_old from private.admin_notification_settings where category=p_category for update;
 if v_old.version<>p_expected_version then raise exception 'Notification policy changed; refresh required' using errcode='40001'; end if;
 update private.admin_notification_settings set enabled=p_enabled,recipient_roles=p_roles,version=version+1,updated_by=v_actor,updated_at=clock_timestamp()
 where category=p_category;
 insert into private.admin_notification_settings_audit(category,actor_id,previous,current)
 values(p_category,v_actor,to_jsonb(v_old),jsonb_build_object('enabled',p_enabled,'recipient_roles',p_roles,'version',p_expected_version+1));
 return jsonb_build_object('category',p_category,'enabled',p_enabled,'recipient_roles',p_roles,'version',p_expected_version+1);
end$$;

create function private.reject_admin_notification_mutation() returns trigger
language plpgsql set search_path=pg_catalog as $$begin raise exception 'Notification audit is append-only' using errcode='55000'; end$$;
create trigger admin_notification_audit_immutable before update or delete on private.admin_notification_settings_audit for each row execute function private.reject_admin_notification_mutation();
create trigger admin_notification_events_immutable before update or delete on private.admin_notification_events for each row execute function private.reject_admin_notification_mutation();
create trigger admin_notification_reads_immutable before update or delete on private.admin_notification_reads for each row execute function private.reject_admin_notification_mutation();
create trigger admin_notification_read_commands_immutable before update or delete on private.admin_notification_read_commands for each row execute function private.reject_admin_notification_mutation();

create function private.admin_notification_source_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare v_id uuid; v_branch uuid; v_revision text; v_category text; v_template text;
begin
 if tg_table_name='bookings' then
  v_id:=new.id; v_branch:=new.branch_id;
  if tg_op='INSERT' then v_category:='bookings';v_template:='booking_created';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_category:='bookings';v_template:='booking_changed';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new; end if;
 elsif tg_table_name='business_orders' then
  v_id:=new.order_id;v_branch:=new.branch_id;v_category:='cashier';
  if tg_op='INSERT' then v_template:='cashier_payment_review';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_template:='cashier_payment_review';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new; end if;
 elsif tg_table_name='cashier_invoice_postings' then
  v_id:=new.request_id;v_branch:=new.branch_id;v_category:='cashier';v_template:='cashier_payment_review';v_revision:='issued:'||new.created_at::text;
 elsif tg_table_name='business_inventory_movements' then
  if new.after_quantity>0 then return new; end if;
  v_id:=new.movement_id;v_branch:=new.branch_id;v_category:='inventory';v_template:='inventory_zero';v_revision:='zero:'||new.after_quantity::text;
 elsif tg_table_name='business_expenses' then
  v_id:=new.expense_id;v_branch:=new.branch_id;v_category:='expenses';v_template:='expense_recorded';v_revision:='created:'||new.created_at::text;
 elsif tg_table_name='business_document_alerts' then
  v_id:=new.alert_id;v_category:='documents';v_template:='document_expiry';v_revision:='alert:'||new.alert_date::text||':'||new.days_before_expiry::text;
 elsif tg_table_name='customer_complaints' then
  v_id:=new.complaint_id;v_branch:=new.branch_id;v_category:='complaints';
  if tg_op='INSERT' then v_template:='complaint_new';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_template:='complaint_changed';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new; end if;
 elsif tg_table_name='employee_service_reviews' then
  v_id:=new.review_id;v_branch:=new.branch_id;v_category:='reviews';v_template:='review_new';v_revision:='created:'||new.created_at::text;
 elsif tg_table_name='recruitment_applications' then
  v_id:=new.id;v_category:='recruitment';v_template:='recruitment_new';v_revision:='submitted:'||new.submitted_at::text;
  select branch_id into v_branch from private.recruitment_jobs where id=new.job_id;
 elsif tg_table_name='hr_payroll' then
  v_id:=new.id;v_category:='payroll';v_template:='payroll_approved';v_revision:='approved:'||new.approved_at::text;
 elsif tg_table_name='hr_adjustment' then
  v_id:=new.id;v_category:='payroll';v_template:='payroll_adjustment';v_revision:='adjustment:'||new.created_by::text||':'||new.on_date::text;
 else raise exception 'Unsupported notification source' using errcode='22023'; end if;
 perform private.emit_admin_notification(v_category,v_template,tg_table_name,v_id,v_revision,v_branch);
 return new;
end$$;
revoke all on function private.admin_notification_source_trigger(),private.reject_admin_notification_mutation() from public,anon,authenticated,service_role;
create trigger admin_notice_bookings after insert or update of status on public.bookings for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_orders after insert or update of status on public.business_orders for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_invoice_postings after insert on private.cashier_invoice_postings for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_inventory_zero after insert on public.business_inventory_movements for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_expenses after insert on public.business_expenses for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_document_alerts after insert on public.business_document_alerts for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_complaints after insert or update of status on public.customer_complaints for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_reviews after insert on public.employee_service_reviews for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_recruitment after insert on private.recruitment_applications for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_payroll after insert on private.hr_payroll for each row execute function private.admin_notification_source_trigger();
create trigger admin_notice_payroll_adjustments after insert on private.hr_adjustment for each row execute function private.admin_notification_source_trigger();

revoke all on function private.list_admin_notifications(text,boolean,integer),private.mark_admin_notification_read(uuid,uuid),
 private.get_admin_notification_settings(),private.save_admin_notification_setting(text,boolean,text[],integer)
 from public,anon,service_role;
grant execute on function private.list_admin_notifications(text,boolean,integer),private.mark_admin_notification_read(uuid,uuid),
 private.get_admin_notification_settings(),private.save_admin_notification_setting(text,boolean,text[],integer) to authenticated;
create function public.list_admin_notifications(p_category text default null,p_unread_only boolean default false,p_limit integer default 50)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_admin_notifications(p_category,p_unread_only,p_limit)$$;
create function public.mark_admin_notification_read(p_request uuid,p_event uuid)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.mark_admin_notification_read(p_request,p_event)$$;
create function public.get_admin_notification_settings() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_admin_notification_settings()$$;
create function public.save_admin_notification_setting(p_category text,p_enabled boolean,p_roles text[],p_expected_version integer)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_admin_notification_setting(p_category,p_enabled,p_roles,p_expected_version)$$;
revoke all on function public.list_admin_notifications(text,boolean,integer),public.mark_admin_notification_read(uuid,uuid),
 public.get_admin_notification_settings(),public.save_admin_notification_setting(text,boolean,text[],integer) from public,anon,service_role;
grant execute on function public.list_admin_notifications(text,boolean,integer),public.mark_admin_notification_read(uuid,uuid),
 public.get_admin_notification_settings(),public.save_admin_notification_setting(text,boolean,text[],integer) to authenticated;
notify pgrst,'reload schema';
commit;
