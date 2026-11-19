begin;
-- Personal list suppression only. Preserve immutable administrative content/read receipts.
create table private.app_inbox_dismissals(event_id uuid not null references private.app_inbox_events(event_id),actor_id uuid not null references auth.users(id),dismissed_at timestamptz not null default clock_timestamp(),primary key(event_id,actor_id));
create table private.app_inbox_dismiss_requests(actor_id uuid not null references auth.users(id),request_id uuid not null,event_id uuid not null references private.app_inbox_events(event_id),created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id));
alter table private.app_inbox_dismissals enable row level security;
alter table private.app_inbox_dismiss_requests enable row level security;
revoke all on private.app_inbox_dismissals,private.app_inbox_dismiss_requests from public,anon,authenticated,service_role;
create trigger immutable_app_inbox_dismissal before update or delete on private.app_inbox_dismissals for each row execute function private.immutable_app_inbox_read();
create trigger immutable_app_inbox_dismiss_request before update or delete on private.app_inbox_dismiss_requests for each row execute function private.immutable_app_inbox_read();
create function private.dismiss_my_app_inbox_event(p_request uuid,p_event uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();prior private.app_inbox_dismiss_requests;stamp timestamptz;begin
 if p_request is null or p_event is null then raise exception 'Exact dismissal request required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('app-inbox-dismiss:'||actor||':'||p_request,0));
 if not exists(select 1 from private.app_inbox_events e where e.event_id=p_event and e.recipient_kind='customer'and e.recipient_customer_id=actor)then raise exception 'Notification unavailable'using errcode='42501';end if;
 select *into prior from private.app_inbox_dismiss_requests where actor_id=actor and request_id=p_request;
 if found and prior.event_id<>p_event then raise exception 'Immutable dismissal request'using errcode='22023';end if;
 insert into private.app_inbox_dismiss_requests values(actor,p_request,p_event,clock_timestamp())on conflict do nothing;
 insert into private.app_inbox_dismissals(event_id,actor_id)values(p_event,actor)on conflict do nothing;
 select dismissed_at into strict stamp from private.app_inbox_dismissals where event_id=p_event and actor_id=actor;
 if not found then raise exception 'Dismissal not recorded'using errcode='55000';end if;
 if prior.request_id is null then
 begin perform realtime.send(jsonb_build_object('kind','inbox_changed'),'inbox_changed','app-inbox:'||actor::text,true);exception when others then null;end;
 end if;
 return jsonb_build_object('event_id',p_event,'dismissed',true,'dismissed_at',stamp,'administrative_record_preserved',true);
end$$;
create function public.dismiss_my_app_inbox_event(p_request uuid,p_event uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.dismiss_my_app_inbox_event(p_request,p_event)$$;
revoke all on function private.dismiss_my_app_inbox_event(uuid,uuid),public.dismiss_my_app_inbox_event(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.dismiss_my_app_inbox_event(uuid,uuid),public.dismiss_my_app_inbox_event(uuid,uuid)to authenticated;
create or replace function private.list_my_app_inbox(p_before_created_at timestamptz default null,p_before_event uuid default null,p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();owner_pool boolean:=private.active_staff_role()='owner';items jsonb;more boolean;unread bigint;last_item jsonb;begin
 if p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_event is null)then raise exception 'Valid bounded inbox cursor required'using errcode='22023';end if;
 with visible as(select e.*,r.read_at from private.app_inbox_events e left join private.app_inbox_reads r on r.event_id=e.event_id and r.actor_id=actor
 where((e.recipient_kind='customer'and e.recipient_customer_id=actor)or(e.recipient_kind='active_owner_pool'and coalesce(owner_pool,false)))and not exists(select 1 from private.app_inbox_dismissals d where d.event_id=e.event_id and d.actor_id=actor)),
 page as(select * from visible where p_before_created_at is null or(created_at,event_id)<(p_before_created_at,p_before_event)order by created_at desc,event_id desc limit p_limit+1),
 limited as(select * from page order by created_at desc,event_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('event_id',event_id,'source_kind',source_kind,'case_reference',source_case_id,'template_code',template_code,'template_version',template_version,
 'can_dismiss',recipient_kind='customer'and recipient_customer_id=actor,'title_ar',title_ar,'title_en',title_en,'body_ar',body_ar,'body_en',body_en,'created_at',created_at,'read',read_at is not null,'read_at',read_at)order by created_at desc,event_id desc),'[]'::jsonb),(select count(*)>p_limit from page)
 into items,more from limited;
 select count(*)into unread from private.app_inbox_events e where((e.recipient_kind='customer'and e.recipient_customer_id=actor)or(e.recipient_kind='active_owner_pool'and coalesce(owner_pool,false)))
 and not exists(select 1 from private.app_inbox_dismissals d where d.event_id=e.event_id and d.actor_id=actor)
 and not exists(select 1 from private.app_inbox_reads r where r.event_id=e.event_id and r.actor_id=actor);
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'unread_count',unread,'next_cursor',case when more then jsonb_build_object('created_at',last_item->'created_at','event_id',last_item->'event_id')else null end,
 'push_enabled',false,'recovery_workflow_complete',false);
end$$;

notify pgrst,'reload schema';
commit;
