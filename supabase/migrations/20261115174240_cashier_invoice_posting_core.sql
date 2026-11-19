begin;
-- First issuing slice: product-only, app-owned customer/car. Mixed service work is
-- deliberately rejected until its capacity/quality/earned-commission adapter exists.
create table private.cashier_invoice_postings(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb not null,
 draft_id uuid not null unique references private.cashier_reviewed_drafts(draft_id),
 invoice_id text not null unique references public.business_invoices(invoice_id)deferrable initially deferred,
 order_id uuid not null unique references public.business_orders(order_id)deferrable initially deferred,
 branch_id uuid not null references public.business_branches(branch_id),quote jsonb not null,subject jsonb not null,
 creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.cashier_invoice_postings enable row level security;
revoke all on private.cashier_invoice_postings from public,anon,authenticated,service_role;
create trigger immutable_cashier_invoice_posting before update or delete on private.cashier_invoice_postings for each row execute function private.immutable_loyalty_policy();

alter table public.business_inventory_movements add column invoice_id text references public.business_invoices(invoice_id);
alter table public.business_inventory_movements drop constraint business_inventory_movements_event_type_check;
alter table public.business_inventory_movements add constraint business_inventory_movements_event_type_check check(event_type in('count','purchase_receipt','pos_sale','pos_refund'));
create table private.cashier_full_refunds(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,
 invoice_id text not null unique references public.business_invoices(invoice_id),payment_id uuid not null unique references public.business_payment_events(payment_id)deferrable initially deferred,
 restock boolean not null,reason text not null,creator_xid bigint not null);
alter table private.cashier_full_refunds enable row level security;
revoke all on private.cashier_full_refunds from public,anon,authenticated,service_role;
create trigger immutable_cashier_full_refund before update or delete on private.cashier_full_refunds for each row execute function private.immutable_loyalty_policy();

create function private.issue_cashier_invoice(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;prior private.cashier_invoice_postings;
 payload jsonb;current_quote jsonb;subject jsonb;invoice text;work uuid;line jsonb;number text;stock record;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_draft_version is null or p_expected_binding_version is null then raise exception 'Saved draft and subject versions required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'draft',p_draft,'draft_version',p_expected_draft_version,'binding_version',p_expected_binding_version);
 perform pg_advisory_xact_lock(hashtextextended('cashier-issue:'||p_request,0));select *into prior from private.cashier_invoice_postings where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable issuance request'using errcode='22023';end if;
 return jsonb_build_object('invoice_id',prior.invoice_id,'order_id',prior.order_id,'invoice_number',(select display_number from public.business_invoices where invoice_id=prior.invoice_id),'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Draft unavailable'using errcode='42501';end if;
 if d.version<>p_expected_draft_version or exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then raise exception 'Draft changed or already issued'using errcode='40001';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft for update;
 if not found or b.version<>p_expected_binding_version or b.draft_version<>d.version then raise exception 'Current customer/car confirmation required'using errcode='40001';end if;
 if b.subject_kind<>'app_customer' then raise exception 'Offline invoice history adapter is not ready; no invoice issued'using errcode='55000';end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by c.item_id for update;
 perform 1 from private.owner_tax_active t where t.branch_id=p_branch and t.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by t.item_id for share;
 current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->'items',d.payload->>'discount_mode',(d.payload->>'discount_value')::numeric);
 if(current_quote-'as_of')is distinct from(d.quote-'as_of')then raise exception 'Prices, stock or classification changed; save and confirm again'using errcode='40001';end if;
 if exists(select 1 from jsonb_array_elements(current_quote->'lines')where value->>'item_type'<>'product')then raise exception 'Mixed service work adapter is not ready; no invoice issued'using errcode='55000';end if;
 if exists(select 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(current_quote->'lines'))and c.stock_quantity is null)then raise exception 'Tracked product stock required'using errcode='55000';end if;
 if(current_quote->>'total')::numeric<=0 then raise exception 'Positive payable invoice required; use the separately authorized reward route'using errcode='55000';end if;
 perform 1 from public.customers where id=b.subject_id for share;
 perform 1 from public.vehicles where id=b.car_id for share;
 subject:=private.cashier_subject_snapshot(p_branch,b.subject_kind,b.subject_id,b.car_id);
 if subject<>b.subject_snapshot then raise exception 'Customer or car changed; confirm again'using errcode='40001';end if;
 invoice:=gen_random_uuid()::text;work:=gen_random_uuid();
 insert into private.cashier_invoice_postings values(p_request,actor,payload,p_draft,invoice,work,p_branch,current_quote,subject,txid_current(),clock_timestamp());
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,order_type,branch_id,created_by)
 values(work,invoice,b.subject_id,subject->>'name',(select phone from public.customers where id=b.subject_id),subject->'car'->>'plate_number','منتجات / Products','product',p_branch,actor::text);
 for line in select value from jsonb_array_elements(current_quote->'lines')loop
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(work,(line->>'item_id')::uuid,line->>'name',(line->>'quantity')::integer,(line->>'unit_price')::numeric,(line->>'catalog_amount')::numeric);
 end loop;
 insert into public.business_invoices(invoice_id,order_id,plate_number,service_name,total,discount,sale_type,payment_method,commission_total,commission_share,workers,branch_id,created_by)
 values(invoice,work,subject->'car'->>'plate_number','منتجات / Products',(current_quote->>'total')::numeric,(current_quote->>'invoice_discount_exact')::numeric,'product','cash_on_receipt',0,0,'[]',p_branch,actor::text);
 for stock in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(current_quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid group by c.item_id,c.stock_quantity order by c.item_id loop
 if stock.quantity>stock.stock_quantity then raise exception 'Insufficient stock'using errcode='55000';end if;
 update public.business_catalog_items set stock_quantity=stock.stock_quantity-stock.quantity,updated_at=clock_timestamp()where item_id=stock.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(p_request,p_branch,stock.item_id,'pos_sale',stock.stock_quantity,stock.stock_quantity-stock.quantity,'Issued cashier product invoice',actor,invoice);
 end loop;
 select display_number into number from public.business_invoices where invoice_id=invoice;
 update public.business_orders set order_number=number where order_id=work;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'cashier_invoice_issued','business_invoices',invoice,p_branch,jsonb_build_object('draft_id',p_draft,'order_id',work,'total',current_quote->'total','payment_confirmed',false));
 return jsonb_build_object('invoice_id',invoice,'order_id',work,'invoice_number',number,'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);
end$$;
create function public.issue_cashier_invoice(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.issue_cashier_invoice(p_request,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version)$$;
revoke all on function private.issue_cashier_invoice(uuid,uuid,uuid,integer,integer),public.issue_cashier_invoice(uuid,uuid,uuid,integer,integer)from public,anon,authenticated,service_role;
grant execute on function private.issue_cashier_invoice(uuid,uuid,uuid,integer,integer),public.issue_cashier_invoice(uuid,uuid,uuid,integer,integer)to authenticated;
-- The exact five-decimal discount remains in the immutable posting/document.
-- The existing numeric(12,2) invoice.discount is a rounded legacy summary only.
-- Work adapters and partial refunds remain unsupported; full cash refunds are explicit.
CREATE OR REPLACE FUNCTION private.invoice_snapshot(p_invoice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare invoice_row public.business_invoices;snapshot jsonb;coverage jsonb;
begin
 if exists(select 1 from private.cashier_invoice_postings where invoice_id=p_invoice)then
 return(select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',(select jsonb_agg(v||jsonb_build_object('subtotal',v->'base_before_discount_exact','catalog_unit_price',v->'unit_price','unit_price',round((v->>'base_before_discount_exact')::numeric/(v->>'quantity')::numeric,5))order by v->>'line_id')from jsonb_array_elements(p.quote->'lines')v),
 'currency','EGP','discount',p.quote->'invoice_discount_exact','discount_summary_amount',round((p.quote->>'invoice_discount_exact')::numeric,2),'discount_precision',5,'legacy_discount_summary_rounded',true,'total',p.quote->'total','tax_amount',p.quote->'tax_amount_exact','tax_configuration','owner_reviewed_versioned','taxable_amount_exact',p.quote->'taxable_amount_exact','net_amount_exact',p.quote->'net_amount_exact','payable_rounding',p.quote->'payable_rounding','eta_accepted',false,'legally_verified_by_software',false)
 from private.cashier_invoice_postings p join public.business_branches b on b.branch_id=p.branch_id where p.invoice_id=p_invoice);
 end if;
 select * into invoice_row from public.business_invoices where invoice_id=p_invoice;
 if not found then return null;end if;
select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('name',x.item_name,'quantity',x.quantity,'unit_price',x.unit_price,'subtotal',x.subtotal) order by x.created_at,x.order_item_id) from public.business_order_items x where x.order_id=i.order_id),jsonb_build_array(jsonb_build_object('name',i.service_name,'quantity',1,'unit_price',i.total+i.discount,'subtotal',i.total+i.discount))),
 'currency','EGP','discount',i.discount,'total',i.total,'tax_amount',null,'tax_configuration','not_recorded_in_legacy_invoice',
 'delivery_fee',(select delivery_fee from public.business_order_fulfillments f where f.order_id=i.order_id))
 into snapshot
 from public.business_invoices i join public.business_branches b using(branch_id) where i.invoice_id=p_invoice;
 if invoice_row.reward_snapshot is null then return snapshot;end if;
 coverage:=private.reward_invoice_coverage(p_invoice);
 if invoice_row.total<>0 or not coalesce(coverage->>'state' in ('covered_by_reward','cancelled_reward'),false) then
  raise exception 'An issued reward document requires complete canonical coverage at creation' using errcode='42501';
 end if;
 return snapshot||jsonb_build_object('reward',invoice_row.reward_snapshot,'reward_coverage',coverage,
  'payment_status',case when coverage->>'state'='covered_by_reward' and invoice_row.status='active' then 'covered_by_reward' else 'cancelled' end,
  'payment_method','reward_coverage');
