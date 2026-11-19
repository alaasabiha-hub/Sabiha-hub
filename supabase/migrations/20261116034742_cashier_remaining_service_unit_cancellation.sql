begin;
-- Keep the refund frontier at original unit granularity: an earlier refunded
-- unit does not block a different, still-unperformed sibling on the same line.
CREATE OR REPLACE FUNCTION private.cancel_cashier_service(p_request uuid, p_order uuid, p_expected_status text, p_reason text, p_physical_clearance boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare w private.cashier_service_worklines;o public.business_orders;b public.bookings;posted private.cashier_invoice_postings;
 actor uuid;prior private.cashier_service_cancellations;payload jsonb;v_result jsonb;event uuid;booking_event uuid;span private.service_resource_spans;release uuid;now_at timestamptz;dummy jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Service cancellation requires READ COMMITTED'using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 select *into w from private.cashier_service_worklines where order_id=p_order;
 if not found then raise exception 'Billed service unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(w.branch_id);
 if private.active_staff_role()not in('owner','manager')then raise exception 'Scoped management approval required'using errcode='42501';end if;
 if p_request is null or p_physical_clearance is null or p_expected_status is null or p_expected_status not in('received','in_progress','quality_check')or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Expected unfinished status, reason and physical clearance decision required'using errcode='22023';end if;
 payload:=jsonb_build_object('order_id',p_order,'expected_status',p_expected_status,'reason',trim(p_reason),'physical_clearance',p_physical_clearance);
 perform pg_advisory_xact_lock(hashtextextended('cashier-service-stop:'||p_request,0));
 perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));
 select *into prior from private.cashier_service_cancellations where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable cancellation request'using errcode='22023';end if;return prior.result;end if;
 -- Match the work kernel lock order: command actor, own order, own booking,
 -- invoice parent, then vehicle/resource days. No shifts or HR rows are rewritten.
 perform pg_advisory_xact_lock(hashtextextended('service-work-actor:'||actor,0));
 perform pg_advisory_xact_lock(hashtextextended('service-work-pair:'||w.booking_id::text,0));
 select *into strict o from public.business_orders where order_id=p_order for update;
 select *into strict b from public.bookings where id=w.booking_id for update;
 select *into strict posted from private.cashier_invoice_postings where invoice_id=w.invoice_id;

 if o.status<>p_expected_status or b.status not in('pending','confirmed','in_progress')or exists(select 1 from private.cashier_service_cancellations where order_id=p_order)then raise exception 'Service changed; refresh before cancellation'using errcode='40001';end if;
 if exists(select 1 from private.cashier_service_earnings where order_id=p_order)then raise exception 'Earned completed service cannot be cancelled'using errcode='55000';end if;
 -- Initial safe scope is confirmed onsite cash only. Unpaid credits and
 -- gateway cancellation/refund adapters require their own accepted workflows.
 if not exists(select 1 from public.business_invoices i join public.business_payment_events pay using(invoice_id)where i.invoice_id=w.invoice_id and i.status='active'and pay.event_type='sale'and pay.method='cash'and pay.amount=i.total)then raise exception 'Confirmed cash invoice required; unpaid or gateway cancellation adapter unavailable'using errcode='55000';end if;
 if (select coalesce(sum(quantity),0)from private.cashier_partial_refund_lines where invoice_id=w.invoice_id and line_id=w.line_id)>=w.unit_number then raise exception 'This exact service unit is already refunded; review its retained history'using errcode='55000';end if;
 dummy:=private.lock_service_source_resource(w.booking_id,null);
 perform 1 from public.business_orders where order_id=posted.order_id for update;
 select *into span from private.service_resource_spans where booking_id=w.booking_id for update;
 if(o.status in('in_progress','quality_check')or span.span_id is not null)and not p_physical_clearance then raise exception 'Management must confirm vehicle and equipment physically clear before releasing capacity'using errcode='55000';end if;
 if span.span_id is not null and span.ended_at is not null then raise exception 'Physical service already ended; review rather than cancel'using errcode='55000';end if;
 event:=gen_random_uuid();booking_event:=gen_random_uuid();now_at:=clock_timestamp();
 v_result:=jsonb_build_object('kind','cashier_service_cancellation_v1','request_id',p_request,'order_id',p_order,'booking_id',w.booking_id,'invoice_id',w.invoice_id,'status','cancelled','performed_status','cancelled','financial_refund_performed',false,'refund_requires_separate_confirmation',true,'physical_span_released',span.span_id is not null);
 insert into private.service_work_commands(request_id,actor_id,order_id,branch_id,payload,source_snapshot,state)values(p_request,actor,p_order,w.branch_id,jsonb_build_object('next_status','cancelled','reason',trim(p_reason)),private.service_work_source_snapshot(p_order),'prepared');
 insert into private.cashier_service_cancellations values(p_request,actor,p_order,w.booking_id,w.invoice_id,w.branch_id,o.status,trim(p_reason),p_physical_clearance,payload,v_result,txid_current(),now_at);
 insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,order_id,expected_status,next_status,reason,purpose,creator_xid)values(event,p_request,actor,'order',p_order,o.status,'cancelled',trim(p_reason),'cashier_explicit_management_stop',txid_current());
 insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,booking_id,expected_status,next_status,reason,purpose,creator_xid)values(booking_event,p_request,actor,'booking',w.booking_id,b.status,'cancelled',trim(p_reason),'cashier_explicit_management_stop',txid_current());
 if span.span_id is not null then
 release:=gen_random_uuid();insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,action,payload,occurred_at,creator_xid)values(release,event,actor,'booking',w.booking_id,'release',jsonb_build_object('cancellation_request',p_request,'work_event_id',event,'reason',trim(p_reason),'physical_clearance_confirmed',true),now_at,txid_current());
 update private.service_resource_spans set ended_at=now_at,end_event_id=release where span_id=span.span_id;
 end if;
 update public.bookings set status='cancelled'where id=w.booking_id;
 update public.business_orders set status='cancelled',updated_at=now_at where order_id=p_order;
 update private.service_work_commands set state='succeeded',result=v_result,resolved_at=now_at where request_id=p_request;
 update private.service_work_commands set acknowledged_at=now_at where request_id=p_request;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason)values(actor::text,actor,'cashier_service_cancel','business_orders',p_order::text,w.branch_id,trim(p_reason));
 return v_result;
