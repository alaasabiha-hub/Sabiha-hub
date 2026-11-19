-- Local accounting ledger only; no payment gateway or real financial transaction is invoked.
create table public.business_cashier_shifts (
 shift_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),cashier_id uuid not null references public.staff_profiles(user_id),
 opening_cash numeric(12,2) not null check(opening_cash>=0),status text not null default 'open' check(status in ('open','awaiting_approval','closed')),
 opened_at timestamptz not null default now(),closed_at timestamptz,expected_cash numeric(12,2),actual_cash numeric(12,2),difference numeric(12,2),difference_reason text,
 approved_by uuid,approved_at timestamptz
);
create unique index one_open_cashier_branch_shift on public.business_cashier_shifts(branch_id,cashier_id) where status<>'closed';
create index shifts_branch_date_idx on public.business_cashier_shifts(branch_id,opened_at desc);
create table public.business_payment_events (
 payment_id uuid primary key,shift_id uuid not null references public.business_cashier_shifts(shift_id),invoice_id text not null references public.business_invoices(invoice_id),
 event_type text not null check(event_type in ('sale','refund')),method text not null check(method in ('cash','electronic')),amount numeric(12,2) not null check(amount>0),
 actor_id uuid not null,created_at timestamptz not null default now(),unique(invoice_id,event_type)
);
create index payments_shift_idx on public.business_payment_events(shift_id);
create table public.business_shift_cash_movements (
 movement_id uuid primary key,shift_id uuid not null references public.business_cashier_shifts(shift_id),movement_type text not null check(movement_type in ('expense','withdrawal','deposit')),
 amount numeric(12,2) not null check(amount>0),reason text not null check(length(trim(reason)) between 5 and 500),actor_id uuid not null,created_at timestamptz not null default now()
);
create index cash_movements_shift_idx on public.business_shift_cash_movements(shift_id);
create function private.can_cashier_branch(p_branch uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select private.active_staff_role()='owner' or (private.can_access_branch(p_branch) and (private.active_staff_role()='manager' or private.active_staff_role()='employee' and exists(select 1 from public.staff_profiles where user_id=auth.uid() and is_active and permissions->>'cashier'='true')));
$$;
revoke all on function private.can_cashier_branch(uuid) from public,anon;
grant execute on function private.can_cashier_branch(uuid) to authenticated;
alter table public.business_cashier_shifts enable row level security;
alter table public.business_payment_events enable row level security;
alter table public.business_shift_cash_movements enable row level security;
revoke all on public.business_cashier_shifts,public.business_payment_events,public.business_shift_cash_movements from anon,authenticated;
grant select on public.business_cashier_shifts,public.business_payment_events,public.business_shift_cash_movements to authenticated;
grant all on public.business_cashier_shifts,public.business_payment_events,public.business_shift_cash_movements to service_role;
create policy "Authorized cashier shifts read" on public.business_cashier_shifts for select to authenticated using((select private.can_cashier_branch(branch_id)) and (cashier_id=(select auth.uid()) or (select private.active_staff_role()) in ('owner','manager')));
create policy "Authorized shift payment reads" on public.business_payment_events for select to authenticated using(exists(select 1 from public.business_cashier_shifts s where s.shift_id=business_payment_events.shift_id));
create policy "Authorized shift movement reads" on public.business_shift_cash_movements for select to authenticated using(exists(select 1 from public.business_cashier_shifts s where s.shift_id=business_shift_cash_movements.shift_id));
create function private.open_cashier_shift(p_request uuid,p_branch uuid,p_opening numeric) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;begin
 if auth.uid() is null or not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Cashier branch permission required';end if;
 if p_request is null or p_opening is null or p_opening<0 then raise exception 'Valid opening amount required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));select * into s from public.business_cashier_shifts where shift_id=p_request;
 if found then if s.cashier_id<>auth.uid() or s.branch_id<>p_branch or s.opening_cash<>p_opening then raise exception 'Request already used';end if;return p_request;end if;
 insert into public.business_cashier_shifts(shift_id,branch_id,cashier_id,opening_cash) values(p_request,p_branch,auth.uid(),p_opening);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'open_shift','business_cashier_shifts',p_request::text,p_branch,jsonb_build_object('opening_cash',p_opening));return p_request;
