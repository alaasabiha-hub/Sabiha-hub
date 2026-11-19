begin;
-- Bundle A. Stays fenced until bundle B installs the complete private creator.
create table private.offline_reward_issuer_runtime(singleton boolean primary key default true check(singleton),kernel_installed boolean not null default false,public_enabled boolean not null default false check(not public_enabled));
insert into private.offline_reward_issuer_runtime values(true,false,false);
create table private.offline_reward_issue_commands(
 request_id uuid primary key,operator_id uuid not null references auth.users(id),preparation_id uuid references private.offline_reward_consumption_preparations(request_id),
 consent_request_id uuid references private.offline_reward_financial_consents(request_id),payload jsonb,
 state text not null check(state in('prepared','issued','closed')),redemption_id uuid unique,result jsonb,
 created_at timestamptz not null default clock_timestamp(),resolved_at timestamptz,acknowledged_at timestamptz,
 check((state='prepared'and payload is not null and preparation_id is not null and consent_request_id is not null and redemption_id is null and result is null and resolved_at is null)
 or(state='issued'and payload is not null and preparation_id is not null and consent_request_id is not null and redemption_id is not null and result is not null and resolved_at is not null)
 or(state='closed'and redemption_id is null and resolved_at is not null)));
create unique index offline_reward_consent_used_once on private.offline_reward_issue_commands(consent_request_id)where state='issued';
create unique index offline_reward_preparation_used_once on private.offline_reward_issue_commands(preparation_id)where state='issued';
create table private.offline_reward_issue_events(event_key text primary key,request_id uuid references private.offline_reward_issue_commands(request_id),redemption_id uuid references private.service_reward_redemptions(redemption_id)deferrable initially deferred,
 profile_id uuid not null references private.offline_customer_profiles(profile_id),action text not null check(action in('consume','restore','forfeit','refund_review','offset','ack')),actor_id uuid not null references auth.users(id),data jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create index offline_reward_completed_work_clock on private.service_work_ledger(order_id,created_at,event_id)where target_kind='order'and next_status='completed';
create index offline_reward_issue_event_receipt on private.offline_reward_issue_events(redemption_id,creator_xid,action);
create index offline_reward_active_claim_owner on private.reward_credit_claims(offline_profile_id,earning_id)where owner_kind='offline_profile'and released_at is null;
create index offline_reward_review_owner on private.reward_refund_reviews(offline_profile_id,created_at)where owner_kind='offline_profile';
alter table private.offline_reward_issue_commands add foreign key(redemption_id)references private.service_reward_redemptions(redemption_id)deferrable initially deferred;
alter table private.offline_walk_in_subjects add column reward_issue_id uuid unique references private.offline_reward_issue_commands(request_id);
alter table private.service_reward_redemptions add column offline_issue_id uuid unique references private.offline_reward_issue_commands(request_id);
alter table private.reward_ledger_events add column offline_creator_xid bigint;
alter table private.offline_reward_reservation_commands drop constraint offline_reward_reservation_commands_state_check;
alter table private.offline_reward_reservation_commands add constraint offline_reward_reservation_commands_state_check check(state in('preparing','active','released','expired','refunded','consumed'));
alter table private.offline_reward_reservation_events drop constraint offline_reward_reservation_events_action_check;
alter table private.offline_reward_reservation_events add constraint offline_reward_reservation_events_action_check check(action in('reserve','released','expired','refunded','consumed'));
do $$declare t text;begin foreach t in array array['offline_reward_issuer_runtime','offline_reward_issue_commands','offline_reward_issue_events']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_offline_reward_issue_event before update or delete on private.offline_reward_issue_events for each row execute function private.immutable_canonical_visit();
create function private.guard_offline_reward_issue_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Issue commands retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['state','redemption_id','result','resolved_at','acknowledged_at'])is distinct from(to_jsonb(old)-array['state','redemption_id','result','resolved_at','acknowledged_at'])then raise exception 'Exact issue payload and operator immutable'using errcode='55000';end if;
 if old.state='prepared'and new.state in('issued','closed')and new.resolved_at is not null and new.acknowledged_at is null then return new;end if;
 if old.state in('issued','closed')and(to_jsonb(new)-'acknowledged_at')=(to_jsonb(old)-'acknowledged_at')and(old.acknowledged_at is null or new.acknowledged_at=old.acknowledged_at)then return new;end if;
 raise exception 'Resolved issue command cannot change'using errcode='55000';end$$;
create trigger guard_offline_reward_issue_command before update or delete on private.offline_reward_issue_commands for each row execute function private.guard_offline_reward_issue_command();

