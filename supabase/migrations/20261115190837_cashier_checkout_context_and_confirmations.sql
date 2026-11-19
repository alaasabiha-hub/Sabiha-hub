begin;
create table private.cashier_refund_approvals(request_id uuid primary key references private.cashier_partial_refunds(request_id)deferrable initially deferred,actor_id uuid not null,payload jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.cashier_refund_approvals enable row level security;
revoke all on private.cashier_refund_approvals from public,anon,authenticated,service_role;
create trigger immutable_cashier_refund_approval before update or delete on private.cashier_refund_approvals for each row execute function private.immutable_loyalty_policy();
create function private.get_cashier_checkout_state(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;p private.cashier_invoice_postings;i public.business_invoices;sale public.business_payment_events;
 b public.business_branches;shifts jsonb;invoice jsonb;work jsonb;refundable jsonb:='[]';history jsonb;line jsonb;previous_quantity integer;remaining integer;ready integer;refunded numeric:=0;can_refund boolean;begin
 actor:=private.cashier_cart_actor(p_branch);select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and branch_id=p_branch and actor_id=actor;
 if not found then raise exception 'Own saved draft required'using errcode='42501';end if;
 select *into b from public.business_branches where branch_id=p_branch;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.shift_id,'cashier_name',s.full_name,'opened_local',x.opened_at at time zone b.time_zone)order by x.opened_at,x.shift_id),'[]')into shifts from public.business_cashier_shifts x join public.staff_profiles s on s.user_id=x.cashier_id where x.branch_id=p_branch and x.status='open'and(x.cashier_id=actor or private.active_staff_role()in('owner','manager'));
 can_refund:=private.active_staff_role()in('owner','manager')or exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true');
 select *into p from private.cashier_invoice_postings where draft_id=p_draft;
 if found then
 select *into strict i from public.business_invoices where invoice_id=p.invoice_id;
 select *into sale from public.business_payment_events where invoice_id=p.invoice_id and event_type='sale';
 select coalesce(sum(amount),0)into refunded from public.business_payment_events where invoice_id=p.invoice_id and event_type='refund';
 invoice:=jsonb_build_object('id',i.invoice_id,'number',i.display_number,'token',i.document_token,'total',i.total,'status',i.status,'refunded_amount',refunded,'net_collected',coalesce(sale.amount,0)-refunded,'payment_status',case when i.status='void'then'cancelled'when i.status='refunded'then'refunded'when sale.payment_id is null then'unpaid'when refunded>0 and refunded<sale.amount then'partially_refunded'when sale.method='cash'then'paid'else'verification_required'end,'cash_confirmed',sale.payment_id is not null and sale.method='cash');
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'number',result->>'refund_number','amount',amount,'payment_event_recorded',amount>0)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=p.invoice_id;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and sale.method='cash'and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
 for line in select value from jsonb_array_elements(p.quote->'lines')loop
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p.invoice_id and x.line_id=line->>'line_id';
 remaining:=(line->>'quantity')::integer-previous_quantity;ready:=remaining;
 if line->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then ready:=0;
 else select coalesce(min(w.unit_number)-previous_quantity-1,remaining)into ready from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p.invoice_id and w.line_id=line->>'line_id'and w.unit_number>previous_quantity and o.status not in('completed','delivered');end if;
 end if;
 if remaining>0 then refundable:=refundable||jsonb_build_array(jsonb_build_object('line_id',line->'line_id','name',line->'name','name_en',line->'name_en','item_type',line->'item_type','remaining_quantity',remaining,'refundable_quantity',greatest(ready,0)));end if;
 end loop;end if;
 end if;
 return jsonb_build_object('kind','cashier_checkout_state_v1','draft_id',p_draft,'draft_version',d.version,'branch_id',p_branch,'role',private.active_staff_role(),'time_zone',b.time_zone,'local_today',(clock_timestamp()at time zone b.time_zone)::date,'local_now',clock_timestamp()at time zone b.time_zone,'binding',private.get_cashier_draft_subject(p_branch,p_draft),'state',case when p.invoice_id is null then'draft'else'issued'end,'invoice',invoice,'open_shifts',shifts,'work',coalesce(work,'[]'),'refunds',coalesce(history,'[]'),'refundable_lines',refundable,'can_refund',can_refund,'live_electronic_enabled',false,'offline_profile_issue_supported',false,'bundle_loyalty_accrual_supported',false);
