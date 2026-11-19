begin;
create table private.auth_visit_verbal_consents(request_id uuid primary key,group_id uuid not null unique references private.auth_visit_groups(request_id),actor_id uuid not null references public.staff_profiles(user_id),session_id uuid not null,cashier_name text not null,policy_id uuid not null references private.owner_mixed_visit_policy_versions(version_id),fingerprint text not null,identity_method text not null,identity_invoice text not null references public.business_invoices(invoice_id),note text not null,language text not null,notice text not null,approval_method text not null check(approval_method='cashier_attested_verbal'),identity_verified boolean not null check(identity_verified),verbal_confirmed boolean not null check(verbal_confirmed),created_at timestamptz not null default clock_timestamp());
create table private.auth_visit_issue_authorizations(request_id uuid primary key,group_id uuid not null unique references private.auth_visit_groups(request_id),consent_id uuid not null unique references private.auth_visit_verbal_consents(request_id),actor_id uuid not null references public.staff_profiles(user_id),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.auth_visit_collection_commits(group_id uuid primary key references private.auth_visit_groups(request_id),payment_id uuid not null unique references public.business_payment_events(payment_id),created_at timestamptz not null default clock_timestamp());
create table private.auth_visit_returned_units(group_id uuid not null references private.auth_visit_groups(request_id),unit_number integer not null,source_id uuid not null,source_kind text not null check(source_kind in('credit','refund','full')),restore boolean not null,frozen_rule text not null check(frozen_rule in('restore_visits','forfeit_visits')),actor_id uuid not null references public.staff_profiles(user_id),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),primary key(group_id,unit_number));
create table private.auth_visit_claim_return_events(request_id uuid primary key,group_id uuid not null references private.auth_visit_groups(request_id),claim_id uuid not null unique references private.auth_visit_claims(claim_id),source_id uuid not null,source_kind text not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['auth_visit_verbal_consents','auth_visit_issue_authorizations','auth_visit_collection_commits','auth_visit_returned_units','auth_visit_claim_return_events']loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);execute format('create trigger immutable_auth_visit_history before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end loop;end$$;
drop trigger auth_visit_binding_not_installed on private.auth_visit_invoice_bindings;drop function private.reject_unfinished_auth_visit_binding();
CREATE OR REPLACE FUNCTION private.get_cashier_offline_mixed_visits_context(p_branch uuid, p_draft uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;choice record;balance bigint;maximum bigint;options jsonb:='[]'::jsonb;docs jsonb:='[]'::jsonb;g private.mixed_visit_groups;hold jsonb;approval jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);

 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and actor_id=actor and branch_id=p_branch;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor;
 if d.draft_id is null then return jsonb_build_object('enabled',false,'state','absent','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 select x.*into g from private.mixed_visit_groups x join private.cashier_loyalty_draft_intents i on i.request_id=x.intent_id where i.draft_id=p_draft and x.actor_id=actor and x.branch_id=p_branch and not exists(select 1 from private.cashier_invoice_postings p where p.draft_id=p_draft)and not exists(select 1 from private.mixed_visit_group_releases z where z.group_id=x.request_id)and exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id where c.group_id=x.request_id and h.released_at is null)order by x.created_at desc limit 1;
 if g.request_id is not null and not exists(select 1 from private.cashier_loyalty_draft_intents i where i.request_id=g.intent_id and i.draft_version=d.version and i.binding_version=b.version and b.draft_version=d.version and b.subject_kind='offline_profile'and g.profile_id=b.subject_id and g.car_id=b.car_id)then
 if hold is null and jsonb_array_length(options)=0 and private.active_staff_role()<>'owner'then return jsonb_build_object('enabled',false,'scope','delegated_branch_cashier','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 perform private.cashier_cart_actor(p_branch);
 return jsonb_build_object('enabled',true,'redemption_enabled',false,'scope','delegated_branch_cashier','state','stale_hold_requires_release','draft_version',d.version,'binding_version',b.version,'hold',jsonb_build_object('group_id',g.request_id,'recovery_only',true,'reservation_live',false,'balance_reserved',true,'payment_confirmed',false),'approval',null,'options','[]'::jsonb,'documents','[]'::jsonb);
 end if;
 if d.draft_id is null or b.draft_id is null or b.draft_version<>d.version or b.subject_kind<>'offline_profile'then return jsonb_build_object('enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'state','offline_subject_required','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 if exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then return jsonb_build_object('enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'state','issued','options','[]'::jsonb,'documents','[]'::jsonb);end if;

 if g.request_id is not null and not private.mixed_visit_scope_current(g.request_id)then return jsonb_build_object('enabled',true,'redemption_enabled',false,'scope','delegated_branch_cashier','state','delegation_revoked_release_required','hold',jsonb_build_object('group_id',g.request_id,'recovery_only',true,'balance_reserved',true,'payment_confirmed',false),'approval',null,'options','[]'::jsonb,'documents','[]'::jsonb);end if;
 if g.request_id is not null then
 hold:=private.mixed_visit_group_snapshot(g.request_id)||jsonb_build_object('balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_visit_verbal_notice('ar',g.quote),'verbal_notice_en',private.mixed_visit_verbal_notice('en',g.quote));
 select jsonb_build_object('group_id',g.request_id,'consent_id',c.request_id)into approval from private.mixed_visit_verbal_consents c where c.group_id=g.request_id and coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false)and private.mixed_visit_verbal_current(c.request_id);
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',invoice_id,'number',display_number)order by invoice_id),'[]')into docs from(select distinct i.invoice_id,i.display_number from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id join public.business_invoices i on i.invoice_id=e.invoice_id where c.group_id=g.request_id and h.released_at is null)s;
 end if;
 for choice in select distinct on(r.rules_version_id,j->>'line_id')r.rules_version_id,c.version_id channel_id,p.version_id policy_id,j->>'line_id'line_id,(j->>'quantity')::bigint quantity,j->>'name'name,j->>'name_en'name_en,(r.terms_snapshot->>'threshold_visits')::bigint required_visits,(v.terms->>'maximum_covered_units')::bigint maximum_units
 from private.owner_mixed_visit_policy_current p join private.owner_mixed_visit_policy_versions v using(version_id)join private.loyalty_redemption_rule_versions r on r.rules_version_id=p.rules_version_id join private.offline_visit_channel_versions c on c.rules_version_id=r.rules_version_id and c.branch_id=p.branch_id and c.enabled join private.offline_visit_channel_activations a on a.channel_version_id=c.version_id cross join lateral jsonb_array_elements(d.quote->'lines')j
 where coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false)and p.branch_id=p_branch and(private.active_staff_role()='owner'or private.visit_cashier_granted(p_branch,p.rules_version_id)) and v.terms->>'allow_walk_in'='true'and j->>'item_type'='service'and j->>'item_id'=r.terms_snapshot#>>'{reward_service,id}'
 order by r.rules_version_id,j->>'line_id',c.version_no desc loop
 if choice.required_visits<1 then continue;end if;
 if not private.offline_reward_debt_clear(b.subject_id,choice.rules_version_id)then continue;end if;
 select count(*)into balance from private.reward_owner_candidate_lots('offline_profile',b.subject_id,choice.rules_version_id,choice.channel_id);
 maximum:=least(div(balance,choice.required_visits)::bigint,choice.quantity,choice.maximum_units);
 if maximum>0 then options:=options||jsonb_build_array(jsonb_build_object('rules_id',choice.rules_version_id,'channel_id',choice.channel_id,'policy_id',choice.policy_id,'line_id',choice.line_id,'name',choice.name,'name_en',choice.name_en,'available_visits',balance,'threshold_visits',choice.required_visits,'maximum_units',maximum));end if;
 end loop;
 if hold is null and jsonb_array_length(options)=0 and private.active_staff_role()<>'owner'then return jsonb_build_object('enabled',false,'scope','delegated_branch_cashier','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 perform private.cashier_cart_actor(p_branch);
 return jsonb_build_object('enabled',hold is not null or coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'redemption_enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'scope','delegated_branch_cashier','state','ready','draft_version',d.version,'binding_version',b.version,'options',options,'documents',docs,'hold',hold,'approval',approval,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal');
end$function$;
CREATE OR REPLACE FUNCTION private.reserve_cashier_offline_mixed_visits(p_request uuid, p_branch uuid, p_intent uuid, p_rules uuid, p_channel uuid, p_line text, p_units bigint, p_policy uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare x jsonb;begin
 perform private.require_mixed_visit_pos(p_branch);x:=private.reserve_mixed_visit_components(p_request,p_branch,p_intent,p_rules,p_channel,p_line,p_units,p_policy);
 return x||jsonb_build_object('balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_visit_verbal_notice('ar',x->'quote'),'verbal_notice_en',private.mixed_visit_verbal_notice('en',x->'quote'));
end$function$;
CREATE OR REPLACE FUNCTION private.confirm_cashier_offline_mixed_visits_verbal(p_request uuid, p_branch uuid, p_group uuid, p_fingerprint text, p_identity_method text, p_identity_invoice text, p_note text, p_language text, p_notice text, p_identity_verified boolean, p_verbal_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 perform private.require_mixed_visit_pos(p_branch);return private.attest_mixed_visit_verbal(p_request,p_branch,p_group,p_fingerprint,p_identity_method,p_identity_invoice,p_note,p_language,p_notice,p_identity_verified,p_verbal_confirmed);
end$function$;
CREATE OR REPLACE FUNCTION private.release_cashier_offline_mixed_visits(p_request uuid, p_branch uuid, p_group uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 perform private.cashier_cart_actor(p_branch);if not exists(select 1 from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid())then raise exception 'Own branch visit hold required'using errcode='42501';end if;return private.release_mixed_visit_components(p_request,p_group,p_reason);
end$function$;
CREATE OR REPLACE FUNCTION private.issue_cashier_offline_visit_invoice(p_request uuid, p_branch uuid, p_group uuid, p_consent uuid, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 if not exists(select 1 from private.mixed_visit_issue_authorizations where request_id=p_request and group_id=p_group and consent_id=p_consent and actor_id=auth.uid())then perform private.require_mixed_visit_pos(p_branch);end if;return private.issue_mixed_visit_invoice(p_request,p_branch,p_group,p_consent,p_start);
end$function$;
CREATE OR REPLACE FUNCTION private.apply_offline_mixed_visit_issuing_quote(p_request uuid, p_quote jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;begin
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;if not found then return p_quote;end if;
 if a.actor_id<>auth.uid()or a.creator_xid<>txid_current()then raise exception 'Same transaction visit authorization required'using errcode='42501';end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 perform private.lock_mixed_visit_backing(g.request_id);
 if not private.mixed_visit_verbal_current(a.consent_id)or(p_quote-'as_of')is distinct from(i.witness->'quote')then raise exception 'Current exact sealed quote and independent verbal assent required'using errcode='40001';end if;
 -- Pin current policy/session while issuer completes, recheck AFTER every wait.
 perform 1 from private.owner_mixed_visit_policy_current where branch_id=g.branch_id and rules_version_id=g.rules_version_id and version_id=g.policy_id for share;
 if not found then raise exception 'Current owner visit policy required'using errcode='40001';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=auth.uid()and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found or not private.mixed_visit_verbal_current(a.consent_id)then raise exception 'Current consenting cashier session required'using errcode='42501';end if;
 return g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id);
end$function$;
create or replace function private.guard_auth_visit_claim()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;e private.canonical_loyalty_visits;terms jsonb;begin
 if tg_op='DELETE'then raise exception 'Auth visit claim history cannot be deleted'using errcode='55000';end if;
 if tg_op='UPDATE'then
 if(to_jsonb(new)-'released_at')is distinct from(to_jsonb(old)-'released_at')or old.released_at is not null or new.released_at is null
 or (not exists(select 1 from private.auth_visit_release_events x where x.group_id=old.group_id and x.creator_xid=txid_current()) and not exists(select 1 from private.auth_visit_claim_return_events x where x.group_id=old.group_id and x.claim_id=old.claim_id and x.creator_xid=txid_current()))or (exists(select 1 from private.auth_visit_invoice_bindings b where b.group_id=old.group_id) and not exists(select 1 from private.auth_visit_claim_return_events x where x.group_id=old.group_id and x.claim_id=old.claim_id and x.creator_xid=txid_current()))then raise exception 'Actual audited unissued Auth hold release required'using errcode='55000';end if;return new;end if;
 select *into g from private.auth_visit_groups where request_id=new.group_id;
 if g.actor_id is distinct from auth.uid()or g.creator_xid<>txid_current()or g.customer_id is distinct from new.customer_id or new.released_at is not null or new.unit_number>g.covered_units or g.expires_at<=clock_timestamp()then raise exception 'Actual same-transaction typed Auth claim required'using errcode='42501';end if;
 select *into e from private.canonical_loyalty_visits where id=new.earning_id and customer_id=g.customer_id and kind='earn'for update;
 if not found or private.reward_credit_refund(e.id)is not null or exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null)then raise exception 'Actual own unrefunded unallocated Auth visit required'using errcode='40001';end if;
 terms:=private.reward_credit_terms(e.id,g.rules_version_id);
 if terms is distinct from new.credit_terms or coalesce((terms->>'valid')::boolean,false)is not true or coalesce((terms->>'adoption_required')::boolean,true)then raise exception 'Original eligible Auth credit terms without implicit adoption required'using errcode='42501';end if;
 if not exists(select 1 from jsonb_array_elements(g.allocations)a where(a->>'earning_id')::uuid=e.id and(a->>'unit_number')::integer=new.unit_number and a->'credit_terms'=terms)then raise exception 'Exact original allocation required'using errcode='55000';end if;
 return new;
end$$;
;
CREATE OR REPLACE FUNCTION private.auth_visit_group_snapshot(p_group uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;held bigint;begin
 select *into g from private.auth_visit_groups where request_id=p_group and actor_id=auth.uid();if not found then raise exception 'Own Auth visit group required'using errcode='42501';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);select count(*)into held from private.auth_visit_claims where group_id=p_group and released_at is null;
 return jsonb_build_object('group_id',p_group,'unit','service_visits','owner_kind','auth_customer','covered_units',g.covered_units,'required_visits',g.required_visits,'held_visits',held,'reservation_live',private.auth_visit_claim_live(p_group)and held=g.required_visits,'fingerprint',g.fingerprint,'expires_at',g.expires_at,'quote',g.quote,'balance_reserved',held>0,'payment_confirmed',exists(select 1 from private.auth_visit_collection_commits where group_id=p_group),'consent_authorized',exists(select 1 from private.auth_visit_verbal_consents where group_id=p_group),'invoice_issued',exists(select 1 from private.auth_visit_invoice_bindings where group_id=p_group));
end$$;
create function private.auth_visit_verbal_current(p_consent uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$declare c private.auth_visit_verbal_consents;g private.auth_visit_groups;begin
 select *into c from private.auth_visit_verbal_consents where request_id=p_consent and actor_id=auth.uid();if not found then return false;end if;select *into strict g from private.auth_visit_groups where request_id=c.group_id and actor_id=c.actor_id;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);if not private.auth_visit_scope_current(g.request_id)then return false;end if;
 return c.session_id=(auth.jwt()->>'session_id')::uuid and exists(select 1 from auth.sessions where id=c.session_id and user_id=c.actor_id and(not_after is null or not_after>clock_timestamp()))and c.fingerprint=g.fingerprint and c.policy_id=g.policy_id and c.notice is not distinct from private.mixed_visit_verbal_notice(c.language,g.quote)
 and exists(select 1 from private.owner_mixed_visit_policy_current x join private.owner_mixed_visit_policy_versions v using(version_id)where x.branch_id=g.branch_id and x.rules_version_id=g.rules_version_id and x.version_id=c.policy_id and v.terms->>'allow_walk_in'='true')
 and (private.get_cashier_loyalty_draft_intent(g.branch_id,g.intent_id)->>'state')='current'and (private.auth_visit_group_snapshot(g.request_id)->>'reservation_live')::boolean;
 exception when others then return false;end$$;
create function private.auth_visit_identity_document_ok(p_group uuid,p_invoice text)returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select exists(select 1 from private.auth_visit_groups g join public.vehicles v on v.id=g.vehicle_id and v.customer_id=g.customer_id join public.business_invoices i on i.invoice_id=p_invoice and i.branch_id=g.branch_id and i.plate_number=v.plate_number join private.auth_visit_claims h on h.group_id=g.request_id join private.canonical_loyalty_visits e on e.id=h.earning_id and e.invoice_id=i.invoice_id and e.customer_id=g.customer_id and e.kind='earn' where g.request_id=p_group and h.released_at is null and private.reward_credit_refund(e.id)is null and exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale' and p.amount>0) and not exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='refund' and p.refund_part_id is null))
$$;
create function private.attest_auth_visit_verbal(p_request uuid,p_branch uuid,p_group uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_note text,p_language text,p_notice text,p_identity_verified boolean,p_verbal_confirmed boolean)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$declare actor uuid;g private.auth_visit_groups;prior private.auth_visit_verbal_consents;policy uuid;name text;begin
 select *into g from private.auth_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own actual Auth visit hold required'using errcode='42501';end if;actor:=private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 if p_request is null or p_fingerprint is null or p_identity_verified is distinct from true or p_verbal_confirmed is distinct from true or p_identity_method not in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')or p_identity_invoice is null or p_language not in('ar','en')or p_notice is null or length(trim(coalesce(p_note,'')))not between 10 and 500 then raise exception 'Independent identity check and separate verbal assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-verbal-request:'||p_request,0));perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||g.customer_id,0));perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||g.customer_id,0));
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=actor and(not_after is null or not_after>clock_timestamp())for share skip locked;if not found then raise exception 'Current staff session required'using errcode='42501';end if;
 select *into prior from private.auth_visit_verbal_consents where request_id=p_request or group_id=p_group;if found then if prior.actor_id<>actor or prior.group_id<>p_group or prior.fingerprint<>p_fingerprint or prior.identity_method<>p_identity_method or prior.identity_invoice<>p_identity_invoice or prior.note<>trim(p_note)or prior.language<>p_language or prior.notice<>p_notice then raise exception 'Immutable Auth consent retry'using errcode='22023';end if;return jsonb_build_object('consent_id',prior.request_id,'approval_method',prior.approval_method,'accepted',true,'payment_confirmed',false,'invoice_issued',false);end if;
 if p_fingerprint<>g.fingerprint or p_notice is distinct from private.mixed_visit_verbal_notice(p_language,g.quote)or not private.auth_visit_identity_document_ok(p_group,p_identity_invoice)or(private.auth_visit_group_snapshot(p_group)->>'reservation_live')is distinct from'true'then raise exception 'Exact live Auth visit and independent funded invoice/car match required'using errcode='42501';end if;
 select c.version_id into policy from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=g.branch_id and c.rules_version_id=g.rules_version_id and c.version_id=g.policy_id and v.terms->>'allow_walk_in'='true'for share of c;if policy is null then raise exception 'Current owner policy required'using errcode='42501';end if;
 perform private.lock_mixed_visit_permission(g.branch_id,g.rules_version_id);if not private.auth_visit_scope_current(g.request_id)then raise exception 'Cashier grant changed before approval'using errcode='42501';end if;
 select full_name into strict name from public.staff_profiles where user_id=actor and is_active;
 insert into private.auth_visit_verbal_consents values(p_request,p_group,actor,(auth.jwt()->>'session_id')::uuid,name,policy,p_fingerprint,p_identity_method,p_identity_invoice,trim(p_note),p_language,p_notice,'cashier_attested_verbal',true,true,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(name,actor,'auth_mixed_visit_verbal_approved','auth_visit_group',p_group::text,p_branch,jsonb_build_object('consent_id',p_request,'cashier_name',name,'approval_method','cashier_attested_verbal','customer_id',g.customer_id,'vehicle_id',g.vehicle_id,'identity_method',p_identity_method,'independent_invoice',p_identity_invoice,'required_visits',g.required_visits,'payable_reduction',g.quote#>'{visit_reward,payable_reduction}','amount_due',g.quote->'total','payment_confirmed',false));
 return jsonb_build_object('consent_id',p_request,'approval_method','cashier_attested_verbal','accepted',true,'payment_confirmed',false,'invoice_issued',false);
end$$;
create function private.lock_auth_visit_backing(p_group uuid)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$declare g private.auth_visit_groups;claim record;begin
 select *into strict g from private.auth_visit_groups where request_id=p_group;perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||g.customer_id,0));perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||g.customer_id,0));
 for claim in select e.id,e.invoice_id from private.auth_visit_claims h join private.canonical_loyalty_visits e on e.id=h.earning_id where h.group_id=g.request_id and h.released_at is null order by e.invoice_id,e.id loop perform 1 from public.business_invoices where invoice_id=claim.invoice_id for update;perform 1 from private.canonical_loyalty_visits where id=claim.id for update;
 if private.reward_credit_refund(claim.id)is not null or not exists(select 1 from private.reward_program_lots_before_auth_pos(g.customer_id,g.rules_version_id)l where l.earning_id=claim.id)then raise exception 'Original Auth visit source refunded, expired or changed'using errcode='40001';end if;end loop;
 if exists(select 1 from private.auth_visit_group_releases where group_id=g.request_id)or (g.expires_at<=clock_timestamp()and not exists(select 1 from private.auth_visit_invoice_bindings where group_id=g.request_id))then raise exception 'Auth visit reservation expired or released'using errcode='40001';end if;
end$$;
create function private.attest_auth_visit_invoice(p_request uuid,p_branch uuid,p_group uuid,p_consent uuid,p_start timestamptz)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$declare g private.auth_visit_groups;i private.cashier_loyalty_draft_intents;a private.auth_visit_issue_authorizations;result jsonb;begin
 select *into g from private.auth_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own actual Auth visit hold required'using errcode='42501';end if;perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);if p_request is null or p_consent is null then raise exception 'Stable invoice request and consent required'using errcode='22023';end if;perform pg_advisory_xact_lock(hashtextextended('mixed-visit-issue:'||p_request,0));select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 select *into a from private.auth_visit_issue_authorizations where request_id=p_request;if found then if a.actor_id<>auth.uid()or a.group_id<>p_group or a.consent_id<>p_consent then raise exception 'Immutable Auth invoice retry'using errcode='22023';end if;return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start)||jsonb_build_object('collection_required',true,'payment_status_at_issuance','unpaid','payment_requires_cashier_confirmation',true,'visit_balance_reserved',true,'visit_collection_committed',exists(select 1 from private.auth_visit_collection_commits where group_id=p_group));end if;
 if (private.get_cashier_loyalty_draft_intent(p_branch,g.intent_id)->>'state')is distinct from'current'or not exists(select 1 from private.auth_visit_verbal_consents c where c.request_id=p_consent and c.group_id=p_group and c.actor_id=auth.uid())then raise exception 'Current exact sealed Auth draft and consent required'using errcode='42501';end if;
 perform private.lock_auth_visit_backing(p_group);if not private.auth_visit_verbal_current(p_consent)then raise exception 'Current independently verified verbal approval required'using errcode='42501';end if;
 insert into private.auth_visit_issue_authorizations values(p_request,p_group,p_consent,auth.uid(),txid_current(),clock_timestamp());result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 perform private.lock_mixed_visit_permission(p_branch,g.rules_version_id);if not private.auth_visit_scope_current(p_group)then raise exception 'Cashier delegation changed while issuing invoice'using errcode='42501';end if;perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 if (result->>'invoice_id')is null or (g.quote->>'total')::numeric<=0 then raise exception 'Auth visit reward requires a positive payable mixed invoice; zero-payable route is not enabled'using errcode='55000';end if;
 return result||jsonb_build_object('collection_required',true,'payment_status_at_issuance','unpaid','payment_requires_cashier_confirmation',true,'visit_balance_reserved',true,'visit_collection_committed',false,'owner_kind','auth_customer');
end$$;
create function private.get_cashier_auth_visit_context(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;intent private.cashier_loyalty_draft_intents;g private.auth_visit_groups;hold jsonb;approval jsonb;options jsonb:='[]'::jsonb;docs jsonb:='[]'::jsonb;choice record;bal bigint;blocked jsonb;max_units bigint;runtime boolean;allowed boolean;begin
 actor:=private.cashier_cart_actor(p_branch);select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and actor_id=actor and branch_id=p_branch;select *into b from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor and branch_id=p_branch;
 if d.draft_id is null or b.draft_id is null or b.subject_kind<>'app_customer'or b.draft_version<>d.version then return jsonb_build_object('enabled',false,'redemption_enabled',false,'state','app_customer_binding_required','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 select *into intent from private.cashier_loyalty_draft_intents where draft_id=p_draft and actor_id=actor and branch_id=p_branch order by created_at desc limit 1;
 select *into g from private.auth_visit_groups where intent_id=intent.request_id and actor_id=actor and branch_id=p_branch and not exists(select 1 from private.auth_visit_group_releases z where z.group_id=request_id) and exists(select 1 from private.auth_visit_claims c where c.group_id=request_id and c.released_at is null) order by created_at desc limit 1;
 if intent.request_id is null then return jsonb_build_object('enabled',g.request_id is not null,'redemption_enabled',false,'state','seal_reviewed_draft_first','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 select coalesce(enabled,false)into runtime from private.mixed_visit_pos_runtime where singleton;allowed:=private.active_staff_role()='owner' or exists(select 1 from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions v using(version_id)where c.staff_id=actor and c.branch_id=p_branch and v.allowed and (g.request_id is null or (c.rules_version_id=g.rules_version_id and c.version_id=g.grant_version_id)));
 if g.request_id is not null then
 if not private.auth_visit_scope_current(g.request_id)then return jsonb_build_object('enabled',true,'redemption_enabled',false,'state','delegation_revoked_release_required','scope','delegated_branch_cashier','hold',private.auth_visit_group_snapshot(g.request_id),'approval',null,'options','[]'::jsonb,'documents','[]'::jsonb,'phone_is_not_identity_proof',true);end if;
 hold:=private.auth_visit_group_snapshot(g.request_id)||jsonb_build_object('balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_visit_verbal_notice('ar',g.quote),'verbal_notice_en',private.mixed_visit_verbal_notice('en',g.quote));
 select jsonb_build_object('group_id',g.request_id,'consent_id',c.request_id)into approval from private.auth_visit_verbal_consents c where c.group_id=g.request_id and private.auth_visit_verbal_current(c.request_id);
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'number',i.display_number)order by i.invoice_id),'[]')into docs from(select distinct i.invoice_id,i.display_number from private.auth_visit_claims h join private.canonical_loyalty_visits e on e.id=h.earning_id join public.business_invoices i on i.invoice_id=e.invoice_id where h.group_id=g.request_id and h.released_at is null and private.auth_visit_identity_document_ok(g.request_id,i.invoice_id))i;
 return jsonb_build_object('enabled',true,'redemption_enabled',runtime and allowed,'scope','delegated_branch_cashier','state','ready','intent_id',intent.request_id,'draft_version',d.version,'binding_version',b.version,'options','[]'::jsonb,'documents',docs,'hold',hold,'approval',approval,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal');
 end if;
 if not runtime or not allowed or (private.get_cashier_loyalty_draft_intent(p_branch,intent.request_id)->>'state')is distinct from'current' then return jsonb_build_object('enabled',runtime or g.request_id is not null,'redemption_enabled',false,'scope','delegated_branch_cashier','state','not_enabled_or_stale','intent_id',intent.request_id,'draft_version',d.version,'binding_version',b.version,'options','[]'::jsonb,'documents','[]'::jsonb,'hold',null,'approval',null,'phone_is_not_identity_proof',true);end if;
 -- An Auth customer's booked-service reward is governed by the current owner
 -- mixed-visit policy and its activated reward rules. Offline channel
 -- activation is unrelated and is deliberately not borrowed here.
 for choice in select distinct on(r.rules_version_id,j->>'line_id')r.rules_version_id,null::uuid channel_id,p.version_id policy_id,j->>'line_id'line_id,(j->>'quantity')::bigint quantity,j->>'name'name,j->>'name_en'name_en,(r.terms_snapshot->>'threshold_visits')::bigint threshold,(p.terms->>'maximum_covered_units')::bigint maximum_units,(r.terms_snapshot->>'reward_service')reward from jsonb_array_elements(intent.witness#>'{quote,lines}')j join public.business_catalog_items service on service.item_id=(j->>'item_id')::uuid and service.branch_id=p_branch and service.is_active and service.is_public and service.item_type='service' join private.loyalty_redemption_rule_versions r on r.branch_id=p_branch and(r.terms_snapshot#>>'{reward_service,id}')=service.item_id::text join private.reward_rule_activations ra using(rules_version_id) join private.owner_mixed_visit_policy_current pc on pc.branch_id=p_branch and pc.rules_version_id=r.rules_version_id join private.owner_mixed_visit_policy_versions p on p.version_id=pc.version_id where p.terms->>'allow_walk_in'='true' and (r.terms_snapshot->'target_customer_ids'='null'::jsonb or r.terms_snapshot->'target_customer_ids'@>to_jsonb(array[b.subject_id])) order by r.rules_version_id,j->>'line_id',p.created_at desc loop
 select count(*)into bal from private.reward_program_lots(b.subject_id,choice.rules_version_id);blocked:=private.reward_program_blockers(b.subject_id,choice.rules_version_id);max_units:=least(div(bal,choice.threshold),choice.quantity,(choice.maximum_units)::bigint);
 if max_units>0 and coalesce((blocked->>'eligible')::boolean,false)then options:=options||jsonb_build_array(jsonb_build_object('rules_id',choice.rules_version_id,'channel_id',choice.channel_id,'policy_id',choice.policy_id,'line_id',choice.line_id,'name',choice.name,'name_en',choice.name_en,'available_visits',bal,'threshold_visits',choice.threshold,'maximum_units',max_units));end if;end loop;
 return jsonb_build_object('enabled',true,'redemption_enabled',true,'scope','delegated_branch_cashier','state','ready','intent_id',intent.request_id,'draft_version',d.version,'binding_version',b.version,'options',options,'documents','[]'::jsonb,'hold',null,'approval',null,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal');
end$$;
CREATE OR REPLACE FUNCTION private.get_cashier_mixed_visits_context(p_branch uuid,p_draft uuid) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$
declare b private.cashier_draft_subjects;begin
 perform private.cashier_cart_actor(p_branch);select *into b from private.cashier_draft_subjects where draft_id=p_draft and branch_id=p_branch;
 if found and b.subject_kind='app_customer' then return private.get_cashier_auth_visit_context(p_branch,p_draft);end if;
 return private.get_cashier_offline_mixed_visits_context(p_branch,p_draft);
end$$;
CREATE OR REPLACE FUNCTION private.reserve_cashier_mixed_visits(p_request uuid,p_branch uuid,p_intent uuid,p_rules uuid,p_channel uuid,p_line text,p_units bigint,p_policy uuid) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$
declare i private.cashier_loyalty_draft_intents;x jsonb;begin perform private.require_mixed_visit_pos(p_branch);select *into i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=auth.uid()and branch_id=p_branch;
 if found and i.witness->>'subject_kind'='app_customer' then x:=private.reserve_auth_visit_group(p_request,p_branch,p_intent,p_rules,p_line,p_units,p_policy);return x||jsonb_build_object('balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_visit_verbal_notice('ar',x->'quote'),'verbal_notice_en',private.mixed_visit_verbal_notice('en',x->'quote'));end if;
 return private.reserve_cashier_offline_mixed_visits(p_request,p_branch,p_intent,p_rules,p_channel,p_line,p_units,p_policy);
end$$;
CREATE OR REPLACE FUNCTION private.confirm_cashier_mixed_visits_verbal(p_request uuid,p_branch uuid,p_group uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_note text,p_language text,p_notice text,p_identity_verified boolean,p_verbal_confirmed boolean) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$begin
 perform private.require_mixed_visit_pos(p_branch);if exists(select 1 from private.auth_visit_groups where request_id=p_group and branch_id=p_branch)then return private.attest_auth_visit_verbal(p_request,p_branch,p_group,p_fingerprint,p_identity_method,p_identity_invoice,p_note,p_language,p_notice,p_identity_verified,p_verbal_confirmed);end if;
 return private.confirm_cashier_offline_mixed_visits_verbal(p_request,p_branch,p_group,p_fingerprint,p_identity_method,p_identity_invoice,p_note,p_language,p_notice,p_identity_verified,p_verbal_confirmed);
end$$;
CREATE OR REPLACE FUNCTION private.release_cashier_mixed_visits(p_request uuid,p_branch uuid,p_group uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$begin
 perform private.cashier_cart_actor(p_branch);if exists(select 1 from private.auth_visit_groups where request_id=p_group and branch_id=p_branch)then return private.release_auth_visit_group(p_request,p_group,p_reason,false);end if;
 return private.release_cashier_offline_mixed_visits(p_request,p_branch,p_group,p_reason);
end$$;
CREATE OR REPLACE FUNCTION private.issue_cashier_visit_invoice(p_request uuid,p_branch uuid,p_group uuid,p_consent uuid,p_start timestamptz) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog AS $$begin
 if exists(select 1 from private.auth_visit_groups where request_id=p_group and branch_id=p_branch)then perform private.require_mixed_visit_pos(p_branch);return private.issue_auth_visit_invoice(p_request,p_branch,p_group,p_consent,p_start);end if;
 return private.issue_cashier_offline_visit_invoice(p_request,p_branch,p_group,p_consent,p_start);
end$$;
CREATE OR REPLACE FUNCTION private.bind_mixed_visit_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare aa private.auth_visit_issue_authorizations;ag private.auth_visit_groups;a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;begin
 select *into aa from private.auth_visit_issue_authorizations where request_id=new.request_id;
 if found then select *into strict ag from private.auth_visit_groups where request_id=aa.group_id;
 if aa.actor_id<>new.actor_id or aa.creator_xid<>txid_current() or new.creator_xid<>txid_current() or new.branch_id<>ag.branch_id or new.draft_id<>(select draft_id from private.cashier_loyalty_draft_intents where request_id=ag.intent_id) or new.quote is distinct from(ag.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',ag.request_id,'visit_reward_consent_id',aa.consent_id,'visit_reward_owner_kind','auth_customer')) then raise exception 'Exact atomic Auth visit invoice binding required'using errcode='55000';end if;
 insert into private.auth_visit_invoice_bindings(group_id,invoice_id)values(ag.request_id,new.invoice_id);return new;end if;
 select *into a from private.mixed_visit_issue_authorizations where request_id=new.request_id;
 if not found then
 if new.quote?'visit_reward'or exists(select 1 from private.mixed_visit_groups existing_group join private.cashier_loyalty_draft_intents i on i.request_id=existing_group.intent_id where i.draft_id=new.draft_id and existing_group.actor_id=new.actor_id and existing_group.expires_at>clock_timestamp() and not exists(select 1 from private.mixed_visit_group_releases r where r.group_id=existing_group.request_id)and exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id where c.group_id=existing_group.request_id and h.released_at is null))then raise exception 'Visit quote requires atomic issuer authorization'using errcode='42501';end if;return new;end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;
 if a.actor_id<>new.actor_id or a.creator_xid<>txid_current()or new.creator_xid<>txid_current()or new.branch_id<>g.branch_id or new.draft_id<>(select draft_id from private.cashier_loyalty_draft_intents where request_id=g.intent_id)or new.quote is distinct from(g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id))then raise exception 'Exact atomic visit invoice binding required'using errcode='55000';end if;
 insert into private.mixed_visit_invoice_bindings(invoice_id,group_id,creator_xid)values(new.invoice_id,g.request_id,txid_current());return new;
end$function$;
CREATE OR REPLACE FUNCTION private.commit_mixed_visit_collection()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare ag private.auth_visit_groups;g private.mixed_visit_groups;begin
 if new.event_type<>'sale'then return new;end if;
 select x.*into ag from private.auth_visit_groups x join private.auth_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=new.invoice_id;if found then
 perform private.mixed_visit_operator(ag.branch_id,ag.rules_version_id,false);perform private.lock_auth_visit_backing(ag.request_id);
 if new.amount<>private.cashier_invoice_payable(new.invoice_id)or new.method not in('cash','card_terminal')or(new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.amount=new.amount))then raise exception 'Actual full cash or verified terminal collection required'using errcode='55000';end if;
 insert into private.auth_visit_collection_commits(group_id,payment_id)values(ag.request_id,new.payment_id);return new;end if;
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);perform private.lock_mixed_visit_backing(g.request_id);
 if new.amount<>private.cashier_invoice_payable(new.invoice_id)or new.method not in('cash','card_terminal')or(new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.amount=new.amount))then raise exception 'Actual full cash or verified terminal collection required'using errcode='55000';end if;
 insert into private.mixed_visit_collection_commits(group_id,payment_id)values(g.request_id,new.payment_id);return new;
end$function$;
CREATE OR REPLACE FUNCTION private.apply_mixed_visit_issuing_quote(p_request uuid,p_quote jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
declare aa private.auth_visit_issue_authorizations; ag private.auth_visit_groups; ai private.cashier_loyalty_draft_intents; a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;begin
 select *into aa from private.auth_visit_issue_authorizations where request_id=p_request;
 if found then
  if aa.actor_id<>auth.uid()or aa.creator_xid<>txid_current()then raise exception 'Same transaction Auth visit authorization required'using errcode='42501';end if;
  select *into strict ag from private.auth_visit_groups where request_id=aa.group_id;select *into strict ai from private.cashier_loyalty_draft_intents where request_id=ag.intent_id;
  perform private.lock_auth_visit_backing(ag.request_id);
  if not private.auth_visit_verbal_current(aa.consent_id)or(p_quote-'as_of')is distinct from(ai.witness->'quote')then raise exception 'Current exact Auth draft and verbal assent required'using errcode='40001';end if;
  perform 1 from private.owner_mixed_visit_policy_current where branch_id=ag.branch_id and rules_version_id=ag.rules_version_id and version_id=ag.policy_id for share;if not found then raise exception 'Current owner visit policy required'using errcode='40001';end if;
  perform private.mixed_visit_operator(ag.branch_id,ag.rules_version_id,true);
  perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=auth.uid()and(not_after is null or not_after>clock_timestamp())for share skip locked;
  if not found or not private.auth_visit_verbal_current(aa.consent_id)then raise exception 'Current consenting cashier session required'using errcode='42501';end if;
  return ag.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',ag.request_id,'visit_reward_consent_id',aa.consent_id,'visit_reward_owner_kind','auth_customer');
 end if;
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;if not found then return p_quote;end if;
 if a.actor_id<>auth.uid()or a.creator_xid<>txid_current()then raise exception 'Same transaction visit authorization required'using errcode='42501';end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 perform private.lock_mixed_visit_backing(g.request_id);
 if not private.mixed_visit_verbal_current(a.consent_id)or(p_quote-'as_of')is distinct from(i.witness->'quote')then raise exception 'Current exact sealed quote and independent verbal assent required'using errcode='40001';end if;
 perform 1 from private.owner_mixed_visit_policy_current where branch_id=g.branch_id and rules_version_id=g.rules_version_id and version_id=g.policy_id for share;
 if not found then raise exception 'Current owner visit policy required'using errcode='40001';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=auth.uid()and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found or not private.mixed_visit_verbal_current(a.consent_id)then raise exception 'Current consenting cashier session required'using errcode='42501';end if;
 return g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id);
end$$;;
CREATE OR REPLACE FUNCTION private.restore_mixed_visit_units(p_invoice text, p_source uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare part record;rule text;returned integer;g private.mixed_visit_groups;begin
 if exists(select 1 from private.auth_visit_groups x join private.auth_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=p_invoice)then perform private.restore_auth_visit_units(p_invoice,p_source,p_kind);return;end if;
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 if p_kind='credit'then
 if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid cancellation required'using errcode='55000';end if;
 elsif p_kind='refund'then
 if(not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)and not private.mixed_visit_zero_coverage_valid(p_invoice))or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.invoice_id=p_invoice and e.refund_part_id=f.request_id and e.event_type='refund'and e.amount=f.amount)))then raise exception 'Actual settled canonical partial refund required'using errcode='55000';end if;
 elsif p_kind='full'then
 if(not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)and not private.mixed_visit_zero_coverage_valid(p_invoice))or not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and payment_id=p_source and event_type='refund'and refund_part_id is null)then raise exception 'Actual canonical full refund required'using errcode='55000';end if;
 else raise exception 'Canonical return source required'using errcode='22023';end if;
 -- Frozen original policy per allocated component, never the latest owner terms.
 for part in select c.*,q.terms_snapshot from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.group_id=g.request_id and(p_kind='full'or p_kind='credit'and exists(select 1 from private.cashier_unpaid_service_credits k where k.request_id=p_source and k.invoice_id=p_invoice and k.line_id=g.line_id and k.unit_number=c.unit_number)or p_kind='refund'and exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=p_source and f.invoice_id=p_invoice and f.line_id=g.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[c.unit_number])else c.unit_number>(f.snapshot->>'previous_quantity')::integer and c.unit_number<=(f.snapshot->>'cumulative_quantity')::integer end)))order by c.unit_number loop
 rule:=part.terms_snapshot#>>'{rules,cancellation}';
 if rule is null or rule not in('restore_visits','forfeit_visits')then raise exception 'Explicit original cancellation policy required'using errcode='55000';end if;
 insert into private.mixed_visit_returned_units(group_id,unit_number,source_id,source_kind,restore,frozen_rule,actor_id,creator_xid)values(g.request_id,part.unit_number,p_source,p_kind,rule='restore_visits',rule,auth.uid(),txid_current())on conflict(group_id,unit_number)do nothing;
 get diagnostics returned=row_count;
 if returned=1 then
 if rule='restore_visits'then perform private.release_mixed_offline_visit_reservation(part.reservation_id,'Canonical mixed visit unit return: '||p_kind||':'||p_source);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'mixed_visit_unit_returned','business_invoices',p_invoice,g.branch_id,jsonb_build_object('group_id',g.request_id,'unit_number',part.unit_number,'source_id',p_source,'source_kind',p_kind,'frozen_rule',rule,'original_expiry_preserved',true));
 end if;
 end loop;