-- Receipt-level proof used by DEFERRED guards, never a client-supplied boolean.
create function private.offline_reward_receipt_coherent(p_redemption uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;i public.business_invoices;s private.offline_walk_in_subjects;c private.offline_reward_issue_commands;p private.offline_reward_consumption_preparations;a private.offline_reward_financial_consents;v_ids uuid[];v_expected uuid[];v_total integer;
begin
 select *into d from private.service_reward_redemptions where redemption_id=p_redemption;
 if d.redemption_id is null or d.owner_kind<>'offline_profile'or d.customer_id is not null or d.booking_id is not null or d.source_channel<>'walk_in'then return false;end if;
 select *into c from private.offline_reward_issue_commands where request_id=d.offline_issue_id;
 select *into p from private.offline_reward_consumption_preparations where request_id=c.preparation_id;
 select *into a from private.offline_reward_financial_consents where request_id=c.consent_request_id;
 select *into q from private.service_reward_quotes where quote_id=d.quote_id;
 select *into i from public.business_invoices where invoice_id=d.invoice_id;
 select *into s from private.offline_walk_in_subjects where order_id=d.order_id;
 if c.state is distinct from'issued'or c.redemption_id is distinct from d.redemption_id or c.operator_id is distinct from d.requested_by or c.request_id is distinct from d.request_id
 or q.owner_kind is distinct from'offline_profile'or q.customer_id is not null or q.offline_profile_id is distinct from d.offline_profile_id or q.offline_channel_version_id is distinct from d.offline_channel_version_id
 or p.offline_profile_id is distinct from d.offline_profile_id or p.reservation_id is distinct from q.reserve_request_id or(p.witness->>'quote_id')::uuid is distinct from q.quote_id
 or a.request_id is null or a.proposal_id::text is distinct from d.consent->>'proposal_id'or a.fingerprint is distinct from d.consent->>'financial_fingerprint'
 or a.actor_id::text is distinct from d.consent->>'customer_id'or a.request_id::text is distinct from d.consent->>'financial_consent_request_id'
 or d.consent->'accept_terms'is distinct from'true'::jsonb or d.rules_version_id is distinct from q.rules_version_id or d.policy_version_id is distinct from q.policy_version_id
 or d.branch_id is distinct from q.branch_id or i.invoice_id is null or i.order_id is distinct from d.order_id or i.branch_id is distinct from d.branch_id
 or i.total<>0 or i.discount is distinct from q.gross_amount or i.reward_snapshot is distinct from d.coverage_snapshot or i.payment_method<>'reward_coverage'
 or s.reward_issue_id is distinct from d.offline_issue_id or s.invoice_id is distinct from d.invoice_id or s.profile_id is distinct from d.offline_profile_id or s.car_ref_id is distinct from q.offline_car_ref_id
 or s.gross is distinct from q.gross_amount or s.service_id is distinct from q.service_id
 or not exists(select 1 from public.business_orders o where o.order_id=d.order_id and o.customer_id is null and o.booking_id is null and o.branch_id=d.branch_id and o.order_type='service'and o.assigned_staff_ids=s.staff_ids)
 or exists(select 1 from public.business_payment_events where invoice_id=d.invoice_id)
 or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id and redemption_id=d.redemption_id)
 or not exists(select 1 from private.offline_reward_issue_events e where e.event_key='consume:'||d.redemption_id and e.redemption_id=d.redemption_id and e.request_id=c.request_id and e.profile_id=d.offline_profile_id and e.action='consume'
 and e.data->>'consent_request_id'=a.request_id::text and(e.data->>'authorized_xid')::bigint=e.creator_xid)
 or not exists(select 1 from private.offline_reward_reservation_commands where request_id=q.reserve_request_id and state='consumed')then return false;end if;
 select array_agg(h.earning_id order by h.earning_id),count(*)into v_ids,v_total from private.reward_credit_claims h where h.redemption_id=d.redemption_id and h.kind='reward'and h.quote_id=q.quote_id
 and h.owner_kind='offline_profile'and h.offline_profile_id=d.offline_profile_id and h.offline_channel_version_id=d.offline_channel_version_id and(d.state='restored'or h.released_at is null);
 select array_agg(x order by x)into v_expected from unnest(q.earning_ids)x;
 if v_total<>q.threshold_visits or v_ids is distinct from v_expected then return false;end if;
 if d.state='covered'then return i.status='active';end if;
 return d.state in('restored','forfeited')and i.status='void'and exists(select 1 from public.business_orders where order_id=d.order_id and status='cancelled');
