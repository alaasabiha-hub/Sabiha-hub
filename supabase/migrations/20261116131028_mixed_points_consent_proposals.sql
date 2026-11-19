begin;
create table private.mixed_points_proposals(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),customer_id uuid not null references public.customers(id),intent_id uuid not null references private.cashier_loyalty_draft_intents(request_id),policy_id uuid not null references private.mixed_points_policy_versions(version_id),points bigint not null check(points>0),terms jsonb not null,fingerprint text not null,expires_at timestamptz not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_consents(
 request_id uuid primary key,proposal_id uuid not null unique references private.mixed_points_proposals(request_id),customer_id uuid not null references public.customers(id),session_id uuid not null,language text not null check(language in('ar','en')),fingerprint text not null,created_at timestamptz not null default clock_timestamp());
alter table private.mixed_points_proposals enable row level security;
alter table private.mixed_points_consents enable row level security;
revoke all on private.mixed_points_proposals,private.mixed_points_consents from public,anon,authenticated,service_role;
create trigger immutable_mixed_proposal before update or delete on private.mixed_points_proposals for each row execute function private.immutable_loyalty_policy();
create trigger immutable_mixed_consent before update or delete on private.mixed_points_consents for each row execute function private.immutable_loyalty_policy();
create table private.mixed_points_consent_revocations(
 request_id uuid primary key,consent_id uuid not null references private.mixed_points_consents(request_id),customer_id uuid not null references public.customers(id),created_at timestamptz not null default clock_timestamp());
