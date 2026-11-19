begin;
-- Independent actual-customer assent only. No issuer, approval shortcut or gate enable.
create table private.offline_reward_financial_proposals(
 proposal_id uuid primary key,preparation_id uuid not null unique references private.offline_reward_consumption_preparations(request_id),
 proposed_by uuid not null references auth.users(id),link_id uuid not null references private.offline_customer_trusted_links(link_id),
 customer_id uuid not null references public.customers(id),witness jsonb not null,display_terms jsonb not null,
 fingerprint text not null check(fingerprint~'^[0-9a-f]{64}$'),expires_at timestamptz not null,created_at timestamptz not null default clock_timestamp()
);
create table private.offline_reward_financial_consents(
 request_id uuid primary key,proposal_id uuid not null unique references private.offline_reward_financial_proposals(proposal_id),
 actor_id uuid not null references public.customers(id),link_id uuid not null references private.offline_customer_trusted_links(link_id),
 session_id uuid not null,consent jsonb not null,fingerprint text not null,created_at timestamptz not null default clock_timestamp()
);
create table private.offline_reward_financial_revocations(
 request_id uuid primary key,consent_request_id uuid not null,actor_id uuid not null references public.customers(id),
 link_id uuid not null references private.offline_customer_trusted_links(link_id),created_at timestamptz not null default clock_timestamp()
);
create index offline_financial_revocations_target on private.offline_reward_financial_revocations(consent_request_id);
do $$declare v_table text;begin
 foreach v_table in array array['offline_reward_financial_proposals','offline_reward_financial_consents','offline_reward_financial_revocations']loop
 execute format('alter table private.%I enable row level security',v_table);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',v_table);
 execute format('create trigger immutable_offline_financial_record before update or delete on private.%I for each row execute function private.immutable_canonical_visit()',v_table);
 end loop;
