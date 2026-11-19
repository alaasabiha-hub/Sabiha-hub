begin;
-- Presentation metadata only; never rewrite closed payroll snapshots or earned amounts.
create function private.cashier_payroll_commission_lines(p_staff uuid,p_from timestamptz,p_to timestamptz)returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select coalesce((select jsonb_agg(jsonb_build_object('invoice_id',w.invoice_id,'order_id',c.order_id,'before_discount',c.base_before_discount_exact,'tax_excluded',true,'rate_percent',case when c.service_policy_snapshot is null then c.rate_percent end,'service_policy_version',c.service_policy_snapshot->'version','allocation_share_percent',(select x->'share_percent'from jsonb_array_elements(c.service_policy_snapshot->'allocations')x where(x->>'staff_id')::uuid=c.staff_id),'assigned_count',c.assigned_count,'commission',c.amount,'earned_at',x.earned_at,'model',case when c.service_policy_snapshot is null then'cashier_frozen_lines'else'owner_service_policy'end)order by x.earned_at,c.order_id)from private.cashier_service_earnings x join private.cashier_service_commissions c using(order_id,staff_id)join private.cashier_service_worklines w using(order_id)where c.staff_id=p_staff and x.earned_at>=p_from and x.earned_at<p_to),'[]'::jsonb)$$;
revoke all on function private.cashier_payroll_commission_lines(uuid,timestamptz,timestamptz)from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION private.hr_execute(p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET "TimeZone" TO 'UTC'
AS $function$
declare uid uuid:=auth.uid();r text:=private.active_staff_role();s uuid;rid uuid;v jsonb;a private.hr_attendance;e private.hr_employment;
 f date;t date;mins numeric;sched numeric;base numeric;comm numeric;adjustments numeric;lines jsonb;pid uuid;existing private.hr_payroll;
begin
 if uid is null or r is null then raise exception 'Active staff access required' using errcode='42501';end if;
 s:=coalesce((p_data->>'staff_id')::uuid,uid);
 if r<>'owner' and s<>uid then raise exception 'Own HR records only' using errcode='42501';end if;
 if p_action='read' then
 return jsonb_build_object('staff',case when r='owner' then (select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'full_name',full_name)),'[]') from public.staff_profiles where is_active) else '[]'::jsonb end,
 'employment',(select to_jsonb(x) from private.hr_employment x where staff_id=s),
 'attendance',(select coalesce(jsonb_agg(to_jsonb(x) order by clock_in desc),'[]') from (select * from private.hr_attendance where staff_id=s order by clock_in desc limit 100)x),
 'leave',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_leave x where staff_id=s),
 'adjustments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s),
 'payroll',(select coalesce(jsonb_agg(to_jsonb(x) order by from_date desc),'[]') from private.hr_payroll x where staff_id=s));
 end if;
 rid:=(p_data->>'request_id')::uuid;if rid is null then raise exception 'Request identity required';end if;
 -- Serialize each staff workflow: avoids overlapping periods and duplicate open shifts.
 perform pg_advisory_xact_lock(hashtextextended('hr:'||s::text,0));
 if p_action in ('clock_in','clock_out','leave') and s<>uid then raise exception 'Attendance and leave must be submitted by employee' using errcode='42501';end if;
 if p_action='clock_in' then
 select to_jsonb(x) into v from private.hr_attendance x where request_id=rid and staff_id=s;if v is not null then return v;end if;
 if exists(select 1 from private.hr_leave where staff_id=s and status='approved' and current_date between from_date and to_date) then raise exception 'Approved leave covers today';end if;
 insert into private.hr_attendance(staff_id,request_id) values(s,rid) returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='clock_out' then
 select * into a from private.hr_attendance where staff_id=s and id=(p_data->>'id')::uuid for update;
 if a.id is null then raise exception 'Attendance record not found';end if;
 if a.clock_out is not null then return to_jsonb(a);end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and a.clock_in::date<=to_date and clock_timestamp()::date>=from_date) then raise exception 'Attendance overlaps approved payroll';end if;
 update private.hr_attendance set clock_out=clock_timestamp() where id=a.id returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='leave' then
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;
 if f is null or t is null or f<current_date then raise exception 'Future leave dates required';end if;
 insert into private.hr_leave(staff_id,from_date,to_date,reason,request_id) values(s,f,t,p_data->>'reason',rid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_leave x where request_id=rid and staff_id=s);
 end if;
 if r<>'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if not exists(select 1 from public.staff_profiles where user_id=s and is_active) then raise exception 'Active staff required';end if;
 if p_action='employment' then
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on,ends_on) values(s,(p_data->>'salary')::numeric,(p_data->>'commission_percent')::numeric,upper(p_data->>'currency'),(p_data->>'starts_on')::date,(p_data->>'ends_on')::date)
 on conflict(staff_id) do update set salary=excluded.salary,commission_percent=excluded.commission_percent,currency=excluded.currency,starts_on=excluded.starts_on,ends_on=excluded.ends_on,updated_at=now();
 return (select to_jsonb(x) from private.hr_employment x where staff_id=s);
 elsif p_action='decide_leave' then
 if p_data->>'status' not in ('approved','rejected') then raise exception 'Choose approved or rejected';end if;
 if p_data->>'status'='approved' and exists(select 1 from private.hr_leave target join private.hr_leave other on other.staff_id=target.staff_id and other.id<>target.id and other.status='approved' and other.from_date<=target.to_date and other.to_date>=target.from_date where target.id=(p_data->>'id')::uuid and target.staff_id=s) then raise exception 'Approved leave dates overlap';end if;
 update private.hr_leave set status=p_data->>'status',decided_by=uid where id=(p_data->>'id')::uuid and staff_id=s and status='pending' returning to_jsonb(hr_leave.*) into v;
 if v is null then raise exception 'Pending leave required';end if;return v;
 elsif p_action='adjustment' then
 select * into e from private.hr_employment where staff_id=s;
 if e.staff_id is null then raise exception 'Employment currency must be configured first';end if;
 f:=(p_data->>'on_date')::date;
 if exists(select 1 from private.hr_payroll where staff_id=s and f between from_date and to_date) then raise exception 'Approved payroll period is closed';end if;
 insert into private.hr_adjustment(staff_id,on_date,currency,kind,amount,reason,request_id,created_by) values(s,f,e.currency,p_data->>'kind',(p_data->>'amount')::numeric,p_data->>'reason',rid,uid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_adjustment x where request_id=rid and staff_id=s);
 elsif p_action='approve_payroll' then
 select * into existing from private.hr_payroll where request_id=rid;
 if existing.id is not null then if existing.staff_id<>s then raise exception 'Request belongs to another staff';end if;return to_jsonb(existing);end if;
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;sched:=(p_data->>'scheduled_minutes')::numeric;
 if f is null or t is null or t<f or t>=current_date or t-f>366 or sched is null or sched<=0 or sched::text in ('NaN','Infinity','-Infinity') then raise exception 'Closed dates and explicit scheduled minutes required';end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and from_date<=t and to_date>=f) then raise exception 'Payroll periods cannot overlap';end if;
 select * into e from private.hr_employment where staff_id=s;
 if e.currency is distinct from 'EGP' then raise exception 'Payroll requires EGP compensation; no exchange conversion is configured';end if;
 if e.staff_id is null or e.starts_on>f or coalesce(e.ends_on,t)<t then raise exception 'Employment must cover entire period';end if;
 if exists(select 1 from private.hr_attendance where staff_id=s and clock_in<(t+1)::timestamptz and (clock_out is null or clock_out>f::timestamptz) and (clock_out is null or clock_in<f::timestamptz or clock_out>(t+1)::timestamptz)) then raise exception 'Open or boundary-spanning attendance must be resolved before payroll';end if;
 select coalesce(sum(extract(epoch from(clock_out-clock_in))/60),0) into mins from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz;
 base:=round(e.salary*least(mins/sched,1),2);
 -- Freeze relevant assignments and invoice values while approving the financial snapshot.
 perform 1 from public.business_orders o join public.business_invoices i using(order_id) where s=any(o.assigned_staff_ids) and o.order_type='service' and i.status='active' and i.sale_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz for update of o,i;
 -- One invoice per order only. Duplicate invoice associations are rejected, never multiplied or silently chosen.
 if exists(select 1 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz and (select count(*) from public.business_invoices dup where dup.order_id=i.order_id and dup.status='active')>1) then raise exception 'Duplicate service invoices require reconciliation';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'order_id',i.order_id,'before_discount',i.total+i.discount,'rate_percent',case when i.commission_model='walk_in_frozen_workers'then(select wc.rate_percent from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s)else e.commission_percent end,'assigned_count',(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),'commission',case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end)),'[]'),coalesce(sum(case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end),0) into lines,comm
 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and o.status in ('completed','delivered') and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz;
 -- New work commissions are earned once at actual completion, never from mixed invoice gross.
 lines:=lines||private.cashier_payroll_commission_lines(s,f::timestamptz,(t+1)::timestamptz);
 comm:=comm+coalesce((select sum(c.amount)from private.cashier_service_earnings x join private.cashier_service_commissions c using(order_id,staff_id)where c.staff_id=s and x.earned_at>=f::timestamptz and x.earned_at<(t+1)::timestamptz),0);
 if exists(select 1 from private.hr_adjustment where staff_id=s and on_date between f and t and currency<>e.currency) then raise exception 'Adjustment and payroll currencies must match';end if;
 select coalesce(sum(case when kind='bonus' then amount else -amount end),0) into adjustments from private.hr_adjustment where staff_id=s and on_date between f and t;
 v:=jsonb_build_object('employment',to_jsonb(e),'actual_minutes',mins,'scheduled_minutes',sched,'base_earned',base,'commission',comm,'commission_lines',lines,'adjustments',adjustments,'net',base+comm+adjustments,'currency',e.currency,'attendance_ids',(select coalesce(jsonb_agg(id),'[]') from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz),'adjustment_lines',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s and on_date between f and t),'leave_policy','Leave approval does not create paid time; actual clocked minutes only','payment_status','not_transferred');
 insert into private.hr_payroll(staff_id,from_date,to_date,scheduled_minutes,snapshot,request_id,approved_by) values(s,f,t,sched,v,rid,uid) returning to_jsonb(hr_payroll.*) into v;return v;
 end if;
 raise exception 'Unknown HR action';
end $function$;
commit;
