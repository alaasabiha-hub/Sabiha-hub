begin;
-- Private preparation component only. Canonical old visit claims remain the
-- single entitlement allocator; no invoice, consent or public spend route.
create table private.mixed_visit_groups(
 request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),session_id uuid not null references auth.sessions(id),
 branch_id uuid not null references public.business_branches(branch_id),intent_id uuid not null unique references private.cashier_loyalty_draft_intents(request_id),
 profile_id uuid not null references private.offline_customer_profiles(profile_id),car_id uuid not null references private.offline_customer_car_refs(car_ref_id),
 rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),channel_id uuid not null references private.offline_visit_channel_versions(version_id),
 policy_id uuid not null references private.owner_mixed_visit_policy_versions(version_id),line_id text not null,covered_units integer not null check(covered_units>0),required_visits bigint not null check(required_visits>0),
 payload jsonb not null,quote jsonb not null,fingerprint text not null,expires_at timestamptz not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_visit_components(group_id uuid not null references private.mixed_visit_groups(request_id),unit_number integer not null check(unit_number>0),reservation_id uuid not null unique references private.offline_reward_reservation_commands(request_id),quote_id uuid not null unique references private.service_reward_quotes(quote_id),primary key(group_id,unit_number));
create table private.mixed_visit_group_releases(request_id uuid primary key,group_id uuid not null unique references private.mixed_visit_groups(request_id),actor_id uuid not null references public.staff_profiles(user_id),reason text not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['mixed_visit_groups','mixed_visit_components','mixed_visit_group_releases']loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);execute format('create trigger immutable_mixed_visit_data before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end loop;end$$;
create function private.mixed_visit_group_holds(p_group uuid)returns boolean language sql volatile security invoker set search_path=pg_catalog as $$
 select exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id join private.service_reward_quotes q on q.quote_id=x.quote_id where x.group_id=p_group and c.state='active'and q.expires_at>clock_timestamp()and exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and h.released_at is null))$$;
create function private.mixed_visit_group_snapshot(p_group uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.mixed_visit_groups;held bigint;live boolean;begin
 select *into g from private.mixed_visit_groups where request_id=p_group;
 if not found or g.actor_id<>auth.uid()then raise exception 'Visit group unavailable'using errcode='42501';end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 select count(*)into held from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=p_group and h.released_at is null;
 live:=g.expires_at>clock_timestamp()and held=g.required_visits and not exists(select 1 from private.mixed_visit_group_releases where group_id=p_group)and not exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=p_group and(c.state<>'active'or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is not null)));
 return jsonb_build_object('group_id',p_group,'unit','service_visits','covered_units',g.covered_units,'required_visits',g.required_visits,'held_visits',held,'reservation_live',live,'fingerprint',g.fingerprint,'expires_at',g.expires_at,'quote',g.quote,'released',exists(select 1 from private.mixed_visit_group_releases where group_id=p_group),'consent_authorized',false,'invoice_issued',false,'redemption_enabled',false);
end$$;
-- Both reservation routes serialize on the SAME already-canonical draft row.
-- The points allocator takes this row before its wallet lock; no new mutex with
-- a reversed ordering is introduced into its established lock chain.
create function private.guard_points_against_visit_hold()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare draft uuid;begin
 select draft_id into draft from private.cashier_loyalty_draft_intents where request_id=new.intent_id;
 perform 1 from private.cashier_reviewed_drafts where draft_id=draft for update;
 if exists(select 1 from private.mixed_visit_groups g where g.intent_id=new.intent_id and private.mixed_visit_group_holds(g.request_id))then raise exception 'Recover or release current visit reservation before selecting points'using errcode='40001';end if;
 return new;end$$;
