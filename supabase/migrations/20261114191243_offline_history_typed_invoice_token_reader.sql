begin;
-- Typed token adapter only; runtime remains disabled and generic invoice RLS unchanged.
create or replace function private.offline_history_capabilities(p_available boolean)returns jsonb language sql stable set search_path=pg_catalog as $$select jsonb_build_object(
'linked_visit_history',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'linked_invoice_documents',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'offline_car_reference_read',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'wallet_access',false,'walk_in_loyalty_accrual',false,'guest_redemption',false,'vehicle_management',false,'qr_reader_bridge',p_available and coalesce((select enabled from private.offline_history_runtime where id),false))$$;

create or replace function private.get_my_offline_invoice_document(p_invoice text)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_invoice public.business_invoices;v_subject private.offline_walk_in_subjects;v_order public.business_orders;v_snapshot jsonb;v_lines jsonb;v_payment text;
begin
 v_link:=private.resolve_my_offline_history_link();
 if not coalesce((select enabled from private.offline_history_runtime where id),false)or not exists(select 1 from private.offline_history_scope_consents c where c.link_id=v_link.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_subject from private.offline_walk_in_subjects s where s.invoice_id=p_invoice and s.profile_id=v_link.profile_id;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_invoice from public.business_invoices i where i.invoice_id=v_subject.invoice_id and i.order_id=v_subject.order_id and i.branch_id=v_subject.branch_id and i.commission_model='walk_in_frozen_workers'and i.document_link_enabled;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_order from public.business_orders o where o.order_id=v_subject.order_id and o.branch_id=v_subject.branch_id and o.customer_id is null and o.booking_id is null;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',x.value->'name','quantity',x.value->'quantity','unit_price',x.value->'unit_price','subtotal',x.value->'subtotal')order by x.ordinality),'[]'::jsonb)
 into v_lines from jsonb_array_elements(v_invoice.document_snapshot->'lines')with ordinality x(value,ordinality);
 v_snapshot:=jsonb_build_object('branch',jsonb_build_object('name_ar',v_invoice.document_snapshot#>'{branch,name_ar}','name_en',v_invoice.document_snapshot#>'{branch,name_en}','address_ar',v_invoice.document_snapshot#>'{branch,address_ar}','address_en',v_invoice.document_snapshot#>'{branch,address_en}'),
 'lines',v_lines,'currency','EGP','discount',v_invoice.document_snapshot->'discount','total',v_invoice.document_snapshot->'total','tax_amount',v_invoice.document_snapshot->'tax_amount','tax_configuration',v_invoice.document_snapshot->'tax_configuration','delivery_fee',v_invoice.document_snapshot->'delivery_fee');
 v_payment:=private.offline_history_payment_status(v_invoice.invoice_id);
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('schema_version','offline-customer-invoice-v1','source_kind','offline_walk_in','invoice_id',v_invoice.invoice_id,'branch_id',v_invoice.branch_id,'order_id',v_subject.order_id,'invoice_number',v_invoice.display_number,'issued_at',v_invoice.issued_at,
 'issued_at_cairo',to_char(v_invoice.issued_at at time zone 'Africa/Cairo','YYYY-MM-DD"T"HH24:MI:SS'),'snapshot',v_snapshot,
 'invoice_total',v_invoice.total,'invoice_discount',v_invoice.discount,'payment_status',v_payment,'payment_method',v_invoice.payment_method,'service_status',v_order.status,
 'document_token',v_invoice.document_token,'portal_origin',v_invoice.document_origin,'qr_reader_bridge',coalesce((select enabled from private.offline_history_runtime where id),false),'capabilities',private.offline_history_capabilities(true));
end$$;


create or replace function private.get_my_offline_visit_history(p_before_created_at timestamptz default null,p_before_order uuid default null,p_limit integer default 25)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_items jsonb;v_last jsonb;v_more boolean;
begin
 v_link:=private.resolve_my_offline_history_link();
 if p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_order is null)then raise exception 'Valid bounded cursor required'using errcode='22023';end if;
 if not coalesce((select enabled from private.offline_history_runtime where id),false)or not exists(select 1 from private.offline_history_scope_consents c where c.link_id=v_link.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')then raise exception 'History unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(q.item order by q.created_at desc,q.order_id desc),'[]'::jsonb)into v_items from(
 select s.created_at,s.order_id,jsonb_build_object('source_kind','offline_walk_in','order_id',s.order_id,'invoice_id',s.invoice_id,
 'invoice_token',i.document_token,'work_reference',i.display_number,'invoice_number',i.display_number,'branch',jsonb_build_object('name_ar',i.document_snapshot#>'{branch,name_ar}','name_en',i.document_snapshot#>'{branch,name_en}'),
 'service_name',i.service_name,'created_at',s.created_at,'arrived_at',r.arrived_at,'service_status',o.status,
 'car',jsonb_build_object('plate_number',c.car_snapshot->'plate_number','brand',c.car_snapshot->'brand','model',c.car_snapshot->'model','year',c.car_snapshot->'year','color',c.car_snapshot->'color'),
 'gross_amount',s.gross,'invoice_total',i.total,'invoice_discount',i.discount,'currency','EGP','payment_status',private.offline_history_payment_status(i.invoice_id),
 'collectible_amount',case when i.status<>'active'or private.offline_history_payment_status(i.invoice_id)in('paid','verification_required')then 0 else i.total end,'loyalty_earning_supported',false) item
 from private.offline_walk_in_subjects s join public.business_orders o on o.order_id=s.order_id and o.branch_id=s.branch_id and o.customer_id is null and o.booking_id is null
 join public.business_invoices i on i.invoice_id=s.invoice_id and i.order_id=s.order_id and i.branch_id=s.branch_id and i.commission_model='walk_in_frozen_workers'
 join private.offline_customer_car_refs c on c.car_ref_id=s.car_ref_id and c.profile_id=s.profile_id
 left join private.offline_walk_in_reception r on r.order_id=s.order_id
 where s.profile_id=v_link.profile_id and(p_before_created_at is null or(s.created_at,s.order_id)<(p_before_created_at,p_before_order))
 order by s.created_at desc,s.order_id desc limit p_limit+1)q;
 v_more:=jsonb_array_length(v_items)>p_limit;
 if v_more then v_items:=v_items-(jsonb_array_length(v_items)-1);end if;
 v_last:=v_items->(jsonb_array_length(v_items)-1);
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','available','items',v_items,'next_cursor',case when v_more then jsonb_build_object('created_at',v_last->'created_at','order_id',v_last->'order_id')else null end,'capabilities',private.offline_history_capabilities(true));
end$$;

create function private.get_my_offline_invoice_by_token(p_token uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_invoice text;
begin
 v_link:=private.resolve_my_offline_history_link();
 select i.invoice_id into v_invoice from private.offline_walk_in_subjects s
 join public.business_invoices i on i.invoice_id=s.invoice_id and i.order_id=s.order_id and i.branch_id=s.branch_id
 where s.profile_id=v_link.profile_id and i.document_token=p_token and i.document_link_enabled and i.commission_model='walk_in_frozen_workers';
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 return private.get_my_offline_invoice_document(v_invoice);
end$$;
create function public.get_my_offline_invoice_by_token(p_token uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_invoice_by_token(p_token)$$;
revoke all on function private.get_my_offline_invoice_by_token(uuid),public.get_my_offline_invoice_by_token(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_my_offline_invoice_by_token(uuid),public.get_my_offline_invoice_by_token(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
