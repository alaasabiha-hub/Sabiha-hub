begin;
-- Signal only. The existing durable inbox/RPC remains the sole content source.
-- Do not alter managed Realtime schema/tables/publications or private inbox grants.
do $$begin
 if to_regprocedure('realtime.send(jsonb,text,text,boolean)')is null or to_regprocedure('realtime.topic()')is null then raise exception 'Installed Realtime database broadcast required'using errcode='55000';end if;
 if not coalesce((select relrowsecurity from pg_class where oid='realtime.messages'::regclass),false)then raise exception 'Realtime message authorization must already use RLS'using errcode='55000';end if;
 -- Reviewed local baseline has zero policies. Refuse silently combining unknown
 -- permissive policies; later applications must review their existing namespace.
 if exists(select 1 from pg_policy where polrelid='realtime.messages'::regclass)then raise exception 'Review existing Realtime policies before inbox hint installation'using errcode='55000';end if;
end$$;
create function private.can_receive_app_inbox_hint(p_topic text)returns boolean
language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if auth.uid()is null or p_topic is distinct from 'app-inbox:'||auth.uid()::text then return false;end if;
 -- Current actual session/Auth/eligible account, not user-editable JWT metadata.
 return private.app_inbox_actor()=auth.uid();
 exception when insufficient_privilege then return false;
end$$;
revoke all on function private.can_receive_app_inbox_hint(text)from public,anon,service_role;
grant execute on function private.can_receive_app_inbox_hint(text)to authenticated;
create policy app_inbox_receive_own_hint on realtime.messages for select to authenticated
 using(extension='broadcast'and topic=(select realtime.topic())and private.can_receive_app_inbox_hint(topic));
-- Restrictive namespace guard also prevents a future permissive authenticated
-- read policy from accidentally opening other actors' app-inbox topics.
create policy app_inbox_guard_private_hint_namespace on realtime.messages as restrictive for select to authenticated
 using(topic not like 'app-inbox:%'or(extension='broadcast'and topic=(select realtime.topic())and private.can_receive_app_inbox_hint(topic)));
create policy app_inbox_no_client_hint_publish on realtime.messages as restrictive for insert to anon,authenticated
 with check(topic not like 'app-inbox:%');
-- No INSERT/publish allow policy and no new Realtime/private-table SELECT grant.

create table private.app_inbox_hint_targets(
 inbox_event_id uuid not null references private.app_inbox_events(event_id),
 recipient_actor_id uuid not null references auth.users(id),
 recipient_kind text not null check(recipient_kind in('customer','active_owner_pool')),
 created_at timestamptz not null default clock_timestamp(),primary key(inbox_event_id,recipient_actor_id));
alter table private.app_inbox_hint_targets enable row level security;
revoke all on private.app_inbox_hint_targets from public,anon,authenticated,service_role;
create function private.guard_app_inbox_hint_target()returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare e private.app_inbox_events;begin
 if tg_op<>'INSERT'then raise exception 'Inbox hint target history is retained'using errcode='55000';end if;
 select *into e from private.app_inbox_events where event_id=new.inbox_event_id;
 if not found or new.recipient_kind is distinct from e.recipient_kind then raise exception 'Actual inbox recipient required'using errcode='55000';end if;
 if not exists(select 1 from auth.users where id=new.recipient_actor_id and deleted_at is null and(banned_until is null or banned_until<=clock_timestamp()))then raise exception 'Current recipient required'using errcode='55000';end if;
 if e.recipient_kind='customer'then
 if new.recipient_actor_id is distinct from e.recipient_customer_id then raise exception 'Exact own customer recipient required'using errcode='55000';end if;
 elsif not exists(select 1 from public.staff_profiles where user_id=new.recipient_actor_id and role='owner'and is_active)then
 raise exception 'Current active owner recipient required'using errcode='55000';end if;
 return new;
end$$;
revoke all on function private.guard_app_inbox_hint_target()from public,anon,authenticated,service_role;
create trigger guard_app_inbox_hint_target before insert or update or delete on private.app_inbox_hint_targets
 for each row execute function private.guard_app_inbox_hint_target();

create function private.dispatch_app_inbox_hint()returns trigger
language plpgsql security definer set search_path=pg_catalog as $$begin
 -- Positional API avoids version-specific argument names. No NEW/OLD row, case
 -- IDs, event IDs, names, phone, email, title, body or counts are broadcast.
 perform realtime.send(jsonb_build_object('kind','inbox_changed'),'inbox_changed','app-inbox:'||new.recipient_actor_id::text,true);
 return new;
 exception when others then
 -- Optional transport must not roll back an otherwise valid durable case/inbox.
 -- Target row records INTENT only. No delivery/success assertion or fake ACK.
 return new;
end$$;
revoke all on function private.dispatch_app_inbox_hint()from public,anon,authenticated,service_role;
create trigger dispatch_app_inbox_hint after insert on private.app_inbox_hint_targets
 for each row execute function private.dispatch_app_inbox_hint();

create function private.append_app_inbox_hint_targets()returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare recipient uuid;begin
 if new.recipient_kind='customer'then
 -- Do not wait on an account being changed/revoked. Durable inbox remains and
 -- reconnect/foreground RPC refresh recovers a skipped best-effort hint.
 for recipient in select u.id from auth.users u where u.id=new.recipient_customer_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())for share of u skip locked loop
 insert into private.app_inbox_hint_targets(inbox_event_id,recipient_actor_id,recipient_kind)values(new.event_id,recipient,'customer')on conflict do nothing;
 end loop;
 else
 -- Never fan out to a historical/shared owner topic. Lock current recipients
 -- against concurrent role/ban changes; skip already-changing accounts.
 for recipient in select s.user_id from public.staff_profiles s join auth.users u on u.id=s.user_id
 where s.role='owner'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())
 order by s.user_id for share of s,u skip locked loop
 insert into private.app_inbox_hint_targets(inbox_event_id,recipient_actor_id,recipient_kind)values(new.event_id,recipient,'active_owner_pool')on conflict do nothing;
 end loop;
 end if;
 return new;
end$$;
revoke all on function private.append_app_inbox_hint_targets()from public,anon,authenticated,service_role;
create trigger append_app_inbox_hint_targets after insert on private.app_inbox_events
 for each row execute function private.append_app_inbox_hint_targets();
-- Existing append helper is unchanged: exact retries return before INSERT,
-- so cannot create duplicate targets or duplicate signals. No historical backfill.
commit;