create trigger a_points_visit_exclusion before insert on private.mixed_points_reservations for each row execute function private.guard_points_against_visit_hold();
-- Canonical standalone issuers must not consume a component behind this group's
-- back. A future verified mixed issuer will need an explicit new typed fence.
create function private.fence_grouped_visit_consumption()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.state='consumed'and old.state is distinct from new.state and exists(select 1 from private.mixed_visit_components where reservation_id=new.request_id)then raise exception 'Grouped visit consumption requires the unfinished typed mixed issuer'using errcode='55000';end if;return new;end$$;
create trigger a_fence_grouped_visit_consumption before update of state on private.offline_reward_reservation_commands for each row execute function private.fence_grouped_visit_consumption();
create function private.reserve_mixed_visit_components(p_request uuid,p_branch uuid,p_intent uuid,p_rules uuid,p_channel uuid,p_line text,p_units bigint,p_policy uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid:=private.owner_mixed_visit_actor(p_branch,p_rules);old_group private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;settings private.owner_mixed_visit_policy_versions;
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
 for pending in select c.request_id from private.offline_reward_reservation_commands c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.offline_profile_id=(i.witness->>'subject')::uuid and c.state='active'and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and private.reward_credit_refund(h.earning_id)is not null))order by c.request_id loop perform private.release_offline_reward_reservation(pending.request_id,'Release expired or refunded unconsumed hold before mixed visit reservation');end loop;
 perform private.sync_offline_profile_rewards((i.witness->>'subject')::uuid);
 preview:=private.preview_saved_mixed_visit_candidates(p_branch,p_intent,p_rules,p_channel,p_line,p_units,p_policy);
 if preview->>'candidate_threshold_met'is distinct from'true'then raise exception 'Actual unreserved visit candidates or refund review not ready'using errcode='55000';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(i.witness#>'{quote,lines}')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'One-visit work must fit the existing business-day work bound'using errcode='22023';end if;
 select(value->>'item_id')::uuid into strict service from jsonb_array_elements(i.witness#>'{quote,lines}')where value->>'line_id'=p_line;
 select price into strict gross from public.business_catalog_items where item_id=service;deadline:=i.expires_at;
 for unit_no in 1..p_units::integer loop
 child:=gen_random_uuid();part:=private.reserve_offline_reward_candidates(child,(i.witness->>'subject')::uuid,(i.witness->>'car')::uuid,p_channel,gross);
 if part->>'state'is distinct from'active'or(part->>'held_visits')::numeric<>(preview->>'required_visits')::numeric/p_units then raise exception 'Exact original visit component funding required'using errcode='55000';end if;
 deadline:=least(deadline,(part->>'expires_at')::timestamptz);components:=components||jsonb_build_array(jsonb_build_object('reservation_id',child,'quote_id',part->'quote_id','unit_number',unit_no));
 end loop;
 perform private.require_typed_reward_document_session(actor);perform private.owner_mixed_visit_actor(p_branch,p_rules);
 if(private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'or deadline<=clock_timestamp()then raise exception 'Draft or reservation expired while waiting'using errcode='40001';end if;
 fp:=encode(extensions.digest(jsonb_build_object('payload',payload,'intent_fingerprint',i.fingerprint,'quote',preview->'quote','components',components,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.mixed_visit_groups values(p_request,actor,(auth.jwt()->>'session_id')::uuid,p_branch,p_intent,(i.witness->>'subject')::uuid,(i.witness->>'car')::uuid,p_rules,p_channel,p_policy,p_line,p_units::integer,(preview->>'required_visits')::bigint,payload,preview->'quote',fp,deadline,txid_current(),clock_timestamp());
 for entry in select value from jsonb_array_elements(components)loop insert into private.mixed_visit_components values(p_request,(entry->>'unit_number')::integer,(entry->>'reservation_id')::uuid,(entry->>'quote_id')::uuid);end loop;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'mixed_visit_components_reserved','cashier_reviewed_draft',i.draft_id::text,p_branch,jsonb_build_object('group_id',p_request,'policy_id',p_policy,'covered_units',p_units,'held_visits',preview->'required_visits','invoice_issued',false,'payment_confirmed',false));
 return private.mixed_visit_group_snapshot(p_request);end$$;
create function private.release_mixed_visit_components(p_request uuid,p_group uuid,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare g private.mixed_visit_groups;actor uuid;prior private.mixed_visit_group_releases;part record;result jsonb;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_group is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact release and audit reason required'using errcode='22023';end if;
 select *into g from private.mixed_visit_groups where request_id=p_group;
 if not found or g.actor_id<>auth.uid()then raise exception 'Visit group unavailable'using errcode='42501';end if;
 actor:=private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));perform pg_advisory_xact_lock(hashtextextended('mixed-visit-release:'||p_request,0));
 select *into prior from private.mixed_visit_group_releases where request_id=p_request or group_id=p_group;
 if found then if prior.actor_id<>actor or prior.group_id<>p_group or prior.reason<>trim(p_reason)then raise exception 'Immutable mixed visit release'using errcode='22023';end if;return prior.result;end if;
 for part in select reservation_id from private.mixed_visit_components where group_id=p_group order by unit_number loop perform private.release_offline_reward_reservation(part.reservation_id,trim(p_reason));end loop;
 perform private.require_typed_reward_document_session(actor);
 if exists(select 1 from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=p_group and h.released_at is null)then raise exception 'All unconsumed component holds must be released atomically'using errcode='55000';end if;
 result:=jsonb_build_object('release_id',p_request,'group_id',p_group,'released',true,'held_visits',0,'invoice_issued',false,'financial_refund_executed',false);
 insert into private.mixed_visit_group_releases values(p_request,p_group,actor,trim(p_reason),result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'mixed_visit_components_released','cashier_reviewed_draft',(select draft_id::text from private.cashier_loyalty_draft_intents where request_id=g.intent_id),g.branch_id,jsonb_build_object('release_id',p_request,'group_id',p_group,'reason',trim(p_reason),'held_visits',0,'financial_refund_executed',false));
 return result;end$$;
create function private.check_mixed_visit_group_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g private.mixed_visit_groups;components bigint;held bigint;closed boolean;begin
 select *into g from private.mixed_visit_groups where request_id=new.request_id;
 select count(*)into components from private.mixed_visit_components where group_id=g.request_id;
 if components<>g.covered_units or g.creator_xid<>txid_current()then raise exception 'Atomic complete visit group required'using errcode='55000';end if;
 if exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id join private.service_reward_quotes q on q.quote_id=x.quote_id where x.group_id=g.request_id and(c.creator_xid<>g.creator_xid or c.quote_id<>x.quote_id or c.offline_profile_id<>g.profile_id or c.requested_by<>g.actor_id or q.offline_car_ref_id<>g.car_id or q.branch_id<>g.branch_id or q.rules_version_id<>g.rules_version_id or q.offline_channel_version_id<>g.channel_id))then raise exception 'Original typed component facts mismatch'using errcode='55000';end if;
 if g.quote#>>'{visit_reward,unit}'is distinct from'service_visits'or g.quote#>>'{visit_reward,covered_line}'is distinct from g.line_id or(g.quote#>>'{visit_reward,covered_units}')::numeric<>g.covered_units or(g.quote#>>'{visit_reward,required_visits}')::numeric<>g.required_visits
 or g.expires_at>(select min(q.expires_at)from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.group_id=g.request_id)
 or not exists(select 1 from private.cashier_loyalty_draft_intents i where i.request_id=g.intent_id and i.actor_id=g.actor_id and i.branch_id=g.branch_id and i.witness->>'subject_kind'='offline_profile'and(i.witness->>'subject')::uuid=g.profile_id and(i.witness->>'car')::uuid=g.car_id and i.expires_at>=g.expires_at)
 then raise exception 'Exact sealed coverage interval and expiry required'using errcode='55000';end if;
 select count(*)into held from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=g.request_id and h.released_at is null;
 closed:=exists(select 1 from private.mixed_visit_group_releases where group_id=g.request_id);
 if closed then
 if held<>0 or exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=g.request_id and c.state not in('released','expired','refunded'))then raise exception 'Closed group requires fully released canonical holds'using errcode='55000';end if;
 else
 if held<>g.required_visits or g.expires_at<=clock_timestamp()or exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=g.request_id and c.state<>'active')then raise exception 'Exactly funded active visit group required'using errcode='55000';end if;
 end if;return null;end$$;
create constraint trigger complete_mixed_visit_group after insert on private.mixed_visit_groups deferrable initially deferred for each row execute function private.check_mixed_visit_group_commit();
revoke all on function private.mixed_visit_group_holds(uuid),private.mixed_visit_group_snapshot(uuid),private.guard_points_against_visit_hold(),private.fence_grouped_visit_consumption(),private.reserve_mixed_visit_components(uuid,uuid,uuid,uuid,uuid,text,bigint,uuid),private.release_mixed_visit_components(uuid,uuid,text),private.check_mixed_visit_group_commit()from public,anon,authenticated,service_role;
commit;