end$$;
create function private.resolve_cashier_start_time(p_branch uuid,p_day date,p_time time)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare zone text;begin
 perform private.cashier_cart_actor(p_branch);if p_day is null or p_time is null or not isfinite(p_day)then raise exception 'Explicit business date and time required'using errcode='22023';end if;
 select time_zone into zone from public.business_branches where branch_id=p_branch;
 return jsonb_build_object('start_at',(p_day+p_time)at time zone zone,'time_zone',zone,'local_date',p_day,'local_time',p_time);
end$$;
create function private.preview_cashier_refund_lines(p_invoice text,p_lines jsonb)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare p private.cashier_invoice_postings;actor uuid;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]';previous_quantity integer;quantity integer;amount numeric:=0;paid numeric;refunded numeric;version jsonb;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Refund permission required'using errcode='42501';end if;
 if jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'Distinct original lines required'using errcode='22023';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already fully refunded'using errcode='40001';end if;
 select pe.amount into paid from public.business_payment_events pe where pe.invoice_id=p_invoice and pe.event_type='sale'and pe.method='cash';if not found then raise exception 'Confirmed cash payment required'using errcode='55000';end if;
 for entry in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(entry)is distinct from'object'or(select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['line_id','quantity','restock'])or jsonb_typeof(entry->'line_id')is distinct from'string'or jsonb_typeof(entry->'quantity')is distinct from'number'or(entry->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(entry->'restock')is distinct from'boolean'then raise exception 'Line identity, integer quantity and stock-return choice only'using errcode='22023';end if;
 select value into original from jsonb_array_elements(p.quote->'lines')where value->>'line_id'=entry->>'line_id';if original is null then raise exception 'Original line unavailable'using errcode='42501';end if;
 quantity:=(entry->>'quantity')::integer;select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p_invoice and x.line_id=entry->>'line_id';
 slice:=private.cashier_refund_slice_core(p.quote,entry->>'line_id',previous_quantity,quantity);
 if original->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then raise exception 'Service refund requires management'using errcode='42501';end if;
 if(entry->>'restock')::boolean or exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number>previous_quantity and w.unit_number<=previous_quantity+quantity and o.status not in('completed','delivered'))or(select count(*)from private.cashier_service_worklines where invoice_id=p_invoice and line_id=entry->>'line_id'and unit_number>previous_quantity and unit_number<=previous_quantity+quantity)<>quantity then raise exception 'Completed service units required; cancellation is separate'using errcode='55000';end if;
 end if;
 amount:=amount+(slice->>'amount')::numeric;prepared:=prepared||jsonb_build_array(slice||jsonb_build_object('name',original->'name','name_en',original->'name_en','restock',entry->'restock'));
 end loop;
 select coalesce(sum(e.amount),0)into refunded from public.business_payment_events e where e.invoice_id=p_invoice and e.event_type='refund';if amount+refunded>paid then raise exception 'Original collected amount exceeded'using errcode='22023';end if;
 version:=jsonb_build_object('version','cashier-refund-preview-v1','invoice',p_invoice,'requested_lines',p_lines,'calculated_lines',prepared,'amount',amount,'paid',paid,'refunded',refunded);
 return jsonb_build_object('quote_hash',encode(extensions.digest(version::text,'sha256'),'hex'),'amount',amount,'currency','EGP','lines',prepared,'quote_only',true,'financial_event_created',false);
