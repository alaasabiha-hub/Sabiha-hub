begin;
create or replace function private.attest_mixed_points_verbal_consent(p_request uuid,p_branch uuid,p_reservation uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_evidence_note text,p_language text,p_notice text,p_confirmed boolean)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;old private.mixed_points_verbal_consents;policy uuid;name text;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_confirmed is distinct from true or p_language is null or p_language not in('ar','en')or p_identity_method is null or p_identity_method not in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')or p_identity_invoice is null or length(trim(coalesce(p_evidence_note,'')))not between 10 and 500 or p_fingerprint is null or p_notice is null then raise exception 'Explicit independent identity verification and verbal approval required'using errcode='22023';end if;
 select *into r from private.mixed_points_reservations where request_id=p_reservation and actor_id=actor;if not found then raise exception 'Own reservation required'using errcode='42501';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id and branch_id=p_branch;
 if (private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'then raise exception 'Review current draft before verbal approval'using errcode='40001';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 -- Do not record an approval from a cashier whose session/role changed while the wallet lock was awaited.
 perform private.cashier_cart_actor(p_branch);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=actor and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found then raise exception 'Current unchanged cashier session required'using errcode='42501';end if;
 perform 1 from public.staff_profiles where user_id=actor and is_active for share skip locked;
 if not found then raise exception 'Current unchanged cashier role required'using errcode='42501';end if;
 perform private.cashier_cart_actor(p_branch);
 select *into old from private.mixed_points_verbal_consents where request_id=p_request;
 if found then
 if old.actor_id<>actor or old.reservation_id<>p_reservation or old.fingerprint<>p_fingerprint or old.identity_method<>p_identity_method or old.identity_invoice<>p_identity_invoice or old.evidence_note<>trim(p_evidence_note)or old.language<>p_language or old.notice<>p_notice then raise exception 'Immutable verbal consent request'using errcode='22023';end if;
 return jsonb_build_object('consent_id',p_request,'approval_method','cashier_attested_verbal','accepted',private.mixed_points_hold_live(p_reservation),'payment_confirmed',false);end if;
 select c.version_id into policy from private.mixed_points_verbal_policy_current c join private.mixed_points_verbal_policy_versions v on v.request_id=c.version_id where c.branch_id=p_branch and v.allowed for share of c;
 if policy is null then raise exception 'Owner has not allowed cashier verbal redemption'using errcode='42501';end if;
 if not private.mixed_points_hold_live(p_reservation)or r.fingerprint<>p_fingerprint or p_notice is distinct from private.mixed_points_verbal_notice(p_language,private.mixed_loyalty_customer_terms(r.quote))then raise exception 'Exact current points, discount and final total required'using errcode='40001';end if;
 if not exists(select 1 from private.mixed_points_earned_lots l where l.wallet_id=r.wallet_id and l.invoice_id=p_identity_invoice)then raise exception 'Independent original service record must belong to this typed balance'using errcode='42501';end if;
 if exists(select 1 from private.mixed_points_reservation_consents where request_id=p_request)then raise exception 'Consent request already used'using errcode='40001';end if;
 select full_name into strict name from public.staff_profiles where user_id=actor and is_active;
 insert into private.mixed_points_verbal_consents values(p_request,p_reservation,actor,(auth.jwt()->>'session_id')::uuid,name,policy,p_identity_method,p_identity_invoice,trim(p_evidence_note),p_language,p_fingerprint,p_notice,'cashier_attested_verbal',clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(name,actor,'cashier_mixed_points_verbal_approved','mixed_points_reservation',p_reservation::text,p_branch,jsonb_build_object('consent',p_request,'approval_method','cashier_attested_verbal','cashier_name',name,'points',r.points,'discount',r.quote->'loyalty_payable_reduction','final_total',r.quote->'total','identity_method',p_identity_method,'independent_record',p_identity_invoice));
 return jsonb_build_object('consent_id',p_request,'approval_method','cashier_attested_verbal','accepted',true,'payment_confirmed',false);
end$$;
commit;
