begin;
-- In-app transport only. No case/link/financial writers or historical notices.
create function private.app_inbox_template(p_code text) returns jsonb
language plpgsql stable set search_path=pg_catalog as $$
begin
 return case p_code
 when 'recovery_submitted' then jsonb_build_object('title_ar','طلب مراجعة زيارات سابقة','title_en','Previous visits review request','body_ar','يوجد طلب جديد يحتاج مراجعة المالك.','body_en','A new request needs owner review.')
 when 'recovery_received' then jsonb_build_object('title_ar','تم استلام طلبك','title_en','Request received','body_ar','طلب استرجاع زياراتك السابقة في انتظار مطابقة معلوماتك','body_en','Your previous visits recovery request is waiting for information matching.')
 when 'recovery_more_info' then jsonb_build_object('title_ar','معلومات إضافية مطلوبة','title_en','More information needed','body_ar','نحتاج إلى بعض المعلومات الإضافية لاستكمال مطابقة بياناتك. يُرجى مراجعة طلبك داخل التطبيق.','body_en','Open your request to review the information needed to continue.')
 when 'recovery_held' then jsonb_build_object('title_ar','الطلب قيد المراجعة','title_en','Request under review','body_ar','المراجعة لم تكتمل بعد. لا يمنح هذا الإشعار صلاحية عرض السجلات.','body_en','The review is not complete. This notice does not grant access to records.')
 when 'recovery_approved' then jsonb_build_object('title_ar','تمت الموافقة على مراجعة الهوية','title_en','Identity review approved','body_ar','افتح سجل الاستقبال المرتبط للتحقق من السجلات المتاحة. يخضع الوصول للتحقق الحالي والموافقة على نطاق العرض.','body_en','Open linked reception history to check available records. Access still requires current verification and history scope consent.')
 when 'recovery_rejected' then jsonb_build_object('title_ar','لم تتم الموافقة على الطلب','title_en','Request not approved','body_ar','تعذر الموافقة على طلب استرجاع زياراتك السابقة. يمكنك مراجعة حالة الطلب والتواصل مع إدارة المغسلة.','body_en','Open your request to review the outcome. No new record access was granted.')
 when 'recovery_withdrawn' then jsonb_build_object('title_ar','تم سحب الطلب','title_en','Request withdrawn','body_ar','تم تسجيل سحب الطلب. لا يغير هذا الإشعار ملكية السجلات أو الأرصدة.','body_en','The request withdrawal was recorded. This notice does not change record or credit ownership.')
 when 'recovery_access_ended' then jsonb_build_object('title_ar','انتهى الوصول إلى السجلات المرتبطة','title_en','Linked record access ended','body_ar','لم يعد الربط السابق يمنح الوصول. افتح الطلب للتحقق من الحالة الحالية.','body_en','The previous link no longer grants access. Open your request to check its current state.')
 else null end;
end$$;
revoke all on function private.app_inbox_template(text) from public,anon,authenticated,service_role;

create table private.app_inbox_events(
 event_id uuid primary key default gen_random_uuid(),
 source_kind text not null check(source_kind='visit_recovery'),source_event_id uuid not null,source_case_id uuid not null,
 recipient_kind text not null check(recipient_kind in('customer','active_owner_pool')),
 recipient_customer_id uuid references public.customers(id),
 template_code text not null,template_version integer not null check(template_version=1),
 parameters jsonb not null default '{}'::jsonb check(parameters='{}'::jsonb),
 title_ar text not null,title_en text not null,body_ar text not null,body_en text not null,
 created_at timestamptz not null default clock_timestamp(),
 check((recipient_kind='customer'and recipient_customer_id is not null)or(recipient_kind='active_owner_pool'and recipient_customer_id is null)));
create unique index app_inbox_customer_source_once on private.app_inbox_events(source_event_id,recipient_customer_id)where recipient_kind='customer';
create unique index app_inbox_owner_source_once on private.app_inbox_events(source_event_id)where recipient_kind='active_owner_pool';
create index app_inbox_customer_page on private.app_inbox_events(recipient_customer_id,created_at desc,event_id desc)where recipient_kind='customer';
create index app_inbox_owner_page on private.app_inbox_events(created_at desc,event_id desc)where recipient_kind='active_owner_pool';
create table private.app_inbox_reads(
 event_id uuid not null references private.app_inbox_events(event_id),actor_id uuid not null references auth.users(id),
 read_at timestamptz not null default clock_timestamp(),primary key(event_id,actor_id));
