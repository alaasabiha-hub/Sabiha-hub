begin;
-- Foundation only: service-visit eligibility snapshots, never points, money or redemption.
create table if not exists private.managed_visit_reward_offers(offer_id uuid primary key references public.business_offers(offer_id),managed_by uuid not null references public.staff_profiles(user_id),managed_at timestamptz not null default clock_timestamp());
alter table private.managed_visit_reward_offers enable row level security;
revoke all on private.managed_visit_reward_offers from public,anon,authenticated;
create table private.loyalty_policy_versions (
 version_no bigint generated always as identity primary key,version_id uuid not null unique,branch_id uuid not null references public.business_branches(branch_id),
 offer_id uuid not null references public.business_offers(offer_id),eligible_service_ids uuid[] not null check(cardinality(eligible_service_ids) between 1 and 100),enabled boolean not null,
 policy_snapshot jsonb not null,request_payload jsonb not null,created_by uuid not null references public.staff_profiles(user_id),created_at timestamptz not null default clock_timestamp());
create index loyalty_policy_branch_latest on private.loyalty_policy_versions(branch_id,version_no desc);
create table private.booking_loyalty_policy_snapshots (
 booking_id uuid primary key references public.bookings(id),policy_version_id uuid not null references private.loyalty_policy_versions(version_id),
 catalog_item_id uuid not null references public.business_catalog_items(item_id),branch_id uuid not null references public.business_branches(branch_id),policy_snapshot jsonb not null,captured_at timestamptz not null default clock_timestamp());
create index booking_loyalty_policy_version on private.booking_loyalty_policy_snapshots(policy_version_id);
alter table private.loyalty_policy_versions enable row level security;
alter table private.booking_loyalty_policy_snapshots enable row level security;
revoke all on private.loyalty_policy_versions,private.booking_loyalty_policy_snapshots from public,anon,authenticated;
create function private.immutable_loyalty_policy() returns trigger language plpgsql security invoker set search_path=pg_catalog as $$begin raise exception 'Loyalty policy history is immutable';end $$;
revoke all on function private.immutable_loyalty_policy() from public,anon,authenticated;
create trigger immutable_managed_visit_offer before update or delete on private.managed_visit_reward_offers for each row execute function private.immutable_loyalty_policy();
create trigger immutable_loyalty_policy_version before update or delete on private.loyalty_policy_versions for each row execute function private.immutable_loyalty_policy();
create trigger immutable_booking_loyalty_snapshot before update or delete on private.booking_loyalty_policy_snapshots for each row execute function private.immutable_loyalty_policy();
create function private.get_loyalty_policy(p_branch uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_active and (p_branch is null or branch_id=p_branch) order by is_default desc,branch_id limit 1;
 if b is null then raise exception 'Active branch required';end if;
 return jsonb_build_object('branch_id',b,'unit','service_visits','automatic_earning_implemented',false,'redemption_implemented',false,
 'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',branch_id,'name_ar',name_ar,'name_en',name_en)),'[]') from public.business_branches where is_active),
 'offers',(select coalesce(jsonb_agg(jsonb_build_object('id',offer_id,'name',name,'visits_required',visits_required,'is_active',is_active,'is_public',is_public,'starts_at',starts_at,'ends_at',ends_at,'branch_id',branch_id,'name_en',name_en,'reward_item_id',reward_item_id,'reward_value',reward_value)),'[]') from public.business_offers where offer_type='visit_reward' and visits_required is not null and (branch_id=b or branch_id is null)),
 'services',(select coalesce(jsonb_agg(jsonb_build_object('id',item_id,'name',name,'is_active',is_active,'is_public',is_public)),'[]') from public.business_catalog_items where branch_id=b and item_type='service'),
 'current',(select to_jsonb(v) from private.loyalty_policy_versions v where branch_id=b order by version_no desc limit 1),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by version_no desc),'[]') from (select v.version_id,v.version_no,v.enabled,v.offer_id,v.eligible_service_ids,v.created_at,v.created_by,(select count(*) from private.booking_loyalty_policy_snapshots s where s.policy_version_id=v.version_id) captured_bookings from private.loyalty_policy_versions v where branch_id=b order by version_no desc limit 50)x));