end$$;
create function private.check_offline_reward_receipt_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare v_redemption uuid;v_new jsonb:=to_jsonb(new);begin
 if tg_relid not in('private.service_reward_redemptions'::regclass,'private.offline_reward_issue_commands'::regclass,'public.business_invoices'::regclass)or jsonb_typeof(v_new)is distinct from'object'then raise exception 'Unexpected reward receipt trigger relation'using errcode='55000';end if;
 if tg_table_name='service_reward_redemptions'then if ((v_new->>'owner_kind')::text)<>'offline_profile'then return new;end if;v_redemption:=((v_new->>'redemption_id')::uuid);
 elsif tg_table_name='offline_reward_issue_commands'then if ((v_new->>'state')::text)<>'issued'then return new;end if;v_redemption:=((v_new->>'redemption_id')::uuid);
 else select redemption_id into v_redemption from private.service_reward_redemptions where invoice_id=((v_new->>'invoice_id')::text) and owner_kind='offline_profile';if not found then return new;end if;end if;
 if not coalesce(private.offline_reward_receipt_coherent(v_redemption),false)then raise exception 'Complete typed reward invoice/claim/consent receipt required at commit'using errcode='55000';end if;return new;
end$$;
create constraint trigger offline_reward_receipt_commit after insert or update on private.service_reward_redemptions deferrable initially deferred for each row execute function private.check_offline_reward_receipt_commit();
create constraint trigger offline_reward_command_commit after insert or update on private.offline_reward_issue_commands deferrable initially deferred for each row execute function private.check_offline_reward_receipt_commit();
create constraint trigger offline_reward_invoice_commit after insert or update on public.business_invoices deferrable initially deferred for each row execute function private.check_offline_reward_receipt_commit();

create function private.guard_typed_offline_reward_claim(p_old private.reward_credit_claims,p_new private.reward_credit_claims,p_operation text)returns private.reward_credit_claims language plpgsql volatile security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;d private.service_reward_redemptions;q private.service_reward_quotes;r private.reward_refund_reviews;
begin
 if p_operation='UPDATE'then
 if(to_jsonb(p_new)-'released_at')is distinct from(to_jsonb(p_old)-'released_at')or p_old.released_at is not null or p_new.released_at is null then raise exception 'Only one-way typed claim release allowed'using errcode='55000';end if;
 if p_old.kind='reserve'then
 if exists(select 1 from private.offline_reward_reservation_events event where event.request_id=p_old.reserve_request_id and event.creator_xid=txid_current()and event.action in('released','expired','refunded'))then return p_new;end if;
 if exists(select 1 from private.offline_reward_issue_events event join private.service_reward_redemptions receipt on receipt.redemption_id=event.redemption_id where event.action='consume'and event.creator_xid=txid_current()and event.profile_id=p_old.offline_profile_id and receipt.quote_id=p_old.quote_id and receipt.offline_profile_id=p_old.offline_profile_id)then return p_new;end if;
 else
 select *into d from private.service_reward_redemptions where redemption_id=coalesce(p_old.redemption_id,(select redemption_id from private.reward_refund_reviews where review_id=p_old.debt_id));
 if exists(select 1 from private.offline_reward_issue_events event where event.redemption_id=d.redemption_id and event.action='restore'and event.creator_xid=txid_current()and event.profile_id=p_old.offline_profile_id)then return p_new;end if;
 end if;raise exception 'Typed release requires exact same-transaction event witness'using errcode='55000';end if;
 if p_new.kind='reserve'then raise exception 'Reserve must use accepted reservation guard'using errcode='55000';end if;
 if not exists(select 1 from private.offline_reward_issuer_runtime where singleton and kernel_installed)then raise exception 'Typed issuer kernel not installed'using errcode='55000';end if;
 select *into e from private.canonical_loyalty_visits where id=p_new.earning_id and kind='earn'and source_channel='offline_walk_in'and customer_id is null and offline_profile_id=p_new.offline_profile_id;
 if e.id is null or p_new.customer_id is not null or private.reward_credit_refund(e.id)is not null
 or exists(select 1 from private.canonical_loyalty_visits where reverses_earning=e.id and kind='refund')then raise exception 'Actual same-owner unrefunded typed earning required'using errcode='55000';end if;
 if p_new.kind='reward'then
 select *into d from private.service_reward_redemptions where redemption_id=p_new.redemption_id;
 select *into q from private.service_reward_quotes where quote_id=p_new.quote_id;
 if d.offline_profile_id is distinct from p_new.offline_profile_id or d.quote_id is distinct from q.quote_id or d.offline_channel_version_id is distinct from p_new.offline_channel_version_id
 or not(p_new.earning_id=any(q.earning_ids))or q.expires_at<=clock_timestamp()
 or not exists(select 1 from private.offline_reward_issue_events event where event.redemption_id=d.redemption_id and event.action='consume'and event.creator_xid=txid_current()and event.profile_id=p_new.offline_profile_id)
 then raise exception 'Exact typed consumption receipt required'using errcode='55000';end if;
 elsif p_new.kind='offset'then
 select *into r from private.reward_refund_reviews where review_id=p_new.debt_id;
 select *into q from private.service_reward_quotes where quote_id=(select quote_id from private.service_reward_redemptions where redemption_id=r.redemption_id);
 if r.offline_profile_id is distinct from p_new.offline_profile_id or r.offline_channel_version_id is distinct from p_new.offline_channel_version_id or r.closed_at is not null or r.branch_id<>e.branch_id
 or r.offer_id is distinct from(select offer_id from private.loyalty_policy_versions where version_id=e.policy_version_id)
 or not exists(select 1 from private.offline_reward_issue_events event where event.event_key='offset:'||r.review_id||':'||e.id and event.creator_xid=txid_current()and event.profile_id=p_new.offline_profile_id)
 then raise exception 'Exact typed offset debt witness required'using errcode='55000';end if;
 else raise exception 'Unsupported typed claim kind'using errcode='55000';end if;return p_new;
