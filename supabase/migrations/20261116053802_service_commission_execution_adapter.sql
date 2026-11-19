begin;
alter table private.cashier_service_commissions add column service_policy_snapshot jsonb;
alter table private.cashier_service_commissions drop constraint cashier_service_commissions_check;
alter table private.cashier_service_commissions add constraint cashier_service_commissions_check check(
 (service_policy_snapshot is null and amount=round(base_before_discount_exact*rate_percent/100/assigned_count,2))or
 (service_policy_snapshot is not null and jsonb_typeof(service_policy_snapshot)='object'and service_policy_snapshot->>'configured'='true'));
CREATE OR REPLACE FUNCTION private.calculate_service_commission(p_branch uuid, p_item uuid, p_base numeric, p_staff uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare policy private.owner_service_commission_policies;total numeric;remaining numeric;amount numeric;worker uuid;weight numeric;allocations jsonb:='[]';n integer;idx integer:=0;begin

 if p_base is null or p_base<0 or p_base::text in('NaN','Infinity','-Infinity')or cardinality(p_staff)is null or cardinality(p_staff)=0 or array_position(p_staff,null)is not null or(select count(distinct x)from unnest(p_staff)x)<>cardinality(p_staff)then raise exception 'Valid pretax base and unique crew required'using errcode='22023';end if;
 select *into policy from private.owner_service_commission_policies where branch_id=p_branch and item_id=p_item order by version desc limit 1;
 if not found then return jsonb_build_object('configured',false,'work_adapter_enabled',true);end if;
 if policy.split_mode='configured'and(select array_agg((x->>'staff_id')::uuid order by(x->>'staff_id')::uuid)from jsonb_array_elements(policy.shares)x)is distinct from(select array_agg(x order by x)from unnest(p_staff)x)then raise exception 'Crew must match the owner configured shares'using errcode='22023';end if;
 total:=case when not policy.enabled then 0 when policy.mode='percentage'then round(p_base*policy.value/100,2)else round(policy.value,2)end;
 if total>p_base then raise exception 'Commission exceeds service pretax base'using errcode='22023';end if;
 remaining:=total;n:=cardinality(p_staff);
 for worker in select x from unnest(p_staff)x order by x loop
 idx:=idx+1;weight:=case when policy.split_mode='equal'then 100::numeric/n else(select(x->>'percent')::numeric from jsonb_array_elements(policy.shares)x where(x->>'staff_id')::uuid=worker)end;
 amount:=case when idx=n then remaining else trunc(total*weight/100,2)end;remaining:=remaining-amount;
 allocations:=allocations||jsonb_build_array(jsonb_build_object('staff_id',worker,'share_percent',weight,'amount',amount));end loop;
 return jsonb_build_object('configured',true,'policy_id',policy.policy_id,'version',policy.version,'base_before_discount_ex_tax',p_base,'total_commission',total,'allocations',allocations,'work_adapter_enabled',true);end$function$;
revoke all on function private.calculate_service_commission(uuid,uuid,numeric,uuid[])from public,anon,authenticated,service_role;
create function private.validate_service_policy_commission()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare w private.cashier_service_worklines;crew uuid[];expected jsonb;begin
 select *into strict w from private.cashier_service_worklines where order_id=new.order_id;
 select assigned_staff_ids into crew from public.business_orders where order_id=new.order_id;
 perform pg_advisory_xact_lock(hashtextextended('owner-service-commission:'||w.branch_id||':'||w.item_id,0));
 expected:=private.calculate_service_commission(w.branch_id,w.item_id,w.base_before_discount_exact,crew);
 if expected->>'configured'='true'then
 if new.service_policy_snapshot is distinct from expected or new.base_before_discount_exact<>w.base_before_discount_exact or new.assigned_count<>cardinality(crew)or not(new.staff_id=any(crew))or new.amount is distinct from(select(x->>'amount')::numeric from jsonb_array_elements(expected->'allocations')x where(x->>'staff_id')::uuid=new.staff_id)or not exists(select 1 from private.service_work_ledger e where e.order_id=new.order_id and e.actor_id=auth.uid()and e.command_id is not null and e.creator_xid=txid_current()and e.next_status='in_progress')then raise exception 'Canonical future service policy allocation and actual start required'using errcode='55000';end if;
 elsif new.service_policy_snapshot is not null then raise exception 'Unconfigured service cannot forge commission policy'using errcode='55000';end if;
 return new;end$$;
revoke all on function private.validate_service_policy_commission()from public,anon,authenticated,service_role;
create trigger validate_service_policy_commission before insert on private.cashier_service_commissions for each row execute function private.validate_service_policy_commission();
CREATE OR REPLACE FUNCTION private.cashier_service_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare w private.cashier_service_worklines;p private.cashier_invoice_postings;worker uuid;e private.hr_employment;name text;event uuid;staff_count integer;parent_status text;next_parent text;all_quality boolean;all_completed boolean;commission_policy jsonb;all_delivered boolean;begin
 if old.status is not distinct from new.status then return new;end if;
 select *into w from private.cashier_service_worklines where order_id=new.order_id;if not found then return new;end if;
 select *into p from private.cashier_invoice_postings where invoice_id=w.invoice_id;
 select event_id into event from private.service_work_ledger where order_id=new.order_id and actor_id=auth.uid()and command_id is not null and creator_xid=txid_current()and next_status=new.status order by created_at desc limit 1;
 if event is null then raise exception 'Durable actual work event required'using errcode='55000';end if;
 if new.status='in_progress'then
 if cardinality(new.assigned_staff_ids)=0 or new.assigned_staff_ids is distinct from(select assigned_staff_ids from public.bookings where id=w.booking_id)then raise exception 'Confirm matching actual booking and work crew before starting'using errcode='55000';end if;
 staff_count:=cardinality(new.assigned_staff_ids);perform pg_advisory_xact_lock(hashtextextended('owner-service-commission:'||w.branch_id||':'||w.item_id,0));commission_policy:=private.calculate_service_commission(w.branch_id,w.item_id,w.base_before_discount_exact,new.assigned_staff_ids);
 for worker in select unnest(new.assigned_staff_ids)order by 1 loop
 perform pg_advisory_xact_lock(hashtextextended('hr:'||worker,0));
 select *into e from private.hr_employment where staff_id=worker and currency='EGP'and starts_on<=current_date and(ends_on is null or ends_on>=current_date)for share;
 if not found or not exists(select 1 from public.staff_profiles x where x.user_id=worker and x.is_active and(x.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=worker and a.branch_id=w.branch_id)))then raise exception 'Actual eligible crew and EGP employment required'using errcode='55000';end if;
 select full_name into name from public.staff_profiles where user_id=worker;
 if commission_policy->>'configured'='true'then
 insert into private.cashier_service_commissions(order_id,staff_id,staff_name,base_before_discount_exact,rate_percent,assigned_count,amount,employment_snapshot,service_policy_snapshot)values(new.order_id,worker,name,w.base_before_discount_exact,0,staff_count,(select(x->>'amount')::numeric from jsonb_array_elements(commission_policy->'allocations')x where(x->>'staff_id')::uuid=worker),to_jsonb(e),commission_policy);
 else insert into private.cashier_service_commissions(order_id,staff_id,staff_name,base_before_discount_exact,rate_percent,assigned_count,amount,employment_snapshot)values(new.order_id,worker,name,w.base_before_discount_exact,e.commission_percent,staff_count,round(w.base_before_discount_exact*e.commission_percent/100/staff_count,2),to_jsonb(e));end if;
 end loop;
 elsif new.status='completed'then
 if(select count(*)from private.cashier_service_commissions where order_id=new.order_id)<>cardinality(new.assigned_staff_ids)or exists(select 1 from private.cashier_service_commissions where order_id=new.order_id and not(staff_id=any(new.assigned_staff_ids)))then raise exception 'Exact performed frozen crew required'using errcode='55000';end if;
 for worker in select staff_id from private.cashier_service_commissions where order_id=new.order_id order by staff_id loop
 perform pg_advisory_xact_lock(hashtextextended('hr:'||worker,0));
 insert into private.cashier_service_earnings(order_id,staff_id,work_event)values(new.order_id,worker,event);
 end loop;
 end if;
 select status into parent_status from public.business_orders where order_id=p.order_id for update;
 select bool_and(o.status in('quality_check','completed','delivered','cancelled')),bool_and(o.status in('completed','delivered','cancelled')),bool_and(o.status in('delivered','cancelled'))into all_quality,all_completed,all_delivered from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id;
 loop
 next_parent:=case when parent_status<>'cancelled'and not exists(select 1 from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id and o.status<>'cancelled')then'cancelled'when parent_status='received'and exists(select 1 from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id and o.status not in('received','cancelled'))then'in_progress'when parent_status='in_progress'and all_quality then'quality_check'when parent_status='quality_check'and all_completed then'completed'when parent_status='completed'and all_delivered then'delivered'else null end;
 exit when next_parent is null;
 insert into private.cashier_bundle_events(order_id,next_status,source_event,actor_id,creator_xid)values(p.order_id,next_parent,event,auth.uid(),txid_current());
 update public.business_orders set status=next_parent,updated_at=clock_timestamp()where order_id=p.order_id;parent_status:=next_parent;
 end loop;
 return new;end$function$;
-- Owner preview retains its authorization; the execution calculator is internal.
create or replace function private.preview_owner_service_commission(p_branch uuid,p_item uuid,p_base numeric,p_staff uuid[])returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin perform private.require_owner_tax_branch(p_branch);return private.calculate_service_commission(p_branch,p_item,p_base,p_staff);end$$;
notify pgrst,'reload schema';
commit;
