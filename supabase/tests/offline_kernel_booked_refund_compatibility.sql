-- Targeted regression: newly changed shared typed guard on existing booked refund.
begin;
do $$declare reversal private.canonical_loyalty_visits;before_count bigint;denied boolean:=false;other uuid;begin
 select *into strict reversal from private.canonical_loyalty_visits where kind='refund'and source_channel='booking'limit 1;
 select count(*)into before_count from private.canonical_loyalty_visits;
 reversal.id:=gen_random_uuid();
 insert into private.canonical_loyalty_visits select reversal.* on conflict(reverses_earning)where kind='refund'do nothing;
 assert(select count(*)from private.canonical_loyalty_visits)=before_count,'Existing reversal replay must stay one';
 select id into strict other from public.customers where id<>reversal.customer_id limit 1;
 reversal.id:=gen_random_uuid();reversal.customer_id:=other;
 begin insert into private.canonical_loyalty_visits select reversal.* on conflict(reverses_earning)where kind='refund'do nothing;
 exception when object_not_in_prerequisite_state then denied:=true;end;
 assert denied,'Reversal owner substitution must fail even on replay';
end$$;
rollback;
