begin;
-- Auth-customer POS visits have their own typed associations. No UUID, legacy
-- profile, customer booking quote, claim shape or invoice is reinterpreted.
create table private.auth_visit_groups(
 request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),session_id uuid not null,
 branch_id uuid not null references public.business_branches(branch_id),intent_id uuid not null unique references private.cashier_loyalty_draft_intents(request_id),
 customer_id uuid not null references public.customers(id),vehicle_id uuid not null references public.vehicles(id),
 rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),policy_id uuid not null references private.owner_mixed_visit_policy_versions(version_id),
 grant_version_id uuid references private.mixed_visit_cashier_grant_versions(version_id),line_id text not null,
 covered_units integer not null check(covered_units>0),required_visits bigint not null check(required_visits>0),
 payload jsonb not null,quote jsonb not null,allocations jsonb not null,fingerprint text not null,expires_at timestamptz not null,
 creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create index auth_visit_customer_groups on private.auth_visit_groups(customer_id,created_at);
create table private.auth_visit_claims(
 claim_id uuid primary key,group_id uuid not null references private.auth_visit_groups(request_id),unit_number integer not null check(unit_number>0),
 earning_id uuid not null references private.canonical_loyalty_visits(id),customer_id uuid not null references public.customers(id),credit_terms jsonb not null,
 released_at timestamptz,created_at timestamptz not null default clock_timestamp(),unique(group_id,earning_id));
