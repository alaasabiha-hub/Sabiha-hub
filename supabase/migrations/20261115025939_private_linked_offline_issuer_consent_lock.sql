begin;
-- Live cross-actor authorization prerequisite, NOT an issuer or saved authorization.
-- Do not call customer auth.uid()-scoped consent functions as an owner or change
-- caller identity. A later issuer must call this in its SAME issuing transaction.
create function private.lock_linked_offline_reward_issuer_consent(p_preparation uuid,p_consent_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare
 v_operator uuid;v_consent private.offline_reward_financial_consents;v_proposal private.offline_reward_financial_proposals;
 v_preparation private.offline_reward_consumption_preparations;v_link private.offline_customer_trusted_links;v_auth auth.users;
 v_witness jsonb;v_fingerprint text;
begin
 v_operator:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_preparation is null or p_consent_request is null then raise exception 'Exact actual preparation and consent required'using errcode='22023';end if;
 -- These records are immutable. Derive the subject, never accept p_customer,
 -- p_profile, email, phone, approved flag or a customer token from the operator.
 select *into v_consent from private.offline_reward_financial_consents where request_id=p_consent_request;
 if not found then raise exception 'Actual financial consent unavailable'using errcode='42501';end if;
 select *into v_proposal from private.offline_reward_financial_proposals where proposal_id=v_consent.proposal_id;
 select *into v_preparation from private.offline_reward_consumption_preparations where request_id=p_preparation;
 if v_preparation.request_id is null or v_preparation.requested_by<>v_operator or v_proposal.preparation_id is distinct from p_preparation
 or v_proposal.proposed_by is distinct from v_operator or v_proposal.customer_id is distinct from v_consent.actor_id
 or v_proposal.link_id is distinct from v_consent.link_id then raise exception 'Own exact financial preparation required'using errcode='42501';end if;
 -- Same identity ordering as canonical approval/revocation and customer consent.
 -- No reward-owner/source-invoice lock may precede these identity mutexes.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_consent.actor_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_preparation.offline_profile_id::text,0));
 select *into v_link from private.offline_customer_trusted_links where link_id=v_consent.link_id and auth_user_id=v_consent.actor_id
 and profile_id=v_preparation.offline_profile_id and revoked_at is null for share;
 if not found then raise exception 'Current approved customer identity required'using errcode='55000';end if;
 select *into v_auth from auth.users where id=v_consent.actor_id for share;
 if not found or v_auth.deleted_at is not null or v_auth.email is null or v_auth.email_confirmed_at is null
 or(v_auth.banned_until is not null and v_auth.banned_until>clock_timestamp())
 or v_auth.email_confirmed_at is distinct from v_link.email_confirmed_at
 or extensions.digest(lower(trim(v_auth.email)),'sha256')is distinct from v_link.email_hash then raise exception 'Current actual confirmed customer required'using errcode='55000';end if;
 -- The independently consenting session must still exist: logout/session expiry
 -- cannot leave a reusable operator approval while the five-minute hold survives.
 perform 1 from auth.sessions where id=v_consent.session_id and user_id=v_consent.actor_id and(not_after is null or not_after>clock_timestamp())for share;
 if not found then raise exception 'Actual consenting session no longer current'using errcode='55000';end if;
 perform 1 from public.customers where id=v_consent.actor_id for share;
 if not found or exists(select 1 from public.staff_profiles where user_id=v_consent.actor_id and is_active)then raise exception 'Independent actual customer required'using errcode='55000';end if;
 lock table private.offline_customer_contacts in share mode;
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash
 or not exists(select 1 from private.offline_claim_requests claim join private.offline_claim_decisions decision on decision.claim_id=claim.request_id
 where claim.request_id=v_link.claim_id and claim.actor_id=v_consent.actor_id and claim.profile_id=v_link.profile_id and claim.receipt_key=v_link.receipt_id
 and claim.outcome='pending_owner_review'and claim.email_hash=v_link.email_hash and claim.email_confirmed_at=v_link.email_confirmed_at and claim.contact_hash=v_link.contact_hash
 and decision.owner_id=v_link.approved_by and decision.result->>'link_id'=v_link.link_id::text
 and(decision.decision='approve_with_secret'and claim.secret_proved or decision.decision='approve_exception'and claim.mode='lost_secret_review'
 and decision.evidence_type in('in_person_original_service_documents','in_person_independent_continuity_witness')))
 then raise exception 'Actual canonical reviewed continuity proof required'using errcode='55000';end if;
 -- Customer revoke takes the same identity mutex before this exact consent nonce.
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_consent_request::text,0));
 if exists(select 1 from private.offline_reward_financial_revocations where consent_request_id=p_consent_request)
 then raise exception 'Financial consent was withdrawn'using errcode='55000';end if;
 -- Serialize unknown/known preparation close before touching reward/source locks.
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_preparation::text,0));
 if exists(select 1 from private.offline_reward_consumption_closures where request_id=p_preparation)
 then raise exception 'Original preparation was closed'using errcode='55000';end if;
 v_witness:=private.lock_offline_reward_hold_witness(v_preparation.reservation_id);
 if v_witness is distinct from v_preparation.witness or v_witness is distinct from v_proposal.witness
 or v_proposal.expires_at<=clock_timestamp()or(v_witness->>'expires_at')::timestamptz is distinct from v_proposal.expires_at
 or v_consent.created_at<v_proposal.created_at or v_consent.created_at>=v_proposal.expires_at
 then raise exception 'Current exact unexpired held proposal required'using errcode='55000';end if;
 v_fingerprint:=encode(extensions.digest(jsonb_build_object('proposal',v_proposal.proposal_id,'preparation',p_preparation,'link',v_link.link_id,'customer',v_consent.actor_id,'witness',v_witness,'display',v_proposal.display_terms)::text,'sha256'),'hex');
 if v_fingerprint is distinct from v_proposal.fingerprint or v_fingerprint is distinct from v_consent.fingerprint
 or jsonb_typeof(v_consent.consent)is distinct from'object'
 or v_consent.consent-array['accepted','version','language','text']<>'{}'::jsonb
 or v_consent.consent->'accepted'is distinct from'true'::jsonb
 or v_consent.consent->>'version'is distinct from'offline-reward-financial-v1'
 or coalesce(v_consent.consent->>'language','')not in('ar','en')
 or v_consent.consent->>'text'is distinct from private.offline_reward_financial_notice(v_consent.consent->>'language',v_proposal.display_terms)
 then raise exception 'Independent exact financial assent required'using errcode='55000';end if;
 -- Internal transaction-local evidence only. No ledger, claim, invoice, work,
 -- payment, document, consent or identity record is written. Never persist this
 -- result as permission for another transaction; re-invoke after actual locks.
 return jsonb_build_object('state','locked_consent_valid','authorized_xid',txid_current(),'operator_id',v_operator,
 'customer_id',v_consent.actor_id,'link_id',v_link.link_id,'owner_kind','offline_profile','offline_profile_id',v_link.profile_id,
 'preparation_id',p_preparation,'reservation_id',v_preparation.reservation_id,'proposal_id',v_proposal.proposal_id,
 'consent_request_id',p_consent_request,'consent_recorded_at',v_consent.created_at,'fingerprint',v_fingerprint,'witness',v_witness,
 'same_transaction_only',true,'issuer_enabled',false,'redemption_enabled',false,'reward_issued',false);
end$$;
revoke all on function private.lock_linked_offline_reward_issuer_consent(uuid,uuid)from public,anon,authenticated,service_role;
-- No public wrapper, saved permit, role impersonation, claim conversion, runtime
-- change or weakening of existing offline invoice/redemption/debt fences.
commit;