end$$;

-- Existing Auth branches preserved verbatim; scoped offline dispatch only.
create or replace function private.guard_reward_claim() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;q private.service_reward_quotes;
begin
 if tg_op='DELETE' then raise exception 'Reward claim history cannot be deleted';end if;
 if new.owner_kind='offline_profile'and(tg_op='UPDATE'or new.kind<>'reserve')then return private.guard_typed_offline_reward_claim(case when tg_op='UPDATE'then old else null::private.reward_credit_claims end,new,tg_op);end if;
 if new.owner_kind='offline_profile'or(tg_op='UPDATE'and old.owner_kind='offline_profile')then
 if tg_op='UPDATE'then
 if(to_jsonb(new)-'released_at')is distinct from(to_jsonb(old)-'released_at')or old.kind<>'reserve'or old.released_at is not null or new.released_at is null
 or not exists(select 1 from private.offline_reward_reservation_events event where event.request_id=old.reserve_request_id and event.action in('released','expired','refunded')and event.creator_xid=txid_current())then raise exception 'Only audited one-way offline hold release allowed'using errcode='55000';end if;return new;end if;
 select *into q from private.service_reward_quotes where quote_id=new.quote_id;
 if new.kind<>'reserve'or q.owner_kind is distinct from'offline_profile'or q.offline_profile_id is distinct from new.offline_profile_id or q.offline_channel_version_id is distinct from new.offline_channel_version_id or q.reserve_request_id is distinct from new.reserve_request_id
 or q.expires_at<=clock_timestamp()or new.hold_expires_at is distinct from q.expires_at or not(new.earning_id=any(q.earning_ids))
 or not exists(select 1 from private.reward_owner_candidate_lots('offline_profile',new.offline_profile_id,q.rules_version_id,q.offline_channel_version_id)lot where lot.earning_id=new.earning_id and exists(select 1 from jsonb_array_elements(q.allocation_snapshot)item where(item->>'earning_id')::uuid=lot.earning_id and item->'credit_terms'=lot.credit_terms))then raise exception 'Actual same-owner unrefunded original-cohort hold required'using errcode='55000';end if;
 return new;end if;
 if new.customer_id is null or new.owner_kind<>'auth_customer'then raise exception 'Explicit Auth owner required'using errcode='55000';end if;

 if tg_op='UPDATE' then
 if(to_jsonb(new)-'released_at') is distinct from(to_jsonb(old)-'released_at') or(old.released_at is not null and new.released_at is distinct from old.released_at) or(old.released_at is null and new.released_at is null) then raise exception 'Only one-way claim release is allowed';end if;return new;end if;
 select * into e from private.canonical_loyalty_visits where id=new.earning_id and kind='earn';
 if e.id is null or e.customer_id is distinct from new.customer_id or private.reward_credit_refund(e.id) is not null then raise exception 'Actual own unrefunded earning required';end if;
 if new.kind='reward' and not exists(select 1 from private.service_reward_redemptions d where d.redemption_id=new.redemption_id and d.quote_id=new.quote_id and d.customer_id=new.customer_id) then raise exception 'Claim redemption association mismatch';end if;
 if new.kind='offset' and not exists(select 1 from private.reward_refund_reviews r join private.loyalty_policy_versions p on p.version_id=e.policy_version_id where r.review_id=new.debt_id and r.customer_id=e.customer_id and r.branch_id=e.branch_id and r.offer_id=p.offer_id and r.closed_at is null) then raise exception 'Offset debt association mismatch';end if;
 return new;
