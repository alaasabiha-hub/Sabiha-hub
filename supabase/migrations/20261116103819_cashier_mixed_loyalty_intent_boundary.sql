begin;
-- Seal only. No wallet lookup, consent, reservation, discount, debit or activation.
create table private.cashier_loyalty_draft_intents(
 request_id uuid primary key,
 actor_id uuid not null references auth.users(id),
 branch_id uuid not null references public.business_branches(branch_id),
 draft_id uuid not null references private.cashier_reviewed_drafts(draft_id),
 draft_version integer not null check(draft_version>0),
 binding_version integer not null check(binding_version>0),
 witness jsonb not null,
 fingerprint text not null check(fingerprint ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 unique(draft_id,draft_version,binding_version),
 check(expires_at>created_at and expires_at<=created_at+interval '15 minutes')
);
alter table private.cashier_loyalty_draft_intents enable row level security;
revoke all on private.cashier_loyalty_draft_intents from public,anon,authenticated,service_role;
create trigger immutable_cashier_loyalty_intent before update or delete on private.cashier_loyalty_draft_intents for each row execute function private.immutable_loyalty_policy();

create function private.cashier_loyalty_draft_witness(p_actor uuid,p_branch uuid,p_draft uuid,p_version integer,p_binding integer)returns jsonb
language plpgsql volatile security invoker set search_path=pg_catalog set lock_timeout='20s' as $$
declare d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;q jsonb;s jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Draft sealing requires READ COMMITTED'using errcode='25001';end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>p_actor or d.branch_id<>p_branch then raise exception 'Own draft required'using errcode='42501';end if;
 if d.version<>p_version or exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then raise exception 'Current unissued draft required'using errcode='40001';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft for update;
 if not found or b.actor_id<>p_actor or b.branch_id<>p_branch or b.version<>p_binding or b.draft_version<>d.version then raise exception 'Current explicit subject binding required'using errcode='40001';end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by c.item_id for update;
 perform 1 from private.owner_tax_active t where t.branch_id=p_branch and t.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by t.item_id for share;
 q:=private.quote_cashier_cart_reviewed(p_branch,d.payload->'items',d.payload->>'discount_mode',(d.payload->>'discount_value')::numeric);
 if(q-'as_of')is distinct from(d.quote-'as_of')then raise exception 'Review current price, tax and availability first'using errcode='40001';end if;
 s:=private.cashier_subject_snapshot(p_branch,b.subject_kind,b.subject_id,b.car_id);
 if s is distinct from b.subject_snapshot then raise exception 'Review current subject and car first'using errcode='40001';end if;
 return jsonb_build_object('version','mixed-pos-loyalty-base-v1','draft',p_draft,'draft_version',d.version,'binding_version',b.version,
 'branch',p_branch,'subject_kind',b.subject_kind,'subject',b.subject_id,'car',b.car_id,'subject_snapshot',s,'payload',d.payload,'quote',q-'as_of','currency','EGP');
end$$;

create function private.seal_cashier_loyalty_draft(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare a uuid;prior private.cashier_loyalty_draft_intents;w jsonb;v_now timestamptz:=clock_timestamp();fp text;
begin
 a:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_draft_version is null or p_expected_draft_version<1 or p_expected_binding_version is null or p_expected_binding_version<1 then raise exception 'Exact saved draft and binding versions required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('cashier-loyalty-intent:'||p_request,0));
 select *into prior from private.cashier_loyalty_draft_intents where request_id=p_request;
 if found then
  if prior.actor_id<>a or prior.branch_id<>p_branch then raise exception 'Intent unavailable'using errcode='42501';end if;
  if prior.draft_id<>p_draft or prior.draft_version<>p_expected_draft_version or prior.binding_version<>p_expected_binding_version then raise exception 'Immutable intent request'using errcode='22023';end if;
  -- A retry recovers the original receipt, never a fresh consent or extended expiry.
  return jsonb_build_object('intent_id',prior.request_id,'fingerprint',prior.fingerprint,'expires_at',prior.expires_at,'seal_only',true,'consent_authorized',false,'redemption_enabled',false);
 end if;
 w:=private.cashier_loyalty_draft_witness(a,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version);
 perform private.cashier_cart_actor(p_branch);
 perform private.cashier_cart_actor(p_branch);
 if exists(select 1 from private.cashier_loyalty_draft_intents where draft_id=p_draft and draft_version=p_expected_draft_version and binding_version=p_expected_binding_version)then raise exception 'Draft version already sealed; recover its original intent'using errcode='40001';end if;
 fp:=encode(extensions.digest(jsonb_build_object('request',p_request,'actor',a,'witness',w,'created_at',v_now,'expires_at',v_now+interval '15 minutes')::text,'sha256'),'hex');
 insert into private.cashier_loyalty_draft_intents values(p_request,a,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version,w,fp,v_now,v_now+interval '15 minutes');
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(a::text,a,'cashier_loyalty_draft_sealed','cashier_reviewed_draft',p_draft::text,p_branch,jsonb_build_object('intent_id',p_request,'draft_version',p_expected_draft_version,'binding_version',p_expected_binding_version,'fingerprint',fp,'redemption_enabled',false));
 return jsonb_build_object('intent_id',p_request,'fingerprint',fp,'expires_at',v_now+interval '15 minutes','seal_only',true,'consent_authorized',false,'redemption_enabled',false);
end$$;

create function private.get_cashier_loyalty_draft_intent(p_branch uuid,p_request uuid)returns jsonb
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
 exception when serialization_failure or object_not_in_prerequisite_state then state:='stale';end;
 end if;
 return jsonb_build_object('intent_id',i.request_id,'fingerprint',i.fingerprint,'state',state,'expires_at',i.expires_at,'seal_only',true,'consent_authorized',false,'redemption_enabled',false,'wallet_disclosed',false);
end$$;
create function public.seal_cashier_loyalty_draft(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.seal_cashier_loyalty_draft(p_request,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version)$$;
create function public.get_cashier_loyalty_draft_intent(p_branch uuid,p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_loyalty_draft_intent(p_branch,p_request)$$;
revoke all on function private.cashier_loyalty_draft_witness(uuid,uuid,uuid,integer,integer),private.seal_cashier_loyalty_draft(uuid,uuid,uuid,integer,integer),private.get_cashier_loyalty_draft_intent(uuid,uuid),public.seal_cashier_loyalty_draft(uuid,uuid,uuid,integer,integer),public.get_cashier_loyalty_draft_intent(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.seal_cashier_loyalty_draft(uuid,uuid,uuid,integer,integer),private.get_cashier_loyalty_draft_intent(uuid,uuid),public.seal_cashier_loyalty_draft(uuid,uuid,uuid,integer,integer),public.get_cashier_loyalty_draft_intent(uuid,uuid)to authenticated;
notify pgrst,'reload schema';
commit;
