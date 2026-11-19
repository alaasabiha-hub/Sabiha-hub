begin;
create table private.loyalty_offer_requests(request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.loyalty_offer_requests enable row level security;
revoke all on private.loyalty_offer_requests from public,anon,authenticated;
create function private.save_visit_reward_offer(p_request uuid,p_branch uuid,p_name text,p_visits integer,p_publish boolean,p_reward_service uuid,p_name_en text,p_offer uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare payload jsonb;prior private.loyalty_offer_requests;existing public.business_offers;oid uuid;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_branch is null or p_name is null or length(trim(p_name)) not between 2 and 120 or p_visits is null or p_visits not between 1 and 100000 or p_publish is null or length(coalesce(p_name_en,''))>120 then raise exception 'Explicit actual name, visit threshold, branch and publication choice required';end if;
 payload:=jsonb_build_object('branch',p_branch,'name',p_name,'visits',p_visits,'publish',p_publish,'reward_service',p_reward_service,'name_en',p_name_en,'offer',p_offer);
 perform pg_advisory_xact_lock(hashtextextended('loyalty-offer-request:'||p_request::text,0));
 select * into prior from private.loyalty_offer_requests where request_id=p_request;
 if prior.request_id is not null then if prior.actor_id<>auth.uid() or prior.payload<>payload then raise exception 'Request identity reused with different offer inputs';end if;return prior.result;end if;
 perform 1 from public.business_branches where branch_id=p_branch and is_active for share;
 if not found then raise exception 'Active branch required';end if;
 if p_reward_service is not null then
 perform 1 from public.business_catalog_items where item_id=p_reward_service and branch_id=p_branch and item_type='service' and (not p_publish or is_active and is_public) for share;
 if not found then raise exception 'Choose an actual reward service in this branch';end if;end if;
 if p_offer is null then
 oid:=gen_random_uuid();
 -- Visit thresholds are not a monetary price. The legacy reward_value default is unused.
 insert into public.business_offers(offer_id,branch_id,name,name_en,offer_type,visits_required,reward_item_id,is_active,is_public,presentation_category) values(oid,p_branch,trim(p_name),nullif(trim(p_name_en),''),'visit_reward',p_visits,p_reward_service,p_publish,p_publish,'reward');
 else
 select * into existing from public.business_offers where offer_id=p_offer for update;
 if existing.offer_id is null or existing.offer_type<>'visit_reward' or existing.branch_id is distinct from p_branch then raise exception 'Existing visit offer in the selected branch required';end if;
 oid:=existing.offer_id;
 update public.business_offers set name=trim(p_name),name_en=nullif(trim(p_name_en),''),visits_required=p_visits,reward_item_id=p_reward_service,is_active=p_publish,is_public=p_publish,updated_at=clock_timestamp() where offer_id=oid;
 end if;
 insert into private.managed_visit_reward_offers(offer_id,managed_by) values(oid,auth.uid()) on conflict(offer_id) do nothing;
 select jsonb_build_object('offer_id',offer_id,'branch_id',branch_id,'name',name,'name_en',name_en,'visits_required',visits_required,'reward_item_id',reward_item_id,'is_active',is_active,'is_public',is_public,'unit','service_visits','earning_implemented',false,'redemption_implemented',false) into result from public.business_offers where offer_id=oid;
 insert into private.loyalty_offer_requests(request_id,actor_id,payload,result) values(p_request,auth.uid(),payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'save_visit_reward_offer','business_offers',oid::text,p_branch,result);
 return result;
end $$;
revoke all on function private.save_visit_reward_offer(uuid,uuid,text,integer,boolean,uuid,text,uuid) from public,anon;
grant execute on function private.save_visit_reward_offer(uuid,uuid,text,integer,boolean,uuid,text,uuid) to authenticated;
create function public.save_visit_reward_offer(p_request uuid,p_branch uuid,p_name text,p_visits integer,p_publish boolean default false,p_reward_service uuid default null,p_name_en text default null,p_offer uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_visit_reward_offer(p_request,p_branch,p_name,p_visits,p_publish,p_reward_service,p_name_en,p_offer)$$;
revoke all on function public.save_visit_reward_offer(uuid,uuid,text,integer,boolean,uuid,text,uuid) from public,anon;
grant execute on function public.save_visit_reward_offer(uuid,uuid,text,integer,boolean,uuid,text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
