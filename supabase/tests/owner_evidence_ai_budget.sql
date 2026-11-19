-- No model calls. Private quota updates are transaction-local and rolled back.
begin;
do $$
declare own uuid;customer uuid;used integer;i integer;result jsonb;denied boolean;
begin
 select user_id into strict own from public.staff_profiles where role='owner' and is_active limit 1;
 select c.id into strict customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id) limit 1;
 select coalesce((select request_count from private.owner_evidence_ai_daily where owner_id=own and day=(now() at time zone 'UTC')::date),0) into used;
 perform set_config('request.jwt.claim.sub',customer::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.claim_owner_evidence_ai_budget();exception when insufficient_privilege then denied:=true;end;assert denied,'Customer consumed owner quota';
 perform set_config('request.jwt.claim.sub',own::text,true);
 for i in used+1..3 loop
  result:=public.claim_owner_evidence_ai_budget();assert (result->>'remaining')::integer=3-i;
 end loop;
 denied:=false;begin perform public.claim_owner_evidence_ai_budget();exception when invalid_parameter_value then denied:=true;end;assert denied,'Owner exceeded three daily attempts';
 denied:=false;begin perform 1 from private.owner_evidence_ai_daily;exception when insufficient_privilege then denied:=true;end;assert denied,'Client directly accessed private quota rows';
 execute 'set local role anon';denied:=false;begin perform public.claim_owner_evidence_ai_budget();exception when insufficient_privilege then denied:=true;end;assert denied,'Anonymous owner quota access';
 raise notice 'PASS owner-only atomic capped daily AI budget; no provider calls';
end;$$;
rollback;