end$function$;
CREATE OR REPLACE FUNCTION private.get_cashier_checkout_state(p_branch uuid, p_draft uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids),'can_cancel',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.method='cash'and sale.amount=i.total and (select coalesce(sum(r.quantity),0)from private.cashier_partial_refund_lines r where r.invoice_id=w.invoice_id and r.line_id=w.line_id)<w.unit_number,'physical_clearance_required',o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans sp where sp.booking_id=w.booking_id and sp.ended_at is null))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and sale.method='cash'and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
 for line in select value from jsonb_array_elements(p.quote->'lines')loop
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p.invoice_id and x.line_id=line->>'line_id';
 remaining:=(line->>'quantity')::integer-previous_quantity;ready:=remaining;
 if line->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then ready:=0;
 else select coalesce(min(w.unit_number)-previous_quantity-1,remaining)into ready from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p.invoice_id and w.line_id=line->>'line_id'and w.unit_number>previous_quantity and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id)));end if;
 end if;
 if remaining>0 then refundable:=refundable||jsonb_build_array(jsonb_build_object('line_id',line->'line_id','name',line->'name','name_en',line->'name_en','item_type',line->'item_type','remaining_quantity',remaining,'refundable_quantity',greatest(ready,0)));end if;
 end loop;end if;
 end if;
 return jsonb_build_object('kind','cashier_checkout_state_v1','draft_id',p_draft,'draft_version',d.version,'branch_id',p_branch,'role',private.active_staff_role(),'time_zone',b.time_zone,'local_today',(clock_timestamp()at time zone b.time_zone)::date,'local_now',clock_timestamp()at time zone b.time_zone,'binding',private.get_cashier_draft_subject(p_branch,p_draft),'state',case when p.invoice_id is null then'draft'else'issued'end,'invoice',invoice,'open_shifts',shifts,'work',coalesce(work,'[]'),'refunds',coalesce(history,'[]'),'refundable_lines',refundable,'can_refund',can_refund,'live_electronic_enabled',false,'offline_profile_issue_supported',false,'bundle_loyalty_accrual_supported',false);
end$function$;
commit;
