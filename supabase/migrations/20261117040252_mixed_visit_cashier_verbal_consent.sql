begin;
-- Internal verbal assent component only. No history-link consent, OTP/SMS,
-- payment success or permission to use the unfinished mixed visit issuer.
create table private.mixed_visit_verbal_consents(
 request_id uuid primary key,group_id uuid not null unique references private.mixed_visit_groups(request_id),actor_id uuid not null references public.staff_profiles(user_id),session_id uuid not null,
 cashier_name text not null,policy_id uuid not null references private.owner_mixed_visit_policy_versions(version_id),fingerprint text not null,identity_method text not null check(identity_method in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')),
 identity_invoice text not null references public.business_invoices(invoice_id),evidence_note text not null,language text not null check(language in('ar','en')),notice text not null,
 approval_method text not null check(approval_method='cashier_attested_verbal'),identity_verified boolean not null check(identity_verified),verbal_confirmed boolean not null check(verbal_confirmed),created_at timestamptz not null default clock_timestamp());
alter table private.mixed_visit_verbal_consents enable row level security;
revoke all on private.mixed_visit_verbal_consents from public,anon,authenticated,service_role;
create trigger immutable_mixed_visit_consent before update or delete on private.mixed_visit_verbal_consents for each row execute function private.immutable_loyalty_policy();
create function private.mixed_visit_verbal_notice(p_language text,p_quote jsonb)returns text language sql immutable security invoker set search_path=pg_catalog as $$
 select case p_language when'ar'then 'أؤكد أنني تحققت حضوريًا من هوية صاحب الزيارات بوثيقة مستقلة وبيانات السيارة، وليس برقم الهاتف وحده، وعرضت عليه استخدام '||(p_quote#>>'{visit_reward,required_visits}')||' زيارة لتغطية '||(p_quote#>>'{visit_reward,covered_units}')||' وحدة خدمة، بقيمة تغطية '||(p_quote#>>'{visit_reward,payable_reduction}')||' جنيه، والإجمالي المستحق '||(p_quote->>'total')||' جنيه. وافق العميل شفهيًا لهذه المسودة فقط. هذا لا يؤكد الدفع أو إصدار الفاتورة.'
 when'en'then 'I confirm that I verified the visit owner in person using independent documents and vehicle details, not the phone alone, showed the customer '||(p_quote#>>'{visit_reward,required_visits}')||' visits covering '||(p_quote#>>'{visit_reward,covered_units}')||' service units, coverage of '||(p_quote#>>'{visit_reward,payable_reduction}')||' EGP and final amount due of '||(p_quote->>'total')||' EGP, and received verbal approval for this draft only. This confirms neither payment nor invoice issuance.'end$$;
create function private.mixed_visit_verbal_current(p_consent uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.mixed_visit_verbal_consents;g private.mixed_visit_groups;draft_state jsonb;group_state jsonb;begin
 select *into c from private.mixed_visit_verbal_consents where request_id=p_consent and actor_id=auth.uid();if not found then return false;end if;
 select *into strict g from private.mixed_visit_groups where request_id=c.group_id and actor_id=c.actor_id;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 draft_state:=private.get_cashier_loyalty_draft_intent(g.branch_id,g.intent_id);group_state:=private.mixed_visit_group_snapshot(g.request_id);perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 return c.session_id=(auth.jwt()->>'session_id')::uuid and exists(select 1 from auth.sessions where id=c.session_id and user_id=c.actor_id and(not_after is null or not_after>clock_timestamp()))
 and c.fingerprint=g.fingerprint and c.policy_id=g.policy_id and c.notice is not distinct from private.mixed_visit_verbal_notice(c.language,g.quote)
 and exists(select 1 from private.owner_mixed_visit_policy_current x join private.owner_mixed_visit_policy_versions v using(version_id)where x.branch_id=g.branch_id and x.rules_version_id=g.rules_version_id and x.version_id=c.policy_id and v.terms->>'allow_walk_in'='true')
 and draft_state->>'state'='current'
 and(group_state->>'reservation_live')::boolean;
 exception when others then return false;
end$$;
create function private.attest_mixed_visit_verbal(p_request uuid,p_branch uuid,p_group uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_note text,p_language text,p_notice text,p_identity_verified boolean,p_verbal_confirmed boolean)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;g private.mixed_visit_groups;old private.mixed_visit_verbal_consents;policy uuid;name text;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own visit reservation required'using errcode='42501';end if;
 actor:=private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 if p_request is null or p_fingerprint is null or p_identity_verified is distinct from true or p_verbal_confirmed is distinct from true or p_identity_method is null or p_identity_method not in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')or p_identity_invoice is null or p_language is null or p_language not in('ar','en')or p_notice is null or length(trim(coalesce(p_note,'')))not between 10 and 500 then raise exception 'Independent identity check and separate explicit verbal assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-verbal-request:'||p_request,0));
 if(private.get_cashier_loyalty_draft_intent(p_branch,g.intent_id))->>'state'is distinct from'current'then raise exception 'Review current sealed draft before verbal assent'using errcode='40001';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 -- Recheck real role/session AFTER any wait. A phone number or verified email
 -- is never used as proof of ownership or as permission to withdraw visits.
 perform private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=actor and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found then raise exception 'Current unchanged cashier session required'using errcode='42501';end if;
 perform 1 from public.staff_profiles where user_id=actor and is_active for share skip locked;
 if not found then raise exception 'Current unchanged cashier role required'using errcode='42501';end if;
 perform private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 select *into old from private.mixed_visit_verbal_consents where request_id=p_request;
 if found then
 if old.group_id<>p_group or old.actor_id<>actor or old.fingerprint<>p_fingerprint or old.identity_method<>p_identity_method or old.identity_invoice<>p_identity_invoice or old.evidence_note<>trim(p_note)or old.language<>p_language or old.notice<>p_notice then raise exception 'Immutable visit verbal assent request'using errcode='22023';end if;
 return jsonb_build_object('consent_id',p_request,'approval_method','cashier_attested_verbal','verbal_approval_recorded',true,'accepted',private.mixed_visit_verbal_current(p_request),'payment_confirmed',false,'invoice_issued',false,'redemption_enabled',false);end if;
 if exists(select 1 from private.mixed_visit_verbal_consents where group_id=p_group)then raise exception 'Recover the recorded approval; do not duplicate it'using errcode='40001';end if;
 select c.version_id into policy from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=g.branch_id and c.rules_version_id=g.rules_version_id and c.version_id=g.policy_id and v.terms->>'allow_walk_in'='true'for share of c;
 if policy is null then raise exception 'Current saved owner permission required'using errcode='42501';end if;
 if p_fingerprint<>g.fingerprint or p_notice is distinct from private.mixed_visit_verbal_notice(p_language,g.quote)or(private.mixed_visit_group_snapshot(p_group)->>'reservation_live')is distinct from'true'then raise exception 'Exact live visit coverage and final amount required'using errcode='40001';end if;
 if not exists(select 1 from private.mixed_visit_components x join private.reward_credit_claims h on h.reserve_request_id=x.reservation_id and h.released_at is null join private.canonical_loyalty_visits e on e.id=h.earning_id where x.group_id=p_group and e.offline_profile_id=g.profile_id and e.invoice_id=p_identity_invoice)then raise exception 'Independent original service document must belong to the actual funded visit owner'using errcode='42501';end if;
 select full_name into strict name from public.staff_profiles where user_id=actor and is_active;
 insert into private.mixed_visit_verbal_consents values(p_request,p_group,actor,(auth.jwt()->>'session_id')::uuid,name,policy,p_fingerprint,p_identity_method,p_identity_invoice,trim(p_note),p_language,p_notice,'cashier_attested_verbal',true,true,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(name,actor,'mixed_visit_verbal_approved','mixed_visit_group',p_group::text,p_branch,jsonb_build_object('consent_id',p_request,'cashier_name',name,'approval_method','cashier_attested_verbal','covered_units',g.covered_units,'required_visits',g.required_visits,'payable_reduction',g.quote#>'{visit_reward,payable_reduction}','amount_due',g.quote->'total','owner_policy_id',policy,'identity_method',p_identity_method,'independent_invoice',p_identity_invoice,'invoice_issued',false,'payment_confirmed',false));
 return jsonb_build_object('consent_id',p_request,'approval_method','cashier_attested_verbal','verbal_approval_recorded',true,'accepted',true,'payment_confirmed',false,'invoice_issued',false,'redemption_enabled',false);
end$$;
revoke all on function private.mixed_visit_verbal_notice(text,jsonb),private.mixed_visit_verbal_current(uuid),private.attest_mixed_visit_verbal(uuid,uuid,uuid,text,text,text,text,text,text,boolean,boolean)from public,anon,authenticated,service_role;
commit;
