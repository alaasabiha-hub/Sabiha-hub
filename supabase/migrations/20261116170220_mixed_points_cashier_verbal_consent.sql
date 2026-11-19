begin;
-- Verbal financial assent is operator-attested and independent of any Auth/history-link consent.
create table private.mixed_points_verbal_policy_versions(request_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),version integer not null check(version>0),allowed boolean not null,actor_id uuid not null references auth.users(id),reason text not null,created_at timestamptz not null default clock_timestamp(),unique(branch_id,version));
create table private.mixed_points_verbal_policy_current(branch_id uuid primary key references public.business_branches(branch_id),version_id uuid not null unique references private.mixed_points_verbal_policy_versions(request_id),version integer not null);
create table private.mixed_points_verbal_consents(request_id uuid primary key,reservation_id uuid not null unique references private.mixed_points_reservations(request_id),actor_id uuid not null references auth.users(id),session_id uuid not null,cashier_name text not null,policy_id uuid not null references private.mixed_points_verbal_policy_versions(request_id),identity_method text not null check(identity_method in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')),identity_invoice text not null references private.cashier_invoice_postings(invoice_id),evidence_note text not null,language text not null check(language in('ar','en')),fingerprint text not null,notice text not null,approval_method text not null default 'cashier_attested_verbal'check(approval_method='cashier_attested_verbal'),created_at timestamptz not null default clock_timestamp());
do $$declare n text;begin foreach n in array array['mixed_points_verbal_policy_versions','mixed_points_verbal_policy_current','mixed_points_verbal_consents']loop
 execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);if n<>'mixed_points_verbal_policy_current'then execute format('create trigger immutable_verbal_terms before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end if;end loop;end$$;
create function private.save_mixed_points_verbal_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_allowed boolean,p_reason text)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;v integer;old private.mixed_points_verbal_policy_versions;begin
 actor:=private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Owner only'using errcode='42501';end if;
 if p_request is null or p_allowed is null or p_expected_version is null or p_expected_version<0 or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit owner policy and reason required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-verbal-policy-command:'||p_request,0));select *into old from private.mixed_points_verbal_policy_versions where request_id=p_request;
 if found then if old.actor_id<>actor or old.branch_id<>p_branch or old.version<>p_expected_version+1 or old.allowed<>p_allowed or old.reason<>trim(p_reason)then raise exception 'Immutable verbal policy request'using errcode='22023';end if;return jsonb_build_object('version',old.version,'allowed',old.allowed);end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-verbal-policy:'||p_branch,0));select version into v from private.mixed_points_verbal_policy_current where branch_id=p_branch for update;
 if coalesce(v,0)<>p_expected_version then raise exception 'Owner verbal policy changed'using errcode='40001';end if;
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Current owner required'using errcode='42501';end if;
 insert into private.mixed_points_verbal_policy_versions values(p_request,p_branch,p_expected_version+1,p_allowed,actor,trim(p_reason),clock_timestamp());
 insert into private.mixed_points_verbal_policy_current values(p_branch,p_request,p_expected_version+1)on conflict(branch_id)do update set version_id=excluded.version_id,version=excluded.version;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'owner_mixed_points_verbal_policy','mixed_points_policy',p_request::text,p_branch,jsonb_build_object('version',coalesce(v,0)),jsonb_build_object('version',p_expected_version+1,'allowed',p_allowed,'reason',trim(p_reason),'runtime_enabled',false));
 return jsonb_build_object('version',p_expected_version+1,'allowed',p_allowed);
