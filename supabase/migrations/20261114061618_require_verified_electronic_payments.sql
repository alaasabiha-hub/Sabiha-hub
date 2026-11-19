-- No gateway-verification integration exists yet. A manual cashier action must
-- never turn an electronic payment into a paid invoice. Preserve legacy rows;
-- fail closed for new/changed electronic events until a trusted server-only
-- gateway callback and reconciliation ledger are implemented and tested.
begin;

create function private.reject_unverified_electronic_payment()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
begin
  if new.method = 'electronic' then
    raise exception 'Electronic payment requires verified gateway confirmation; manual recording is unavailable'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function private.reject_unverified_electronic_payment()
  from public, anon, authenticated;

-- Guard the ledger itself, including privileged/manual writers, rather than
-- hiding a UI control or trusting a client-supplied "verified" flag.
create trigger require_verified_electronic_payment
before insert or update on public.business_payment_events
for each row execute function private.reject_unverified_electronic_payment();

commit;