end; $$;
create function private.record_shift_payment(p_request uuid,p_shift uuid,p_invoice text,p_event text,p_method text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;i public.business_invoices%rowtype;e public.business_payment_events%rowtype;sale public.business_payment_events%rowtype;
begin
 if p_request is null or p_event not in ('sale','refund') or p_method not in ('cash','electronic') then raise exception 'Invalid payment request';end if;
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(s.branch_id),false) or (s.cashier_id<>auth.uid() and private.active_staff_role() not in ('owner','manager')) then raise exception 'Shift access denied';end if;
 select * into e from public.business_payment_events where payment_id=p_request or(invoice_id=p_invoice and event_type=p_event);
 if found then if e.shift_id<>p_shift or e.invoice_id<>p_invoice or e.event_type<>p_event or e.method<>p_method then raise exception 'Payment already recorded in another request or shift';end if;return e.payment_id;end if;
 if s.status<>'open' then raise exception 'Shift is sealed';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if i.branch_id<>s.branch_id or i.total<=0 or i.status='void' then raise exception 'Invoice is not payable in this branch';end if;
 if p_event='sale' and i.status<>'active' then raise exception 'Invoice is not active';end if;
 if p_event='refund' then
  select * into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
  if not found or sale.method<>p_method then raise exception 'A matching recorded payment is required for refund';end if;
 end if;
 insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id) values(p_request,p_shift,p_invoice,p_event,p_method,case when p_event='refund' then sale.amount else i.total end,auth.uid());
 if p_event='refund' then update public.business_invoices set status='refunded' where invoice_id=p_invoice;else update public.business_invoices set payment_method=p_method where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'record_'||p_event,'business_payment_events',p_request::text,s.branch_id,jsonb_build_object('invoice_id',p_invoice,'method',p_method,'amount',case when p_event='refund' then sale.amount else i.total end));return p_request;
end; $$;
create function private.record_shift_movement(p_request uuid,p_shift uuid,p_type text,p_amount numeric,p_reason text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;m public.business_shift_cash_movements%rowtype;begin
 if p_request is null or p_type not in ('expense','withdrawal','deposit') or p_amount is null or p_amount<=0 or length(trim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Invalid cash movement';end if;
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(s.branch_id),false) or (s.cashier_id<>auth.uid() and private.active_staff_role() not in ('owner','manager')) then raise exception 'Shift access denied';end if;
 select * into m from public.business_shift_cash_movements where movement_id=p_request;
 if found then if m.shift_id<>p_shift or m.movement_type<>p_type or m.amount<>p_amount or m.reason<>trim(p_reason) then raise exception 'Movement request already used';end if;return p_request;end if;
 if s.status<>'open' then raise exception 'Shift is sealed';end if;
 insert into public.business_shift_cash_movements(movement_id,shift_id,movement_type,amount,reason,actor_id) values(p_request,p_shift,p_type,p_amount,trim(p_reason),auth.uid());
 -- Expenses are recorded once in the shared financial ledger too. Withdrawals are not operating expenses.
 if p_type='expense' then insert into public.business_expenses(branch_id,expense_date,category,amount,note,created_by) values(s.branch_id,(now() at time zone 'Africa/Cairo')::date,'SHIFT-'||p_request::text,p_amount,trim(p_reason),auth.uid()::text);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data) values(auth.uid()::text,auth.uid(),'cash_'||p_type,'business_shift_cash_movements',p_request::text,s.branch_id,trim(p_reason),jsonb_build_object('amount',p_amount));return p_request;