end;$function$;

create function private.guard_cashier_posting()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare p private.cashier_invoice_postings;begin
 if tg_table_schema='private'then
 if exists(select 1 from private.cashier_invoice_postings where draft_id=old.draft_id)then raise exception 'Issued draft and customer binding are sealed'using errcode='55000';end if;return new;
 end if;
 select *into p from private.cashier_invoice_postings where invoice_id=case when tg_op='DELETE'then old.invoice_id else new.invoice_id end;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Issued invoice is retained'using errcode='55000';end if;
 if tg_op='INSERT'then
 if p.creator_xid<>txid_current()or new.order_id<>p.order_id or new.branch_id<>p.branch_id or new.total<>(p.quote->>'total')::numeric or new.discount<>round((p.quote->>'invoice_discount_exact')::numeric,2) or new.sale_type<>'product'or new.commission_total<>0 or new.commission_share<>0 or new.workers<>'[]'::jsonb or new.reward_snapshot is not null then raise exception 'Complete original posting proof required'using errcode='55000';end if;
 else
 if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued financial terms are immutable'using errcode='55000';end if;
 if new.status is distinct from old.status and not(new.status='refunded'and exists(select 1 from private.cashier_full_refunds r where r.invoice_id=p.invoice_id and r.creator_xid=txid_current()))then raise exception 'Use canonical refund or cancellation'using errcode='55000';end if;
 end if;return new;end$$;
