begin;
-- An unavailable catalogue item invalidates the seal; it never authorizes spending.
create or replace function private.get_cashier_loyalty_draft_intent(p_branch uuid,p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare a uuid;i private.cashier_loyalty_draft_intents;w jsonb;state text:='current';
begin
 a:=private.cashier_cart_actor(p_branch);
 select *into i from private.cashier_loyalty_draft_intents where request_id=p_request;
 if not found or i.actor_id<>a or i.branch_id<>p_branch then raise exception 'Intent unavailable'using errcode='42501';end if;
 if i.expires_at<=clock_timestamp()then state:='expired';
 else begin
  w:=private.cashier_loyalty_draft_witness(a,p_branch,i.draft_id,i.draft_version,i.binding_version);
  if w is distinct from i.witness then state:='stale';end if;
 exception when serialization_failure or object_not_in_prerequisite_state or invalid_parameter_value then state:='stale';end;
 end if;
 return jsonb_build_object('intent_id',i.request_id,'fingerprint',i.fingerprint,'state',state,'expires_at',i.expires_at,'seal_only',true,'consent_authorized',false,'redemption_enabled',false,'wallet_disclosed',false);
end$$;
commit;