end; $$;
create function private.cashier_shift_totals(p_shift uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;v_cash numeric;v_electronic numeric;v_movements numeric;begin
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(s.branch_id),false) or (s.cashier_id<>auth.uid() and private.active_staff_role() not in ('owner','manager')) then raise exception 'Shift access denied';end if;
 select coalesce(sum(case when event_type='sale' then amount else -amount end) filter(where method='cash'),0),coalesce(sum(case when event_type='sale' then amount else -amount end) filter(where method='electronic'),0) into v_cash,v_electronic from public.business_payment_events where shift_id=p_shift;
 select coalesce(sum(case when movement_type='deposit' then amount else -amount end),0) into v_movements from public.business_shift_cash_movements where shift_id=p_shift;
 return jsonb_build_object('shift_id',p_shift,'branch_id',s.branch_id,'status',s.status,'opening_cash',s.opening_cash,'cash_payments_net',v_cash,'electronic_payments_net',v_electronic,'cash_movements_net',v_movements,'expected_cash',s.opening_cash+v_cash+v_movements,'actual_cash',s.actual_cash,'difference',s.difference,'difference_reason',s.difference_reason);
end; $$;
create function private.close_cashier_shift(p_shift uuid,p_actual numeric,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;t jsonb;v_expected numeric;begin
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift for update;
 t:=private.cashier_shift_totals(p_shift);v_expected:=(t->>'expected_cash')::numeric;
 if p_actual is null or p_actual<0 or length(coalesce(p_reason,''))>1000 or (p_actual<>v_expected and length(trim(coalesce(p_reason,'')))<5) then raise exception 'Actual cash and explanation of differences required';end if;
 if s.status<>'open' then if s.actual_cash=p_actual and coalesce(s.difference_reason,'')=coalesce(trim(p_reason),'') then return t;end if;raise exception 'Shift is already sealed';end if;
 update public.business_cashier_shifts set status='awaiting_approval',closed_at=now(),expected_cash=v_expected,actual_cash=p_actual,difference=p_actual-v_expected,difference_reason=nullif(trim(p_reason),'') where shift_id=p_shift;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data) values(auth.uid()::text,auth.uid(),'close_shift','business_cashier_shifts',p_shift::text,s.branch_id,p_reason,jsonb_build_object('expected',v_expected,'actual',p_actual,'difference',p_actual-v_expected));return private.cashier_shift_totals(p_shift);
end; $$;
create function private.approve_cashier_shift(p_shift uuid) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare s public.business_cashier_shifts%rowtype;begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Owner approval required';end if;
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift for update;
 if s.status='closed' then return;end if;if s.status<>'awaiting_approval' then raise exception 'Close shift first';end if;
 update public.business_cashier_shifts set status='closed',approved_by=auth.uid(),approved_at=now() where shift_id=p_shift;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id) values(auth.uid()::text,auth.uid(),'approve_shift','business_cashier_shifts',p_shift::text,s.branch_id);
end; $$;

revoke all on function private.open_cashier_shift(uuid,uuid,numeric) from public,anon;
grant execute on function private.open_cashier_shift(uuid,uuid,numeric) to authenticated;
create function public.open_cashier_shift(p_request uuid,p_branch uuid,p_opening numeric) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.open_cashier_shift(p_request,p_branch,p_opening); $$;
revoke all on function public.open_cashier_shift(uuid,uuid,numeric) from public,anon;
grant execute on function public.open_cashier_shift(uuid,uuid,numeric) to authenticated;

revoke all on function private.record_shift_payment(uuid,uuid,text,text,text) from public,anon;
grant execute on function private.record_shift_payment(uuid,uuid,text,text,text) to authenticated;
create function public.record_shift_payment(p_request uuid,p_shift uuid,p_invoice text,p_event text,p_method text) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.record_shift_payment(p_request,p_shift,p_invoice,p_event,p_method); $$;
revoke all on function public.record_shift_payment(uuid,uuid,text,text,text) from public,anon;
grant execute on function public.record_shift_payment(uuid,uuid,text,text,text) to authenticated;

revoke all on function private.record_shift_movement(uuid,uuid,text,numeric,text) from public,anon;
grant execute on function private.record_shift_movement(uuid,uuid,text,numeric,text) to authenticated;
create function public.record_shift_movement(p_request uuid,p_shift uuid,p_type text,p_amount numeric,p_reason text) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.record_shift_movement(p_request,p_shift,p_type,p_amount,p_reason); $$;
revoke all on function public.record_shift_movement(uuid,uuid,text,numeric,text) from public,anon;
grant execute on function public.record_shift_movement(uuid,uuid,text,numeric,text) to authenticated;

