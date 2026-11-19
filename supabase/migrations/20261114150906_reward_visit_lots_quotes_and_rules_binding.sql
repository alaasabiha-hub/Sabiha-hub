begin;
-- No activations, prices, points or historical-rights adoption are seeded.
create table private.reward_runtime(singleton boolean primary key default true check(singleton),booking_installed boolean not null default false,readers_integrated boolean not null default false);
insert into private.reward_runtime values(true,false,false);
create table private.reward_rule_activations(request_id uuid primary key,rules_version_id uuid not null unique references private.loyalty_redemption_rule_versions(rules_version_id),activated_by uuid not null references public.staff_profiles(user_id),activated_at timestamptz not null default clock_timestamp());
create table private.reward_booking_earning_terms(booking_id uuid primary key references private.loyalty_earning_snapshot_bindings(booking_id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),captured_at timestamptz not null default clock_timestamp());
create table private.reward_earning_terms(earning_id uuid primary key references private.canonical_loyalty_visits(id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),adoption_quote_id uuid,captured_at timestamptz not null default clock_timestamp());
create table private.service_reward_quotes(
 quote_id uuid primary key,customer_id uuid not null references public.customers(id),source_channel text not null check(source_channel in ('booking','walk_in')),payload jsonb not null,
 branch_id uuid not null references public.business_branches(branch_id),service_id uuid not null references public.business_catalog_items(item_id),vehicle_id uuid not null references public.vehicles(id),booking_date date not null,booking_time time not null,notes text,
 policy_version_id uuid not null references private.loyalty_policy_versions(version_id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),threshold_visits integer not null check(threshold_visits>0),gross_amount numeric(12,2) not null check(gross_amount>0 and gross_amount<>'NaN'::numeric),
 earning_ids uuid[] not null,adoption_ids uuid[] not null,allocation_snapshot jsonb not null,terms_snapshot jsonb not null,fingerprint text not null,expires_at timestamptz not null,created_at timestamptz not null default clock_timestamp(),check(cardinality(earning_ids)=threshold_visits));
alter table private.reward_earning_terms add foreign key(adoption_quote_id) references private.service_reward_quotes(quote_id);
create table private.service_reward_redemptions(
 redemption_id uuid primary key,customer_id uuid not null references public.customers(id),request_id uuid not null,quote_id uuid not null unique references private.service_reward_quotes(quote_id),source_channel text not null check(source_channel in ('booking','walk_in')),
 branch_id uuid not null references public.business_branches(branch_id),order_id uuid not null unique references public.business_orders(order_id),booking_id uuid unique references public.bookings(id),invoice_id text not null unique references public.business_invoices(invoice_id) deferrable initially deferred,
 rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),policy_version_id uuid not null references private.loyalty_policy_versions(version_id),consent jsonb not null,coverage_snapshot jsonb not null,creator_xid bigint not null,
 state text not null default 'covered' check(state in ('covered','restored','forfeited')),result jsonb,created_at timestamptz not null default clock_timestamp(),unique(customer_id,request_id));
create table private.reward_credit_claims(
 claim_id uuid primary key default gen_random_uuid(),earning_id uuid not null references private.canonical_loyalty_visits(id),customer_id uuid not null references public.customers(id),kind text not null check(kind in ('reward','offset')),
 redemption_id uuid references private.service_reward_redemptions(redemption_id),quote_id uuid references private.service_reward_quotes(quote_id),debt_id uuid,released_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),check((kind='reward' and redemption_id is not null and quote_id is not null and debt_id is null) or(kind='offset' and redemption_id is null and quote_id is null and debt_id is not null)));
create unique index reward_one_active_claim_per_earning on private.reward_credit_claims(earning_id) where released_at is null;
create index reward_claim_redemption on private.reward_credit_claims(redemption_id);
create table private.reward_refund_reviews(
 review_id uuid primary key default gen_random_uuid(),redemption_id uuid not null references private.service_reward_redemptions(redemption_id),original_claim_id uuid not null references private.reward_credit_claims(claim_id),earning_id uuid not null references private.canonical_loyalty_visits(id),refund_payment_id uuid not null references public.business_payment_events(payment_id),
 customer_id uuid not null references public.customers(id),branch_id uuid not null references public.business_branches(branch_id),offer_id uuid not null references public.business_offers(offer_id),mode text not null check(mode in ('offset_future_visits','freeze_for_owner_review')),
 acknowledged_at timestamptz,acknowledged_by uuid references public.staff_profiles(user_id),closed_at timestamptz,created_at timestamptz not null default clock_timestamp(),unique(original_claim_id,refund_payment_id));
