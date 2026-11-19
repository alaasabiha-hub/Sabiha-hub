begin;
-- PRIVATE prerequisite only: preparing a consumption witness does NOT consume a
-- visit, approve financial consent, issue an invoice or enable any runtime gate.
create table private.offline_reward_consumption_preparations(
 request_id uuid primary key,
 reservation_id uuid not null unique references private.offline_reward_reservation_commands(request_id),
 requested_by uuid not null references auth.users(id),
 offline_profile_id uuid not null references private.offline_customer_profiles(profile_id),
 payload jsonb not null,
 witness jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
create table private.offline_reward_consumption_closures(
 request_id uuid primary key,
 closed_by uuid not null references auth.users(id),
 reservation_id uuid references private.offline_reward_reservation_commands(request_id),
 reason text not null check(length(trim(reason))between 10 and 500),
 created_at timestamptz not null default clock_timestamp()
);
alter table private.offline_reward_consumption_preparations enable row level security;
alter table private.offline_reward_consumption_closures enable row level security;
revoke all on private.offline_reward_consumption_preparations,private.offline_reward_consumption_closures from public,anon,authenticated,service_role;
create trigger immutable_offline_consumption_preparation before update or delete on private.offline_reward_consumption_preparations for each row execute function private.immutable_canonical_visit();
create trigger immutable_offline_consumption_closure before update or delete on private.offline_reward_consumption_closures for each row execute function private.immutable_canonical_visit();

-- Caller holds the GLOBAL consumption nonce first. Reuse the accepted reservation
-- owner -> reservation -> source invoices ordering; never acquire a cash shift.
create function private.lock_offline_reward_hold_witness(p_reservation uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_hold private.offline_reward_reservation_commands;v_quote private.service_reward_quotes;v_claim_ids uuid[];v_earning_ids uuid[];v_expected_ids uuid[];v_claims jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 select *into v_hold from private.offline_reward_reservation_commands where request_id=p_reservation;
 if not found then raise exception 'Actual private hold required'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||v_hold.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_reservation::text,0));
 select *into v_hold from private.offline_reward_reservation_commands where request_id=p_reservation for update;
 select *into v_quote from private.service_reward_quotes where quote_id=v_hold.quote_id;
 if v_hold.state<>'active'or v_quote.owner_kind is distinct from'offline_profile'or v_quote.reserve_request_id is distinct from p_reservation
 or v_quote.offline_profile_id is distinct from v_hold.offline_profile_id or v_quote.requested_by is distinct from v_hold.requested_by
 or v_quote.expires_at<=clock_timestamp()then raise exception 'Unexpired complete private hold required'using errcode='55000';end if;
 -- Source refund writers use shift -> invoice. This path never takes a shift.
 perform 1 from public.business_invoices i join private.canonical_loyalty_visits e on e.invoice_id=i.invoice_id
 where e.id=any(v_quote.earning_ids)order by i.invoice_id for update of i;
 -- Every following statement has a fresh READ COMMITTED snapshot after lock waits.
 select array_agg(h.claim_id order by h.earning_id),array_agg(h.earning_id order by h.earning_id),
 jsonb_agg(jsonb_build_object('claim_id',h.claim_id,'earning_id',h.earning_id,'original_expiry',h.hold_expires_at)order by h.earning_id)
 into v_claim_ids,v_earning_ids,v_claims from private.reward_credit_claims h
 where h.reserve_request_id=p_reservation and h.released_at is null and h.kind='reserve'and h.owner_kind='offline_profile'
 and h.offline_profile_id=v_hold.offline_profile_id and h.quote_id=v_quote.quote_id
 and h.offline_channel_version_id=v_quote.offline_channel_version_id and h.hold_expires_at=v_quote.expires_at;
 select array_agg(id order by id)into v_expected_ids from unnest(v_quote.earning_ids)as lot(id);
 if cardinality(v_claim_ids)is distinct from v_quote.threshold_visits or v_earning_ids is distinct from v_expected_ids
 or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=p_reservation and h.released_at is null and not(h.claim_id=any(coalesce(v_claim_ids,'{}'::uuid[]))))
 or exists(select 1 from unnest(v_quote.earning_ids)as lot(earning_id) where private.reward_credit_refund(lot.earning_id)is not null
 or exists(select 1 from private.canonical_loyalty_visits reversal where reversal.reverses_earning=lot.earning_id and reversal.kind='refund'))
 or exists(select 1 from jsonb_array_elements(v_quote.allocation_snapshot)allocation where allocation->'credit_terms'is distinct from private.reward_credit_terms((allocation->>'earning_id')::uuid,v_quote.rules_version_id))
 or not exists(select 1 from public.business_catalog_items s where s.item_id=v_quote.service_id and s.branch_id=v_quote.branch_id and s.item_type='service'and s.is_active and s.is_public and s.price=v_quote.gross_amount)
 or not exists(select 1 from public.business_branches b where b.branch_id=v_quote.branch_id and b.is_active and not b.temporarily_closed)
 or v_quote.expires_at<=clock_timestamp()
 then raise exception 'Hold source, original terms, refund or actual benefit changed'using errcode='55000';end if;
 return jsonb_build_object('reservation_id',p_reservation,'quote_id',v_quote.quote_id,'owner_kind','offline_profile','offline_profile_id',v_quote.offline_profile_id,
 'car_reference',v_quote.offline_car_ref_id,'channel_version_id',v_quote.offline_channel_version_id,'branch_id',v_quote.branch_id,'service_id',v_quote.service_id,
 'rules_version_id',v_quote.rules_version_id,'policy_version_id',v_quote.policy_version_id,'quote_fingerprint',v_quote.fingerprint,'expires_at',v_quote.expires_at,
 'gross_amount',v_quote.gross_amount,'amount_due',0,'unit','service_visits','threshold_visits',v_quote.threshold_visits,'claims',v_claims,
 'allocation_snapshot',v_quote.allocation_snapshot,'terms_snapshot',v_quote.terms_snapshot);