end $$;
create or replace function private.block_offline_reward_claim_until_typed_allocator()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.owner_kind='offline_profile'and new.kind in('reward','offset')and exists(select 1 from private.offline_reward_issuer_runtime where singleton and kernel_installed)then return new;end if;
 if exists(select 1 from private.canonical_loyalty_visits where id=new.earning_id and source_channel='offline_walk_in')then
 if new.owner_kind<>'offline_profile'or new.kind<>'reserve'or not exists(select 1 from private.offline_reward_reservation_commands c where c.request_id=new.reserve_request_id and c.offline_profile_id=new.offline_profile_id and c.quote_id=new.quote_id and c.state='preparing'and c.creator_xid=txid_current())then raise exception 'Only internal typed offline reserve proof is installed'using errcode='55000';end if;end if;return new;end$$;
create or replace function private.fence_unimplemented_offline_reward_entities()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_new jsonb:=to_jsonb(new);v_old jsonb:='{}'::jsonb;
begin
 if tg_op='UPDATE'then v_old:=to_jsonb(old);end if;
 if tg_relid not in('private.service_reward_redemptions'::regclass,'private.reward_refund_reviews'::regclass)or jsonb_typeof(v_new)is distinct from'object'or not(v_new?&array['owner_kind','customer_id','offline_profile_id','offline_channel_version_id'])then raise exception 'Unexpected typed reward fence relation'using errcode='55000';end if;
 if tg_op='UPDATE'and ((v_old->>'owner_kind')::text)='offline_profile'and(((v_new->>'owner_kind')::text) is distinct from ((v_old->>'owner_kind')::text) or ((v_new->>'customer_id')::uuid) is distinct from ((v_old->>'customer_id')::uuid) or ((v_new->>'offline_profile_id')::uuid) is distinct from ((v_old->>'offline_profile_id')::uuid) or ((v_new->>'offline_channel_version_id')::uuid) is distinct from ((v_old->>'offline_channel_version_id')::uuid))then raise exception 'Typed owner evidence immutable'using errcode='55000';end if;
 if ((v_new->>'owner_kind')::text)='auth_customer'and ((v_new->>'customer_id')::uuid) is not null then return new;end if;
 if ((v_new->>'owner_kind')::text)is distinct from'offline_profile'or ((v_new->>'customer_id')::uuid) is not null or not exists(select 1 from private.offline_reward_issuer_runtime where singleton and kernel_installed)then raise exception 'Offline issuer bundle not installed'using errcode='55000';end if;
 if tg_table_name='service_reward_redemptions'then
 if tg_op='INSERT'then
 if ((v_new->>'creator_xid')::bigint)<>txid_current()or ((v_new->>'booking_id')::uuid) is not null or ((v_new->>'source_channel')::text)<>'walk_in'
 or not exists(select 1 from private.offline_reward_issue_commands cmd join private.offline_reward_issue_events event on event.request_id=cmd.request_id where cmd.request_id=((v_new->>'offline_issue_id')::uuid) and cmd.state='prepared'and cmd.operator_id=auth.uid()and event.redemption_id=((v_new->>'redemption_id')::uuid) and event.profile_id=((v_new->>'offline_profile_id')::uuid) and event.action='consume'and event.creator_xid=txid_current())then raise exception 'Actual same-transaction offline issuance proof required'using errcode='55000';end if;
 else
 if ((v_new->>'state')::text) is distinct from ((v_old->>'state')::text) and not exists(select 1 from private.offline_reward_issue_events event where event.redemption_id=((v_new->>'redemption_id')::uuid) and event.profile_id=((v_new->>'offline_profile_id')::uuid) and event.creator_xid=txid_current()and event.action=case ((v_new->>'state')::text) when'restored'then'restore'when'forfeited'then'forfeit'end)then raise exception 'Audited typed cancellation required'using errcode='55000';end if;
 end if;
 else
 if tg_op='INSERT'then
 if private.reward_credit_refund(((v_new->>'earning_id')::uuid))is distinct from ((v_new->>'refund_payment_id')::uuid)
 or not exists(select 1 from private.reward_credit_claims claim join private.service_reward_redemptions receipt on receipt.redemption_id=claim.redemption_id where claim.claim_id=((v_new->>'original_claim_id')::uuid) and claim.earning_id=((v_new->>'earning_id')::uuid) and claim.offline_profile_id=((v_new->>'offline_profile_id')::uuid) and receipt.redemption_id=((v_new->>'redemption_id')::uuid) and receipt.state in('covered','forfeited'))
 or not exists(select 1 from private.offline_reward_issue_events event where event.event_key='review:'||((v_new->>'original_claim_id')::uuid)||':'||((v_new->>'refund_payment_id')::uuid) and event.creator_xid=txid_current()and event.profile_id=((v_new->>'offline_profile_id')::uuid))then raise exception 'Actual typed consumed-source refund witness required'using errcode='55000';end if;
 elsif(v_new-array['acknowledged_at','acknowledged_by','closed_at'])is distinct from(v_old-array['acknowledged_at','acknowledged_by','closed_at'])
 or(((v_old->>'acknowledged_at')::timestamptz) is not null and ((v_new->>'acknowledged_at')::timestamptz) is distinct from ((v_old->>'acknowledged_at')::timestamptz))or(((v_old->>'closed_at')::timestamptz) is not null and ((v_new->>'closed_at')::timestamptz) is distinct from ((v_old->>'closed_at')::timestamptz))
 or not exists(select 1 from private.offline_reward_issue_events event where event.redemption_id=((v_new->>'redemption_id')::uuid) and event.profile_id=((v_new->>'offline_profile_id')::uuid) and event.creator_xid=txid_current()and event.action in('ack','restore'))then raise exception 'One-way audited typed refund review resolution required'using errcode='55000';end if;
 end if;return new;
