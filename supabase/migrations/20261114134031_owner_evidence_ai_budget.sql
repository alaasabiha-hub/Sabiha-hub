begin;
-- Optional external AI only; three attempted provider requests per owner/UTC day.
create table private.owner_evidence_ai_daily(owner_id uuid not null references public.staff_profiles(user_id),day date not null,request_count integer not null check(request_count between 1 and 3),primary key(owner_id,day));
alter table private.owner_evidence_ai_daily enable row level security;
revoke all on private.owner_evidence_ai_daily from public,anon,authenticated,service_role;
create function private.claim_owner_evidence_ai_budget() returns jsonb language plpgsql security definer set search_path=pg_catalog set timezone='UTC' as $$
declare used integer;begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 insert into private.owner_evidence_ai_daily as budget(owner_id,day,request_count) values(auth.uid(),current_date,1)
 on conflict(owner_id,day) do update set request_count=budget.request_count+1 where budget.request_count<3 returning request_count into used;
 if used is null then raise exception 'Daily AI request limit reached' using errcode='22023';end if;
 return jsonb_build_object('remaining',3-used,'day',current_date,'daily_limit',3);
end;$$;
revoke all on function private.claim_owner_evidence_ai_budget() from public,anon;
grant execute on function private.claim_owner_evidence_ai_budget() to authenticated;
create function public.claim_owner_evidence_ai_budget() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.claim_owner_evidence_ai_budget();$$;
revoke all on function public.claim_owner_evidence_ai_budget() from public,anon;
grant execute on function public.claim_owner_evidence_ai_budget() to authenticated;
notify pgrst,'reload schema';
commit;