end$$;

create function private.get_offline_reward_consumption_preparation(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_command private.offline_reward_consumption_preparations;v_closed private.offline_reward_consumption_closures;v_current jsonb;v_usable boolean:=false;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null then raise exception 'Exact private nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_request::text,0));
 select *into v_closed from private.offline_reward_consumption_closures where request_id=p_request;
 select *into v_command from private.offline_reward_consumption_preparations where request_id=p_request;
 if(v_closed.request_id is not null and v_closed.closed_by<>v_actor)or(v_command.request_id is not null and v_command.requested_by<>v_actor)then raise exception 'Preparation unavailable'using errcode='42501';end if;
 if v_closed.request_id is not null then return jsonb_build_object('state','closed','request_id',p_request,'definitive_failure',true,'consumption_enabled',false,'issuer_enabled',false);end if;
 if v_command.request_id is null then return jsonb_build_object('state','absent','request_id',p_request,'definitive_failure',false,'consumption_enabled',false,'issuer_enabled',false);end if;
 begin
 v_current:=private.lock_offline_reward_hold_witness(v_command.reservation_id);
 v_usable:=v_current=v_command.witness;
 exception when object_not_in_prerequisite_state then v_usable:=false;end;
 return jsonb_build_object('state','prepared','request_id',p_request,'payload',v_command.payload,'witness',v_command.witness,'hold_current',v_usable,
 'definitive_failure',false,'consumption_enabled',false,'issuer_enabled',false,'financial_consent_recorded',false);
end$$;

create function private.prepare_offline_reward_consumption(p_request uuid,p_reservation uuid,p_fingerprint text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_command private.offline_reward_consumption_preparations;v_closed private.offline_reward_consumption_closures;v_payload jsonb;v_witness jsonb;v_hold private.offline_reward_reservation_commands;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null or p_reservation is null or p_fingerprint is null or p_fingerprint !~'^[0-9a-f]{64}$'then raise exception 'Exact reservation and fingerprint required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_request::text,0));
 select *into v_closed from private.offline_reward_consumption_closures where request_id=p_request;
 if found then
 if v_closed.closed_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 return private.get_offline_reward_consumption_preparation(p_request);end if;
 v_payload:=jsonb_build_object('reservation_id',p_reservation,'fingerprint',p_fingerprint,'purpose','private_consumption_preparation_only');
 select *into v_command from private.offline_reward_consumption_preparations where request_id=p_request;
 if found then
 if v_command.requested_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 if v_command.payload<>v_payload then raise exception 'Preparation nonce payload changed'using errcode='22023';end if;
 return private.get_offline_reward_consumption_preparation(p_request);end if;
 select *into v_hold from private.offline_reward_reservation_commands where request_id=p_reservation;
 if not found or v_hold.requested_by<>v_actor then raise exception 'Own actual private hold required'using errcode='42501';end if;
 v_witness:=private.lock_offline_reward_hold_witness(p_reservation);
 if exists(select 1 from private.offline_reward_consumption_preparations where reservation_id=p_reservation)then raise exception 'Hold already has its immutable preparation nonce'using errcode='55000';end if;
 if v_witness->>'quote_fingerprint'<>p_fingerprint then raise exception 'Original quote fingerprint changed'using errcode='40001';end if;
 insert into private.offline_reward_consumption_preparations(request_id,reservation_id,requested_by,offline_profile_id,payload,witness)
 values(p_request,p_reservation,v_actor,v_hold.offline_profile_id,v_payload,v_witness);
 return private.get_offline_reward_consumption_preparation(p_request);
end$$;

create function private.close_offline_reward_consumption(p_request uuid,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_command private.offline_reward_consumption_preparations;v_closed private.offline_reward_consumption_closures;v_hold private.offline_reward_reservation_commands;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 v_actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact nonce and audit reason required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_request::text,0));
 select *into v_closed from private.offline_reward_consumption_closures where request_id=p_request;
 if found then
 if v_closed.closed_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 return private.get_offline_reward_consumption_preparation(p_request);end if;
 select *into v_command from private.offline_reward_consumption_preparations where request_id=p_request;
 if found then
 if v_command.requested_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 select *into strict v_hold from private.offline_reward_reservation_commands where request_id=v_command.reservation_id;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||v_hold.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||v_command.reservation_id::text,0));
 perform 1 from public.business_invoices invoice join private.canonical_loyalty_visits earning on earning.invoice_id=invoice.invoice_id
 join private.service_reward_quotes quote on earning.id=any(quote.earning_ids)
 where quote.quote_id=v_hold.quote_id order by invoice.invoice_id for update of invoice;
 -- Existing release accepts ONLY unconsumed reserve claims and has its own
 -- same-transaction event witness. No restore, debt forgiveness or new credit.
 perform private.release_offline_reward_reservation(v_command.reservation_id,trim(p_reason));
 end if;
 insert into private.offline_reward_consumption_closures(request_id,closed_by,reservation_id,reason)values(p_request,v_actor,v_command.reservation_id,trim(p_reason));
 return private.get_offline_reward_consumption_preparation(p_request);
end$$;
revoke all on function private.lock_offline_reward_hold_witness(uuid),private.get_offline_reward_consumption_preparation(uuid),private.prepare_offline_reward_consumption(uuid,uuid,text),private.close_offline_reward_consumption(uuid,text)from public,anon,authenticated,service_role;
-- Existing reserve/reward fences, runtime disabled constraints, canonical uniqueness,
-- invoice/commission/payment paths and old Auth wrappers remain untouched.
commit;
