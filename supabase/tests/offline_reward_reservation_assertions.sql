-- SOURCE ONLY helper: load into root's REAL earned-credit component fixture.
-- Requires genuine unrefunded own candidates >= actual threshold (suggest QA threshold1).
-- No fake credit INSERT, Auth creation, HR edit, payment or issued invoice creation here.
create function pg_temp.assert_offline_reserve_release(p_profile uuid,p_car uuid,p_channel uuid,p_gross numeric)returns void language plpgsql as $$
declare request_id uuid:=gen_random_uuid();first jsonb;again jsonb;released jsonb;q private.service_reward_quotes;before_invoices bigint;before_redemptions bigint;before_reviews bigint;denied boolean;terms_before jsonb;
begin
 select count(*)into before_invoices from public.business_invoices;select count(*)into before_redemptions from private.service_reward_redemptions;select count(*)into before_reviews from private.reward_refund_reviews;
 select coalesce(jsonb_object_agg(e.id::text,private.reward_credit_terms(e.id,b.rules_version_id)-'valid'),'{}'::jsonb)into terms_before from private.canonical_loyalty_visits e join private.reward_earning_terms b on b.earning_id=e.id where e.offline_profile_id=p_profile and e.kind='earn';
 assert not has_function_privilege('authenticated','private.reserve_offline_reward_candidates(uuid,uuid,uuid,uuid,numeric)','EXECUTE');
 first:=private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross);
 assert first->>'state'='active'and(first->>'held_visits')::integer>0;
 again:=private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross);assert again=first,'Same nonce must replay same quote/claims';
 select *into strict q from private.service_reward_quotes where quote_id=(first->>'quote_id')::uuid;
 assert q.owner_kind='offline_profile'and q.customer_id is null and q.vehicle_id is null and q.booking_date is null and q.booking_time is null and q.offline_profile_id=p_profile and q.offline_car_ref_id=p_car;
 assert q.gross_amount=p_gross and q.expires_at<=clock_timestamp()+interval'5 minutes';
 assert(select count(*)from private.reward_credit_claims where reserve_request_id=request_id and released_at is null)=q.threshold_visits;
 assert not exists(select 1 from jsonb_array_elements(q.allocation_snapshot)item where item->'credit_terms'is distinct from private.reward_credit_terms((item->>'earning_id')::uuid,q.rules_version_id));
 denied:=false;begin perform private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross+1);exception when invalid_parameter_value then denied:=true;end;assert denied;
 -- Public Auth quote path cannot replay/expose an offline quote with a known UUID.
 denied:=false;begin perform private.quote_service_reward(q.quote_id,q.service_id,q.branch_id,q.offline_car_ref_id,current_date+1,'12:00',q.policy_version_id,q.rules_version_id,null);exception when insufficient_privilege then denied:=true;end;assert denied;
 released:=private.release_offline_reward_reservation(request_id,'Explicit unconsumed component hold cancellation');assert released->>'state'='released'and released->>'held_visits'='0';
 assert private.release_offline_reward_reservation(request_id,'Repeated safe release of original component hold')=released;
 assert private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross)=released,'Terminal nonce must not reserve again';
 assert not exists(select 1 from private.reward_credit_claims where reserve_request_id=request_id and released_at is null);
 assert terms_before=(select coalesce(jsonb_object_agg(e.id::text,private.reward_credit_terms(e.id,b.rules_version_id)-'valid'),'{}'::jsonb)from private.canonical_loyalty_visits e join private.reward_earning_terms b on b.earning_id=e.id where e.offline_profile_id=p_profile and e.kind='earn'),'Release must preserve original expiry/cohort';
 assert(select count(*)from public.business_invoices)=before_invoices;
 assert(select count(*)from private.service_reward_redemptions)=before_redemptions;
 assert(select count(*)from private.reward_refund_reviews)=before_reviews;
 set constraints all immediate;
 set constraints all deferred;
end$$;

-- Call after root's ACTUAL full cash refund has committed, even before async reversal.
create function pg_temp.assert_offline_refund_blocks_reserve(p_profile uuid,p_car uuid,p_channel uuid,p_gross numeric)returns void language plpgsql as $$
declare before_count bigint;denied boolean;
begin
 select count(*)into before_count from private.reward_credit_claims;
 denied:=false;begin perform private.reserve_offline_reward_candidates(gen_random_uuid(),p_profile,p_car,p_channel,p_gross);exception when object_not_in_prerequisite_state or serialization_failure then denied:=true;end;assert denied,'Actual refund before claim must exclude candidates';
 assert(select count(*)from private.reward_credit_claims)=before_count;
end$$;

-- Requires a REAL original frozen expiry within10seconds, prepared by root's QA policy.
-- No fake clock, immutable quote edit or shipped test bypass.
create function pg_temp.assert_offline_reservation_expiry(p_profile uuid,p_car uuid,p_channel uuid,p_gross numeric)returns void language plpgsql as $$
declare request_id uuid:=gen_random_uuid();result jsonb;q private.service_reward_quotes;wait_seconds numeric;before_terms jsonb;
begin
 result:=private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross);
 select *into strict q from private.service_reward_quotes where quote_id=(result->>'quote_id')::uuid;
 wait_seconds:=extract(epoch from(q.expires_at-clock_timestamp()))+0.05;
 assert wait_seconds>0 and wait_seconds<=10,'Provide genuinely short original expiry, never mutate an issued quote';
 before_terms:=q.allocation_snapshot;
 perform pg_sleep(wait_seconds::double precision);
 result:=private.reserve_offline_reward_candidates(request_id,p_profile,p_car,p_channel,p_gross);
 assert result->>'state'='expired'and result->>'held_visits'='0';
 assert(select allocation_snapshot from private.service_reward_quotes where quote_id=q.quote_id)=before_terms;
 assert not exists(select 1 from private.reward_credit_claims where reserve_request_id=request_id and released_at is null);
 set constraints all immediate;set constraints all deferred;
end$$;
