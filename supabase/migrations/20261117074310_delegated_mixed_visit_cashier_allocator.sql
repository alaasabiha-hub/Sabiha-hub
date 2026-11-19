begin;
-- Delegation is restricted to the typed mixed-invoice adapter. Legacy owner
-- entry points and the runtime activation gate are deliberately unchanged.
create table private.mixed_visit_cashier_scopes(
 group_id uuid primary key references private.mixed_visit_groups(request_id),
 staff_id uuid not null references public.staff_profiles(user_id),grant_version_id uuid not null references private.mixed_visit_cashier_grant_versions(version_id),
 creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.mixed_visit_cashier_scopes enable row level security;
revoke all on private.mixed_visit_cashier_scopes from public,anon,authenticated,service_role;
create trigger immutable_mixed_visit_scope before update or delete on private.mixed_visit_cashier_scopes for each row execute function private.immutable_loyalty_policy();
create function private.mixed_visit_operator(p_branch uuid,p_rules uuid,p_new boolean default true)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.cashier_cart_actor(p_branch);begin
 if not exists(select 1 from private.loyalty_redemption_rule_versions where branch_id=p_branch and rules_version_id=p_rules)then raise exception 'Actual branch benefit required'using errcode='22023';end if;
 if private.active_staff_role()='owner'then return actor;end if;
 if p_new and not exists(select 1 from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id
 where c.branch_id=p_branch and c.rules_version_id=p_rules and c.staff_id=actor and v.allowed and private.visit_cashier_eligible(actor,p_branch))then raise exception 'Current scoped cashier delegation required'using errcode='42501';end if;
 return actor;end$$;
-- Final locks are taken AFTER business waits. A revocation committed while a
-- request was waiting must be seen; no user-supplied session flag is trusted.
create function private.lock_mixed_visit_permission(p_branch uuid,p_rules uuid)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.mixed_visit_operator(p_branch,p_rules,true);version uuid;begin
 if private.active_staff_role()='owner'then return null;end if;
 perform 1 from public.staff_profiles where user_id=actor for share;
 perform 1 from public.staff_branch_access where user_id=actor and branch_id=p_branch for share;
 select c.version_id into version from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id
 where c.branch_id=p_branch and c.rules_version_id=p_rules and c.staff_id=actor and v.allowed for share of c;
 perform private.mixed_visit_operator(p_branch,p_rules,true);
 if version is null then raise exception 'Current scoped cashier delegation required'using errcode='42501';end if;return version;
end$$;
create function private.mixed_visit_scope_current(p_group uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.mixed_visit_groups;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and actor_id=auth.uid();if not found then return false;end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 if private.active_staff_role()='owner'then return true;end if;
 return exists(select 1 from private.mixed_visit_cashier_scopes s join private.mixed_visit_cashier_grant_current c on c.version_id=s.grant_version_id and c.staff_id=s.staff_id
 where s.group_id=g.request_id and s.staff_id=g.actor_id and c.branch_id=g.branch_id and c.rules_version_id=g.rules_version_id);
 exception when insufficient_privilege then return false;
end$$;
create function private.record_mixed_visit_cashier_scope()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare version uuid;begin
 if new.actor_id<>auth.uid()or new.creator_xid<>txid_current()then raise exception 'Actual same-transaction cashier required'using errcode='42501';end if;
 version:=private.lock_mixed_visit_permission(new.branch_id,new.rules_version_id);
 if version is not null then
 insert into private.mixed_visit_cashier_scopes values(new.request_id,new.actor_id,version,txid_current(),clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(new.actor_id::text,new.actor_id,'delegated_mixed_visit_reserved','mixed_visit_group',new.request_id::text,new.branch_id,jsonb_build_object('grant_version_id',version,'rules_version_id',new.rules_version_id,'session_id',new.session_id,'payment_confirmed',false));end if;return new;
end$$;
create trigger z_record_mixed_visit_scope after insert on private.mixed_visit_groups for each row execute function private.record_mixed_visit_cashier_scope();

CREATE OR REPLACE FUNCTION private.release_mixed_offline_visit_reservation(p_request uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;actor uuid;terminal text;
begin
 select x.*into c from private.offline_reward_reservation_commands x where x.request_id=p_request;
 select x.*into q from private.service_reward_quotes x where x.quote_id=c.quote_id;
 if q.quote_id is null then raise exception 'Reservation unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(q.branch_id);
 if private.active_staff_role()<>'owner'and c.requested_by<>actor and q.expires_at>clock_timestamp()and not exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=p_request and private.reward_credit_refund(h.earning_id)is not null)then raise exception 'Own or actually invalidated branch hold required'using errcode='42501';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable reservation and audit reason required'using errcode='22023';end if;
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||c.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request for update;
 if c.state<>'active'then return private.offline_reward_reservation_snapshot(p_request);end if;
 if private.mixed_visit_component_pinned(p_request)then return private.offline_reward_reservation_snapshot(p_request)||jsonb_build_object('pinned_by_issued_invoice',true,'released',false);end if;
 select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 terminal:=case when exists(select 1 from private.reward_credit_claims hold where hold.reserve_request_id=c.request_id and(private.reward_credit_refund(hold.earning_id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=hold.earning_id and rev.kind='refund')))then'refunded'when q.expires_at<=clock_timestamp()then'expired'else'released'end;
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,reason,creator_xid)values('release:'||p_request,p_request,terminal,actor,trim(p_reason),txid_current());
 update private.reward_credit_claims set released_at=clock_timestamp()where reserve_request_id=p_request and released_at is null;
 update private.offline_reward_reservation_commands set state=terminal,result=jsonb_build_object('state',terminal,'consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$function$;
CREATE OR REPLACE FUNCTION private.reserve_mixed_offline_visit_candidates(p_request uuid, p_profile uuid, p_car uuid, p_channel uuid, p_expected_gross numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare actor uuid;c private.offline_reward_reservation_commands;channel private.offline_visit_channel_versions;rules private.loyalty_redemption_rule_versions;service public.business_catalog_items;
 payload jsonb;plan jsonb;fresh jsonb;ids uuid[];allocations jsonb;quote uuid:=gen_random_uuid();deadline timestamptz;threshold integer;fingerprint text;item jsonb;pending record;
begin
 actor:=private.mixed_visit_operator((select branch_id from private.offline_visit_channel_versions where version_id=p_channel),(select rules_version_id from private.offline_visit_channel_versions where version_id=p_channel),true);
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_profile is null or p_car is null or p_channel is null or p_expected_gross is null or p_expected_gross<=0 or p_expected_gross::text in('NaN','Infinity','-Infinity')then raise exception 'Exact typed component request required'using errcode='22023';end if;
 payload:=jsonb_build_object('owner_kind','offline_profile','owner_id',p_profile,'car_reference',p_car,'channel',p_channel,'expected_gross',p_expected_gross,'operator',actor,'purpose','private_reservation_component');
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||p_profile::text,0));
 -- Free only actually expired/refunded UNCONSUMED holds before debt allocation;
 -- otherwise an expired reserve could prevent repayment and every later retry.
 for pending in select cmd.request_id from private.offline_reward_reservation_commands cmd join private.service_reward_quotes held_quote on held_quote.quote_id=cmd.quote_id where cmd.offline_profile_id=p_profile and cmd.state='active'and(held_quote.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims held_claim where held_claim.reserve_request_id=cmd.request_id and private.reward_credit_refund(held_claim.earning_id)is not null))order by cmd.request_id loop
 perform private.release_mixed_offline_visit_reservation(pending.request_id,'Release expired or refunded unconsumed hold before debt sync');end loop;
 perform private.sync_offline_profile_rewards(p_profile);
 if not exists(select 1 from private.offline_reward_reservation_commands where request_id=p_request)and not private.offline_reward_debt_clear(p_profile,(select rules_version_id from private.offline_visit_channel_versions where version_id=p_channel))then raise exception 'Typed consumed-source debt or owner review outstanding'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if found then
 if c.requested_by<>actor or c.offline_profile_id<>p_profile then raise exception 'Reservation unavailable'using errcode='42501';end if;
 if c.payload<>payload then raise exception 'Reservation request changed'using errcode='22023';end if;
 if c.state='active'and exists(select 1 from private.service_reward_quotes q where q.quote_id=c.quote_id and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and private.reward_credit_refund(h.earning_id)is not null)))then return private.release_mixed_offline_visit_reservation(p_request,'Actual expiry or source refund invalidated unconsumed hold');end if;
 return private.offline_reward_reservation_snapshot(p_request);end if;
 -- Same owner lock is acquired BEFORE all request locks, including expired-hold release.
 for pending in select cmd.request_id from private.offline_reward_reservation_commands cmd join private.service_reward_quotes q on q.quote_id=cmd.quote_id where cmd.offline_profile_id=p_profile and cmd.state='active'and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=cmd.request_id and private.reward_credit_refund(h.earning_id)is not null))order by cmd.request_id loop
 perform private.release_mixed_offline_visit_reservation(pending.request_id,'Release expired or actually refunded unconsumed component hold');end loop;
 select *into channel from private.offline_visit_channel_versions where version_id=p_channel;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=channel.rules_version_id;
 select *into service from public.business_catalog_items where item_id=(rules.terms_snapshot#>>'{reward_service,id}')::uuid and branch_id=channel.branch_id and item_type='service'and is_active and is_public for share;
 if service.item_id is null or service.price is distinct from p_expected_gross or not exists(select 1 from private.offline_customer_car_refs car where car.car_ref_id=p_car and car.profile_id=p_profile)then raise exception 'Actual owner/car/reward service price changed'using errcode='40001';end if;
 plan:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if not coalesce((plan->>'threshold_met')::boolean,false)then raise exception 'Insufficient actual candidate credits'using errcode='55000';end if;
 select array_agg(candidate.value::uuid order by candidate.ordinality)into ids from jsonb_array_elements_text(plan->'candidate_ids')with ordinality candidate(value,ordinality);
 perform 1 from public.business_invoices i join private.canonical_loyalty_visits e on e.invoice_id=i.invoice_id where e.id=any(ids)order by i.invoice_id for update of i;
 fresh:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if fresh->'candidate_ids'is distinct from plan->'candidate_ids'or fresh->'allocation_candidates'is distinct from plan->'allocation_candidates'then raise exception 'Candidate facts changed after financial lock wait'using errcode='40001';end if;
 allocations:=fresh->'allocation_candidates';threshold:=(fresh->>'required_visits')::integer;
 select least(clock_timestamp()+interval'5 minutes',min((entry#>>'{credit_terms,expires_at}')::timestamptz))into deadline from jsonb_array_elements(allocations)entry;
 if rules.rules->>'expiry'='snapshot_offer_end'then deadline:=least(deadline,(rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz);end if;
 if deadline is null or deadline<=clock_timestamp()then raise exception 'Original credit or selected benefit expiry passed'using errcode='55000';end if;
 fingerprint:=encode(extensions.digest(jsonb_build_object('payload',payload,'rules',rules.terms_snapshot,'earning_ids',ids,'allocations',allocations,'gross',service.price,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.offline_reward_reservation_commands(request_id,offline_profile_id,requested_by,quote_id,payload,state,creator_xid)values(p_request,p_profile,actor,quote,payload,'preparing',txid_current());
 insert into private.service_reward_quotes(quote_id,customer_id,source_channel,payload,branch_id,service_id,vehicle_id,booking_date,booking_time,policy_version_id,rules_version_id,threshold_visits,gross_amount,earning_ids,adoption_ids,allocation_snapshot,terms_snapshot,fingerprint,expires_at,owner_kind,offline_profile_id,offline_car_ref_id,offline_channel_version_id,requested_by,reserve_request_id)
 values(quote,null,'walk_in',payload,channel.branch_id,service.item_id,null,null,null,channel.policy_version_id,rules.rules_version_id,threshold,service.price,ids,'{}'::uuid[],allocations,rules.terms_snapshot||jsonb_build_object('source_channel','walk_in','component_reservation',true,'consumption_enabled',false),fingerprint,deadline,'offline_profile',p_profile,p_car,p_channel,actor,p_request);
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,creator_xid)values('reserve:'||p_request,p_request,'reserve',actor,txid_current());
 for item in select value from jsonb_array_elements(allocations)loop
 insert into private.reward_credit_claims(earning_id,customer_id,kind,quote_id,owner_kind,offline_profile_id,offline_channel_version_id,reserve_request_id,hold_expires_at)
 values((item->>'earning_id')::uuid,null,'reserve',quote,'offline_profile',p_profile,p_channel,p_request,deadline);end loop;
 update private.offline_reward_reservation_commands set state='active',result=jsonb_build_object('state','active','consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$function$;
CREATE OR REPLACE FUNCTION private.mixed_visit_group_snapshot(p_group uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare g private.mixed_visit_groups;held bigint;live boolean;begin
 select *into g from private.mixed_visit_groups where request_id=p_group;
 if not found or g.actor_id<>auth.uid()then raise exception 'Visit group unavailable'using errcode='42501';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);
 select count(*)into held from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=p_group and h.released_at is null;
 live:=(exists(select 1 from private.mixed_visit_invoice_bindings where group_id=p_group)or g.expires_at>clock_timestamp())and held=g.required_visits and not exists(select 1 from private.mixed_visit_group_releases where group_id=p_group)and not exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=p_group and(c.state<>'active'or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is not null)));
 return jsonb_build_object('group_id',p_group,'unit','service_visits','covered_units',g.covered_units,'required_visits',g.required_visits,'held_visits',held,'reservation_live',live,'fingerprint',g.fingerprint,'expires_at',g.expires_at,'quote',g.quote,'released',exists(select 1 from private.mixed_visit_group_releases where group_id=p_group),'consent_authorized',false,'invoice_issued',exists(select 1 from private.mixed_visit_invoice_bindings where group_id=p_group),'invoice_id',(select invoice_id from private.mixed_visit_invoice_bindings where group_id=p_group),'visit_collection_committed',exists(select 1 from private.mixed_visit_collection_commits where group_id=p_group),'redemption_enabled',false);
end$function$;
CREATE OR REPLACE FUNCTION private.reserve_mixed_visit_components(p_request uuid, p_branch uuid, p_intent uuid, p_rules uuid, p_channel uuid, p_line text, p_units bigint, p_policy uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare actor uuid:=private.mixed_visit_operator(p_branch,p_rules,true);old_group private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;settings private.owner_mixed_visit_policy_versions;
 payload jsonb;preview jsonb;components jsonb:='[]'::jsonb;part jsonb;child uuid;entry jsonb;service uuid;gross numeric;deadline timestamptz;fp text;pending record;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_intent is null or p_channel is null or p_line is null or p_units is null or p_units<1 or p_units>2147483647 or p_policy is null then raise exception 'Exact mixed visit reservation required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'intent',p_intent,'rules',p_rules,'channel',p_channel,'line',p_line,'units',p_units,'policy',p_policy);
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-command:'||p_request,0));select *into old_group from private.mixed_visit_groups where request_id=p_request;
 if found then if old_group.actor_id<>actor then raise exception 'Reservation unavailable'using errcode='42501';end if;if old_group.payload<>payload then raise exception 'Immutable visit group request'using errcode='22023';end if;return private.mixed_visit_group_snapshot(p_request);end if;
 if(private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Current reviewed sealed draft required'using errcode='40001';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=actor and branch_id=p_branch;
 if i.witness->>'subject_kind'is distinct from'offline_profile'then raise exception 'Auth-customer visit hold adapter remains separate; no UUID substitution'using errcode='55000';end if;
 if exists(select 1 from private.mixed_points_reservations where intent_id=p_intent and private.mixed_points_hold_live(request_id))then raise exception 'Recover or release current point reservation before selecting visits'using errcode='40001';end if;
 if exists(select 1 from private.mixed_visit_groups where intent_id=p_intent)then raise exception 'Recover this sealed draft visit group; a new selection needs a fresh reviewed version'using errcode='40001';end if;
 select v.*into settings from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules for share of c;
 if not found or settings.version_id<>p_policy or settings.terms->>'allow_walk_in'is distinct from'true'then raise exception 'Current owner permission required'using errcode='42501';end if;
 -- The same profile mutex and cleanup/sync order as the accepted old allocator.
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||(i.witness->>'subject'),0));perform private.require_typed_reward_document_session(actor);
 for pending in select c.request_id from private.offline_reward_reservation_commands c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.offline_profile_id=(i.witness->>'subject')::uuid and c.state='active'and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and private.reward_credit_refund(h.earning_id)is not null))order by c.request_id loop perform private.release_mixed_offline_visit_reservation(pending.request_id,'Release expired or refunded unconsumed hold before mixed visit reservation');end loop;
 perform private.sync_offline_profile_rewards((i.witness->>'subject')::uuid);
 preview:=private.preview_saved_mixed_visit_candidates(p_branch,p_intent,p_rules,p_channel,p_line,p_units,p_policy);
 if preview->>'candidate_threshold_met'is distinct from'true'then raise exception 'Actual unreserved visit candidates or refund review not ready'using errcode='55000';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(i.witness#>'{quote,lines}')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'One-visit work must fit the existing business-day work bound'using errcode='22023';end if;
 select(value->>'item_id')::uuid into strict service from jsonb_array_elements(i.witness#>'{quote,lines}')where value->>'line_id'=p_line;
 select price into strict gross from public.business_catalog_items where item_id=service;deadline:=i.expires_at;
 for unit_no in 1..p_units::integer loop
 child:=gen_random_uuid();part:=private.reserve_mixed_offline_visit_candidates(child,(i.witness->>'subject')::uuid,(i.witness->>'car')::uuid,p_channel,gross);
 if part->>'state'is distinct from'active'or(part->>'held_visits')::numeric<>(preview->>'required_visits')::numeric/p_units then raise exception 'Exact original visit component funding required'using errcode='55000';end if;
 deadline:=least(deadline,(part->>'expires_at')::timestamptz);components:=components||jsonb_build_array(jsonb_build_object('reservation_id',child,'quote_id',part->'quote_id','unit_number',unit_no));
 end loop;
 perform private.require_typed_reward_document_session(actor);perform private.mixed_visit_operator(p_branch,p_rules,true);
 if(private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'or deadline<=clock_timestamp()then raise exception 'Draft or reservation expired while waiting'using errcode='40001';end if;
 fp:=encode(extensions.digest(jsonb_build_object('payload',payload,'intent_fingerprint',i.fingerprint,'quote',preview->'quote','components',components,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.mixed_visit_groups values(p_request,actor,(auth.jwt()->>'session_id')::uuid,p_branch,p_intent,(i.witness->>'subject')::uuid,(i.witness->>'car')::uuid,p_rules,p_channel,p_policy,p_line,p_units::integer,(preview->>'required_visits')::bigint,payload,preview->'quote',fp,deadline,txid_current(),clock_timestamp());
 for entry in select value from jsonb_array_elements(components)loop insert into private.mixed_visit_components values(p_request,(entry->>'unit_number')::integer,(entry->>'reservation_id')::uuid,(entry->>'quote_id')::uuid);end loop;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'mixed_visit_components_reserved','cashier_reviewed_draft',i.draft_id::text,p_branch,jsonb_build_object('group_id',p_request,'policy_id',p_policy,'covered_units',p_units,'held_visits',preview->'required_visits','invoice_issued',false,'payment_confirmed',false));
 return private.mixed_visit_group_snapshot(p_request);end$function$;
CREATE OR REPLACE FUNCTION private.release_mixed_visit_components(p_request uuid, p_group uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare g private.mixed_visit_groups;actor uuid;prior private.mixed_visit_group_releases;part record;result jsonb;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_group is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact release and audit reason required'using errcode='22023';end if;
 select *into g from private.mixed_visit_groups where request_id=p_group;
 if not found or g.actor_id<>auth.uid()then raise exception 'Visit group unavailable'using errcode='42501';end if;
 actor:=private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));perform pg_advisory_xact_lock(hashtextextended('mixed-visit-release:'||p_request,0));
 select *into prior from private.mixed_visit_group_releases where request_id=p_request or group_id=p_group;
 if found then if prior.actor_id<>actor or prior.group_id<>p_group or prior.reason<>trim(p_reason)then raise exception 'Immutable mixed visit release'using errcode='22023';end if;return prior.result;end if;
 for part in select reservation_id from private.mixed_visit_components where group_id=p_group order by unit_number loop perform private.release_mixed_offline_visit_reservation(part.reservation_id,trim(p_reason));end loop;
 perform private.require_typed_reward_document_session(actor);
 if exists(select 1 from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=p_group and h.released_at is null)then raise exception 'All unconsumed component holds must be released atomically'using errcode='55000';end if;
 result:=jsonb_build_object('release_id',p_request,'group_id',p_group,'released',true,'held_visits',0,'invoice_issued',false,'financial_refund_executed',false);
 insert into private.mixed_visit_group_releases values(p_request,p_group,actor,trim(p_reason),result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'mixed_visit_components_released','cashier_reviewed_draft',(select draft_id::text from private.cashier_loyalty_draft_intents where request_id=g.intent_id),g.branch_id,jsonb_build_object('release_id',p_request,'group_id',p_group,'reason',trim(p_reason),'held_visits',0,'financial_refund_executed',false));
 return result;end$function$;
CREATE OR REPLACE FUNCTION private.mixed_visit_verbal_current(p_consent uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare c private.mixed_visit_verbal_consents;g private.mixed_visit_groups;draft_state jsonb;group_state jsonb;begin
 select *into c from private.mixed_visit_verbal_consents where request_id=p_consent and actor_id=auth.uid();if not found then return false;end if;
 select *into strict g from private.mixed_visit_groups where request_id=c.group_id and actor_id=c.actor_id;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 if not private.mixed_visit_scope_current(g.request_id)then return false;end if;
 draft_state:=private.get_cashier_loyalty_draft_intent(g.branch_id,g.intent_id);group_state:=private.mixed_visit_group_snapshot(g.request_id);perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);
 return c.session_id=(auth.jwt()->>'session_id')::uuid and exists(select 1 from auth.sessions where id=c.session_id and user_id=c.actor_id and(not_after is null or not_after>clock_timestamp()))
 and c.fingerprint=g.fingerprint and c.policy_id=g.policy_id and c.notice is not distinct from private.mixed_visit_verbal_notice(c.language,g.quote)
 and exists(select 1 from private.owner_mixed_visit_policy_current x join private.owner_mixed_visit_policy_versions v using(version_id)where x.branch_id=g.branch_id and x.rules_version_id=g.rules_version_id and x.version_id=c.policy_id and v.terms->>'allow_walk_in'='true')
 and draft_state->>'state'='current'
 and(group_state->>'reservation_live')::boolean;
 exception when others then return false;
end$function$;
CREATE OR REPLACE FUNCTION private.attest_mixed_visit_verbal(p_request uuid, p_branch uuid, p_group uuid, p_fingerprint text, p_identity_method text, p_identity_invoice text, p_note text, p_language text, p_notice text, p_identity_verified boolean, p_verbal_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare actor uuid;g private.mixed_visit_groups;old private.mixed_visit_verbal_consents;policy uuid;name text;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own visit reservation required'using errcode='42501';end if;
 actor:=private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 if p_request is null or p_fingerprint is null or p_identity_verified is distinct from true or p_verbal_confirmed is distinct from true or p_identity_method is null or p_identity_method not in('original_service_document_and_vehicle','in_person_identity_and_registered_vehicle')or p_identity_invoice is null or p_language is null or p_language not in('ar','en')or p_notice is null or length(trim(coalesce(p_note,'')))not between 10 and 500 then raise exception 'Independent identity check and separate explicit verbal assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-verbal-request:'||p_request,0));
 if(private.get_cashier_loyalty_draft_intent(p_branch,g.intent_id))->>'state'is distinct from'current'then raise exception 'Review current sealed draft before verbal assent'using errcode='40001';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 -- Recheck real role/session AFTER any wait. A phone number or verified email
 -- is never used as proof of ownership or as permission to withdraw visits.
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=actor and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found then raise exception 'Current unchanged cashier session required'using errcode='42501';end if;
 perform 1 from public.staff_profiles where user_id=actor and is_active for share skip locked;
 if not found then raise exception 'Current unchanged cashier role required'using errcode='42501';end if;
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 perform private.lock_mixed_visit_permission(p_branch,g.rules_version_id);if not private.mixed_visit_scope_current(p_group)then raise exception 'Visit delegation version changed; release and review again'using errcode='42501';end if;
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
end$function$;
CREATE OR REPLACE FUNCTION private.issue_mixed_visit_invoice(p_request uuid, p_branch uuid, p_group uuid, p_consent uuid, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;a private.mixed_visit_issue_authorizations;result jsonb;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own actual visit group required'using errcode='42501';end if;
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,false);
 if p_request is null or p_consent is null then raise exception 'Exact issuance request and assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-issue:'||p_request,0));
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;
 if found then
 if a.actor_id<>auth.uid()or a.group_id<>p_group or a.consent_id<>p_consent then raise exception 'Immutable visit invoice request'using errcode='22023';end if;
 return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start)||jsonb_build_object('zero_visit_coverage',private.mixed_visit_zero_coverage_valid((select invoice_id from private.mixed_visit_invoice_bindings where group_id=p_group)),'collection_required',(g.quote->>'total')::numeric>0,'payment_status_at_issuance',case when(g.quote->>'total')::numeric=0 then'covered_by_reward'else'unpaid'end,'payment_requires_cashier_confirmation',(g.quote->>'total')::numeric>0,'visit_balance_reserved',true,'visit_collection_committed',false);end if;
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 if(private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'or not exists(select 1 from private.mixed_visit_verbal_consents c where c.request_id=p_consent and c.group_id=p_group and c.actor_id=auth.uid())then raise exception 'Own current sealed draft and exact consent required'using errcode='42501';end if;
 perform private.lock_mixed_visit_backing(p_group);
 if not private.mixed_visit_verbal_current(p_consent)then raise exception 'Current independently verified verbal approval required'using errcode='42501';end if;
 insert into private.mixed_visit_issue_authorizations values(p_request,p_group,p_consent,auth.uid(),txid_current());
 result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 perform private.lock_mixed_visit_permission(p_branch,g.rules_version_id);if not private.mixed_visit_scope_current(p_group)then raise exception 'Visit delegation version changed'using errcode='42501';end if;
 -- Scheduling/capacity waits must not allow an expired session or quote through.
 perform private.mixed_visit_operator(p_branch,g.rules_version_id,true);
 if g.expires_at<=clock_timestamp()then raise exception 'Visit quote expired before issuance completed'using errcode='40001';end if;
 if(g.quote->>'total')::numeric=0 then
 insert into private.mixed_visit_zero_coverages values(p_group,result->>'invoice_id',p_consent,auth.uid(),txid_current(),clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'mixed_visit_zero_covered','business_invoices',result->>'invoice_id',p_branch,jsonb_build_object('group_id',p_group,'consent_id',p_consent,'amount_due',0,'payment_event_created',false));
 end if;
 return result||jsonb_build_object('zero_visit_coverage',(g.quote->>'total')::numeric=0,'collection_required',(g.quote->>'total')::numeric>0,'payment_status_at_issuance',case when(g.quote->>'total')::numeric=0 then'covered_by_reward'else'unpaid'end,'payment_requires_cashier_confirmation',(g.quote->>'total')::numeric>0,'visit_balance_reserved',true,'visit_collection_committed',false);
end$function$;
CREATE OR REPLACE FUNCTION private.apply_mixed_visit_issuing_quote(p_request uuid, p_quote jsonb)
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
CREATE OR REPLACE FUNCTION private.guard_zero_visit_coverage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;p private.cashier_invoice_postings;begin
 select *into a from private.mixed_visit_issue_authorizations where group_id=new.group_id and consent_id=new.consent_id and actor_id=new.actor_id and creator_xid=txid_current();
 select x.*into p from private.cashier_invoice_postings x join private.mixed_visit_invoice_bindings b using(invoice_id)where b.group_id=new.group_id and x.invoice_id=new.invoice_id;
 select *into g from private.mixed_visit_groups where request_id=new.group_id;
 if a.request_id is null or p.request_id is distinct from a.request_id or new.actor_id is distinct from auth.uid()or new.creator_xid<>txid_current()or p.creator_xid<>txid_current()or g.expires_at<=clock_timestamp()or(p.quote->>'total')::numeric<>0 or(g.quote->>'total')::numeric<>0 or not exists(select 1 from public.business_invoices where invoice_id=new.invoice_id and total=0 and status='active')or jsonb_array_length(g.quote->'lines')<>1 or g.covered_units<>(g.quote#>>'{lines,0,quantity}')::integer or g.quote#>>'{lines,0,item_type}'is distinct from'service'or(g.quote->>'visit_discount_exact')::numeric<=0 or(select count(*)from private.cashier_service_worklines where invoice_id=new.invoice_id and allocated_payable=0)<>g.covered_units or exists(select 1 from public.business_payment_events where invoice_id=new.invoice_id)then raise exception 'Actual same-transaction fully covered service invoice required'using errcode='55000';end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,true);return new;
end$function$;
CREATE OR REPLACE FUNCTION private.restore_mixed_visit_units(p_invoice text, p_source uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare g private.mixed_visit_groups;part record;rule text;returned integer;begin
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
CREATE OR REPLACE FUNCTION private.commit_mixed_visit_collection()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare g private.mixed_visit_groups;begin
 if new.event_type<>'sale'then return new;end if;
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.mixed_visit_operator(g.branch_id,g.rules_version_id,false);perform private.lock_mixed_visit_backing(g.request_id);
 if new.amount<>private.cashier_invoice_payable(new.invoice_id)or new.method not in('cash','card_terminal')or(new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.amount=new.amount))then raise exception 'Actual full cash or verified terminal collection required'using errcode='55000';end if;
 insert into private.mixed_visit_collection_commits(group_id,payment_id)values(g.request_id,new.payment_id);return new;
end$function$;
CREATE OR REPLACE FUNCTION private.preview_saved_mixed_visit_candidates(p_branch uuid, p_intent uuid, p_rules uuid, p_channel uuid, p_line text, p_units bigint, p_policy uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;i private.cashier_loyalty_draft_intents;rules private.loyalty_redemption_rule_versions;
 settings private.owner_mixed_visit_policy_versions;state jsonb;kind text;subject uuid;needed numeric;candidate_count bigint;rules_for_math jsonb;quote jsonb;clear boolean;fp text;
begin
 actor:=private.cashier_cart_actor(p_branch);
 perform private.mixed_visit_operator(p_branch,p_rules,true);
 if p_intent is null or p_rules is null or p_line is null or p_units is null or p_units<=0 or p_policy is null then raise exception 'Exact draft, benefit, units and saved owner policy required'using errcode='22023';end if;
 select v.*into settings from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules for share of c;
 if not found or settings.version_id<>p_policy then raise exception 'Current saved owner visit policy required'using errcode='40001';end if;
 if settings.terms->>'allow_walk_in'is distinct from'true'then raise exception 'Owner has not permitted mixed walk-in visit coverage'using errcode='42501';end if;
 state:=private.get_cashier_loyalty_draft_intent(p_branch,p_intent);
 if state->>'state'is distinct from'current'then raise exception 'Review and reseal current draft first'using errcode='40001';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=actor and branch_id=p_branch;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=p_rules and branch_id=p_branch;
 if not found or(i.witness->>'subject_kind'='app_customer'and not exists(select 1 from private.reward_rule_activations where rules_version_id=p_rules))then raise exception 'Actual activated benefit terms required'using errcode='22023';end if;
 if settings.source_terms_hash<>encode(extensions.digest(rules.terms_snapshot::text,'sha256'),'hex')then raise exception 'Owner policy benefit terms mismatch'using errcode='40001';end if;
 if rules.rules->>'expiry'='snapshot_offer_end'and coalesce((rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz<=clock_timestamp(),true)then raise exception 'Benefit snapshot expired'using errcode='55000';end if;
 kind:=case i.witness->>'subject_kind'when'app_customer'then'auth_customer'when'offline_profile'then'offline_profile'else null end;
 subject:=(i.witness->>'subject')::uuid;
 if kind is null then raise exception 'Typed bound customer required'using errcode='22023';end if;
 if kind='auth_customer'then
 if p_channel is not null then raise exception 'Auth customer cannot borrow an offline channel'using errcode='22023';end if;
 clear:=coalesce((private.reward_program_blockers(subject,p_rules)->>'eligible')::boolean,false);
 else
 if p_channel is null or not exists(select 1 from private.offline_visit_channel_versions c join private.offline_visit_channel_activations a on a.channel_version_id=c.version_id where c.version_id=p_channel and c.rules_version_id=p_rules and c.branch_id=p_branch and c.enabled)then raise exception 'Actual activated offline benefit channel required'using errcode='22023';end if;
 clear:=private.offline_reward_debt_clear(subject,p_rules);
 end if;
 -- This is the existing typed selector: no legacy point conversion, adoption,
 -- phone matching, cached balance or private source UUIDs returned to clients.
 select count(*)into candidate_count from private.reward_owner_candidate_lots(kind,subject,p_rules,p_channel);
 needed:=(rules.terms_snapshot->>'threshold_visits')::numeric*p_units;
 if needed is null or needed<=0 or needed<>trunc(needed)then raise exception 'Actual visit threshold required'using errcode='22023';end if;
 if not clear or candidate_count<needed then return jsonb_build_object('unit','service_visits','preview_only',true,'candidate_threshold_met',false,'candidate_count',candidate_count,'required_visits',needed,'review_required',not clear,'quote',null,'balance_reserved',false,'consent_authorized',false,'redemption_enabled',false,'tax_choice_saved',true,'owner_policy_id',settings.version_id);end if;
 rules_for_math:=settings.terms||jsonb_build_object('reward_item_id',rules.terms_snapshot#>>'{reward_service,id}','threshold_visits',rules.terms_snapshot->'threshold_visits');
 quote:=private.mixed_visit_coverage_core(i.witness->'quote',rules_for_math,p_line,p_units);
 fp:=encode(extensions.digest(jsonb_build_object('intent',i.fingerprint,'rules_version',p_rules,'channel',p_channel,'line',p_line,'units',p_units,'owner_policy_id',settings.version_id,'source_terms_hash',settings.source_terms_hash,'quote',quote)::text,'sha256'),'hex');
 perform private.require_typed_reward_document_session(actor);
 perform private.mixed_visit_operator(p_branch,p_rules,true);
 return jsonb_build_object('unit','service_visits','preview_only',true,'candidate_threshold_met',true,'candidate_count',candidate_count,'required_visits',needed,'rules_version_id',p_rules,'intent_fingerprint',i.fingerprint,'preview_fingerprint',fp,'quote',quote,'expires_at',i.expires_at,'balance_reserved',false,'consent_authorized',false,'redemption_enabled',false,'tax_choice_saved',true,'owner_policy_id',settings.version_id,'issuance_blockers',jsonb_build_array('atomic_relock_reservation_and_source_refund_resync_required','verbal_assent_invoice_and_collection_adapters_required','covered_unit_work_refund_and_cancellation_adapters_required'));
end$function$;
CREATE OR REPLACE FUNCTION private.require_mixed_visit_pos(p_branch uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 perform private.cashier_cart_actor(p_branch);
 
 perform 1 from private.mixed_visit_pos_runtime where singleton and enabled for share;if not found then raise exception 'Visit POS redemption is not activated'using errcode='55000';end if;perform private.cashier_cart_actor(p_branch);
end$function$;
CREATE OR REPLACE FUNCTION private.release_cashier_mixed_visits(p_request uuid, p_branch uuid, p_group uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 perform private.cashier_cart_actor(p_branch);if not exists(select 1 from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid())then raise exception 'Own branch visit hold required'using errcode='42501';end if;return private.release_mixed_visit_components(p_request,p_group,p_reason);
end$function$;
CREATE OR REPLACE FUNCTION private.issue_cashier_visit_invoice(p_request uuid, p_branch uuid, p_group uuid, p_consent uuid, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 if not exists(select 1 from private.mixed_visit_issue_authorizations where request_id=p_request and group_id=p_group and consent_id=p_consent and actor_id=auth.uid())then perform private.require_mixed_visit_pos(p_branch);end if;return private.issue_mixed_visit_invoice(p_request,p_branch,p_group,p_consent,p_start);
end$function$;
CREATE OR REPLACE FUNCTION private.get_cashier_mixed_visits_context(p_branch uuid, p_draft uuid)
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
CREATE OR REPLACE FUNCTION private.get_owner_visit_cashier_grants(p_branch uuid, p_rules uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;begin
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.user_id,'name',s.full_name,'eligible',private.visit_cashier_eligible(s.user_id,p_branch),
 'allowed',coalesce(v.allowed,false),'version_no',coalesce(v.version_no,0),'version_id',v.version_id,'changed_at',v.created_at,'changed_by',v.actor_id,'reason',v.reason)order by s.full_name,s.user_id),'[]'::jsonb)into result
 from public.staff_profiles s left join private.mixed_visit_cashier_grant_current c on c.staff_id=s.user_id and c.branch_id=p_branch and c.rules_version_id=p_rules
 left join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id
 where private.visit_cashier_eligible(s.user_id,p_branch)or c.staff_id is not null;
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 return jsonb_build_object('staff',result,'default_allowed',false,'runtime_enabled',(select enabled from private.mixed_visit_pos_runtime where singleton),'allocator_delegation_ready',true,'financial_operation',false);
end$function$;
do $$declare f record;begin for f in select oid::regprocedure sig from pg_proc where pronamespace='private'::regnamespace and proname in('mixed_visit_operator','lock_mixed_visit_permission','mixed_visit_scope_current','record_mixed_visit_cashier_scope','reserve_mixed_offline_visit_candidates','release_mixed_offline_visit_reservation')loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);end loop;end$$;
notify pgrst,'reload schema';
commit;