end$$;
create or replace function private.guard_offline_reservation_command()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Reservation command retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['state','result'])is distinct from(to_jsonb(old)-array['state','result'])or old.state not in('preparing','active')
 or(old.state='preparing'and(new.state<>'active'or old.creator_xid<>txid_current()))or(old.state='active'and new.state not in('released','expired','refunded','consumed'))then raise exception 'Only canonical reservation transitions allowed'using errcode='55000';end if;
 if new.state='consumed'and not exists(select 1 from private.offline_reward_issue_events event join private.service_reward_redemptions receipt on receipt.redemption_id=event.redemption_id where receipt.quote_id=old.quote_id and event.profile_id=old.offline_profile_id and event.action='consume'and event.creator_xid=txid_current())then raise exception 'Same-transaction consumed receipt required'using errcode='55000';end if;
 return new;end$$;
create or replace function private.check_offline_reservation_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;n integer;d uuid;
begin
 select *into c from private.offline_reward_reservation_commands where request_id=new.request_id;select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 select count(distinct earning_id)into n from private.reward_credit_claims where reserve_request_id=c.request_id and released_at is null;
 if c.state='preparing'or q.owner_kind is distinct from'offline_profile'or q.reserve_request_id is distinct from c.request_id or q.offline_profile_id is distinct from c.offline_profile_id
 or(c.state='active'and n<>q.threshold_visits)or(c.state<>'active'and n<>0)
 or not exists(select 1 from private.offline_reward_reservation_events where request_id=c.request_id and action='reserve')then raise exception 'Complete typed reservation required at commit'using errcode='55000';end if;
 if c.state='consumed'then
 select redemption_id into d from private.service_reward_redemptions where quote_id=q.quote_id and owner_kind='offline_profile';
 if d is null or not coalesce(private.offline_reward_receipt_coherent(d),false)then raise exception 'Consumed hold must have coherent real receipt'using errcode='55000';end if;end if;return new;
end$$;
create function private.guard_offline_reward_subject()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.offline_reward_issue_commands where request_id=new.command_id)or new.reward_issue_id is not null then
 if new.reward_issue_id is distinct from new.command_id or not exists(select 1 from private.offline_reward_issue_commands cmd join private.offline_reward_issue_events event on event.request_id=cmd.request_id where cmd.request_id=new.reward_issue_id and cmd.state='prepared'and cmd.operator_id=auth.uid()and event.action='consume'and event.creator_xid=txid_current()and event.profile_id=new.profile_id and event.data->>'order_id'=new.order_id::text and event.data->>'invoice_id'=new.invoice_id)then raise exception 'Reward command cannot use normal cash placement or fake subject'using errcode='55000';end if;
 end if;return new;end$$;
create trigger guard_offline_reward_subject before insert on private.offline_walk_in_subjects for each row execute function private.guard_offline_reward_subject();

-- Causal qualification time comes from real facts, never async worker insertion.
create function private.offline_reward_credit_qualified_at(p_earning uuid)returns timestamptz language sql stable security definer set search_path=pg_catalog as $$
 select greatest(work.created_at,completion.occurred_at,sale_event.created_at)
 from private.canonical_loyalty_visits earning
 join public.business_payment_events sale on sale.payment_id=earning.sale_payment_id and sale.invoice_id=earning.invoice_id and sale.event_type='sale'and sale.method='cash'and sale.amount>0
 join private.loyalty_visit_outbox sale_event on sale_event.source_kind='business_payment_events'and sale_event.source_id=sale.payment_id and sale_event.order_id=earning.order_id and sale_event.invoice_id=earning.invoice_id
 join private.service_work_ledger work on work.target_kind='order'and work.order_id=earning.order_id and work.next_status='completed'and work.expected_status='quality_check'
 join private.service_work_commands command on command.request_id=work.command_id and command.order_id=earning.order_id and command.state='succeeded'and command.result->>'work_event_id'=work.event_id::text
 join private.service_resource_spans span on span.walk_in_order_id=earning.order_id and span.ended_at is not null
 join private.service_resource_events completion on completion.event_id=span.end_event_id and completion.walk_in_order_id=earning.order_id and completion.action='complete'and completion.payload->>'work_event_id'=work.event_id::text
 where earning.id=p_earning and earning.kind='earn'and earning.source_channel='offline_walk_in'and earning.customer_id is null
 order by work.created_at,work.event_id limit 1