end$function$;
create function private.restore_auth_visit_units(p_invoice text,p_source uuid,p_kind text)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$declare g private.auth_visit_groups;part record;claim record;rule text;ret integer;begin
 select x.*into g from private.auth_visit_groups x join private.auth_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||g.customer_id,0));
 if p_kind='credit'then if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid service cancellation required'using errcode='55000';end if;
 elsif p_kind='refund'then if(not exists(select 1 from private.auth_visit_collection_commits where group_id=g.request_id)or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.invoice_id=p_invoice and e.refund_part_id=f.request_id and e.event_type='refund'and e.amount=f.amount))))then raise exception 'Actual settled canonical partial refund required'using errcode='55000';end if;
 elsif p_kind='full'then if not exists(select 1 from private.auth_visit_collection_commits where group_id=g.request_id)or not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and payment_id=p_source and event_type='refund'and refund_part_id is null)then raise exception 'Actual canonical full refund required'using errcode='55000';end if;else raise exception 'Canonical return source required'using errcode='22023';end if;
 for part in select u.n unit_number from generate_series(1,g.covered_units)u(n)where p_kind='full'or p_kind='credit'and exists(select 1 from private.cashier_unpaid_service_credits k where k.request_id=p_source and k.invoice_id=p_invoice and k.line_id=g.line_id and k.unit_number=u.n)or p_kind='refund'and exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=p_source and f.invoice_id=p_invoice and f.line_id=g.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[u.n])else u.n>(f.snapshot->>'previous_quantity')::integer and u.n<=(f.snapshot->>'cumulative_quantity')::integer end)) order by u.n loop
 select coalesce(r.terms_snapshot#>>'{rules,cancellation}',r.rules->>'cancellation')into rule from private.loyalty_redemption_rule_versions r where r.rules_version_id=g.rules_version_id;if rule not in('restore_visits','forfeit_visits')then raise exception 'Explicit frozen Auth reward cancellation policy required'using errcode='55000';end if;
 insert into private.auth_visit_returned_units(group_id,unit_number,source_id,source_kind,restore,frozen_rule,actor_id,creator_xid)values(g.request_id,part.unit_number,p_source,p_kind,rule='restore_visits',rule,auth.uid(),txid_current())on conflict(group_id,unit_number)do nothing;get diagnostics ret=row_count;
 if ret=1 and rule='restore_visits'then
 for claim in select claim_id from private.auth_visit_claims where group_id=g.request_id and unit_number=part.unit_number and released_at is null order by claim_id loop insert into private.auth_visit_claim_return_events values(gen_random_uuid(),g.request_id,claim.claim_id,p_source,p_kind,txid_current(),clock_timestamp());update private.auth_visit_claims set released_at=clock_timestamp()where claim_id=claim.claim_id;end loop;
 end if;
 if ret=1 then insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'auth_visit_unit_returned','business_invoices',p_invoice,g.branch_id,jsonb_build_object('group_id',g.request_id,'unit_number',part.unit_number,'source_id',p_source,'source_kind',p_kind,'frozen_rule',rule,'original_invoice_and_commission_preserved',true));end if;
 end loop;
end$$;
create or replace function private.issue_auth_visit_invoice(p_request uuid,p_branch uuid,p_group uuid,p_consent uuid,p_start timestamptz)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$begin return private.attest_auth_visit_invoice(p_request,p_branch,p_group,p_consent,p_start);end$$;
do $$declare f record;begin for f in select oid::regprocedure sig from pg_proc where pronamespace='private'::regnamespace and proname in('get_cashier_auth_visit_context','auth_visit_verbal_current','auth_visit_identity_document_ok','attest_auth_visit_verbal','lock_auth_visit_backing','attest_auth_visit_invoice','issue_auth_visit_invoice','restore_auth_visit_units')loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);end loop;end$$;
notify pgrst,'reload schema';commit;
