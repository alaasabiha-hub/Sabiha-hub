begin;
-- Coherent typed metadata + PRIVATE offline holds only. No consumption/issuer/public spend.
alter table private.service_reward_quotes add column owner_kind text not null default 'auth_customer',add column offline_profile_id uuid references private.offline_customer_profiles(profile_id),add column offline_car_ref_id uuid references private.offline_customer_car_refs(car_ref_id),add column offline_channel_version_id uuid references private.offline_visit_channel_versions(version_id),add column requested_by uuid references auth.users(id),add column reserve_request_id uuid;
alter table private.service_reward_quotes alter column customer_id drop not null,alter column vehicle_id drop not null,alter column booking_date drop not null,alter column booking_time drop not null;
alter table private.service_reward_quotes add constraint reward_quote_typed_owner check(
(owner_kind='auth_customer'and customer_id is not null and vehicle_id is not null and booking_date is not null and booking_time is not null and offline_profile_id is null and offline_car_ref_id is null and offline_channel_version_id is null and reserve_request_id is null)
or(owner_kind='offline_profile'and source_channel='walk_in'and customer_id is null and vehicle_id is null and booking_date is null and booking_time is null and offline_profile_id is not null and offline_car_ref_id is not null and offline_channel_version_id is not null and requested_by is not null and reserve_request_id is not null));
alter table private.service_reward_redemptions add column owner_kind text not null default 'auth_customer',add column offline_profile_id uuid references private.offline_customer_profiles(profile_id),add column offline_channel_version_id uuid references private.offline_visit_channel_versions(version_id),add column requested_by uuid references auth.users(id);
alter table private.service_reward_redemptions alter column customer_id drop not null;
alter table private.service_reward_redemptions add constraint reward_redemption_typed_owner check((owner_kind='auth_customer'and customer_id is not null and offline_profile_id is null and offline_channel_version_id is null)or(owner_kind='offline_profile'and customer_id is null and offline_profile_id is not null and offline_channel_version_id is not null and requested_by is not null and booking_id is null and source_channel='walk_in'));
create unique index offline_reward_request_once on private.service_reward_redemptions(offline_profile_id,request_id)where owner_kind='offline_profile';
alter table private.reward_refund_reviews add column owner_kind text not null default 'auth_customer',add column offline_profile_id uuid references private.offline_customer_profiles(profile_id),add column offline_channel_version_id uuid references private.offline_visit_channel_versions(version_id);
alter table private.reward_refund_reviews alter column customer_id drop not null;
alter table private.reward_refund_reviews add constraint reward_review_typed_owner check((owner_kind='auth_customer'and customer_id is not null and offline_profile_id is null and offline_channel_version_id is null)or(owner_kind='offline_profile'and customer_id is null and offline_profile_id is not null and offline_channel_version_id is not null));
create table private.offline_reward_reservation_commands(request_id uuid primary key,offline_profile_id uuid not null references private.offline_customer_profiles(profile_id),requested_by uuid not null references auth.users(id),quote_id uuid not null unique references private.service_reward_quotes(quote_id)deferrable initially deferred,payload jsonb not null,state text not null check(state in('preparing','active','released','expired','refunded')),result jsonb,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.offline_reward_reservation_events(event_key text primary key,request_id uuid not null references private.offline_reward_reservation_commands(request_id),action text not null check(action in('reserve','released','expired','refunded')),actor_id uuid not null references auth.users(id),reason text,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.service_reward_quotes add foreign key(reserve_request_id)references private.offline_reward_reservation_commands(request_id)deferrable initially deferred;
alter table private.reward_credit_claims add column owner_kind text not null default 'auth_customer',add column offline_profile_id uuid references private.offline_customer_profiles(profile_id),add column offline_channel_version_id uuid references private.offline_visit_channel_versions(version_id),add column reserve_request_id uuid references private.offline_reward_reservation_commands(request_id),add column hold_expires_at timestamptz;
alter table private.reward_credit_claims alter column customer_id drop not null;
alter table private.reward_credit_claims drop constraint reward_credit_claims_kind_check,drop constraint reward_credit_claims_check;
alter table private.reward_credit_claims add constraint reward_claim_kind check(kind in('reward','offset','reserve')),
add constraint reward_claim_shape check((kind='reward'and redemption_id is not null and quote_id is not null and debt_id is null and reserve_request_id is null and hold_expires_at is null)or(kind='offset'and redemption_id is null and quote_id is null and debt_id is not null and reserve_request_id is null and hold_expires_at is null)or(kind='reserve'and redemption_id is null and quote_id is not null and debt_id is null and reserve_request_id is not null and hold_expires_at is not null)),
add constraint reward_claim_typed_owner check((owner_kind='auth_customer'and customer_id is not null and offline_profile_id is null and offline_channel_version_id is null and kind<>'reserve')or(owner_kind='offline_profile'and customer_id is null and offline_profile_id is not null and offline_channel_version_id is not null));
do $$declare t text;begin foreach t in array array['offline_reward_reservation_commands','offline_reward_reservation_events']loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_offline_reservation_event before update or delete on private.offline_reward_reservation_events for each row execute function private.immutable_canonical_visit();
create or replace function private.quote_service_reward(p_request uuid,p_service uuid,p_branch uuid,p_vehicle uuid,p_date date,p_time time,p_policy uuid,p_rules uuid,p_notes text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r private.loyalty_redemption_rule_versions;s public.business_catalog_items;q private.service_reward_quotes;payload jsonb;terms jsonb;allocations jsonb;ids uuid[];adoptions uuid[];deadline timestamptz;fingerprint text;blocked jsonb;threshold integer;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null or p_service is null or p_branch is null or p_vehicle is null or p_date is null or p_time is null or p_policy is null or p_rules is null or length(coalesce(p_notes,''))>2000 then raise exception 'Complete explicit reward booking details required' using errcode='22023';end if;
 payload:=jsonb_build_object('service',p_service,'branch',p_branch,'vehicle',p_vehicle,'date',p_date,'time',p_time,'policy',p_policy,'rules',p_rules,'notes',nullif(trim(p_notes),''),'source_channel','booking');
 perform pg_advisory_xact_lock(hashtextextended('reward-quote:'||p_request::text,0));select * into q from private.service_reward_quotes where quote_id=p_request;
 if q.quote_id is not null then if q.owner_kind<>'auth_customer'or q.customer_id is distinct from auth.uid() then raise exception 'Quote access denied' using errcode='42501';end if;if q.payload<>payload then raise exception 'Quote request changed' using errcode='22023';end if;return private.customer_reward_quote(q)||jsonb_build_object('eligible',q.expires_at>clock_timestamp(),'reason',case when q.expires_at<=clock_timestamp() then 'quote_expired' else 'quoted' end,'amount_due',0,'reward_discount',q.gross_amount,'adoption_required',cardinality(q.adoption_ids)>0,'unit','service_visits','currency','EGP');end if;
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
 return private.customer_reward_quote(q)||jsonb_build_object('eligible',true,'amount_due',0,'reward_discount',q.gross_amount,'adoption_required',cardinality(q.adoption_ids)>0,'unit','service_visits','currency','EGP','collectible',false);
end $$;
create or replace function private.sync_customer_rewards(p_customer uuid) returns void language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare redemption private.service_reward_redemptions;q private.service_reward_quotes;review private.reward_refund_reviews;candidate uuid;needed integer;
begin
 if p_customer is null or not exists(select 1 from public.customers where id=p_customer)then raise exception 'Actual Auth owner required'using errcode='22023';end if;
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
 select d.redemption_id,c.claim_id,c.earning_id,f.refund,p_customer,d.branch_id,(refund_quote.terms_snapshot->>'offer_id')::uuid,refund_quote.terms_snapshot#>>'{rules,refunded_contribution}' from private.reward_credit_claims c join private.service_reward_redemptions d on d.redemption_id=c.redemption_id join private.service_reward_quotes refund_quote on refund_quote.quote_id=d.quote_id cross join lateral(select private.reward_credit_refund(c.earning_id) refund)f where c.customer_id=p_customer and c.kind='reward' and c.released_at is null and d.state in('covered','forfeited') and f.refund is not null on conflict(original_claim_id,refund_payment_id) do nothing;
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
create or replace function private.list_reward_refund_reviews(p_branch uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare customer_key uuid;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 for customer_key in select distinct customer_id from private.service_reward_redemptions where owner_kind='auth_customer'and customer_id is not null and(p_branch is null or branch_id=p_branch)order by customer_id loop perform private.sync_customer_rewards(customer_key);end loop;
 select coalesce(jsonb_agg(jsonb_build_object('review_id',r.review_id,'customer_id',r.customer_id,'customer_name',customer.full_name,'invoice_number',coalesce(invoice.display_number,invoice.invoice_id),'booking_number',booking.display_number,'created_at',r.created_at,'service_name',invoice.service_name,'redemption_status',redemption.state,'branch_id',r.branch_id,'offer_id',r.offer_id,'mode',r.mode,'acknowledged_at',r.acknowledged_at,'closed_at',r.closed_at,'debt_outstanding',not exists(select 1 from private.reward_credit_claims c where c.debt_id=r.review_id and c.released_at is null and private.reward_credit_refund(c.earning_id) is null))order by r.created_at),'[]') into result from private.reward_refund_reviews r join private.service_reward_redemptions redemption on redemption.redemption_id=r.redemption_id join public.business_invoices invoice on invoice.invoice_id=redemption.invoice_id left join public.bookings booking on booking.id=redemption.booking_id join public.customers customer on customer.id=r.customer_id where p_branch is null or r.branch_id=p_branch;return result;
end $$;
create or replace function private.resolve_reward_refund_review(p_request uuid,p_review uuid,p_note text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare review private.reward_refund_reviews;prior private.reward_command_requests;payload jsonb;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_review is null or length(trim(coalesce(p_note,''))) not between 2 and 1000 then raise exception 'Explicit review and audit note required';end if;
 payload:=jsonb_build_object('review',p_review,'note',p_note,'action','acknowledge_without_debt_waiver');perform pg_advisory_xact_lock(hashtextextended('reward-command:'||p_request::text,0));select * into prior from private.reward_command_requests where request_id=p_request;
 if prior.request_id is not null then if prior.actor_id<>auth.uid() or prior.payload<>payload then raise exception 'Review request mismatch';end if;return prior.result;end if;
 select * into review from private.reward_refund_reviews where review_id=p_review;if review.review_id is null or review.owner_kind<>'auth_customer'or review.customer_id is null then raise exception 'Actual refund review required';end if;
 perform private.sync_customer_rewards(review.customer_id);
 update private.reward_refund_reviews set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),acknowledged_by=coalesce(acknowledged_by,auth.uid()) where review_id=p_review;
 perform private.sync_customer_rewards(review.customer_id);
 result:=jsonb_build_object('review_id',p_review,'acknowledged',true,'debt_waived',false,'visits_minted',0);
 insert into private.reward_command_requests values(p_request,auth.uid(),payload,result,clock_timestamp());
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data) values('review_ack:'||p_review,review.redemption_id,auth.uid(),payload) on conflict(event_key)do nothing;return result;
end $$;
create or replace function private.reward_invoice_coverage(p_invoice text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;i public.business_invoices;n bigint;
begin
 select * into d from private.service_reward_redemptions where invoice_id=p_invoice;if d.redemption_id is null then return null;end if;
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;select * into i from public.business_invoices where invoice_id=p_invoice;
 if i.invoice_id is null or i.order_id is distinct from d.order_id or i.branch_id is distinct from d.branch_id or i.total<>0 or i.discount is distinct from q.gross_amount or i.reward_snapshot is distinct from d.coverage_snapshot then return null;end if;
 if d.owner_kind<>'auth_customer'or q.owner_kind<>'auth_customer'or d.customer_id is null or q.customer_id is null then return null;end if;
 if q.quote_id is null or d.customer_id<>q.customer_id or d.branch_id<>q.branch_id or d.rules_version_id<>q.rules_version_id or d.policy_version_id<>q.policy_version_id or d.source_channel<>q.source_channel or not coalesce((d.consent->>'accept_terms')::boolean,false) then return null;end if;
 select count(distinct c.earning_id) into n from private.reward_credit_claims c where c.redemption_id=d.redemption_id and c.quote_id=q.quote_id and c.kind='reward' and c.customer_id=d.customer_id and c.earning_id=any(q.earning_ids) and(d.state='restored' or c.released_at is null);
 if n<>q.threshold_visits or not exists(select 1 from public.business_orders where order_id=d.order_id and customer_id=d.customer_id and branch_id=d.branch_id and(booking_id is not distinct from d.booking_id)) or exists(select 1 from public.business_payment_events where invoice_id=p_invoice) or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id and redemption_id=d.redemption_id) then return null;end if;
 if d.state='covered' and i.status<>'active' then return null;end if;
 if d.state in('restored','forfeited') and(i.status<>'void' or not exists(select 1 from public.business_orders where order_id=d.order_id and status='cancelled') or(d.source_channel='booking' and not exists(select 1 from public.bookings where id=d.booking_id and status='cancelled')))then return null;end if;
 return jsonb_build_object('state',case when d.state='covered' and i.status='active' then 'covered_by_reward' else 'cancelled_reward' end,'quote_id',q.quote_id,'rules_version_id',q.rules_version_id,'policy_version_id',q.policy_version_id,'threshold_visits',q.threshold_visits,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','rules',q.terms_snapshot->'rules','redemption_status',d.state,'source_channel',d.source_channel);
end $$;
create or replace function private.guard_reward_invoice() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;n bigint;
begin
 if tg_op='UPDATE' then
 if new.reward_snapshot is distinct from old.reward_snapshot then raise exception 'Issued reward snapshot cannot be added or changed';end if;
 if old.reward_snapshot is not null and(new.total is distinct from old.total or new.discount is distinct from old.discount or new.order_id is distinct from old.order_id or new.branch_id is distinct from old.branch_id) then raise exception 'Issued reward financial amounts/identity are immutable';end if;return new;end if;
 if new.reward_snapshot is null then return new;end if;
 select * into d from private.service_reward_redemptions where invoice_id=new.invoice_id and creator_xid=txid_current() and state='covered';
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;
 if d.owner_kind is distinct from'auth_customer'or q.owner_kind is distinct from'auth_customer'or d.customer_id is null or q.customer_id is null then raise exception 'Offline coverage issuer is not installed'using errcode='42501';end if;
 select count(*) into n from private.reward_credit_claims where redemption_id=d.redemption_id and kind='reward' and released_at is null and customer_id=d.customer_id and earning_id=any(q.earning_ids);
 if d.redemption_id is null or q.quote_id is null or n<>q.threshold_visits or new.reward_snapshot is distinct from d.coverage_snapshot or new.total<>0 or new.discount is distinct from q.gross_amount or new.order_id is distinct from d.order_id or new.branch_id is distinct from d.branch_id or not coalesce((d.consent->>'accept_terms')::boolean,false) then raise exception 'Server-created consented reward coverage and actual allocated visits required' using errcode='42501';end if;
 return new;
end $$;
create function private.fence_unimplemented_offline_reward_entities()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.owner_kind<>'auth_customer'or new.customer_id is null then raise exception 'Offline redemption/debt issuer not implemented'using errcode='55000';end if;
 return new;end$$;
create trigger fence_offline_redemption before insert or update on private.service_reward_redemptions for each row execute function private.fence_unimplemented_offline_reward_entities();
create trigger fence_offline_refund_review before insert or update on private.reward_refund_reviews for each row execute function private.fence_unimplemented_offline_reward_entities();
create function private.guard_offline_reward_quote()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.owner_kind='auth_customer'then return new;end if;
 if not exists(select 1 from private.offline_reward_reservation_commands c where c.request_id=new.reserve_request_id and c.quote_id=new.quote_id and c.offline_profile_id=new.offline_profile_id and c.requested_by=new.requested_by and c.creator_xid=txid_current()and c.state='preparing')
 or not exists(select 1 from private.offline_customer_car_refs car where car.car_ref_id=new.offline_car_ref_id and car.profile_id=new.offline_profile_id)
 or not exists(select 1 from private.offline_visit_channel_versions v where v.version_id=new.offline_channel_version_id and v.policy_version_id=new.policy_version_id and v.rules_version_id=new.rules_version_id and v.branch_id=new.branch_id)
 then raise exception 'Actual typed reservation quote proof required'using errcode='55000';end if;
 return new;end$$;
create trigger guard_typed_offline_quote before insert on private.service_reward_quotes for each row execute function private.guard_offline_reward_quote();
create or replace function private.block_offline_reward_claim_until_typed_allocator()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.canonical_loyalty_visits where id=new.earning_id and source_channel='offline_walk_in')then
 if new.owner_kind<>'offline_profile'or new.kind<>'reserve'or not exists(select 1 from private.offline_reward_reservation_commands c where c.request_id=new.reserve_request_id and c.offline_profile_id=new.offline_profile_id and c.quote_id=new.quote_id and c.state='preparing'and c.creator_xid=txid_current())then raise exception 'Only internal typed offline reserve proof is installed'using errcode='55000';end if;end if;return new;end$$;
create or replace function private.guard_reward_claim() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;q private.service_reward_quotes;
begin
 if tg_op='DELETE' then raise exception 'Reward claim history cannot be deleted';end if;
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
create function private.guard_offline_reservation_command()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Reservation command retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['state','result'])is distinct from(to_jsonb(old)-array['state','result'])or old.state not in('preparing','active')
 or(old.state='preparing'and(new.state<>'active'or old.creator_xid<>txid_current()))or(old.state='active'and new.state not in('released','expired','refunded'))then raise exception 'Only canonical reservation transitions allowed'using errcode='55000';end if;
 return new;end$$;
create trigger guard_offline_reservation_command before update or delete on private.offline_reward_reservation_commands for each row execute function private.guard_offline_reservation_command();
create function private.check_offline_reservation_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;n integer;
begin
 select *into c from private.offline_reward_reservation_commands where request_id=new.request_id;select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 select count(distinct earning_id)into n from private.reward_credit_claims where reserve_request_id=c.request_id and released_at is null;
 if c.state='preparing'or q.owner_kind is distinct from'offline_profile'or q.reserve_request_id is distinct from c.request_id or q.offline_profile_id is distinct from c.offline_profile_id
 or(c.state='active'and n<>q.threshold_visits)or(c.state<>'active'and n<>0)
 or not exists(select 1 from private.offline_reward_reservation_events where request_id=c.request_id and action='reserve')then raise exception 'Complete typed reservation required at commit'using errcode='55000';end if;return new;end$$;
create constraint trigger offline_reservation_commit after insert or update on private.offline_reward_reservation_commands deferrable initially deferred for each row execute function private.check_offline_reservation_commit();
create function private.require_offline_reservation_operator()returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 return private.require_offline_channel_owner(); -- reuse actual current owner/session proof, no channel mutation
end$$;
create function private.offline_reward_reservation_snapshot(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;
begin
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 return jsonb_build_object('request_id',c.request_id,'quote_id',c.quote_id,'state',c.state,'expires_at',q.expires_at,'fingerprint',q.fingerprint,'held_visits',(select count(*)from private.reward_credit_claims where reserve_request_id=c.request_id and released_at is null),
 'unit','service_visits','component_reservation',true,'consumption_enabled',false,'issuer_enabled',false);
end$$;
create function private.release_offline_reward_reservation(p_request uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;actor uuid;terminal text;
begin
 actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable reservation and audit reason required'using errcode='22023';end if;
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||c.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request for update;
 if c.state<>'active'then return private.offline_reward_reservation_snapshot(p_request);end if;
 select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 terminal:=case when exists(select 1 from private.reward_credit_claims hold where hold.reserve_request_id=c.request_id and(private.reward_credit_refund(hold.earning_id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=hold.earning_id and rev.kind='refund')))then'refunded'when q.expires_at<=clock_timestamp()then'expired'else'released'end;
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,reason,creator_xid)values('release:'||p_request,p_request,terminal,actor,trim(p_reason),txid_current());
 update private.reward_credit_claims set released_at=clock_timestamp()where reserve_request_id=p_request and released_at is null;
 update private.offline_reward_reservation_commands set state=terminal,result=jsonb_build_object('state',terminal,'consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$$;
create function private.reserve_offline_reward_candidates(p_request uuid,p_profile uuid,p_car uuid,p_channel uuid,p_expected_gross numeric)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;c private.offline_reward_reservation_commands;channel private.offline_visit_channel_versions;rules private.loyalty_redemption_rule_versions;service public.business_catalog_items;
 payload jsonb;plan jsonb;fresh jsonb;ids uuid[];allocations jsonb;quote uuid:=gen_random_uuid();deadline timestamptz;threshold integer;fingerprint text;item jsonb;pending record;
begin
 actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_profile is null or p_car is null or p_channel is null or p_expected_gross is null or p_expected_gross<=0 or p_expected_gross::text in('NaN','Infinity','-Infinity')then raise exception 'Exact typed component request required'using errcode='22023';end if;
 payload:=jsonb_build_object('owner_kind','offline_profile','owner_id',p_profile,'car_reference',p_car,'channel',p_channel,'expected_gross',p_expected_gross,'operator',actor,'purpose','private_reservation_component');
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||p_profile::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if found then
 if c.requested_by<>actor or c.offline_profile_id<>p_profile then raise exception 'Reservation unavailable'using errcode='42501';end if;
 if c.payload<>payload then raise exception 'Reservation request changed'using errcode='22023';end if;
 if c.state='active'and exists(select 1 from private.service_reward_quotes q where q.quote_id=c.quote_id and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and private.reward_credit_refund(h.earning_id)is not null)))then return private.release_offline_reward_reservation(p_request,'Actual expiry or source refund invalidated unconsumed hold');end if;
 return private.offline_reward_reservation_snapshot(p_request);end if;
 -- Same owner lock is acquired BEFORE all request locks, including expired-hold release.
 for pending in select cmd.request_id from private.offline_reward_reservation_commands cmd join private.service_reward_quotes q on q.quote_id=cmd.quote_id where cmd.offline_profile_id=p_profile and cmd.state='active'and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=cmd.request_id and private.reward_credit_refund(h.earning_id)is not null))order by cmd.request_id loop
 perform private.release_offline_reward_reservation(pending.request_id,'Release expired or actually refunded unconsumed component hold');end loop;
 select *into channel from private.offline_visit_channel_versions where version_id=p_channel;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=channel.rules_version_id;
 select *into service from public.business_catalog_items where item_id=(rules.terms_snapshot#>>'{reward_service,id}')::uuid and branch_id=channel.branch_id and item_type='service'and is_active and is_public for share;
 if service.item_id is null or service.price is distinct from p_expected_gross or not exists(select 1 from private.offline_customer_car_refs car where car.car_ref_id=p_car and car.profile_id=p_profile)then raise exception 'Actual owner/car/reward service price changed'using errcode='40001';end if;
 plan:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if not coalesce((plan->>'threshold_met')::boolean,false)then raise exception 'Insufficient actual candidate credits'using errcode='55000';end if;
 select array_agg(candidate.value::uuid order by candidate.ordinality)into ids from jsonb_array_elements_text(plan->'candidate_ids')with ordinality candidate(value,ordinality);
 perform 1 from public.business_invoices i join private.canonical_loyalty_visits e on e.invoice_id=i.invoice_id where e.id=any(ids)order by i.invoice_id for update of i;
 fresh:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if fresh->'candidate_ids'is distinct from plan->'candidate_ids'or fresh->'allocation_candidates'is distinct from plan->'allocation_candidates'then raise exception 'Candidate facts changed after financial lock wait'using errcode='40001';end if;
 allocations:=fresh->'allocation_candidates';threshold:=(fresh->>'required_visits')::integer;
 select least(clock_timestamp()+interval'5 minutes',min((entry#>>'{credit_terms,expires_at}')::timestamptz))into deadline from jsonb_array_elements(allocations)entry;
 if rules.rules->>'expiry'='snapshot_offer_end'then deadline:=least(deadline,(rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz);end if;
 if deadline is null or deadline<=clock_timestamp()then raise exception 'Original credit or selected benefit expiry passed'using errcode='55000';end if;
 fingerprint:=encode(extensions.digest(jsonb_build_object('payload',payload,'rules',rules.terms_snapshot,'earning_ids',ids,'allocations',allocations,'gross',service.price,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.offline_reward_reservation_commands(request_id,offline_profile_id,requested_by,quote_id,payload,state,creator_xid)values(p_request,p_profile,actor,quote,payload,'preparing',txid_current());
 insert into private.service_reward_quotes(quote_id,customer_id,source_channel,payload,branch_id,service_id,vehicle_id,booking_date,booking_time,policy_version_id,rules_version_id,threshold_visits,gross_amount,earning_ids,adoption_ids,allocation_snapshot,terms_snapshot,fingerprint,expires_at,owner_kind,offline_profile_id,offline_car_ref_id,offline_channel_version_id,requested_by,reserve_request_id)
 values(quote,null,'walk_in',payload,channel.branch_id,service.item_id,null,null,null,channel.policy_version_id,rules.rules_version_id,threshold,service.price,ids,'{}'::uuid[],allocations,rules.terms_snapshot||jsonb_build_object('source_channel','walk_in','component_reservation',true,'consumption_enabled',false),fingerprint,deadline,'offline_profile',p_profile,p_car,p_channel,actor,p_request);
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,creator_xid)values('reserve:'||p_request,p_request,'reserve',actor,txid_current());
 for item in select value from jsonb_array_elements(allocations)loop
 insert into private.reward_credit_claims(earning_id,customer_id,kind,quote_id,owner_kind,offline_profile_id,offline_channel_version_id,reserve_request_id,hold_expires_at)
 values((item->>'earning_id')::uuid,null,'reserve',quote,'offline_profile',p_profile,p_channel,p_request,deadline);end loop;
 update private.offline_reward_reservation_commands set state='active',result=jsonb_build_object('state','active','consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$$;
revoke all on function private.fence_unimplemented_offline_reward_entities(),private.guard_offline_reward_quote(),private.guard_offline_reservation_command(),private.check_offline_reservation_commit(),private.require_offline_reservation_operator(),private.offline_reward_reservation_snapshot(uuid),private.release_offline_reward_reservation(uuid,text),private.reserve_offline_reward_candidates(uuid,uuid,uuid,uuid,numeric)from public,anon,authenticated,service_role;
-- No public entry point, activation/financial consent shortcut, consumption or reward invoice.
commit;