end$$;
create function private.offline_reward_financial_notice(p_language text,p_terms jsonb)returns text language sql immutable set search_path=pg_catalog as $$select case p_language
 when'en'then 'Service: '||coalesce(nullif(p_terms#>>'{service,name_en}',''),p_terms#>>'{service,name_ar}')||'. Visits: '||(p_terms->>'visits')||'. Original price: '||(p_terms->>'gross_amount')||' EGP. Reward discount: '||(p_terms->>'reward_discount')||' EGP. Customer charge: 0 EGP. Proposal expiry: '||(p_terms->>'expires_at')||'. I agree to use only these reception visits for this one benefit under the shown cancellation, original expiry and refunded-contribution rules. This does not transfer or combine credits, authorize another purchase or automatically issue a reward. I can withdraw consent before issuance.'
 when'ar'then 'الخدمة: '||(p_terms#>>'{service,name_ar}')||'. عدد الزيارات: '||(p_terms->>'visits')||'. السعر الأصلي: '||(p_terms->>'gross_amount')||' جنيه. خصم المكافأة: '||(p_terms->>'reward_discount')||' جنيه. المستحق عليّ: 0 جنيه. انتهاء المقترح: '||(p_terms->>'expires_at')||'. أوافق على استخدام زيارات الاستقبال هذه فقط لهذه المنفعة الواحدة وفق قواعد الإلغاء والانتهاء الأصلي ورد المساهمات المعروضة. لا تنقل الموافقة الأرصدة ولا تدمجها ولا تسمح بعملية أخرى ولا تصدر مكافأة تلقائياً. يمكنني سحب الموافقة قبل الإصدار.'end$$;

-- No read-consent requirement: this resolves actual identity evidence, not history
-- permission. Contact append, link revoke and Auth/session changes cannot pass mid-TX.
create function private.require_offline_financial_customer()returns private.offline_customer_trusted_links
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;
begin
 if private.active_staff_role()is not null then raise exception 'Actual linked customer required'using errcode='42501';end if;
 v_link:=private.resolve_my_offline_history_link();
 lock table private.offline_customer_contacts in share mode;
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'Current linked contact evidence required'using errcode='42501';end if;
 return v_link;
end$$;

create function private.propose_offline_reward_financial_consent(p_proposal uuid,p_preparation uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_preparation private.offline_reward_consumption_preparations;v_proposal private.offline_reward_financial_proposals;v_link private.offline_customer_trusted_links;
 v_witness jsonb;v_display jsonb;v_fingerprint text;v_customer uuid;
begin
 v_actor:=private.require_offline_reservation_operator();
 if p_proposal is null or p_preparation is null then raise exception 'Exact private proposal required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-proposal:'||p_proposal::text,0));
 select *into v_proposal from private.offline_reward_financial_proposals where proposal_id=p_proposal;
 if found then
 if v_proposal.proposed_by<>v_actor then raise exception 'Proposal unavailable'using errcode='42501';end if;
 if v_proposal.preparation_id<>p_preparation then raise exception 'Proposal nonce changed'using errcode='22023';end if;
 return jsonb_build_object('proposal_id',p_proposal,'created',true,'issuer_enabled',false);end if;
 select *into v_preparation from private.offline_reward_consumption_preparations where request_id=p_preparation;
 if not found or v_preparation.requested_by<>v_actor then raise exception 'Own actual preparation required'using errcode='42501';end if;
 select auth_user_id into v_customer from private.offline_customer_trusted_links where profile_id=v_preparation.offline_profile_id and revoked_at is null;
 if v_customer is null then raise exception 'Actual approved link required; no phone lookup'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_customer::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_preparation.offline_profile_id::text,0));
 lock table private.offline_customer_contacts in share mode;
 select *into v_link from private.offline_customer_trusted_links where profile_id=v_preparation.offline_profile_id and auth_user_id=v_customer and revoked_at is null for share;
 if not found or private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash
 or not exists(select 1 from auth.users u join public.customers c on c.id=u.id where u.id=v_customer and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and u.email_confirmed_at is not null and u.email_confirmed_at=v_link.email_confirmed_at and extensions.digest(lower(trim(u.email)),'sha256')=v_link.email_hash)
 then raise exception 'Current actual linked identity required'using errcode='55000';end if;
 if exists(select 1 from private.offline_reward_consumption_closures where request_id=p_preparation)then raise exception 'Preparation closed'using errcode='55000';end if;
 v_witness:=private.lock_offline_reward_hold_witness(v_preparation.reservation_id);
 if v_witness<>v_preparation.witness then raise exception 'Original preparation changed'using errcode='40001';end if;
 if jsonb_typeof(v_witness#>'{terms_snapshot,rules}')is distinct from'object'
 or not(v_witness#>'{terms_snapshot,rules}')?&array['pooling','expiry','cancellation','refunded_contribution']
 or coalesce(v_witness#>>'{terms_snapshot,rules,pooling}','')not in('policy_version','offer_branch')
 or coalesce(v_witness#>>'{terms_snapshot,rules,expiry}','')not in('no_expiry','snapshot_offer_end')
 or coalesce(v_witness#>>'{terms_snapshot,rules,cancellation}','')not in('restore_visits','forfeit_visits')
 or coalesce(v_witness#>>'{terms_snapshot,rules,refunded_contribution}','')not in('offset_future_visits','freeze_for_owner_review')
 then raise exception 'Complete supported frozen financial rules required'using errcode='55000';end if;
 select jsonb_build_object('service',jsonb_build_object('name_ar',s.name,'name_en',s.name_en),'branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en),
 'unit','service_visits','visits',(v_witness->>'threshold_visits')::integer,'gross_amount',(v_witness->>'gross_amount')::numeric,'reward_discount',(v_witness->>'gross_amount')::numeric,'amount_due',0,'currency','EGP',
 'rules',v_witness#>'{terms_snapshot,rules}','expires_at',v_witness->'expires_at')into v_display
 from public.business_catalog_items s join public.business_branches b on b.branch_id=s.branch_id where s.item_id=(v_witness->>'service_id')::uuid;
 v_fingerprint:=encode(extensions.digest(jsonb_build_object('proposal',p_proposal,'preparation',p_preparation,'link',v_link.link_id,'customer',v_customer,'witness',v_witness,'display',v_display)::text,'sha256'),'hex');
 insert into private.offline_reward_financial_proposals(proposal_id,preparation_id,proposed_by,link_id,customer_id,witness,display_terms,fingerprint,expires_at)
 values(p_proposal,p_preparation,v_actor,v_link.link_id,v_customer,v_witness,v_display,v_fingerprint,(v_witness->>'expires_at')::timestamptz);
 return jsonb_build_object('proposal_id',p_proposal,'created',true,'issuer_enabled',false);
end$$;

-- Internal caller has resolved/locked its current actual link. Only exact own
-- proposal is visible; no list/phone discovery/history or allocation-ID disclosure.
create function private.offline_financial_proposal_view(p_proposal uuid,p_link uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_proposal private.offline_reward_financial_proposals;v_preparation private.offline_reward_consumption_preparations;v_current jsonb;v_ready boolean:=false;
begin
 select *into v_proposal from private.offline_reward_financial_proposals where proposal_id=p_proposal and customer_id=auth.uid()and link_id=p_link;
 if not found then return jsonb_build_object('state','unavailable','issuer_enabled',false,'redemption_enabled',false);end if;
 select *into v_preparation from private.offline_reward_consumption_preparations where request_id=v_proposal.preparation_id;
 if v_proposal.expires_at>clock_timestamp()and not exists(select 1 from private.offline_reward_consumption_closures where request_id=v_proposal.preparation_id)then
 begin v_current:=private.lock_offline_reward_hold_witness(v_preparation.reservation_id);v_ready:=v_current=v_proposal.witness;
 exception when object_not_in_prerequisite_state then v_ready:=false;end;end if;
 return jsonb_build_object('state',case when v_ready then'proposal'else'inactive'end,'proposal_id',p_proposal,'fingerprint',v_proposal.fingerprint,'terms',v_proposal.display_terms,
 'consent',jsonb_build_object('version','offline-reward-financial-v1','notice_ar',private.offline_reward_financial_notice('ar',v_proposal.display_terms),'notice_en',private.offline_reward_financial_notice('en',v_proposal.display_terms)),
 'issuer_enabled',false,'redemption_enabled',false,'reward_issued',false);
end$$;
create function private.get_my_offline_reward_financial_proposal(p_proposal uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$declare v_link private.offline_customer_trusted_links;begin
 v_link:=private.require_offline_financial_customer();
 if p_proposal is null then select proposal_id into p_proposal from private.offline_reward_financial_proposals where customer_id=auth.uid()and link_id=v_link.link_id order by created_at desc,proposal_id desc limit 1;end if;
 return private.offline_financial_proposal_view(p_proposal,v_link.link_id);end$$;

create function private.get_my_offline_reward_financial_consent(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_consent private.offline_reward_financial_consents;v_revocation private.offline_reward_financial_revocations;v_view jsonb;
begin
 v_link:=private.require_offline_financial_customer();
 if p_request is null then raise exception 'Exact consent nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_request::text,0));
 select *into v_revocation from private.offline_reward_financial_revocations where consent_request_id=p_request order by created_at,request_id limit 1;
 select *into v_consent from private.offline_reward_financial_consents where request_id=p_request;
 if(v_revocation.request_id is not null and(v_revocation.actor_id<>auth.uid()or v_revocation.link_id<>v_link.link_id))or(v_consent.request_id is not null and(v_consent.actor_id<>auth.uid()or v_consent.link_id<>v_link.link_id))then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_revocation.request_id is not null then return jsonb_build_object('state','revoked','request_id',p_request,'definitive_failure',true,'issuer_enabled',false);end if;
 if v_consent.request_id is null then return jsonb_build_object('state','absent','request_id',p_request,'definitive_failure',false,'issuer_enabled',false);end if;
 v_view:=private.offline_financial_proposal_view(v_consent.proposal_id,v_link.link_id);
 return jsonb_build_object('state',case when v_view->>'state'='proposal'then'consent_recorded'else'inactive'end,'request_id',p_request,'proposal_id',v_consent.proposal_id,'fingerprint',v_consent.fingerprint,
 'consent',v_consent.consent,'proposal',v_view,'definitive_failure',false,'issuer_enabled',false,'redemption_enabled',false,'reward_issued',false);
end$$;

create function private.accept_my_offline_reward_financial_consent(p_request uuid,p_proposal uuid,p_fingerprint text,p_consent jsonb)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_prior private.offline_reward_financial_consents;v_view jsonb;v_language text;
begin
 -- Claim mutexes precede the per-consent nonce consistently for all customer ops.
 v_link:=private.require_offline_financial_customer();
 if p_request is null or p_proposal is null or p_fingerprint is null then raise exception 'Exact proposal and nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_request::text,0));
 if exists(select 1 from private.offline_reward_financial_revocations where consent_request_id=p_request)then return private.get_my_offline_reward_financial_consent(p_request);end if;
 select *into v_prior from private.offline_reward_financial_consents where request_id=p_request;
 if found then
 if v_prior.actor_id<>auth.uid()or v_prior.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_prior.proposal_id<>p_proposal or v_prior.fingerprint<>p_fingerprint or v_prior.consent is distinct from p_consent then raise exception 'Consent nonce changed'using errcode='22023';end if;
 return private.get_my_offline_reward_financial_consent(p_request);end if;
 if jsonb_typeof(p_consent)is distinct from'object'or not p_consent?&array['accepted','version','language','text']or p_consent-array['accepted','version','language','text']<>'{}'::jsonb
 or p_consent->'accepted'is distinct from'true'::jsonb or p_consent->>'version'is distinct from'offline-reward-financial-v1' then raise exception 'Separate explicit financial consent required'using errcode='22023';end if;
 v_view:=private.offline_financial_proposal_view(p_proposal,v_link.link_id);
 if v_view->>'state'<>'proposal'or v_view->>'fingerprint'is distinct from p_fingerprint then raise exception 'Current exact own proposal required'using errcode='55000';end if;
 v_language:=p_consent->>'language';
 if v_language is null or v_language not in('ar','en')or p_consent->>'text'is distinct from private.offline_reward_financial_notice(v_language,v_view->'terms')then raise exception 'Actual financial notice required'using errcode='22023';end if;
 if exists(select 1 from private.offline_reward_financial_consents where proposal_id=p_proposal)then raise exception 'Proposal already has its immutable consent nonce'using errcode='55000';end if;
 insert into private.offline_reward_financial_consents(request_id,proposal_id,actor_id,link_id,session_id,consent,fingerprint)
 values(p_request,p_proposal,auth.uid(),v_link.link_id,(auth.jwt()->>'session_id')::uuid,p_consent,p_fingerprint);
 return private.get_my_offline_reward_financial_consent(p_request);
end$$;

create function private.revoke_my_offline_reward_financial_consent(p_request uuid,p_consent_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_prior private.offline_reward_financial_revocations;v_consent private.offline_reward_financial_consents;
begin
 v_link:=private.require_offline_financial_customer();
 if p_request is null or p_consent_request is null then raise exception 'Exact revocation and consent nonce required'using errcode='22023';end if;
 -- Global revocation nonce then consent target. No reverse acquisition elsewhere.
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-revoke:'||p_request::text,0));
 select *into v_prior from private.offline_reward_financial_revocations where request_id=p_request;
 if found then
 if v_prior.actor_id<>auth.uid()or v_prior.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_prior.consent_request_id<>p_consent_request then raise exception 'Revocation nonce changed'using errcode='22023';end if;
 return private.get_my_offline_reward_financial_consent(p_consent_request);end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_consent_request::text,0));
 select *into v_consent from private.offline_reward_financial_consents where request_id=p_consent_request;
 if found and(v_consent.actor_id<>auth.uid()or v_consent.link_id<>v_link.link_id)then raise exception 'Consent unavailable'using errcode='42501';end if;
 select *into v_prior from private.offline_reward_financial_revocations where consent_request_id=p_consent_request order by created_at,request_id limit 1;
 if found then
 if v_prior.actor_id<>auth.uid()or v_prior.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 end if;
 insert into private.offline_reward_financial_revocations(request_id,consent_request_id,actor_id,link_id)values(p_request,p_consent_request,auth.uid(),v_link.link_id);
 return private.get_my_offline_reward_financial_consent(p_consent_request);
end$$;
revoke all on function private.offline_reward_financial_notice(text,jsonb),private.require_offline_financial_customer(),private.propose_offline_reward_financial_consent(uuid,uuid),private.offline_financial_proposal_view(uuid,uuid),private.get_my_offline_reward_financial_proposal(uuid),private.get_my_offline_reward_financial_consent(uuid),private.accept_my_offline_reward_financial_consent(uuid,uuid,text,jsonb),private.revoke_my_offline_reward_financial_consent(uuid,uuid)from public,anon,authenticated,service_role;
create function public.get_my_offline_reward_financial_proposal(p_proposal uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_reward_financial_proposal(p_proposal)$$;
create function public.get_my_offline_reward_financial_consent(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_reward_financial_consent(p_request)$$;
create function public.accept_my_offline_reward_financial_consent(p_request uuid,p_proposal uuid,p_fingerprint text,p_consent jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.accept_my_offline_reward_financial_consent(p_request,p_proposal,p_fingerprint,p_consent)$$;
create function public.revoke_my_offline_reward_financial_consent(p_request uuid,p_consent_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.revoke_my_offline_reward_financial_consent(p_request,p_consent_request)$$;
revoke all on function public.get_my_offline_reward_financial_proposal(uuid),public.get_my_offline_reward_financial_consent(uuid),public.accept_my_offline_reward_financial_consent(uuid,uuid,text,jsonb),public.revoke_my_offline_reward_financial_consent(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_my_offline_reward_financial_proposal(uuid),private.get_my_offline_reward_financial_consent(uuid),private.accept_my_offline_reward_financial_consent(uuid,uuid,text,jsonb),private.revoke_my_offline_reward_financial_consent(uuid,uuid),public.get_my_offline_reward_financial_proposal(uuid),public.get_my_offline_reward_financial_consent(uuid),public.accept_my_offline_reward_financial_consent(uuid,uuid,text,jsonb),public.revoke_my_offline_reward_financial_consent(uuid,uuid)to authenticated;
notify pgrst,'reload schema';
commit;