alter table private.reward_credit_claims add foreign key(debt_id) references private.reward_refund_reviews(review_id);
create index reward_review_customer on private.reward_refund_reviews(customer_id,branch_id,offer_id);
create index reward_claim_debt on private.reward_credit_claims(debt_id);
create table private.reward_ledger_events(event_id uuid primary key default gen_random_uuid(),event_key text not null unique,redemption_id uuid references private.service_reward_redemptions(redemption_id),actor_id uuid,data jsonb not null,created_at timestamptz not null default clock_timestamp());
create table private.reward_command_requests(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['reward_runtime','reward_rule_activations','reward_booking_earning_terms','reward_earning_terms','service_reward_quotes','service_reward_redemptions','reward_credit_claims','reward_refund_reviews','reward_ledger_events','reward_command_requests'] loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end $$;
create trigger immutable_reward_activation before update or delete on private.reward_rule_activations for each row execute function private.immutable_loyalty_policy();
create trigger immutable_reward_booking_terms before update or delete on private.reward_booking_earning_terms for each row execute function private.immutable_loyalty_policy();
create trigger immutable_reward_earning_terms before update or delete on private.reward_earning_terms for each row execute function private.immutable_loyalty_policy();
create trigger immutable_service_reward_quote before update or delete on private.service_reward_quotes for each row execute function private.immutable_loyalty_policy();
create trigger immutable_reward_event before update or delete on private.reward_ledger_events for each row execute function private.immutable_loyalty_policy();
create trigger immutable_reward_command before update or delete on private.reward_command_requests for each row execute function private.immutable_loyalty_policy();
create function private.capture_reward_earning_terms() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare rid uuid;
begin
 if tg_table_name='loyalty_earning_snapshot_bindings' then
 select r.rules_version_id into rid from private.loyalty_redemption_rule_versions r join private.reward_rule_activations a using(rules_version_id) join private.loyalty_visit_activations v on v.activation_id=new.activation_id where r.policy_version_id=v.policy_version_id order by r.version_no desc limit 1;
 if rid is not null then insert into private.reward_booking_earning_terms(booking_id,rules_version_id) values(new.booking_id,rid);end if;
 elsif new.kind='earn' then
 select rules_version_id into rid from private.reward_booking_earning_terms where booking_id=new.booking_id;
 if rid is not null then insert into private.reward_earning_terms(earning_id,rules_version_id) values(new.id,rid);end if;end if;
 return new;
end $$;
revoke all on function private.capture_reward_earning_terms() from public,anon,authenticated,service_role;
create trigger capture_new_reward_booking_terms after insert on private.loyalty_earning_snapshot_bindings for each row execute function private.capture_reward_earning_terms();
create trigger capture_new_reward_credit_terms after insert on private.canonical_loyalty_visits for each row execute function private.capture_reward_earning_terms();
create function private.reward_credit_refund(p_earning uuid) returns uuid language sql stable security definer set search_path=pg_catalog as $$
 select r.payment_id from private.canonical_loyalty_visits e join public.business_payment_events r on r.invoice_id=e.invoice_id and r.event_type='refund' and r.method='cash' and r.amount=(e.facts->>'sale_amount')::numeric join public.business_cashier_shifts s on s.shift_id=r.shift_id and s.branch_id=e.branch_id where e.id=p_earning and e.kind='earn' limit 1;
$$;
revoke all on function private.reward_credit_refund(uuid) from public,anon,authenticated,service_role;
create function private.reward_credit_terms(p_earning uuid,p_proposed_rules uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare original uuid;r private.loyalty_redemption_rule_versions;deadline timestamptz;
begin
 select rules_version_id into original from private.reward_earning_terms where earning_id=p_earning;
 select * into r from private.loyalty_redemption_rule_versions where rules_version_id=coalesce(original,p_proposed_rules);
 if r.rules_version_id is null then return jsonb_build_object('valid',false,'reason','explicit_rules_required');end if;
 if r.rules->>'expiry'='snapshot_offer_end' then deadline:=(r.terms_snapshot#>>'{offer,ends_at}')::timestamptz;if deadline is null then return jsonb_build_object('valid',false,'reason','frozen_expiry_missing');end if;end if;
 return jsonb_build_object('valid',deadline is null or deadline>clock_timestamp(),'expires_at',deadline,'adoption_required',original is null,'original_rules_version_id',original,'effective_rules_version_id',r.rules_version_id);
end $$;
revoke all on function private.reward_credit_terms(uuid,uuid) from public,anon,authenticated,service_role;
create function private.reward_program_lots(p_customer uuid,p_rules uuid) returns table(earning_id uuid,credit_terms jsonb,earned_at timestamptz) language sql stable security definer set search_path=pg_catalog as $$
 select e.id,t.details,e.created_at from private.canonical_loyalty_visits e join private.loyalty_policy_versions p on p.version_id=e.policy_version_id join private.loyalty_redemption_rule_versions r on r.rules_version_id=p_rules cross join lateral(select private.reward_credit_terms(e.id,p_rules) details)t
 where e.kind='earn' and e.customer_id=p_customer and e.branch_id=r.branch_id and p.offer_id=r.offer_id and(r.rules->>'pooling'='offer_branch' or e.policy_version_id=r.policy_version_id)
 and private.reward_credit_refund(e.id) is null and not exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund') and not exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null) and(t.details->>'valid')::boolean
 order by(t.details->>'expires_at')::timestamptz nulls last,e.created_at,e.id;
$$;
revoke all on function private.reward_program_lots(uuid,uuid) from public,anon,authenticated,service_role;
create function private.sync_customer_rewards(p_customer uuid) returns void language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare redemption private.service_reward_redemptions;q private.service_reward_quotes;review private.reward_refund_reviews;candidate uuid;needed integer;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Reward operations require READ COMMITTED' using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||p_customer::text,0));
 -- Settle debt only after serializing actual cash refunds on already allocated credits.
 perform 1 from public.business_invoices i where exists(select 1 from private.canonical_loyalty_visits e join private.reward_credit_claims c on c.earning_id=e.id where e.invoice_id=i.invoice_id and c.customer_id=p_customer and c.released_at is null)order by i.invoice_id for update of i;
 -- A consistent actual cancellation restores/forfeits under the issued rules only.
 for redemption in select d.* from private.service_reward_redemptions d join public.business_orders o on o.order_id=d.order_id join public.business_invoices i on i.invoice_id=d.invoice_id left join public.bookings b on b.id=d.booking_id where d.customer_id=p_customer and d.state='covered' and o.status='cancelled' and i.status='void' and(d.source_channel<>'booking' or b.status='cancelled') order by d.redemption_id for update of d loop
 select * into q from private.service_reward_quotes where quote_id=redemption.quote_id;
 if q.terms_snapshot#>>'{rules,cancellation}'='restore_visits' then
 update private.reward_credit_claims set released_at=clock_timestamp() where redemption_id=redemption.redemption_id and released_at is null;
 update private.reward_credit_claims set released_at=clock_timestamp() where debt_id in(select review_id from private.reward_refund_reviews where redemption_id=redemption.redemption_id) and released_at is null;
 update private.reward_refund_reviews set closed_at=coalesce(closed_at,clock_timestamp()) where redemption_id=redemption.redemption_id;
 update private.service_reward_redemptions set state='restored' where redemption_id=redemption.redemption_id;
 else update private.service_reward_redemptions set state='forfeited' where redemption_id=redemption.redemption_id;end if;
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data) values('cancel:'||redemption.redemption_id,redemption.redemption_id,auth.uid(),jsonb_build_object('action',q.terms_snapshot#>>'{rules,cancellation}','original_expiry_preserved',true)) on conflict(event_key) do nothing;
 end loop;
 -- Check ACTUAL cash refunds even before the async visit reversal is processed.
 insert into private.reward_refund_reviews(redemption_id,original_claim_id,earning_id,refund_payment_id,customer_id,branch_id,offer_id,mode)
 select d.redemption_id,c.claim_id,c.earning_id,f.refund,p_customer,d.branch_id,(q.terms_snapshot->>'offer_id')::uuid,q.terms_snapshot#>>'{rules,refunded_contribution}' from private.reward_credit_claims c join private.service_reward_redemptions d on d.redemption_id=c.redemption_id join private.service_reward_quotes q on q.quote_id=d.quote_id cross join lateral(select private.reward_credit_refund(c.earning_id) refund)f where c.customer_id=p_customer and c.kind='reward' and c.released_at is null and d.state in('covered','forfeited') and f.refund is not null on conflict(original_claim_id,refund_payment_id) do nothing;
 -- Offset debt within the SAME offer+branch only. Review mode holds until owner acknowledgement.
 for review in select * from private.reward_refund_reviews where customer_id=p_customer and closed_at is null and(mode='offset_future_visits' or acknowledged_at is not null) order by created_at,review_id for update loop
 select 1-count(*) into needed from private.reward_credit_claims c where c.debt_id=review.review_id and c.released_at is null and private.reward_credit_refund(c.earning_id) is null;
 if needed>0 then
 select e.id into candidate from private.canonical_loyalty_visits e join public.business_invoices locked_invoice on locked_invoice.invoice_id=e.invoice_id join private.loyalty_policy_versions p on p.version_id=e.policy_version_id join private.reward_earning_terms et on et.earning_id=e.id cross join lateral(select private.reward_credit_terms(e.id,et.rules_version_id) terms)t
 where e.kind='earn' and e.customer_id=p_customer and e.branch_id=review.branch_id and p.offer_id=review.offer_id and e.created_at>=(select created_at from public.business_payment_events where payment_id=review.refund_payment_id) and private.reward_credit_refund(e.id) is null and(t.terms->>'valid')::boolean and not exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null) order by e.created_at,e.id limit 1 for update of locked_invoice;
 -- A candidate may have appeared after the initial lock scan. Re-read after its lock wait.
 if candidate is not null and private.reward_credit_refund(candidate) is null and coalesce((private.reward_credit_terms(candidate,(select rules_version_id from private.reward_earning_terms where earning_id=candidate))->>'valid')::boolean,false) then
 insert into private.reward_credit_claims(earning_id,customer_id,kind,debt_id) values(candidate,p_customer,'offset',review.review_id);
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data) values('offset:'||review.review_id||':'||candidate,review.redemption_id,auth.uid(),jsonb_build_object('review_id',review.review_id,'earning_id',candidate,'unit','service_visits')) on conflict(event_key) do nothing;
 end if;end if;end loop;
end $$;
revoke all on function private.sync_customer_rewards(uuid) from public,anon,authenticated,service_role;
create function private.reward_program_blockers(p_customer uuid,p_rules uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare r private.loyalty_redemption_rule_versions;holds integer;debt integer;
begin
 select * into r from private.loyalty_redemption_rule_versions where rules_version_id=p_rules;
 select count(*) into holds from private.reward_refund_reviews where customer_id=p_customer and branch_id=r.branch_id and offer_id=r.offer_id and closed_at is null and mode='freeze_for_owner_review' and acknowledged_at is null;
 select count(*) into debt from private.reward_refund_reviews v where v.customer_id=p_customer and v.branch_id=r.branch_id and v.offer_id=r.offer_id and v.closed_at is null and not exists(select 1 from private.reward_credit_claims c where c.debt_id=v.review_id and c.released_at is null and private.reward_credit_refund(c.earning_id) is null);
 return jsonb_build_object('owner_review_required',holds>0,'outstanding_refund_debt',debt,'eligible',holds=0 and debt=0);
end $$;
revoke all on function private.reward_program_blockers(uuid,uuid) from public,anon,authenticated,service_role;
create function private.activate_loyalty_redemption(p_request uuid,p_rules uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a private.reward_rule_activations;r private.loyalty_redemption_rule_versions;s public.business_catalog_items;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_rules is null then raise exception 'Explicit activation request and rules required';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-activation:'||p_rules::text,0));select * into a from private.reward_rule_activations where request_id=p_request;
 if a.request_id is not null then if a.rules_version_id<>p_rules or a.activated_by<>auth.uid() then raise exception 'Activation request mismatch';end if;return to_jsonb(a);end if;
 if not exists(select 1 from private.reward_runtime where singleton and booking_installed and readers_integrated) then raise exception 'Reward checkout/readers are not fully installed' using errcode='55000';end if;
 if not private.loyalty_visit_scheduler_ready() or coalesce(private.loyalty_visit_cron_last_success()<clock_timestamp()-interval '5 minutes',true) then raise exception 'Actual recent earning scheduler execution required' using errcode='55000';end if;
 select * into r from private.loyalty_redemption_rule_versions where rules_version_id=p_rules;
 if r.rules_version_id is null or not exists(select 1 from private.loyalty_visit_activations where policy_version_id=r.policy_version_id) then raise exception 'Actual rules and earning activation required';end if;
 select * into s from public.business_catalog_items where item_id=(r.terms_snapshot#>>'{reward_service,id}')::uuid and branch_id=r.branch_id and item_type='service' and is_active and is_public for share;
 if s.item_id is null or (r.rules->>'expiry'='snapshot_offer_end' and coalesce((r.terms_snapshot#>>'{offer,ends_at}')::timestamptz<=clock_timestamp(),true)) then raise exception 'Actual reward service or frozen expiry unavailable';end if;
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by) values(p_request,p_rules,auth.uid()) returning * into a;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'activate_loyalty_redemption','loyalty_redemption_rule_versions',p_rules::text,r.branch_id,to_jsonb(a));return to_jsonb(a);
end $$;
create function public.activate_loyalty_redemption(p_request uuid,p_rules_version uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.activate_loyalty_redemption(p_request,p_rules_version)$$;
revoke all on function private.activate_loyalty_redemption(uuid,uuid),public.activate_loyalty_redemption(uuid,uuid) from public,anon;
grant execute on function private.activate_loyalty_redemption(uuid,uuid),public.activate_loyalty_redemption(uuid,uuid) to authenticated;
create function private.guard_reward_claim() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;
begin
 if tg_op='DELETE' then raise exception 'Reward claim history cannot be deleted';end if;
 if tg_op='UPDATE' then
 if(to_jsonb(new)-'released_at') is distinct from(to_jsonb(old)-'released_at') or(old.released_at is not null and new.released_at is distinct from old.released_at) or(old.released_at is null and new.released_at is null) then raise exception 'Only one-way claim release is allowed';end if;return new;end if;
 select * into e from private.canonical_loyalty_visits where id=new.earning_id and kind='earn';
 if e.id is null or e.customer_id<>new.customer_id or private.reward_credit_refund(e.id) is not null then raise exception 'Actual own unrefunded earning required';end if;
 if new.kind='reward' and not exists(select 1 from private.service_reward_redemptions d where d.redemption_id=new.redemption_id and d.quote_id=new.quote_id and d.customer_id=new.customer_id) then raise exception 'Claim redemption association mismatch';end if;
 if new.kind='offset' and not exists(select 1 from private.reward_refund_reviews r join private.loyalty_policy_versions p on p.version_id=e.policy_version_id where r.review_id=new.debt_id and r.customer_id=e.customer_id and r.branch_id=e.branch_id and r.offer_id=p.offer_id and r.closed_at is null) then raise exception 'Offset debt association mismatch';end if;
 return new;
end $$;
revoke all on function private.guard_reward_claim() from public,anon,authenticated,service_role;
create trigger guard_reward_claim before insert or update or delete on private.reward_credit_claims for each row execute function private.guard_reward_claim();
create function private.guard_reward_redemption_update() returns trigger language plpgsql security invoker set search_path=pg_catalog as $$begin
 if tg_op='DELETE' then raise exception 'Reward coverage history cannot be deleted';end if;
 if(to_jsonb(new)-array['state','result']) is distinct from(to_jsonb(old)-array['state','result']) or(old.result is not null and new.result is distinct from old.result) or(new.state is distinct from old.state and(old.state<>'covered' or new.state not in('restored','forfeited'))) then raise exception 'Reward coverage identity/terms are immutable';end if;return new;
end $$;
revoke all on function private.guard_reward_redemption_update() from public,anon,authenticated,service_role;
create trigger guard_reward_redemption_history before update or delete on private.service_reward_redemptions for each row execute function private.guard_reward_redemption_update();
create function private.reward_backend_readiness(p_policy uuid) returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 with capability as(select
 to_regprocedure('private.quote_service_reward(uuid,uuid,uuid,uuid,date,time without time zone,uuid,uuid,text)')is not null quote,
 to_regprocedure('private.place_customer_reward_booking(uuid,uuid,text,boolean,boolean)')is not null and x.booking_installed booking,
 to_regclass('private.reward_credit_claims')is not null allocation,
 exists(select 1 from pg_trigger where tgrelid='public.business_invoices'::regclass and tgname='guard_new_reward_invoice'and not tgisinternal) consumption,
 to_regprocedure('private.sync_customer_rewards(uuid)')is not null and position('sync_customer_rewards' in pg_get_functiondef(to_regprocedure('private.change_customer_booking(uuid,uuid,text,date,time without time zone)')))>0 release,
 to_regprocedure('private.resolve_reward_refund_review(uuid,uuid,text)')is not null resolution,
 exists(select 1 from pg_trigger where tgname='capture_new_reward_credit_terms'and not tgisinternal) binding,
 x.readers_integrated readers from private.reward_runtime x where singleton)
 select jsonb_build_object('quote_implemented',quote,'booking_implemented',booking,'allocation_implemented',allocation,'consumption_implemented',consumption,'release_implemented',release,'refund_resolution_implemented',resolution,'earning_rules_binding_implemented',binding,'readers_integrated',readers,'booking_channel_supported',true,'walk_in_supported',false,'stacking_supported',false,'partial_redemption_supported',false,'current_rules_activated',exists(select 1 from private.reward_rule_activations where rules_version_id=(select rules_version_id from private.loyalty_redemption_rule_versions where policy_version_id=p_policy order by version_no desc limit 1)),'redemption_enabled',quote and booking and allocation and consumption and release and resolution and binding and readers and exists(select 1 from private.reward_rule_activations a join private.loyalty_redemption_rule_versions r using(rules_version_id)where r.policy_version_id=p_policy))from capability;
$$;
revoke all on function private.reward_backend_readiness(uuid) from public,anon,authenticated,service_role;
create function private.get_service_reward_options(p_service uuid,p_branch uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r private.loyalty_redemption_rule_versions;programs jsonb:='[]';lots bigint;adoptions bigint;blocked jsonb;ready boolean;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 select booking_installed and readers_integrated into ready from private.reward_runtime where singleton;
 if not coalesce(ready,false) then return jsonb_build_object('redemption_enabled',false,'programs','[]'::jsonb,'reason','checkout_not_fully_installed','unit','service_visits');end if;
 perform private.sync_customer_rewards(auth.uid());
 for r in select v.* from private.loyalty_redemption_rule_versions v join private.reward_rule_activations a using(rules_version_id) where v.branch_id=p_branch and(v.terms_snapshot#>>'{reward_service,id}')::uuid=p_service and(v.terms_snapshot->'target_customer_ids'='null'::jsonb or v.terms_snapshot->'target_customer_ids' @> to_jsonb(array[auth.uid()])) order by v.version_no desc loop
 select count(*),count(*)filter(where(credit_terms->>'adoption_required')::boolean) into lots,adoptions from private.reward_program_lots(auth.uid(),r.rules_version_id);
 blocked:=private.reward_program_blockers(auth.uid(),r.rules_version_id);
 programs:=programs||jsonb_build_array(jsonb_build_object('rules_version_id',r.rules_version_id,'policy_version_id',r.policy_version_id,'offer_id',r.offer_id,'branch_id',r.branch_id,'threshold_visits',(r.terms_snapshot->>'threshold_visits')::integer,'reward_service',r.terms_snapshot->'reward_service','rules',r.rules,'terms_snapshot',r.terms_snapshot,'available_visits',lots,'pre_rule_visits',adoptions,'blockers',blocked,'eligible',lots>=(r.terms_snapshot->>'threshold_visits')::integer and(blocked->>'eligible')::boolean and(r.rules->>'expiry'='no_expiry' or(r.terms_snapshot#>>'{offer,ends_at}')::timestamptz>clock_timestamp())));
 end loop;
 return jsonb_build_object('redemption_enabled',true,'programs',programs,'unit','service_visits','legacy_imported',false,'stacking_supported',false,'walk_in_supported',false);
end $$;
create function public.get_service_reward_options(p_service uuid,p_branch uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_service_reward_options(p_service,p_branch)$$;
revoke all on function private.get_service_reward_options(uuid,uuid),public.get_service_reward_options(uuid,uuid) from public,anon;
grant execute on function private.get_service_reward_options(uuid,uuid),public.get_service_reward_options(uuid,uuid) to authenticated;
create function private.quote_service_reward(p_request uuid,p_service uuid,p_branch uuid,p_vehicle uuid,p_date date,p_time time,p_policy uuid,p_rules uuid,p_notes text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r private.loyalty_redemption_rule_versions;s public.business_catalog_items;q private.service_reward_quotes;payload jsonb;terms jsonb;allocations jsonb;ids uuid[];adoptions uuid[];deadline timestamptz;fingerprint text;blocked jsonb;threshold integer;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null or p_service is null or p_branch is null or p_vehicle is null or p_date is null or p_time is null or p_policy is null or p_rules is null or length(coalesce(p_notes,''))>2000 then raise exception 'Complete explicit reward booking details required' using errcode='22023';end if;
 payload:=jsonb_build_object('service',p_service,'branch',p_branch,'vehicle',p_vehicle,'date',p_date,'time',p_time,'policy',p_policy,'rules',p_rules,'notes',nullif(trim(p_notes),''),'source_channel','booking');
 perform pg_advisory_xact_lock(hashtextextended('reward-quote:'||p_request::text,0));select * into q from private.service_reward_quotes where quote_id=p_request;
 if q.quote_id is not null then if q.customer_id<>auth.uid() then raise exception 'Quote access denied' using errcode='42501';end if;if q.payload<>payload then raise exception 'Quote request changed' using errcode='22023';end if;return to_jsonb(q)||jsonb_build_object('eligible',q.expires_at>clock_timestamp(),'reason',case when q.expires_at<=clock_timestamp() then 'quote_expired' else 'quoted' end,'amount_due',0,'reward_discount',q.gross_amount,'adoption_required',cardinality(q.adoption_ids)>0,'unit','service_visits','currency','EGP');end if;
 if not exists(select 1 from private.reward_runtime where singleton and booking_installed and readers_integrated) then return jsonb_build_object('eligible',false,'reason','checkout_not_fully_installed');end if;
 perform private.sync_customer_rewards(auth.uid());
 select v.* into r from private.loyalty_redemption_rule_versions v join private.reward_rule_activations a using(rules_version_id) where v.rules_version_id=p_rules and v.policy_version_id=p_policy and v.branch_id=p_branch and(v.terms_snapshot#>>'{reward_service,id}')::uuid=p_service;
 if r.rules_version_id is null or(r.terms_snapshot->'target_customer_ids'<>'null'::jsonb and not(r.terms_snapshot->'target_customer_ids' @> to_jsonb(array[auth.uid()]))) then return jsonb_build_object('eligible',false,'reason','actual_activated_reward_terms_required');end if;
 blocked:=private.reward_program_blockers(auth.uid(),p_rules);if not(blocked->>'eligible')::boolean then return jsonb_build_object('eligible',false,'reason','refund_review_or_offset_required','blockers',blocked);end if;
 select * into s from public.business_catalog_items where item_id=p_service and branch_id=p_branch and item_type='service' and is_active and is_public and name !~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)' for share;
 if s.item_id is null or s.price<=0 or s.price::text='NaN' or not exists(select 1 from public.vehicles where id=p_vehicle and customer_id=auth.uid()) or not exists(select 1 from public.business_branches where branch_id=p_branch and is_active and not temporarily_closed) then return jsonb_build_object('eligible',false,'reason','actual_service_vehicle_or_branch_unavailable');end if;
 if(p_date+p_time) at time zone 'Africa/Cairo'<=clock_timestamp() or not exists(select 1 from private.available_booking_slots(p_branch,p_service,p_date) where slot_time=p_time) then return jsonb_build_object('eligible',false,'reason','appointment_unavailable');end if;
 threshold:=(r.terms_snapshot->>'threshold_visits')::integer;
 select array_agg(earning_id order by ord),coalesce(array_agg(earning_id order by ord)filter(where(credit_terms->>'adoption_required')::boolean),'{}'::uuid[]),jsonb_agg(jsonb_build_object('earning_id',earning_id,'credit_terms',credit_terms)order by ord),least(clock_timestamp()+interval '10 minutes',min((credit_terms->>'expires_at')::timestamptz)) into ids,adoptions,allocations,deadline from(select l.*,row_number()over(order by(credit_terms->>'expires_at')::timestamptz nulls last,earned_at,earning_id)ord from private.reward_program_lots(auth.uid(),p_rules)l order by(credit_terms->>'expires_at')::timestamptz nulls last,earned_at,earning_id limit threshold)x;
 if coalesce(cardinality(ids),0)<>threshold then return jsonb_build_object('eligible',false,'reason','insufficient_actual_eligible_visits','required_visits',threshold,'available_visits',coalesce(cardinality(ids),0));end if;
 if r.rules->>'expiry'='snapshot_offer_end' then deadline:=least(deadline,(r.terms_snapshot#>>'{offer,ends_at}')::timestamptz);end if;
 if deadline is null or deadline<=clock_timestamp() then return jsonb_build_object('eligible',false,'reason','frozen_expiry_passed');end if;
 terms:=r.terms_snapshot||jsonb_build_object('source_channel','booking','consent_required',true,'adoption_required',cardinality(adoptions)>0,'original_credit_expiry_preserved',true,'offset_scope','same_offer_and_branch','owner_review_resolution','acknowledgement_does_not_waive_debt','stacking_supported',false);
 fingerprint:=encode(extensions.digest(jsonb_build_object('payload',payload,'terms',terms,'earning_ids',ids,'allocation_snapshot',allocations,'gross_amount',s.price,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.service_reward_quotes(quote_id,customer_id,source_channel,payload,branch_id,service_id,vehicle_id,booking_date,booking_time,notes,policy_version_id,rules_version_id,threshold_visits,gross_amount,earning_ids,adoption_ids,allocation_snapshot,terms_snapshot,fingerprint,expires_at) values(p_request,auth.uid(),'booking',payload,p_branch,p_service,p_vehicle,p_date,p_time,nullif(trim(p_notes),''),p_policy,p_rules,threshold,s.price,ids,adoptions,allocations,terms,fingerprint,deadline) returning * into q;
 return to_jsonb(q)||jsonb_build_object('eligible',true,'amount_due',0,'reward_discount',q.gross_amount,'adoption_required',cardinality(q.adoption_ids)>0,'unit','service_visits','currency','EGP','collectible',false);
end $$;
create function public.quote_service_reward(p_request uuid,p_service uuid,p_branch uuid,p_vehicle uuid,p_date date,p_time time,p_policy_version uuid,p_rules_version uuid,p_notes text default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.quote_service_reward(p_request,p_service,p_branch,p_vehicle,p_date,p_time,p_policy_version,p_rules_version,p_notes)$$;
revoke all on function private.quote_service_reward(uuid,uuid,uuid,uuid,date,time,uuid,uuid,text),public.quote_service_reward(uuid,uuid,uuid,uuid,date,time,uuid,uuid,text) from public,anon;
grant execute on function private.quote_service_reward(uuid,uuid,uuid,uuid,date,time,uuid,uuid,text),public.quote_service_reward(uuid,uuid,uuid,uuid,date,time,uuid,uuid,text) to authenticated;
create function private.list_reward_refund_reviews(p_branch uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c uuid;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 for c in select distinct customer_id from private.service_reward_redemptions where(p_branch is null or branch_id=p_branch)order by customer_id loop perform private.sync_customer_rewards(c);end loop;
 select coalesce(jsonb_agg(jsonb_build_object('review_id',r.review_id,'customer_id',r.customer_id,'branch_id',r.branch_id,'offer_id',r.offer_id,'mode',r.mode,'acknowledged_at',r.acknowledged_at,'closed_at',r.closed_at,'debt_outstanding',not exists(select 1 from private.reward_credit_claims c where c.debt_id=r.review_id and c.released_at is null and private.reward_credit_refund(c.earning_id) is null))order by r.created_at),'[]') into result from private.reward_refund_reviews r where p_branch is null or r.branch_id=p_branch;return result;
end $$;
create function private.resolve_reward_refund_review(p_request uuid,p_review uuid,p_note text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare review private.reward_refund_reviews;prior private.reward_command_requests;payload jsonb;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_review is null or length(trim(coalesce(p_note,''))) not between 2 and 1000 then raise exception 'Explicit review and audit note required';end if;
 payload:=jsonb_build_object('review',p_review,'note',p_note,'action','acknowledge_without_debt_waiver');perform pg_advisory_xact_lock(hashtextextended('reward-command:'||p_request::text,0));select * into prior from private.reward_command_requests where request_id=p_request;
 if prior.request_id is not null then if prior.actor_id<>auth.uid() or prior.payload<>payload then raise exception 'Review request mismatch';end if;return prior.result;end if;
 select * into review from private.reward_refund_reviews where review_id=p_review;if review.review_id is null then raise exception 'Actual refund review required';end if;
 perform private.sync_customer_rewards(review.customer_id);
 update private.reward_refund_reviews set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),acknowledged_by=coalesce(acknowledged_by,auth.uid()) where review_id=p_review;
 perform private.sync_customer_rewards(review.customer_id);
 result:=jsonb_build_object('review_id',p_review,'acknowledged',true,'debt_waived',false,'visits_minted',0);
 insert into private.reward_command_requests values(p_request,auth.uid(),payload,result,clock_timestamp());
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data) values('review_ack:'||p_review,review.redemption_id,auth.uid(),payload) on conflict(event_key)do nothing;return result;
end $$;
create function public.list_reward_refund_reviews(p_branch uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_reward_refund_reviews(p_branch)$$;
create function public.resolve_reward_refund_review(p_request uuid,p_review uuid,p_note text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.resolve_reward_refund_review(p_request,p_review,p_note)$$;
revoke all on function private.list_reward_refund_reviews(uuid),public.list_reward_refund_reviews(uuid),private.resolve_reward_refund_review(uuid,uuid,text),public.resolve_reward_refund_review(uuid,uuid,text) from public,anon;
grant execute on function private.list_reward_refund_reviews(uuid),public.list_reward_refund_reviews(uuid),private.resolve_reward_refund_review(uuid,uuid,text),public.resolve_reward_refund_review(uuid,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