create unique index one_active_auth_visit_pos_claim on private.auth_visit_claims(earning_id)where released_at is null;
create index auth_visit_claim_group on private.auth_visit_claims(group_id,unit_number);
create index auth_visit_claim_customer on private.auth_visit_claims(customer_id)where released_at is null;
-- This fence is read by hold expiry. It cannot be populated until the verified
-- invoice bridge replaces the rejecting trigger below in a later migration.
create table private.auth_visit_invoice_bindings(group_id uuid primary key references private.auth_visit_groups(request_id),invoice_id text not null unique references private.cashier_invoice_postings(invoice_id),created_at timestamptz not null default clock_timestamp());
create table private.auth_visit_release_events(
 request_id uuid primary key,group_id uuid not null references private.auth_visit_groups(request_id),actor_id uuid not null references public.staff_profiles(user_id),
 reason text not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.auth_visit_group_releases(
 request_id uuid primary key references private.auth_visit_release_events(request_id),group_id uuid not null unique references private.auth_visit_groups(request_id),
 actor_id uuid not null references public.staff_profiles(user_id),reason text not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['auth_visit_groups','auth_visit_claims','auth_visit_invoice_bindings','auth_visit_release_events','auth_visit_group_releases']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;
 foreach t in array array['auth_visit_groups','auth_visit_invoice_bindings','auth_visit_release_events','auth_visit_group_releases']loop execute format('create trigger immutable_auth_visit_data before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end loop;end$$;
create function private.auth_visit_claim_live(p_group uuid)returns boolean language sql volatile security definer set search_path=pg_catalog as $$
 select exists(select 1 from private.auth_visit_groups g where g.request_id=p_group and not exists(select 1 from private.auth_visit_group_releases r where r.group_id=g.request_id)
 and(g.expires_at>clock_timestamp()or exists(select 1 from private.auth_visit_invoice_bindings b where b.group_id=g.request_id)))
$$;
create function private.reject_unfinished_auth_visit_binding()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin raise exception 'Auth visit invoice bridge not installed'using errcode='55000';end$$;
create trigger auth_visit_binding_not_installed before insert on private.auth_visit_invoice_bindings for each row execute function private.reject_unfinished_auth_visit_binding();
create function private.auth_visit_scope_current(p_group uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;begin
 select *into g from private.auth_visit_groups where request_id=p_group and actor_id=auth.uid();if not found then return false;end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 return private.active_staff_role()='owner'or exists(select 1 from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id where c.staff_id=g.actor_id and c.branch_id=g.branch_id and c.rules_version_id=g.rules_version_id and c.version_id=g.grant_version_id and v.allowed);
 exception when insufficient_privilege then return false;
end$$;
create function private.guard_auth_visit_claim()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;e private.canonical_loyalty_visits;terms jsonb;begin
 if tg_op='DELETE'then raise exception 'Auth visit claim history cannot be deleted'using errcode='55000';end if;
 if tg_op='UPDATE'then
 if(to_jsonb(new)-'released_at')is distinct from(to_jsonb(old)-'released_at')or old.released_at is not null or new.released_at is null
 or not exists(select 1 from private.auth_visit_release_events x where x.group_id=old.group_id and x.creator_xid=txid_current())or exists(select 1 from private.auth_visit_invoice_bindings b where b.group_id=old.group_id)then raise exception 'Actual audited unissued Auth hold release required'using errcode='55000';end if;return new;end if;
 select *into g from private.auth_visit_groups where request_id=new.group_id;
 if g.actor_id is distinct from auth.uid()or g.creator_xid<>txid_current()or g.customer_id is distinct from new.customer_id or new.released_at is not null or new.unit_number>g.covered_units or g.expires_at<=clock_timestamp()then raise exception 'Actual same-transaction typed Auth claim required'using errcode='42501';end if;
 select *into e from private.canonical_loyalty_visits where id=new.earning_id and customer_id=g.customer_id and kind='earn'for update;
 if not found or private.reward_credit_refund(e.id)is not null or exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null)then raise exception 'Actual own unrefunded unallocated Auth visit required'using errcode='40001';end if;
 terms:=private.reward_credit_terms(e.id,g.rules_version_id);
 if terms is distinct from new.credit_terms or coalesce((terms->>'valid')::boolean,false)is not true or coalesce((terms->>'adoption_required')::boolean,true)then raise exception 'Original eligible Auth credit terms without implicit adoption required'using errcode='42501';end if;
 if not exists(select 1 from jsonb_array_elements(g.allocations)a where(a->>'earning_id')::uuid=e.id and(a->>'unit_number')::integer=new.unit_number and a->'credit_terms'=terms)then raise exception 'Exact original allocation required'using errcode='55000';end if;
 return new;
end$$;
create trigger validate_auth_visit_claim before insert or update or delete on private.auth_visit_claims for each row execute function private.guard_auth_visit_claim();
create function private.exclude_auth_visit_hold_from_canonical_claim()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.owner_kind='auth_customer'then
 perform 1 from private.canonical_loyalty_visits where id=new.earning_id for update;
 if exists(select 1 from private.auth_visit_claims c where c.earning_id=new.earning_id and c.released_at is null and private.auth_visit_claim_live(c.group_id))then raise exception 'Visit already held by an Auth POS invoice'using errcode='40001';end if;
 end if;return new;end$$;
create trigger a_auth_visit_canonical_exclusion before insert on private.reward_credit_claims for each row execute function private.exclude_auth_visit_hold_from_canonical_claim();
create function private.auth_visit_group_snapshot(p_group uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;held bigint;begin
 select *into g from private.auth_visit_groups where request_id=p_group and actor_id=auth.uid();if not found then raise exception 'Own Auth visit group required'using errcode='42501';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);select count(*)into held from private.auth_visit_claims where group_id=p_group and released_at is null;
 return jsonb_build_object('group_id',p_group,'unit','service_visits','owner_kind','auth_customer','covered_units',g.covered_units,'required_visits',g.required_visits,'held_visits',held,'reservation_live',private.auth_visit_claim_live(p_group)and held=g.required_visits,'fingerprint',g.fingerprint,'expires_at',g.expires_at,'quote',g.quote,'balance_reserved',held>0,'payment_confirmed',false,'consent_authorized',false,'invoice_issued',false);
end$$;
create function private.release_auth_visit_group(p_request uuid,p_group uuid,p_reason text,p_cleanup boolean default false)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare g private.auth_visit_groups;prior private.auth_visit_group_releases;actor uuid;result jsonb;begin
 select *into g from private.auth_visit_groups where request_id=p_group;if not found then raise exception 'Auth group unavailable'using errcode='42501';end if;
 actor:=private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable release request and audit reason required'using errcode='22023';end if;
 if not p_cleanup and g.actor_id<>actor then raise exception 'Own Auth group required'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||g.customer_id,0));perform pg_advisory_xact_lock(hashtextextended('auth-visit-release:'||p_request,0));
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);
 select *into prior from private.auth_visit_group_releases where request_id=p_request or group_id=p_group;
 if found then if prior.actor_id<>actor or prior.group_id<>p_group or prior.reason<>trim(p_reason)then raise exception 'Immutable Auth release'using errcode='22023';end if;return prior.result;end if;
 if exists(select 1 from private.auth_visit_invoice_bindings where group_id=p_group)then raise exception 'Issued Auth visit needs canonical unit return'using errcode='55000';end if;
 if p_cleanup and g.expires_at>clock_timestamp()and not exists(select 1 from private.auth_visit_claims c where c.group_id=p_group and c.released_at is null and private.reward_credit_refund(c.earning_id)is not null)then raise exception 'Actual expiry or source refund required'using errcode='55000';end if;
 insert into private.auth_visit_release_events values(p_request,p_group,actor,trim(p_reason),txid_current(),clock_timestamp());
 update private.auth_visit_claims set released_at=clock_timestamp()where group_id=p_group and released_at is null;
 result:=jsonb_build_object('group_id',p_group,'release_id',p_request,'released',true,'financial_operation',false);
 insert into private.auth_visit_group_releases values(p_request,p_group,actor,trim(p_reason),result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'auth_pos_visit_hold_released','auth_visit_group',p_group::text,g.branch_id,result||jsonb_build_object('reason',trim(p_reason)));
 return result;
