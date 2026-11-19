begin;
-- Capability metadata and frozen bilingual work names only; no financial writes.
create or replace function private.get_owner_tax_invoice_settings(p_branch uuid,p_search text,p_after uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare items jsonb;defaults jsonb;begin
 perform private.require_owner_tax_branch(p_branch);
 if p_search is null or length(p_search)>120 then raise exception 'Valid search required'using errcode='22023';end if;
 select to_jsonb(d)-'actor_id'into defaults from private.owner_tax_defaults d where branch_id=p_branch;
 select coalesce(jsonb_agg(to_jsonb(x)order by item_id),'[]')into items from(select c.item_id,c.name,c.name_en,c.price,c.item_type,coalesce(a.version,0)active_version,private.resolve_owner_reviewed_tax(p_branch,c.item_id)active_classification,
 (select coalesce(jsonb_agg(jsonb_build_object('proposal_id',z.proposal_id,'base_version',z.base_version,'spec',z.spec,'created_at',z.created_at)order by z.created_at desc,z.proposal_id),'[]')from(select p.*from private.owner_tax_proposals p where p.branch_id=p_branch and p.item_id=c.item_id and not exists(select 1 from private.owner_tax_reviews r where r.proposal_id=p.proposal_id)order by p.created_at desc,p.proposal_id limit 10)z)pending_proposals
 from public.business_catalog_items c left join private.owner_tax_active a on a.branch_id=c.branch_id and a.item_id=c.item_id where c.branch_id=p_branch and c.is_active and(p_after is null or c.item_id>p_after)and(c.name ilike'%'||p_search||'%'or c.name_en ilike'%'||p_search||'%')order by c.item_id limit 101)x;
 return jsonb_build_object('items',case when jsonb_array_length(items)>100 then items-100 else items end,'has_more',jsonb_array_length(items)>100,'defaults',defaults,'default_rate_assumed',false,'notice_version','tax-review-v1','notice_ar',private.owner_tax_review_notice('ar'),'notice_en',private.owner_tax_review_notice('en'),'owner_only',true,'eta_submission_enabled',false,'invoice_issuance_integrated',to_regprocedure('private.issue_cashier_invoice(uuid,uuid,uuid,integer,integer)')is not null and to_regprocedure('private.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamp with time zone)')is not null,'invoice_issuance_scope','reviewed_cashier_registered_customer_only');
end$$;
create or replace function private.get_cashier_checkout_state(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
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
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
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
notify pgrst,'reload schema';
commit;