end$$;
create function private.confirm_cashier_refund(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text,p_quote_hash text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare p private.cashier_invoice_postings;actor uuid;payload jsonb;prior private.cashier_refund_approvals;preview jsonb;result jsonb;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Invoice unavailable'using errcode='42501';end if;actor:=private.cashier_cart_actor(p.branch_id);
 if p_request is null or p_quote_hash is null or p_quote_hash!~'^[0-9a-f]{64}$'then raise exception 'Explicit current preview approval required'using errcode='22023';end if;
 payload:=jsonb_build_object('invoice',p_invoice,'shift',p_shift,'lines',p_lines,'reason',trim(p_reason),'quote_hash',p_quote_hash);
 perform pg_advisory_xact_lock(hashtextextended('cashier-partial-refund:'||p_request,0));select *into prior from private.cashier_refund_approvals where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable approved refund'using errcode='22023';end if;return(select r.result from private.cashier_partial_refunds r where r.request_id=p_request);end if;
 if exists(select 1 from private.cashier_partial_refunds where request_id=p_request)then raise exception 'Use the original refund recovery path'using errcode='40001';end if;
 perform 1 from public.business_cashier_shifts where shift_id=p_shift and branch_id=p.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))and status='open'for update;
 if not found then raise exception 'Authorized open shift required'using errcode='42501';end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 preview:=private.preview_cashier_refund_lines(p_invoice,p_lines);
 if preview->>'quote_hash'<>p_quote_hash then raise exception 'Refund preview changed; review again'using errcode='40001';end if;
 insert into private.cashier_refund_approvals(request_id,actor_id,payload)values(p_request,actor,payload);
 result:=private.refund_cashier_invoice_lines(p_request,p_shift,p_invoice,p_lines,p_reason);return result;
end$$;
create function public.get_cashier_checkout_state(p_branch uuid,p_draft uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_checkout_state(p_branch,p_draft)$$;
create function public.resolve_cashier_start_time(p_branch uuid,p_day date,p_time time)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.resolve_cashier_start_time(p_branch,p_day,p_time)$$;
create function public.preview_cashier_refund_lines(p_invoice text,p_lines jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.preview_cashier_refund_lines(p_invoice,p_lines)$$;
create function public.confirm_cashier_refund(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text,p_quote_hash text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_refund(p_request,p_shift,p_invoice,p_lines,p_reason,p_quote_hash)$$;
revoke all on function private.get_cashier_checkout_state(uuid,uuid),public.get_cashier_checkout_state(uuid,uuid),private.resolve_cashier_start_time(uuid,date,time),public.resolve_cashier_start_time(uuid,date,time),private.preview_cashier_refund_lines(text,jsonb),public.preview_cashier_refund_lines(text,jsonb),private.confirm_cashier_refund(uuid,uuid,text,jsonb,text,text),public.confirm_cashier_refund(uuid,uuid,text,jsonb,text,text)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_checkout_state(uuid,uuid),public.get_cashier_checkout_state(uuid,uuid),private.resolve_cashier_start_time(uuid,date,time),public.resolve_cashier_start_time(uuid,date,time),private.preview_cashier_refund_lines(text,jsonb),public.preview_cashier_refund_lines(text,jsonb),private.confirm_cashier_refund(uuid,uuid,text,jsonb,text,text),public.confirm_cashier_refund(uuid,uuid,text,jsonb,text,text)to authenticated;

create function private.confirm_cashier_cash_payment(p_request uuid,p_shift uuid,p_invoice text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare p private.cashier_invoice_postings;actor uuid;prior public.business_payment_events;payment uuid;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);if p_request is null or p_shift is null then raise exception 'Exact cash confirmation request required'using errcode='22023';end if;
 perform 1 from public.business_cashier_shifts where shift_id=p_shift and branch_id=p.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))for update;
 if not found then raise exception 'Authorized shift required'using errcode='42501';end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 select *into prior from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
 if found then
 if prior.payment_id<>p_request then raise exception 'Invoice already collected; refresh before accepting cash'using errcode='40001';end if;
 if prior.shift_id<>p_shift or prior.method<>'cash'then raise exception 'Immutable cash confirmation'using errcode='22023';end if;payment:=prior.payment_id;
 else payment:=private.record_shift_payment(p_request,p_shift,p_invoice,'sale','cash');end if;
 return jsonb_build_object('payment_id',payment,'invoice_id',p_invoice,'sale_recorded',true,'payment_status_requires_refresh',true);
end$$;
create function public.confirm_cashier_cash_payment(p_request uuid,p_shift uuid,p_invoice text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_cash_payment(p_request,p_shift,p_invoice)$$;
revoke all on function private.confirm_cashier_cash_payment(uuid,uuid,text),public.confirm_cashier_cash_payment(uuid,uuid,text)from public,anon,authenticated,service_role;
grant execute on function private.confirm_cashier_cash_payment(uuid,uuid,text),public.confirm_cashier_cash_payment(uuid,uuid,text)to authenticated;

notify pgrst,'reload schema';
commit;