$$;

-- Same canonical claim/debt tables, not a second ledger. Invoked before every
-- private offline allocation/issuance; actual refunds checked before async reversal.
create function private.sync_offline_profile_rewards(p_profile uuid)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;r private.reward_refund_reviews;h record;v_refund uuid;v_candidate uuid;v_needed integer;v_actor uuid:=auth.uid();
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if v_actor is null or not exists(select 1 from private.offline_customer_profiles where profile_id=p_profile)then raise exception 'Actual typed owner and actor required'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||p_profile::text,0));
 perform 1 from public.business_invoices invoice where exists(select 1 from private.canonical_loyalty_visits earning join private.reward_credit_claims claim on claim.earning_id=earning.id where earning.invoice_id=invoice.invoice_id and claim.offline_profile_id=p_profile and claim.released_at is null)order by invoice.invoice_id for update of invoice;
 for d in select receipt.*from private.service_reward_redemptions receipt join public.business_orders orders on orders.order_id=receipt.order_id join public.business_invoices invoice on invoice.invoice_id=receipt.invoice_id where receipt.owner_kind='offline_profile'and receipt.offline_profile_id=p_profile and receipt.state='covered'and orders.status='cancelled'and invoice.status='void'order by receipt.redemption_id for update of receipt loop
 select *into q from private.service_reward_quotes where quote_id=d.quote_id;
 if coalesce(q.terms_snapshot#>>'{rules,cancellation}','')not in('restore_visits','forfeit_visits')then raise exception 'Explicit frozen cancellation rule required'using errcode='55000';end if;
 insert into private.offline_reward_issue_events(event_key,redemption_id,profile_id,action,actor_id,data,creator_xid)values('cancel:'||d.redemption_id,d.redemption_id,p_profile,case when q.terms_snapshot#>>'{rules,cancellation}'='restore_visits'then'restore'else'forfeit'end,v_actor,jsonb_build_object('original_expiry_preserved',true),txid_current())on conflict(event_key)do nothing;
 if q.terms_snapshot#>>'{rules,cancellation}'='restore_visits'then
 update private.reward_credit_claims set released_at=clock_timestamp()where redemption_id=d.redemption_id and released_at is null;
 update private.reward_credit_claims set released_at=clock_timestamp()where debt_id in(select review_id from private.reward_refund_reviews where redemption_id=d.redemption_id)and released_at is null;
 update private.reward_refund_reviews set closed_at=coalesce(closed_at,clock_timestamp())where redemption_id=d.redemption_id;
 update private.service_reward_redemptions set state='restored'where redemption_id=d.redemption_id;
 else update private.service_reward_redemptions set state='forfeited'where redemption_id=d.redemption_id;end if;
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data,offline_creator_xid)values('cancel:'||d.redemption_id,d.redemption_id,v_actor,jsonb_build_object('action',q.terms_snapshot#>>'{rules,cancellation}','owner_kind','offline_profile','original_expiry_preserved',true),txid_current())on conflict(event_key)do nothing;
 end loop;
 for h in select claim.*from private.reward_credit_claims claim join private.service_reward_redemptions receipt on receipt.redemption_id=claim.redemption_id where claim.offline_profile_id=p_profile and claim.kind='reward'and claim.released_at is null and receipt.state in('covered','forfeited')order by claim.claim_id loop
 v_refund:=private.reward_credit_refund(h.earning_id);
 if v_refund is not null and not exists(select 1 from private.reward_refund_reviews where original_claim_id=h.claim_id and refund_payment_id=v_refund)then
 select *into d from private.service_reward_redemptions where redemption_id=h.redemption_id;select *into q from private.service_reward_quotes where quote_id=d.quote_id;
 insert into private.offline_reward_issue_events(event_key,redemption_id,profile_id,action,actor_id,data,creator_xid)values('review:'||h.claim_id||':'||v_refund,d.redemption_id,p_profile,'refund_review',v_actor,jsonb_build_object('claim_id',h.claim_id,'refund_payment_id',v_refund),txid_current())on conflict(event_key)do nothing;
 insert into private.reward_refund_reviews(redemption_id,original_claim_id,earning_id,refund_payment_id,customer_id,branch_id,offer_id,mode,owner_kind,offline_profile_id,offline_channel_version_id)
 values(d.redemption_id,h.claim_id,h.earning_id,v_refund,null,d.branch_id,(q.terms_snapshot->>'offer_id')::uuid,q.terms_snapshot#>>'{rules,refunded_contribution}','offline_profile',p_profile,d.offline_channel_version_id);
 end if;end loop;
 for r in select *from private.reward_refund_reviews where owner_kind='offline_profile'and offline_profile_id=p_profile and closed_at is null and(mode='offset_future_visits'or acknowledged_at is not null)order by created_at,review_id for update loop
 select 1-count(*)into v_needed from private.reward_credit_claims claim where claim.debt_id=r.review_id and claim.released_at is null and private.reward_credit_refund(claim.earning_id)is null;
 if v_needed>0 then
 select *into d from private.service_reward_redemptions where redemption_id=r.redemption_id;select *into q from private.service_reward_quotes where quote_id=d.quote_id;
 -- The SAME typed candidate selector, SAME active-claim unique index. A future
 -- The latest actual completion/cash-sale qualification fact must come after
 -- the actual refund, same offer/branch/original expiry. Delayed worker INSERT
 -- time never makes an older completed/paid service a future visit.
 -- Reuse the EXISTING immutable outbox event clock_timestamp, not payment's
 -- transaction-start now() (which can precede unrelated earnings in a long TX).
 -- Missing actual source event fails closed: no inferred cutoff/debt waiver.
 select lot.earning_id into v_candidate from private.reward_owner_candidate_lots('offline_profile',p_profile,q.rules_version_id,q.offline_channel_version_id)lot join private.canonical_loyalty_visits earning on earning.id=lot.earning_id join public.business_invoices invoice on invoice.invoice_id=earning.invoice_id
 where private.offline_reward_credit_qualified_at(earning.id)>=(select event.created_at from private.loyalty_visit_outbox event join public.business_payment_events payment on payment.payment_id=event.source_id join public.business_invoices source_invoice on source_invoice.invoice_id=payment.invoice_id
 where event.source_kind='business_payment_events'and event.source_id=r.refund_payment_id and payment.event_type='refund'and event.invoice_id=payment.invoice_id and event.order_id=source_invoice.order_id)
 order by lot.earned_at,lot.earning_id limit 1 for update of invoice;
 if v_candidate is not null and private.reward_credit_refund(v_candidate)is null and coalesce((private.reward_credit_terms(v_candidate,q.rules_version_id)->>'valid')::boolean,false)and not exists(select 1 from private.reward_credit_claims where earning_id=v_candidate and released_at is null)then
 insert into private.offline_reward_issue_events(event_key,redemption_id,profile_id,action,actor_id,data,creator_xid)values('offset:'||r.review_id||':'||v_candidate,r.redemption_id,p_profile,'offset',v_actor,jsonb_build_object('review_id',r.review_id,'earning_id',v_candidate),txid_current());
 insert into private.reward_credit_claims(earning_id,customer_id,kind,debt_id,owner_kind,offline_profile_id,offline_channel_version_id)values(v_candidate,null,'offset',r.review_id,'offline_profile',p_profile,q.offline_channel_version_id);
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data,offline_creator_xid)values('offset:'||r.review_id||':'||v_candidate,r.redemption_id,v_actor,jsonb_build_object('review_id',r.review_id,'earning_id',v_candidate,'unit','service_visits','owner_kind','offline_profile'),txid_current());
 end if;end if;end loop;
end$$;
create function private.offline_reward_debt_clear(p_profile uuid,p_rules uuid)returns boolean language sql volatile security definer set search_path=pg_catalog as $$
select not exists(select 1 from private.reward_refund_reviews review join private.loyalty_redemption_rule_versions rules on rules.rules_version_id=p_rules where review.owner_kind='offline_profile'and review.offline_profile_id=p_profile and review.closed_at is null and review.branch_id=rules.branch_id and review.offer_id=rules.offer_id
 and(review.mode='freeze_for_owner_review'and review.acknowledged_at is null or not exists(select 1 from private.reward_credit_claims claim where claim.debt_id=review.review_id and claim.released_at is null and private.reward_credit_refund(claim.earning_id)is null)))$$;
revoke all on function private.guard_offline_reward_issue_command(),private.offline_reward_receipt_coherent(uuid),private.check_offline_reward_receipt_commit(),private.guard_typed_offline_reward_claim(private.reward_credit_claims,private.reward_credit_claims,text),private.guard_offline_reward_subject(),private.sync_offline_profile_rewards(uuid),private.offline_reward_debt_clear(uuid,uuid),private.offline_reward_credit_qualified_at(uuid)from public,anon,authenticated,service_role;
-- Bundle A commits with the transitional kernel fence still false. No offline
-- redemption can be inserted until bundle B installs all private issuer/readers.
commit;