create index app_inbox_actor_reads on private.app_inbox_reads(actor_id,event_id);
create table private.app_inbox_read_requests(
 actor_id uuid not null references auth.users(id),request_id uuid not null,event_id uuid not null references private.app_inbox_events(event_id),
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id));
alter table private.app_inbox_events enable row level security;
alter table private.app_inbox_reads enable row level security;
alter table private.app_inbox_read_requests enable row level security;
revoke all on private.app_inbox_events,private.app_inbox_reads,private.app_inbox_read_requests from public,anon,authenticated,service_role;

create function private.guard_app_inbox_event()returns trigger language plpgsql set search_path=pg_catalog as $$
declare t jsonb;begin
 if tg_op<>'INSERT'then raise exception 'Inbox events are immutable'using errcode='55000';end if;
 t:=private.app_inbox_template(new.template_code);
 if t is null or new.title_ar is distinct from t->>'title_ar'or new.title_en is distinct from t->>'title_en'
 or new.body_ar is distinct from t->>'body_ar'or new.body_en is distinct from t->>'body_en'then
 raise exception 'Only fixed inbox templates are permitted'using errcode='22023';end if;
 return new;
end$$;
create function private.immutable_app_inbox_read()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 raise exception 'Inbox read receipts and request identities are retained'using errcode='55000';end$$;
revoke all on function private.guard_app_inbox_event(),private.immutable_app_inbox_read()from public,anon,authenticated,service_role;
create trigger guard_app_inbox_event before insert or update or delete on private.app_inbox_events for each row execute function private.guard_app_inbox_event();
create trigger immutable_app_inbox_read before update or delete on private.app_inbox_reads for each row execute function private.immutable_app_inbox_read();
create trigger immutable_app_inbox_read_request before update or delete on private.app_inbox_read_requests for each row execute function private.immutable_app_inbox_read();

-- Internal only: future same-transaction case/canonical hooks call this helper.
-- No public event creator, secret/PII parameters, push, webhook or table grant.
create function private.append_visit_recovery_inbox(p_source_event uuid,p_case uuid,p_recipient_kind text,p_customer uuid,p_template text)
returns uuid language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare e private.app_inbox_events;t jsonb;begin
 if p_source_event is null or p_case is null or p_recipient_kind is null or p_recipient_kind not in('customer','active_owner_pool')
 or(p_recipient_kind='customer'and p_customer is null)or(p_recipient_kind='active_owner_pool'and p_customer is not null)then
 raise exception 'Exact source and recipient required'using errcode='22023';end if;
 t:=private.app_inbox_template(p_template);
 if t is null then raise exception 'Supported fixed template required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('app-inbox-event:'||p_source_event::text||':'||p_recipient_kind||':'||coalesce(p_customer::text,'owner_pool'),0));
 select * into e from private.app_inbox_events where source_event_id=p_source_event and recipient_kind=p_recipient_kind and recipient_customer_id is not distinct from p_customer;
 if found then
 if e.source_case_id<>p_case or e.template_code<>p_template then raise exception 'Inbox source identity reused with different fields'using errcode='22023';end if;
 return e.event_id;
 end if;
 insert into private.app_inbox_events(source_kind,source_event_id,source_case_id,recipient_kind,recipient_customer_id,template_code,template_version,title_ar,title_en,body_ar,body_en)
 values('visit_recovery',p_source_event,p_case,p_recipient_kind,p_customer,p_template,1,t->>'title_ar',t->>'title_en',t->>'body_ar',t->>'body_en')returning event_id into e.event_id;
 return e.event_id;
end$$;
revoke all on function private.append_visit_recovery_inbox(uuid,uuid,text,uuid,text)from public,anon,authenticated,service_role;

create function private.app_inbox_actor()returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid();sid uuid;begin
 begin sid:=(auth.jwt()->>'session_id')::uuid;exception when invalid_text_representation then raise exception 'Inbox unavailable'using errcode='42501';end;
 if actor is null or sid is null then raise exception 'Inbox unavailable'using errcode='42501';end if;
 perform 1 from auth.users u join auth.sessions s on s.user_id=u.id where u.id=actor and s.id=sid and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(s.not_after is null or s.not_after>clock_timestamp())for share of u,s;
 if not found then raise exception 'Inbox unavailable'using errcode='42501';end if;
 perform 1 from public.staff_profiles where user_id=actor for share;
 if not exists(select 1 from public.customers c where c.id=actor)and private.active_staff_role()is distinct from'owner'then
 raise exception 'Inbox unavailable'using errcode='42501';end if;
 return actor;