end$$;
create function private.mixed_points_verbal_notice(p_language text,p_terms jsonb)returns text
language sql immutable set search_path=pg_catalog as $$select case p_language when'ar'then 'أؤكد أنني تحققت حضوريًا من هوية صاحب الرصيد بوثيقة مستقلة وبيانات السيارة، وليس بالهاتف وحده، وعرضت عليه استبدال '||(p_terms->>'points')||' نقطة بخصم '||(p_terms->>'payable_discount')||' جنيه، والإجمالي النهائي '||(p_terms->>'amount_due')||' جنيه، ووافق شفهيًا لهذه الفاتورة فقط. هذه الموافقة لا تؤكد التحصيل.'when'en'then 'I confirm that I verified the balance owner in person using independent documents and vehicle details, not the phone alone, showed the customer '||(p_terms->>'points')||' points, a discount of '||(p_terms->>'payable_discount')||' EGP and final total of '||(p_terms->>'amount_due')||' EGP, and received verbal approval for this invoice only. This does not confirm collection.'end$$;
create function private.attest_mixed_points_verbal_consent(p_request uuid,p_branch uuid,p_reservation uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_evidence_note text,p_language text,p_notice text,p_confirmed boolean)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;old private.mixed_points_verbal_consents;policy uuid;name text;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_confirmed is distinct from true or p_language is null or p_language not in('ar','en')or p_identity_method is null or p_identity_method not in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')or p_identity_invoice is null or length(trim(coalesce(p_evidence_note,'')))not between 10 and 500 or p_fingerprint is null or p_notice is null then raise exception 'Explicit independent identity verification and verbal approval required'using errcode='22023';end if;
 select *into r from private.mixed_points_reservations where request_id=p_reservation and actor_id=actor;if not found then raise exception 'Own reservation required'using errcode='42501';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id and branch_id=p_branch;
 if (private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'then raise exception 'Review current draft before verbal approval'using errcode='40001';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
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
-- A typed consent must exist in either audited protocol; public clients cannot write either table.
alter table private.mixed_points_issue_authorizations drop constraint mixed_points_issue_authorizations_consent_id_fkey;
create function private.guard_mixed_points_consent_reference()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if not exists(select 1 from private.mixed_points_reservation_consents where request_id=new.consent_id and reservation_id=new.reservation_id)and not exists(select 1 from private.mixed_points_verbal_consents where request_id=new.consent_id and reservation_id=new.reservation_id and actor_id=new.actor_id)then raise exception 'Exact audited financial consent required'using errcode='42501';end if;return new;end$$;
create trigger typed_mixed_points_consent_reference before insert on private.mixed_points_issue_authorizations for each row execute function private.guard_mixed_points_consent_reference();
alter function private.lock_mixed_points_consent(uuid,uuid)rename to lock_mixed_points_customer_consent;
create function private.lock_mixed_points_consent(p_reservation uuid,p_consent uuid)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.mixed_points_verbal_consents;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;begin
 select *into c from private.mixed_points_verbal_consents where request_id=p_consent;
 if not found then perform private.lock_mixed_points_customer_consent(p_reservation,p_consent);return;end if;
 select *into r from private.mixed_points_reservations where request_id=p_reservation;
 if not found or c.reservation_id<>p_reservation or r.actor_id<>auth.uid()or c.actor_id<>auth.uid()then raise exception 'Own exact verbal approval required'using errcode='42501';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id;
 if private.cashier_cart_actor(i.branch_id)<>c.actor_id or c.session_id is distinct from(auth.jwt()->>'session_id')::uuid then raise exception 'Live actual approving cashier required'using errcode='42501';end if;
 if not exists(select 1 from private.mixed_points_verbal_policy_current x join private.mixed_points_verbal_policy_versions p on p.request_id=x.version_id where x.branch_id=i.branch_id and x.version_id=c.policy_id and p.allowed)or c.fingerprint<>r.fingerprint or c.notice is distinct from private.mixed_points_verbal_notice(c.language,private.mixed_loyalty_customer_terms(r.quote))then raise exception 'Current owner permission and exact verbal terms required'using errcode='42501';end if;
end$$;
create function private.audit_mixed_points_verbal_invoice()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare c private.mixed_points_verbal_consents;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;begin
 select v.*into c from private.mixed_points_verbal_consents v join private.mixed_points_issue_authorizations a on a.consent_id=v.request_id where a.reservation_id=new.reservation_id;if not found then return new;end if;
 select *into strict r from private.mixed_points_reservations where request_id=new.reservation_id;select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(c.cashier_name,c.actor_id,'cashier_mixed_points_verbal_invoice','business_invoices',new.invoice_id,i.branch_id,jsonb_build_object('consent',c.request_id,'approval_method',c.approval_method,'approved_at',c.created_at,'points',r.points,'discount',r.quote->'loyalty_payable_reduction','final_total',r.quote->'total','reservation',r.request_id,'cashier_name',c.cashier_name));return new;
end$$;
create trigger audit_verbal_points_invoice after insert on private.mixed_points_invoice_bindings for each row execute function private.audit_mixed_points_verbal_invoice();
revoke all on function private.save_mixed_points_verbal_policy(uuid,uuid,integer,boolean,text),private.mixed_points_verbal_notice(text,jsonb),private.attest_mixed_points_verbal_consent(uuid,uuid,uuid,text,text,text,text,text,text,boolean),private.guard_mixed_points_consent_reference(),private.lock_mixed_points_consent(uuid,uuid),private.audit_mixed_points_verbal_invoice()from public,anon,authenticated,service_role;
commit;