create trigger guard_cashier_posting before insert or update or delete on public.business_invoices for each row execute function private.guard_cashier_posting();
create trigger seal_issued_cashier_draft before update or delete on private.cashier_reviewed_drafts for each row execute function private.guard_cashier_posting();
create trigger seal_issued_cashier_subject before update or delete on private.cashier_draft_subjects for each row execute function private.guard_cashier_posting();
create function private.cashier_refund_stock()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare p private.cashier_invoice_postings;r private.cashier_full_refunds;s record;begin
 select *into p from private.cashier_invoice_postings where invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.cashier_cart_actor(p.branch_id);
 if new.event_type='sale'then if new.amount<>(p.quote->>'total')::numeric then raise exception 'Original amount required'using errcode='55000';end if;return new;end if;
 select *into r from private.cashier_full_refunds where payment_id=new.payment_id and invoice_id=new.invoice_id and creator_xid=txid_current()and actor_id=auth.uid();
 if not found or new.amount<>(p.quote->>'total')::numeric then raise exception 'Explicit canonical full refund required'using errcode='55000';end if;
 if not r.restock then return new;end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(p.quote->'lines'))order by c.item_id for update;
 for s in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(p.quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=s.stock_quantity+s.quantity,updated_at=clock_timestamp()where item_id=s.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(new.payment_id,p.branch_id,s.item_id,'pos_refund',s.stock_quantity,s.stock_quantity+s.quantity,r.reason,auth.uid(),p.invoice_id);
 end loop;return new;end$$;
create trigger cashier_canonical_refund_stock after insert on public.business_payment_events for each row execute function private.cashier_refund_stock();
create function private.refund_cashier_invoice(p_request uuid,p_shift uuid,p_invoice text,p_restock boolean,p_reason text)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$declare p private.cashier_invoice_postings;prior private.cashier_full_refunds;payload jsonb;actor uuid;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;
 if not found then raise exception 'Cashier-issued invoice required'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Explicit refund permission required'using errcode='42501';end if;
 if p_request is null or p_restock is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit stock-return decision and reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('shift',p_shift,'invoice',p_invoice,'restock',p_restock,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('cashier-full-refund:'||p_request,0));select *into prior from private.cashier_full_refunds where request_id=p_request;
 if found then if prior.actor_id<>actor or prior.payload<>payload then raise exception 'Immutable refund request'using errcode='22023';end if;return prior.payment_id;end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already refunded'using errcode='40001';end if;
 insert into private.cashier_full_refunds values(p_request,actor,payload,p_invoice,p_request,p_restock,trim(p_reason),txid_current());
 return private.record_shift_payment(p_request,p_shift,p_invoice,'refund','cash');
end$$;
create function public.refund_cashier_invoice(p_request uuid,p_shift uuid,p_invoice text,p_restock boolean,p_reason text)returns uuid language sql security invoker set search_path=pg_catalog as $$select private.refund_cashier_invoice(p_request,p_shift,p_invoice,p_restock,p_reason)$$;
revoke all on function private.guard_cashier_posting(),private.cashier_refund_stock(),private.refund_cashier_invoice(uuid,uuid,text,boolean,text),public.refund_cashier_invoice(uuid,uuid,text,boolean,text)from public,anon,authenticated,service_role;
grant execute on function private.refund_cashier_invoice(uuid,uuid,text,boolean,text),public.refund_cashier_invoice(uuid,uuid,text,boolean,text)to authenticated;


create function private.guard_cashier_posted_order()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare p private.cashier_invoice_postings;begin
 select *into p from private.cashier_invoice_postings where order_id=old.order_id;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Issued order retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['status','updated_at','order_number'])is distinct from(to_jsonb(old)-array['status','updated_at','order_number'])then raise exception 'Issued customer, car and order identity immutable'using errcode='55000';end if;
 if new.order_number is distinct from old.order_number and not(p.creator_xid=txid_current()and new.order_number=(select display_number from public.business_invoices where invoice_id=p.invoice_id))then raise exception 'Issued reference immutable'using errcode='55000';end if;
 if new.status is distinct from old.status and exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then raise exception 'Refunded order cannot advance or restore stock again'using errcode='55000';end if;
 if new.status='cancelled'and old.status<>'cancelled'then raise exception 'Use canonical refund; legacy cancellation cannot restore posted stock'using errcode='55000';end if;
 return new;end$$;
revoke all on function private.guard_cashier_posted_order()from public,anon,authenticated,service_role;
create trigger guard_cashier_posted_order before update or delete on public.business_orders for each row execute function private.guard_cashier_posted_order();


create function private.guard_cashier_posted_lines()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare posting private.cashier_invoice_postings;begin
 select *into posting from private.cashier_invoice_postings where order_id=case when tg_op in('DELETE','UPDATE')then old.order_id else new.order_id end;
 if not found and tg_op='UPDATE'then select *into posting from private.cashier_invoice_postings where order_id=new.order_id;end if;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='INSERT'and posting.creator_xid=txid_current()and not exists(select 1 from public.business_invoices where invoice_id=posting.invoice_id)then return new;end if;
 raise exception 'Issued invoice lines are immutable'using errcode='55000';end$$;
revoke all on function private.guard_cashier_posted_lines()from public,anon,authenticated,service_role;
create trigger guard_cashier_posted_lines before insert or update or delete on public.business_order_items for each row execute function private.guard_cashier_posted_lines();

notify pgrst,'reload schema';
commit;