end$$;
revoke all on function private.app_inbox_actor()from public,anon,authenticated,service_role;

create function private.list_my_app_inbox(p_before_created_at timestamptz default null,p_before_event uuid default null,p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();owner_pool boolean:=private.active_staff_role()='owner';items jsonb;more boolean;unread bigint;last_item jsonb;begin
 if p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_event is null)then raise exception 'Valid bounded inbox cursor required'using errcode='22023';end if;
 with visible as(select e.*,r.read_at from private.app_inbox_events e left join private.app_inbox_reads r on r.event_id=e.event_id and r.actor_id=actor
 where(e.recipient_kind='customer'and e.recipient_customer_id=actor)or(e.recipient_kind='active_owner_pool'and coalesce(owner_pool,false))),
 page as(select * from visible where p_before_created_at is null or(created_at,event_id)<(p_before_created_at,p_before_event)order by created_at desc,event_id desc limit p_limit+1),
 limited as(select * from page order by created_at desc,event_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('event_id',event_id,'source_kind',source_kind,'case_reference',source_case_id,'template_code',template_code,'template_version',template_version,
 'title_ar',title_ar,'title_en',title_en,'body_ar',body_ar,'body_en',body_en,'created_at',created_at,'read',read_at is not null,'read_at',read_at)order by created_at desc,event_id desc),'[]'::jsonb),(select count(*)>p_limit from page)
 into items,more from limited;
 select count(*)into unread from private.app_inbox_events e where((e.recipient_kind='customer'and e.recipient_customer_id=actor)or(e.recipient_kind='active_owner_pool'and coalesce(owner_pool,false)))
 and not exists(select 1 from private.app_inbox_reads r where r.event_id=e.event_id and r.actor_id=actor);
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'unread_count',unread,'next_cursor',case when more then jsonb_build_object('created_at',last_item->'created_at','event_id',last_item->'event_id')else null end,
 'push_enabled',false,'recovery_workflow_complete',false);
end$$;

create function private.mark_my_app_inbox_read(p_request uuid,p_event uuid)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid:=private.app_inbox_actor();prior private.app_inbox_read_requests;stamp timestamptz;begin
 if p_request is null or p_event is null then raise exception 'Stable read request and event required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('app-inbox-read:'||actor::text||':'||p_request::text,0));
 -- Recheck AFTER any nonce wait, including exact replay; past owner access is not permanent.
 perform private.app_inbox_actor();
 if not exists(select 1 from private.app_inbox_events e where e.event_id=p_event and((e.recipient_kind='customer'and e.recipient_customer_id=actor)or(e.recipient_kind='active_owner_pool'and private.active_staff_role()='owner')))then
 raise exception 'Inbox event unavailable'using errcode='42501';end if;
 select * into prior from private.app_inbox_read_requests where actor_id=actor and request_id=p_request;
 if found and prior.event_id<>p_event then raise exception 'Read request reused for a different event'using errcode='22023';end if;
 insert into private.app_inbox_reads(event_id,actor_id)values(p_event,actor)on conflict(event_id,actor_id)do nothing;
 insert into private.app_inbox_read_requests(actor_id,request_id,event_id)values(actor,p_request,p_event)on conflict(actor_id,request_id)do nothing;
 select read_at into strict stamp from private.app_inbox_reads where event_id=p_event and actor_id=actor;
 return jsonb_build_object('event_id',p_event,'read',true,'read_at',stamp);
end$$;
revoke all on function private.list_my_app_inbox(timestamptz,uuid,integer),private.mark_my_app_inbox_read(uuid,uuid)from public,anon,service_role;
grant execute on function private.list_my_app_inbox(timestamptz,uuid,integer),private.mark_my_app_inbox_read(uuid,uuid)to authenticated;
create function public.list_my_app_inbox(p_before_created_at timestamptz default null,p_before_event uuid default null,p_limit integer default 25)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_my_app_inbox(p_before_created_at,p_before_event,p_limit)$$;
create function public.mark_my_app_inbox_read(p_request uuid,p_event uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.mark_my_app_inbox_read(p_request,p_event)$$;
revoke all on function public.list_my_app_inbox(timestamptz,uuid,integer),public.mark_my_app_inbox_read(uuid,uuid)from public,anon,service_role;
grant execute on function public.list_my_app_inbox(timestamptz,uuid,integer),public.mark_my_app_inbox_read(uuid,uuid)to authenticated;
notify pgrst,'reload schema';
commit;
