begin;
-- Private hints carry no wallet, invoice, amount or balance. Every consumer must re-read the authorized RPC.
do $$begin
 if to_regprocedure('realtime.send(jsonb,text,text,boolean)')is null or not coalesce((select relrowsecurity from pg_class where oid='realtime.messages'::regclass),false)then raise exception 'Existing authorized database broadcast required'using errcode='55000';end if;
end$$;
create function private.can_receive_mixed_points_hint(p_topic text)returns boolean
language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if auth.uid()is null or p_topic is distinct from 'mixed-points:'||auth.uid()::text then return false;end if;
 perform private.require_typed_reward_document_session(null);
 return private.active_staff_role()is null and exists(select 1 from public.customers c join auth.users u on u.id=c.id where c.id=auth.uid()and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp()));
 exception when others then return false;
end$$;
revoke all on function private.can_receive_mixed_points_hint(text)from public,anon,authenticated,service_role;
grant execute on function private.can_receive_mixed_points_hint(text)to authenticated;
create policy mixed_points_receive_own_hint on realtime.messages for select to authenticated using(extension='broadcast'and topic=(select realtime.topic())and private.can_receive_mixed_points_hint(topic));
create policy mixed_points_private_namespace on realtime.messages as restrictive for select to authenticated using(topic not like 'mixed-points:%'or(extension='broadcast'and topic=(select realtime.topic())and private.can_receive_mixed_points_hint(topic)));
create policy mixed_points_no_anon_receive on realtime.messages as restrictive for select to anon using(topic not like 'mixed-points:%');
create policy mixed_points_no_client_publish on realtime.messages as restrictive for insert to anon,authenticated with check(topic not like 'mixed-points:%');
create table private.mixed_points_hint_intents(
 wallet_id uuid not null references private.mixed_points_wallets(wallet_id),recipient_actor_id uuid not null references public.customers(id),
 event_kind text not null check(event_kind in('earned','reserved','released','collected','restored','offset','refund_review','review_decided','link_changed','contact_changed')),
 source_id uuid not null,created_at timestamptz not null default clock_timestamp(),primary key(wallet_id,recipient_actor_id,event_kind,source_id));
alter table private.mixed_points_hint_intents enable row level security;
revoke all on private.mixed_points_hint_intents from public,anon,authenticated,service_role;
create trigger immutable_mixed_points_hint before update or delete on private.mixed_points_hint_intents for each row execute function private.immutable_loyalty_policy();
create function private.dispatch_mixed_points_hint()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 perform realtime.send(jsonb_build_object('kind','mixed_points_changed'),'mixed_points_changed','mixed-points:'||new.recipient_actor_id::text,true);
 return new;
 exception when others then return new; -- Optional transport cannot roll back a valid financial operation. Intent is not delivery proof.
end$$;
create trigger dispatch_private_mixed_points_hint after insert on private.mixed_points_hint_intents for each row execute function private.dispatch_mixed_points_hint();
create function private.queue_mixed_points_hint(p_wallet uuid,p_kind text,p_source uuid,p_scope_actor uuid default null)returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare w private.mixed_points_wallets;begin
 select *into w from private.mixed_points_wallets where wallet_id=p_wallet;if not found then return;end if;
 insert into private.mixed_points_hint_intents(wallet_id,recipient_actor_id,event_kind,source_id)
 select w.wallet_id,c.id,p_kind,p_source from public.customers c join auth.users u on u.id=c.id
 where u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and not exists(select 1 from public.staff_profiles s where s.user_id=c.id and s.is_active)
 and(case when p_scope_actor is not null then c.id=p_scope_actor when w.subject_kind='app_customer'then c.id=w.subject_id else exists(select 1 from private.offline_customer_trusted_links l where l.profile_id=w.subject_id and l.auth_user_id=c.id and l.revoked_at is null and l.contact_hash=private.offline_claim_contact_hash(l.profile_id))end)
 on conflict(wallet_id,recipient_actor_id,event_kind,source_id)do nothing;