alter table private.mixed_points_consent_revocations enable row level security;
revoke all on private.mixed_points_consent_revocations from public,anon,authenticated,service_role;
create trigger immutable_mixed_revocation before update or delete on private.mixed_points_consent_revocations for each row execute function private.immutable_loyalty_policy();
create function private.prepare_mixed_points_proposal(p_request uuid,p_branch uuid,p_intent uuid,p_policy uuid,p_points bigint)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;i private.cashier_loyalty_draft_intents;prior private.mixed_points_proposals;plan jsonb;terms jsonb;fp text;
begin
 actor:=private.cashier_cart_actor(p_branch);if p_request is null then raise exception 'Request required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-proposal:'||p_request,0));
 select *into prior from private.mixed_points_proposals where request_id=p_request;
 if found then
 if prior.actor_id<>actor then raise exception 'Unavailable proposal'using errcode='42501';end if;
 if prior.intent_id is distinct from p_intent or prior.policy_id is distinct from p_policy or prior.points is distinct from p_points then raise exception 'Immutable proposal request'using errcode='22023';end if;
 return jsonb_build_object('proposal_id',prior.request_id,'fingerprint',prior.fingerprint,'expires_at',prior.expires_at,'balance_reserved',false);end if;
 plan:=private.quote_sealed_mixed_loyalty(p_branch,p_intent,p_policy,p_points);
 select *into i from private.cashier_loyalty_draft_intents where request_id=p_intent;
 if i.witness->>'subject_kind'is distinct from'app_customer'then raise exception 'Offline approval adapter not ready'using errcode='55000';end if;
 terms:=private.mixed_loyalty_customer_terms(plan)||jsonb_build_object('car',i.witness#>'{subject_snapshot,car}');
 fp:=encode(extensions.digest(jsonb_build_object('proposal',p_request,'intent',i.fingerprint,'policy',p_policy,'points',p_points,'terms',terms)::text,'sha256'),'hex');
 insert into private.mixed_points_proposals(request_id,actor_id,customer_id,intent_id,policy_id,points,terms,fingerprint,expires_at)values(p_request,actor,(i.witness->>'subject')::uuid,p_intent,p_policy,p_points,terms,fp,i.expires_at);
 return jsonb_build_object('proposal_id',p_request,'fingerprint',fp,'expires_at',i.expires_at,'balance_reserved',false);
end$$;
create function private.accept_mixed_points_proposal(p_request uuid,p_proposal uuid,p_fingerprint text,p_language text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare entry jsonb;proposal private.mixed_points_proposals;prior private.mixed_points_consents;i private.cashier_loyalty_draft_intents;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;
begin
 if not coalesce(private.has_live_invoice_session(),false)or private.active_staff_role()is not null then raise exception 'Actual customer session required'using errcode='42501';end if;
 if p_fingerprint is null then raise exception 'Fingerprint required'using errcode='22023';end if;
 if p_request is null or p_proposal is null or p_language is null or p_language not in('ar','en')then raise exception 'Explicit consent request and language required'using errcode='22023';end if;
 select *into proposal from private.mixed_points_proposals where request_id=p_proposal;
 if not found or proposal.customer_id<>auth.uid()then raise exception 'Proposal unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-consent:'||p_proposal,0));
 select *into prior from private.mixed_points_consents where request_id=p_request;
 if found then
 if prior.customer_id<>auth.uid()or prior.proposal_id<>p_proposal then raise exception 'Consent unavailable'using errcode='42501';end if;
 if prior.fingerprint is distinct from p_fingerprint or prior.language is distinct from p_language then raise exception 'Immutable consent request'using errcode='22023';end if;
 return jsonb_build_object('consent_id',p_request,'accepted',not exists(select 1 from private.mixed_points_consent_revocations where consent_id=p_request),'balance_reserved',false,'payment_confirmed',false);end if;
 if exists(select 1 from private.mixed_points_consents where proposal_id=p_proposal)then raise exception 'Proposal already has consent'using errcode='40001';end if;

 if found then
 if prior.customer_id<>auth.uid()or prior.proposal_id<>p_proposal or prior.language<>p_language or prior.fingerprint is distinct from p_fingerprint then raise exception 'Immutable consent request'using errcode='22023';end if;
 return jsonb_build_object('consent_id',prior.request_id,'accepted',true,'balance_reserved',false,'payment_confirmed',false);end if;
 if proposal.fingerprint is distinct from p_fingerprint or proposal.expires_at<=clock_timestamp()then raise exception 'Exact unexpired terms required'using errcode='40001';end if;
 if not exists(select 1 from auth.users where id=auth.uid()and email_confirmed_at is not null)then raise exception 'Confirmed customer required'using errcode='42501';end if;
 select *into i from private.cashier_loyalty_draft_intents where request_id=proposal.intent_id;
 select *into d from private.cashier_reviewed_drafts where draft_id=i.draft_id for share;
 select *into b from private.cashier_draft_subjects where draft_id=i.draft_id for share;
 if d.version<>i.draft_version or b.version<>i.binding_version or b.subject_kind<>'app_customer'or b.subject_id<>auth.uid()or b.draft_version<>d.version or exists(select 1 from private.cashier_invoice_postings where draft_id=i.draft_id)then raise exception 'Draft or customer binding changed'using errcode='40001';end if;
 if not exists(select 1 from private.mixed_points_policy_current where branch_id=i.branch_id and version_id=proposal.policy_id)then raise exception 'Owner policy changed'using errcode='40001';end if;
 for entry in select value from jsonb_array_elements(i.witness#>'{quote,lines}')loop
 if not exists(select 1 from public.business_catalog_items c where c.item_id=(entry->>'item_id')::uuid and c.branch_id=i.branch_id and c.is_active and c.price=(entry->>'unit_price')::numeric)then raise exception 'Catalogue changed'using errcode='40001';end if;
 end loop;
 if not exists(select 1 from public.vehicles where id=b.car_id and customer_id=auth.uid())then raise exception 'Owned car required'using errcode='42501';end if;
 if not coalesce(private.has_live_invoice_session(),false)or proposal.expires_at<=clock_timestamp()then raise exception 'Session or proposal expired while waiting'using errcode='42501';end if;
 insert into private.mixed_points_consents values(p_request,p_proposal,auth.uid(),(auth.jwt()->>'session_id')::uuid,p_language,p_fingerprint,clock_timestamp());
 return jsonb_build_object('consent_id',p_request,'accepted',true,'balance_reserved',false,'payment_confirmed',false);
end$$;
revoke all on function private.prepare_mixed_points_proposal(uuid,uuid,uuid,uuid,bigint),private.accept_mixed_points_proposal(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.withdraw_mixed_points_consent(p_request uuid,p_consent uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.mixed_points_consents;old private.mixed_points_consent_revocations;
begin
 if not coalesce(private.has_live_invoice_session(),false)or private.active_staff_role()is not null then raise exception 'Actual customer required'using errcode='42501';end if;
 if p_request is null or p_consent is null then raise exception 'Exact request required'using errcode='22023';end if;
 select *into c from private.mixed_points_consents where request_id=p_consent and customer_id=auth.uid();if not found then raise exception 'Consent unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-consent:'||c.proposal_id,0));
 select *into old from private.mixed_points_consent_revocations where request_id=p_request;
 if found then if old.customer_id<>auth.uid()or old.consent_id<>p_consent then raise exception 'Immutable withdrawal request'using errcode='22023';end if;
 else insert into private.mixed_points_consent_revocations values(p_request,p_consent,auth.uid(),clock_timestamp());end if;
 return jsonb_build_object('consent_id',p_consent,'accepted',false,'balance_reserved',false,'payment_confirmed',false);
end$$;
revoke all on function private.withdraw_mixed_points_consent(uuid,uuid)from public,anon,authenticated,service_role;
commit;
