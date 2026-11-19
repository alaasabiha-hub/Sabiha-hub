begin;
-- Inspection order is server-assigned under the service row lock, not wall-clock order.
-- Latest failed inspection invalidates earlier passes; previous crew evidence never revives.
alter table private.service_quality_checks add column inspection_number bigint generated always as identity;
create unique index service_quality_inspection_sequence on private.service_quality_checks(inspection_number);
create or replace function private.quality_completion_guard()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare c private.service_quality_checks;
begin
 if old.status is distinct from new.status and new.status in('completed','delivered')and exists(select 1 from private.service_quality_bindings where order_id=new.order_id and required)then
 select *into c from private.service_quality_checks where order_id=new.order_id order by inspection_number desc limit 1;
 if c.request_id is null or not c.passed or c.crew_snapshot is distinct from private.quality_crew(new)then raise exception 'Latest required quality inspection must pass for the current service crew'using errcode='55000';end if;
 end if;return new;end$$;
create or replace function private.get_service_quality(p_order uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare o public.business_orders;b private.service_quality_bindings;checks jsonb;begin
 o:=private.quality_work_order(p_order);select *into b from private.service_quality_bindings where order_id=o.order_id;
 select coalesce(jsonb_agg(v order by inspection_number desc),'[]'::jsonb)into checks from(select jsonb_build_object('request_id',c.request_id,'passed',c.passed,'answers',c.payload->'answers','note',c.payload->'note','actor_id',c.actor_id,'created_at',c.created_at,'current_crew',c.crew_snapshot=private.quality_crew(o))v,c.inspection_number from private.service_quality_checks c where c.order_id=o.order_id order by c.inspection_number desc limit 25)s;
 return jsonb_build_object('order_id',o.order_id,'status',o.status,'start_snapshot_exists',b.order_id is not null,'required',coalesce(b.required,false),'items',coalesce(b.items,'[]'::jsonb),'policy_request',b.policy_request,'can_submit',coalesce(b.required,false) and o.status='quality_check','checks',checks);end$$;
notify pgrst,'reload schema';
commit;