revoke all on function private.cashier_shift_totals(uuid) from public,anon;
grant execute on function private.cashier_shift_totals(uuid) to authenticated;
create function public.cashier_shift_totals(p_shift uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.cashier_shift_totals(p_shift); $$;
revoke all on function public.cashier_shift_totals(uuid) from public,anon;
grant execute on function public.cashier_shift_totals(uuid) to authenticated;

revoke all on function private.close_cashier_shift(uuid,numeric,text) from public,anon;
grant execute on function private.close_cashier_shift(uuid,numeric,text) to authenticated;
create function public.close_cashier_shift(p_shift uuid,p_actual numeric,p_reason text) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.close_cashier_shift(p_shift,p_actual,p_reason); $$;
revoke all on function public.close_cashier_shift(uuid,numeric,text) from public,anon;
grant execute on function public.close_cashier_shift(uuid,numeric,text) to authenticated;

revoke all on function private.approve_cashier_shift(uuid) from public,anon;
grant execute on function private.approve_cashier_shift(uuid) to authenticated;
create function public.approve_cashier_shift(p_shift uuid) returns void language sql security invoker set search_path=pg_catalog as $$ select private.approve_cashier_shift(p_shift); $$;
revoke all on function public.approve_cashier_shift(uuid) from public,anon;
grant execute on function public.approve_cashier_shift(uuid) to authenticated;
notify pgrst,'reload schema';
create function private.shift_invoice_options(p_branch uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare result jsonb;begin
 if not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Cashier branch permission required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'total',i.total,'status',i.status,'paid',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale'),'refunded',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='refund'))),'[]') into result from (select * from public.business_invoices where branch_id=p_branch and status<>'void' order by issued_at desc limit 200) i;return result;
end; $$;
revoke all on function private.shift_invoice_options(uuid) from public,anon;
grant execute on function private.shift_invoice_options(uuid) to authenticated;
create function public.shift_invoice_options(p_branch uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.shift_invoice_options(p_branch); $$;
revoke all on function public.shift_invoice_options(uuid) from public,anon;
grant execute on function public.shift_invoice_options(uuid) to authenticated;
create function private.set_cashier_permission(p_user uuid,p_enabled boolean) returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is distinct from 'owner' or p_enabled is null then raise exception 'Owner required';end if;
 update public.staff_profiles set permissions=case when jsonb_typeof(permissions)='object' then jsonb_set(permissions,'{cashier}',to_jsonb(p_enabled),true) else jsonb_build_object('legacy',permissions,'cashier',p_enabled) end where user_id=p_user;
 if not found then raise exception 'Staff not found';end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,after_data) values(auth.uid()::text,auth.uid(),'cashier_permission','staff_profiles',p_user::text,jsonb_build_object('cashier',p_enabled));
end; $$;
revoke all on function private.set_cashier_permission(uuid,boolean) from public,anon;
grant execute on function private.set_cashier_permission(uuid,boolean) to authenticated;
create function public.set_cashier_permission(p_user uuid,p_enabled boolean) returns void language sql security invoker set search_path=pg_catalog as $$ select private.set_cashier_permission(p_user,p_enabled); $$;
revoke all on function public.set_cashier_permission(uuid,boolean) from public,anon;
grant execute on function public.set_cashier_permission(uuid,boolean) to authenticated;
notify pgrst,'reload schema';
create function private.freeze_paid_invoice() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 if exists(select 1 from public.business_payment_events p where p.invoice_id=old.invoice_id) and (new.total is distinct from old.total or new.discount is distinct from old.discount or new.order_id is distinct from old.order_id or new.branch_id is distinct from old.branch_id or new.commission_total is distinct from old.commission_total) then raise exception 'Paid invoice financial snapshot is immutable';end if;return new;end; $$;
revoke all on function private.freeze_paid_invoice() from public;
create trigger freeze_paid_invoice before update on public.business_invoices for each row execute function private.freeze_paid_invoice();
notify pgrst,'reload schema';