end $$;
revoke all on function private.get_loyalty_policy(uuid) from public,anon;
grant execute on function private.get_loyalty_policy(uuid) to authenticated;
create function public.get_loyalty_policy(p_branch uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_loyalty_policy(p_branch)$$;
revoke all on function public.get_loyalty_policy(uuid) from public,anon;
grant execute on function public.get_loyalty_policy(uuid) to authenticated;
create function private.save_loyalty_policy(p_request uuid,p_branch uuid,p_offer uuid,p_services uuid[],p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior private.loyalty_policy_versions;o public.business_offers;payload jsonb;snapshot jsonb;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_branch is null or p_offer is null or p_enabled is null or p_services is null or cardinality(p_services) not between 1 and 100 or array_position(p_services,null) is not null or (select count(distinct x) from unnest(p_services)x)<>cardinality(p_services) then raise exception 'Select explicit branch, visit offer, unique actual services and enabled state';end if;
 payload:=jsonb_build_object('branch_id',p_branch,'offer_id',p_offer,'service_ids',p_services,'enabled',p_enabled);
 perform pg_advisory_xact_lock(hashtextextended('loyalty-request:'||p_request::text,0));
 select * into prior from private.loyalty_policy_versions where version_id=p_request;
 if prior.version_id is not null then if prior.created_by<>auth.uid() or prior.request_payload<>payload then raise exception 'Request identity reused with different inputs';end if;return to_jsonb(prior);end if;
 perform pg_advisory_xact_lock(hashtextextended('loyalty-policy-branch:'||p_branch::text,0));
 perform 1 from public.business_branches where branch_id=p_branch and is_active for share;
 if not found then raise exception 'Active branch required';end if;
 perform 1 from public.business_catalog_items where item_id=any(p_services) and branch_id=p_branch and item_type='service' order by item_id for share;
 select * into o from public.business_offers where offer_id=p_offer and offer_type='visit_reward' and visits_required is not null for share;
 if o.offer_id is null then raise exception 'Actual visit reward offer required';end if;
 if o.branch_id is not null and o.branch_id<>p_branch then raise exception 'Visit offer belongs to another branch';end if;
 if p_enabled and (not o.is_active or not o.is_public or o.starts_at>clock_timestamp() or o.ends_at<clock_timestamp()) then raise exception 'Published currently active visit offer required to enable';end if;
 if exists(select 1 from unnest(p_services) id where not exists(select 1 from public.business_catalog_items c where c.item_id=id and c.branch_id=p_branch and c.item_type='service' and (not p_enabled or c.is_active and c.is_public))) then raise exception 'Choose actual services in this branch; enabled policy requires active public services';end if;
 snapshot:=jsonb_build_object('unit','service_visits','offer_id',o.offer_id,'offer_name',o.name,'threshold_visits',o.visits_required,'offer_starts_at',o.starts_at,'offer_ends_at',o.ends_at,'reward_item_id',o.reward_item_id,'reward_value',o.reward_value,'offer_branch_id',o.branch_id,'target_customer_ids',o.target_customer_ids,'eligibility_basis','booking_created_time','eligible_service_ids',p_services,'branch_id',p_branch,'enabled',p_enabled,'effective_scope','new_bookings_created_after_version','automatic_earning_implemented',false,'redemption_implemented',false);
 insert into private.managed_visit_reward_offers(offer_id,managed_by) values(p_offer,auth.uid()) on conflict(offer_id) do nothing;
 insert into private.loyalty_policy_versions(version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by) values(p_request,p_branch,p_offer,p_services,p_enabled,snapshot,payload,auth.uid()) returning to_jsonb(loyalty_policy_versions.*) into result;return result;
end $$;
revoke all on function private.save_loyalty_policy(uuid,uuid,uuid,uuid[],boolean) from public,anon;
grant execute on function private.save_loyalty_policy(uuid,uuid,uuid,uuid[],boolean) to authenticated;
create function public.save_loyalty_policy(p_request uuid,p_branch uuid,p_offer uuid,p_services uuid[],p_enabled boolean) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_loyalty_policy(p_request,p_branch,p_offer,p_services,p_enabled)$$;
revoke all on function public.save_loyalty_policy(uuid,uuid,uuid,uuid[],boolean) from public,anon;
grant execute on function public.save_loyalty_policy(uuid,uuid,uuid,uuid[],boolean) to authenticated;
create function private.capture_booking_loyalty_policy() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v private.loyalty_policy_versions;
begin
 -- This INSERT trigger never scans/backfills existing bookings and creates no earned balance.
 select * into v from private.loyalty_policy_versions where branch_id=new.branch_id order by version_no desc limit 1;
 if v.version_id is not null and v.enabled and new.catalog_item_id=any(v.eligible_service_ids) and exists(select 1 from public.business_offers where offer_id=v.offer_id and is_active and is_public and (branch_id=new.branch_id or branch_id is null)) and exists(select 1 from public.business_catalog_items where item_id=new.catalog_item_id and branch_id=new.branch_id and item_type='service' and is_active and is_public) and (v.policy_snapshot->>'offer_starts_at' is null or (v.policy_snapshot->>'offer_starts_at')::timestamptz<=clock_timestamp()) and (v.policy_snapshot->>'offer_ends_at' is null or (v.policy_snapshot->>'offer_ends_at')::timestamptz>=clock_timestamp()) and (v.policy_snapshot->'target_customer_ids'='null'::jsonb or v.policy_snapshot->'target_customer_ids' @> to_jsonb(array[new.customer_id])) then
 insert into private.booking_loyalty_policy_snapshots(booking_id,policy_version_id,catalog_item_id,branch_id,policy_snapshot) values(new.id,v.version_id,new.catalog_item_id,new.branch_id,v.policy_snapshot);
 end if;return new;
end $$;
revoke all on function private.capture_booking_loyalty_policy() from public,anon,authenticated;
create trigger capture_new_booking_loyalty_policy after insert on public.bookings for each row execute function private.capture_booking_loyalty_policy();
notify pgrst,'reload schema';
commit;