end$$;
create function private.mixed_points_ledger_hint()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare wallet uuid;source uuid;kind text;begin
 case tg_table_name
 when'mixed_points_earned_lots'then wallet:=new.wallet_id;source:=new.lot_id;kind:='earned';
 when'mixed_points_reservation_lots'then select wallet_id into wallet from private.mixed_points_reservations where request_id=new.reservation_id;source:=new.reservation_id;kind:='reserved';
 when'mixed_points_reservation_releases'then select wallet_id into wallet from private.mixed_points_reservations where request_id=new.reservation_id;source:=new.request_id;kind:='released';
 when'mixed_points_spend_commits'then select wallet_id into wallet from private.mixed_points_reservations where request_id=new.reservation_id;source:=new.payment_id;kind:='collected';
 when'mixed_points_lot_restorations'then select wallet_id into wallet from private.mixed_points_reservations where request_id=new.reservation_id;source:=new.source_id;kind:='restored';
 when'mixed_points_refund_offsets'then select wallet_id into wallet from private.mixed_points_earned_lots where lot_id=new.lot_id;source:=new.lot_id;kind:='offset';
 when'mixed_points_refund_reviews'then select wallet_id into wallet from private.mixed_points_earned_lots where lot_id=new.lot_id;source:=new.lot_id;kind:='refund_review';
 when'mixed_points_review_decisions'then select wallet_id into wallet from private.mixed_points_earned_lots where lot_id=new.lot_id;source:=new.request_id;kind:='review_decided';
 else return new;end case;
 perform private.queue_mixed_points_hint(wallet,kind,source);return new;
end$$;
do $$declare n text;begin foreach n in array array['mixed_points_earned_lots','mixed_points_reservation_lots','mixed_points_reservation_releases','mixed_points_spend_commits','mixed_points_lot_restorations','mixed_points_refund_offsets','mixed_points_refund_reviews','mixed_points_review_decisions']loop
 execute format('create trigger private_points_changed after insert on private.%I for each row execute function private.mixed_points_ledger_hint()',n);end loop;end$$;
-- Revocation/contact replacement must also clear an already-open old view. This force target comes only from canonical private rows.
create function private.mixed_points_identity_scope_hint()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare w record;recipient uuid;source uuid;kind text;profile uuid;begin
 if tg_table_name='offline_customer_trusted_links'then
 if tg_op='UPDATE'and new.revoked_at is not distinct from old.revoked_at then return new;end if;
 profile:=new.profile_id;recipient:=new.auth_user_id;source:=new.link_id;kind:='link_changed';
 -- Insert and later revocation need distinct idempotency keys without modifying the link UUID.
 if tg_op='UPDATE'then source:=(md5(new.link_id::text||':revoked'))::uuid;end if;
 for w in select wallet_id from private.mixed_points_wallets where subject_kind='offline_profile'and subject_id=profile loop perform private.queue_mixed_points_hint(w.wallet_id,kind,source,recipient);end loop;
 else
 for w in select x.wallet_id,l.auth_user_id from private.mixed_points_wallets x join private.offline_customer_trusted_links l on l.profile_id=x.subject_id and l.revoked_at is null where x.subject_kind='offline_profile'and x.subject_id=new.profile_id loop
 perform private.queue_mixed_points_hint(w.wallet_id,'contact_changed',new.contact_id,w.auth_user_id);end loop;
 end if;return new;
end$$;
create trigger mixed_points_link_scope_changed after insert or update of revoked_at on private.offline_customer_trusted_links for each row execute function private.mixed_points_identity_scope_hint();
create trigger mixed_points_contact_scope_changed after insert on private.offline_customer_contacts for each row execute function private.mixed_points_identity_scope_hint();
revoke all on function private.dispatch_mixed_points_hint(),private.queue_mixed_points_hint(uuid,text,uuid,uuid),private.mixed_points_ledger_hint(),private.mixed_points_identity_scope_hint()from public,anon,authenticated,service_role;
commit;
