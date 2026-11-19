-- SOURCE ONLY. All rows, role changes and managed message inserts ROLLBACK.
-- Requires today's Realtime message partition (established by a real local
-- Realtime connection first). No schema/partition creation or function mocking.
begin;
create function pg_temp.inbox_hint_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
do $$
declare customer uuid;other_customer uuid;owner_actor uuid;case_ref uuid:=gen_random_uuid();customer_source uuid:=gen_random_uuid();owner_source uuid:=gen_random_uuid();
 customer_event uuid;owner_event uuid;temporary_event uuid;former_event uuid;wire_before bigint;targets_before bigint;wire_after bigint;owner_count bigint;visible bigint;denied boolean;
begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and exists(select 1 from auth.sessions s where s.user_id=c.id and(s.not_after is null or s.not_after>clock_timestamp()))order by c.id limit 1;
 select c.id into strict other_customer from public.customers c join auth.users u on u.id=c.id where c.id<>customer and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and exists(select 1 from auth.sessions s where s.user_id=c.id and(s.not_after is null or s.not_after>clock_timestamp()))order by c.id limit 1;
 select p.user_id into strict owner_actor from public.staff_profiles p join auth.users u on u.id=p.user_id where p.role='owner'and p.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and exists(select 1 from auth.sessions s where s.user_id=p.user_id and(s.not_after is null or s.not_after>clock_timestamp()))order by p.user_id limit 1;
 select count(*)into owner_count from public.staff_profiles p join auth.users u on u.id=p.user_id where p.role='owner'and p.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp());
 select count(*)into targets_before from private.app_inbox_hint_targets;
 select count(*)into wire_before from realtime.messages where event='inbox_changed';
 assert not has_table_privilege('authenticated','private.app_inbox_events','SELECT');
 assert not has_table_privilege('authenticated','private.app_inbox_hint_targets','INSERT');
 assert not has_function_privilege('authenticated','private.append_app_inbox_hint_targets()','EXECUTE');
 assert not has_function_privilege('anon','private.can_receive_app_inbox_hint(text)','EXECUTE');
 customer_event:=private.append_visit_recovery_inbox(customer_source,case_ref,'customer',customer,'recovery_received');
 owner_event:=private.append_visit_recovery_inbox(owner_source,case_ref,'active_owner_pool',null,'recovery_submitted');
 assert(select count(*)=1 and bool_and(recipient_actor_id=customer)from private.app_inbox_hint_targets where inbox_event_id=customer_event);
 assert(select count(*)=owner_count from private.app_inbox_hint_targets where inbox_event_id=owner_event);
 assert not exists(select 1 from private.app_inbox_hint_targets t left join public.staff_profiles p on p.user_id=t.recipient_actor_id where t.inbox_event_id=owner_event and(p.user_id is null or p.role<>'owner'or not p.is_active));
 select count(*)into wire_after from realtime.messages where event='inbox_changed';
 assert wire_after=wire_before+owner_count+1,'No actual managed message insert: verify local Realtime daily partition/readiness; do not report delivery';
 -- Application supplies ONLY kind. Installed managed realtime.send adds a
 -- fresh transport UUID id and uses that same UUID for realtime.messages.id.
 -- It is transport metadata, never a case/source/event/actor/business identity.
 assert not exists(select 1 from realtime.messages m where m.event='inbox_changed'and m.topic like'app-inbox:%'
 and(m.id is null or m.payload is distinct from jsonb_build_object('kind','inbox_changed','id',m.id::text)or m.private is distinct from true
 or exists(select 1 from private.app_inbox_events e where m.id=e.event_id or m.id=e.source_event_id or m.id=e.source_case_id or m.id=e.recipient_customer_id)
 or exists(select 1 from private.app_inbox_hint_targets t where m.id=t.inbox_event_id or m.id=t.recipient_actor_id)
 or exists(select 1 from auth.users u where u.id=m.id)));
 -- Existing append retry returns before INSERT; no new targets or signal.
 assert private.append_visit_recovery_inbox(customer_source,case_ref,'customer',customer,'recovery_received')=customer_event;
 assert private.append_visit_recovery_inbox(owner_source,case_ref,'active_owner_pool',null,'recovery_submitted')=owner_event;
 assert(select count(*)from private.app_inbox_hint_targets)=targets_before+owner_count+1;
 assert(select count(*)from realtime.messages where event='inbox_changed')=wire_after;
 -- A rolled-back app action leaves neither durable target nor queued message.
 begin
 temporary_event:=private.append_visit_recovery_inbox(gen_random_uuid(),case_ref,'customer',customer,'recovery_more_info');
 assert exists(select 1 from private.app_inbox_hint_targets where inbox_event_id=temporary_event);
 assert(select count(*)from realtime.messages where event='inbox_changed')=wire_after+1;
 raise exception 'Rollback isolated hint action'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 assert not exists(select 1 from private.app_inbox_hint_targets where inbox_event_id=temporary_event);
 assert(select count(*)from realtime.messages where event='inbox_changed')=wire_after;
 -- Former owner remains excluded even if an old Realtime authorization is cached.
 begin
 update public.staff_profiles set is_active=false where user_id=owner_actor;
 former_event:=private.append_visit_recovery_inbox(gen_random_uuid(),case_ref,'active_owner_pool',null,'recovery_submitted');
 assert not exists(select 1 from private.app_inbox_hint_targets where inbox_event_id=former_event and recipient_actor_id=owner_actor);
 raise exception 'Restore isolated role fixture'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 denied:=false;begin update private.app_inbox_hint_targets set created_at=clock_timestamp()where inbox_event_id=customer_event;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 -- Own private topic only; no table-wide read when topic context is forged.
 perform pg_temp.inbox_hint_actor(customer);perform set_config('realtime.topic','app-inbox:'||customer::text,true);
 execute 'set local role authenticated';
 select count(*)into visible from realtime.messages where event='inbox_changed'and topic='app-inbox:'||customer::text;assert visible>=1;
 assert not exists(select 1 from realtime.messages where topic<>'app-inbox:'||customer::text);
 execute 'reset role';
 perform pg_temp.inbox_hint_actor(other_customer);perform set_config('realtime.topic','app-inbox:'||customer::text,true);
 execute 'set local role authenticated';
 assert not exists(select 1 from realtime.messages where topic='app-inbox:'||customer::text);
 execute 'reset role';
 -- Authenticated clients cannot publish even a correct-looking own-topic hint.
 perform pg_temp.inbox_hint_actor(customer);perform set_config('realtime.topic','app-inbox:'||customer::text,true);
 begin
 execute 'set local role authenticated';
 insert into realtime.messages(topic,extension,event,payload,private)values('app-inbox:'||customer::text,'broadcast','inbox_changed','{"kind":"inbox_changed"}',true);
 execute 'reset role';raise exception 'Unexpected client publish'using errcode='PZ999';
 exception when insufficient_privilege then execute 'reset role';end;
 -- Forged session must not authorize receiving, regardless of UID/topic equality.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'role','authenticated','session_id',gen_random_uuid())::text,true);
 assert not private.can_receive_app_inbox_hint('app-inbox:'||customer::text);
 assert(select count(*)from realtime.messages where event='inbox_changed')=wire_after;
 raise notice 'PASS private own-topic authorization, fixed app kind plus managed transport UUID only, current-owner targets, idempotent append and rollback queue rows; outer ROLLBACK sends nothing committed';
end$$;
rollback;
