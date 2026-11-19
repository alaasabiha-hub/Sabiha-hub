begin;
-- Keep applied A immutable; disambiguate the refund query alias from PL/pgSQL's frozen quote row.
create or replace function private.sync_customer_rewards(p_customer uuid) returns void language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
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
commit;