end$$;
create function private.reserve_auth_visit_group(p_request uuid,p_branch uuid,p_intent uuid,p_rules uuid,p_line text,p_units bigint,p_policy uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid:=private.mixed_visit_operator(p_branch,p_rules,true);i private.cashier_loyalty_draft_intents;g private.auth_visit_groups;
 settings private.owner_mixed_visit_policy_versions;r private.loyalty_redemption_rule_versions;payload jsonb;quote jsonb;allocations jsonb:='[]'::jsonb;entry record;pending record;needed numeric;threshold integer;seen integer:=0;deadline timestamptz;fp text;grant_version uuid;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_intent is null or p_rules is null or p_line is null or p_units is null or p_units<1 or p_units>2147483647 or p_policy is null then raise exception 'Exact Auth draft and coverage required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'intent',p_intent,'rules',p_rules,'line',p_line,'units',p_units,'policy',p_policy,'owner_kind','auth_customer');
 perform pg_advisory_xact_lock(hashtextextended('auth-pos-visit-request:'||p_request,0));select *into g from private.auth_visit_groups where request_id=p_request;
 if found then if g.actor_id<>actor then raise exception 'Auth group unavailable'using errcode='42501';end if;if g.payload<>payload then raise exception 'Immutable Auth hold request'using errcode='22023';end if;return private.auth_visit_group_snapshot(p_request);end if;
 select *into i from private.cashier_loyalty_draft_intents where request_id=p_intent and branch_id=p_branch and actor_id=actor;if not found or i.witness->>'subject_kind'is distinct from'app_customer'then raise exception 'Own actual Auth-customer sealed draft required'using errcode='42501';end if;
 perform 1 from private.cashier_reviewed_drafts where draft_id=i.draft_id for update;
 if(private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Current reviewed Auth draft required'using errcode='40001';end if;
 if not exists(select 1 from public.vehicles where id=(i.witness->>'car')::uuid and customer_id=(i.witness->>'subject')::uuid)then raise exception 'Actual customer-owned vehicle required'using errcode='42501';end if;
 if exists(select 1 from private.mixed_points_reservations where intent_id=p_intent and private.mixed_points_hold_live(request_id))or exists(select 1 from private.mixed_visit_groups where intent_id=p_intent and private.mixed_visit_group_holds(request_id))then raise exception 'Release other loyalty selection first'using errcode='40001';end if;
 if exists(select 1 from private.auth_visit_groups where intent_id=p_intent)then raise exception 'Recover this Auth group or review a fresh draft version'using errcode='40001';end if;
 select v.*into settings from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules for share of c;
 select *into r from private.loyalty_redemption_rule_versions where rules_version_id=p_rules and branch_id=p_branch;
 if settings.version_id is distinct from p_policy or settings.terms->>'allow_walk_in'is distinct from'true'or r.rules_version_id is null or not exists(select 1 from private.reward_rule_activations where rules_version_id=p_rules)
 or settings.source_terms_hash<>encode(extensions.digest(r.terms_snapshot::text,'sha256'),'hex')or(r.terms_snapshot->'target_customer_ids'<>'null'::jsonb and not(r.terms_snapshot->'target_customer_ids'@>to_jsonb(array[(i.witness->>'subject')::uuid])))then raise exception 'Actual activated eligible benefit and current owner policy required'using errcode='42501';end if;
 if r.rules->>'expiry'='snapshot_offer_end'and coalesce((r.terms_snapshot#>>'{offer,ends_at}')::timestamptz<=clock_timestamp(),true)then raise exception 'Selected Auth benefit expired'using errcode='55000';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(i.witness#>'{quote,lines}')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'Existing single-business-day work bound required'using errcode='22023';end if;
 threshold:=(r.terms_snapshot->>'threshold_visits')::integer;needed:=threshold::numeric*p_units;if threshold<1 or needed>2147483647 then raise exception 'Actual bounded visit threshold required'using errcode='22023';end if;
 quote:=private.mixed_visit_coverage_core(i.witness->'quote',settings.terms||jsonb_build_object('reward_item_id',r.terms_snapshot#>>'{reward_service,id}','threshold_visits',threshold),p_line,p_units);
 perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||(i.witness->>'subject'),0));perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||(i.witness->>'subject'),0));
 for pending in select x.request_id from private.auth_visit_groups x where x.customer_id=(i.witness->>'subject')::uuid and not exists(select 1 from private.auth_visit_group_releases z where z.group_id=x.request_id)and not exists(select 1 from private.auth_visit_invoice_bindings b where b.group_id=x.request_id)and(x.expires_at<=clock_timestamp()or exists(select 1 from private.auth_visit_claims h where h.group_id=x.request_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is not null))order by x.request_id loop perform private.release_auth_visit_group(gen_random_uuid(),pending.request_id,'Actual expired or refunded unissued Auth POS hold cleanup',true);end loop;
 perform private.sync_customer_rewards((i.witness->>'subject')::uuid);
 if coalesce((private.reward_program_blockers((i.witness->>'subject')::uuid,p_rules)->>'eligible')::boolean,false)is not true then raise exception 'Auth refund debt or review outstanding'using errcode='55000';end if;
 -- Lock actual source invoices before earning rows, matching booking/refund order.
 for entry in select l.*,e.invoice_id from private.reward_program_lots((i.witness->>'subject')::uuid,p_rules)l join private.canonical_loyalty_visits e on e.id=l.earning_id order by(l.credit_terms->>'expires_at')::timestamptz nulls last,l.earned_at,l.earning_id limit needed::integer loop
 if coalesce((entry.credit_terms->>'adoption_required')::boolean,true)then raise exception 'Existing visits require explicit quoted adoption; no implicit POS adoption'using errcode='55000';end if;
 seen:=seen+1;allocations:=allocations||jsonb_build_array(jsonb_build_object('earning_id',entry.earning_id,'unit_number',1+(seen-1)/threshold,'credit_terms',entry.credit_terms));end loop;
 if seen<>needed then raise exception 'Insufficient actual unreserved Auth visits'using errcode='55000';end if;
 perform 1 from public.business_invoices inv join private.canonical_loyalty_visits e on e.invoice_id=inv.invoice_id where e.id in(select(a->>'earning_id')::uuid from jsonb_array_elements(allocations)a)order by inv.invoice_id for update of inv;
 perform 1 from private.canonical_loyalty_visits e where e.id in(select(a->>'earning_id')::uuid from jsonb_array_elements(allocations)a)order by e.id for update;
 for entry in select(a->>'earning_id')::uuid id,a->'credit_terms'terms from jsonb_array_elements(allocations)a loop
 if not exists(select 1 from private.reward_program_lots((i.witness->>'subject')::uuid,p_rules)l where l.earning_id=entry.id and l.credit_terms=entry.terms)then raise exception 'Actual Auth credit changed after lock wait'using errcode='40001';end if;end loop;
 select least(i.expires_at,clock_timestamp()+interval'5minutes',min((a#>>'{credit_terms,expires_at}')::timestamptz))into deadline from jsonb_array_elements(allocations)a;
 if r.rules->>'expiry'='snapshot_offer_end'then deadline:=least(deadline,(r.terms_snapshot#>>'{offer,ends_at}')::timestamptz);end if;
 if deadline is null or deadline<=clock_timestamp()or(private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Auth draft or original credit expired'using errcode='40001';end if;
 grant_version:=private.lock_mixed_visit_permission(p_branch,p_rules);fp:=encode(extensions.digest(jsonb_build_object('payload',payload,'intent',i.fingerprint,'quote',quote,'allocations',allocations,'grant',grant_version,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.auth_visit_groups values(p_request,actor,(auth.jwt()->>'session_id')::uuid,p_branch,p_intent,(i.witness->>'subject')::uuid,(i.witness->>'car')::uuid,p_rules,p_policy,grant_version,p_line,p_units::integer,needed::bigint,payload,quote,allocations,fp,deadline,txid_current(),clock_timestamp());
 for entry in select(a->>'earning_id')::uuid id,(a->>'unit_number')::integer unit_number,a->'credit_terms'terms from jsonb_array_elements(allocations)a loop insert into private.auth_visit_claims(claim_id,group_id,unit_number,earning_id,customer_id,credit_terms)values(gen_random_uuid(),p_request,entry.unit_number,entry.id,(i.witness->>'subject')::uuid,entry.terms);end loop;
 perform private.mixed_visit_operator(p_branch,p_rules,true);if deadline<=clock_timestamp()then raise exception 'Auth hold expired before commit'using errcode='40001';end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'auth_pos_visit_hold_created','auth_visit_group',p_request::text,p_branch,jsonb_build_object('intent_id',p_intent,'grant_version_id',grant_version,'required_visits',needed,'amount_due',quote->'total','payment_confirmed',false));
 return private.auth_visit_group_snapshot(p_request);
end$$;
create function private.check_auth_visit_group_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g private.auth_visit_groups;held bigint;begin
 select *into g from private.auth_visit_groups where request_id=new.request_id;
 select count(*)into held from private.auth_visit_claims where group_id=g.request_id;
 if g.creator_xid<>txid_current()or held<>g.required_visits or g.required_visits<>jsonb_array_length(g.allocations)or g.expires_at<=g.created_at or not exists(select 1 from private.cashier_loyalty_draft_intents i where i.request_id=g.intent_id and i.actor_id=g.actor_id and i.branch_id=g.branch_id and i.witness->>'subject_kind'='app_customer'and(i.witness->>'subject')::uuid=g.customer_id and(i.witness->>'car')::uuid=g.vehicle_id)
 or exists(select 1 from private.auth_visit_claims c where c.group_id=g.request_id and(c.customer_id<>g.customer_id or c.unit_number>g.covered_units))or exists(select 1 from generate_series(1,g.covered_units)u(n)where(select count(*)from private.auth_visit_claims c where c.group_id=g.request_id and c.unit_number=u.n)<>g.required_visits/g.covered_units)then raise exception 'Complete exact typed Auth visit allocation required'using errcode='55000';end if;
 if exists(select 1 from private.auth_visit_group_releases where group_id=g.request_id)then if exists(select 1 from private.auth_visit_claims where group_id=g.request_id and released_at is null)then raise exception 'Released Auth group has active claims'using errcode='55000';end if;
 elsif not exists(select 1 from private.auth_visit_invoice_bindings where group_id=g.request_id)and(g.expires_at<=clock_timestamp()or(select count(*)from private.auth_visit_claims where group_id=g.request_id and released_at is null)<>g.required_visits)then raise exception 'Unissued Auth group must be live and exactly funded'using errcode='55000';end if;return null;
end$$;
create constraint trigger complete_auth_visit_group after insert on private.auth_visit_groups deferrable initially deferred for each row execute function private.check_auth_visit_group_commit();
create function private.guard_auth_visit_draft_changes()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.auth_visit_groups g where g.intent_id in(select i.request_id from private.cashier_loyalty_draft_intents i where i.draft_id=old.draft_id)and private.auth_visit_claim_live(g.request_id))then raise exception 'Release current Auth visit selection before editing draft or customer'using errcode='40001';end if;return new;end$$;
create trigger a_auth_visit_reviewed_draft_guard before update on private.cashier_reviewed_drafts for each row execute function private.guard_auth_visit_draft_changes();
create trigger a_auth_visit_subject_guard before update on private.cashier_draft_subjects for each row execute function private.guard_auth_visit_draft_changes();
create function private.guard_points_against_auth_visit_hold()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare draft uuid;begin
 select draft_id into draft from private.cashier_loyalty_draft_intents where request_id=new.intent_id;perform 1 from private.cashier_reviewed_drafts where draft_id=draft for update;
 if exists(select 1 from private.auth_visit_groups where intent_id=new.intent_id and private.auth_visit_claim_live(request_id))then raise exception 'Release Auth visit hold before selecting points'using errcode='40001';end if;return new;end$$;
create trigger a_auth_visit_points_exclusion before insert on private.mixed_points_reservations for each row execute function private.guard_points_against_auth_visit_hold();

-- Auth selector extension below
CREATE OR REPLACE FUNCTION private.reward_program_lots_before_auth_pos(p_customer uuid, p_rules uuid)
 RETURNS TABLE(earning_id uuid, credit_terms jsonb, earned_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 select e.id,t.details,e.created_at from private.canonical_loyalty_visits e join private.loyalty_policy_versions p on p.version_id=e.policy_version_id join private.loyalty_redemption_rule_versions r on r.rules_version_id=p_rules cross join lateral(select private.reward_credit_terms(e.id,p_rules) details)t
 where e.kind='earn' and e.customer_id=p_customer and e.branch_id=r.branch_id and p.offer_id=r.offer_id and(r.rules->>'pooling'='offer_branch' or e.policy_version_id=r.policy_version_id)
 and private.reward_credit_refund(e.id) is null and not exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund') and not exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null) and(t.details->>'valid')::boolean
 order by(t.details->>'expires_at')::timestamptz nulls last,e.created_at,e.id;
$function$;
create or replace function private.reward_program_lots(p_customer uuid,p_rules uuid)returns table(earning_id uuid,credit_terms jsonb,earned_at timestamptz)language sql stable security definer set search_path=pg_catalog as $$
 select b.*from private.reward_program_lots_before_auth_pos(p_customer,p_rules)b where not exists(select 1 from private.auth_visit_claims c where c.earning_id=b.earning_id and c.released_at is null and private.auth_visit_claim_live(c.group_id))
 order by(b.credit_terms->>'expires_at')::timestamptz nulls last,b.earned_at,b.earning_id;
$$;
do $$declare f record;begin for f in select oid::regprocedure sig from pg_proc where pronamespace='private'::regnamespace and proname in('auth_visit_claim_live','reject_unfinished_auth_visit_binding','auth_visit_scope_current','guard_auth_visit_claim','exclude_auth_visit_hold_from_canonical_claim','auth_visit_group_snapshot','release_auth_visit_group','reserve_auth_visit_group','check_auth_visit_group_commit','guard_auth_visit_draft_changes','guard_points_against_auth_visit_hold','reward_program_lots_before_auth_pos')loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);end loop;end$$;
commit;
