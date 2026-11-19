begin;
create function private.mixed_points_positive_units(p_points bigint,p_quantity integer,p_first integer,p_last integer)returns table(unit_number integer,points bigint)
language plpgsql immutable security invoker set search_path=pg_catalog as $$begin
 if p_points is null or p_quantity is null or p_first is null or p_last is null or p_points<0 or p_quantity<1 or p_first<1 or p_last<p_first or p_last>p_quantity then raise exception 'Exact original integer unit range required'using errcode='22023';end if;
 if p_points=0 then return;end if;
 if p_points<p_quantity then
 return query select ceil(k::numeric*p_quantity/p_points)::integer,1::bigint from generate_series((floor(p_points::numeric*(p_first-1)/p_quantity)+1)::bigint,floor(p_points::numeric*p_last/p_quantity)::bigint)k;
 else return query select n,(floor(p_points::numeric*n/p_quantity)-floor(p_points::numeric*(n-1)/p_quantity))::bigint from generate_series(p_first,p_last)n;end if;
end$$;
revoke all on function private.mixed_points_positive_units(bigint,integer,integer,integer)from public,anon,authenticated,service_role;
create or replace function private.restore_mixed_points_units(p_invoice text,p_source uuid,p_kind text)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare r private.mixed_points_reservations;policy private.mixed_points_policy_versions;amount bigint;remaining bigint;part bigint;lot record;restore boolean;begin
 select x.*into r from private.mixed_points_reservations x join private.mixed_points_invoice_bindings b on b.reservation_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 select *into strict policy from private.mixed_points_policy_versions where version_id=r.spending_policy_id;restore:=policy.rules->>'cancellation'='restore_points';
 if p_kind='credit'then
 if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid credit required'using errcode='55000';end if;
 elsif p_kind='refund'then
 if not exists(select 1 from private.mixed_points_spend_commits where reservation_id=r.request_id)or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.refund_part_id=f.request_id and e.invoice_id=p_invoice and e.event_type='refund'and e.amount=f.amount)))then raise exception 'Confirmed canonical refund required'using errcode='55000';end if;
 elsif p_kind='full'then
 if not exists(select 1 from private.mixed_points_spend_commits where reservation_id=r.request_id)or not exists(select 1 from public.business_payment_events where payment_id=p_source and invoice_id=p_invoice and event_type='refund'and refund_part_id is null)then raise exception 'Confirmed full refund required'using errcode='55000';end if;
 else raise exception 'Canonical returns only'using errcode='22023';end if;
 with ranges as(
 select sl.line_id,sl.quantity,sl.points,c.unit_number first_unit,c.unit_number last_unit from private.mixed_points_spend_lines sl join private.cashier_unpaid_service_credits c on c.line_id=sl.line_id where sl.reservation_id=r.request_id and c.request_id=p_source and p_kind='credit'
 union all
 select sl.line_id,sl.quantity,sl.points,u.value::integer,u.value::integer from private.mixed_points_spend_lines sl join private.cashier_partial_refund_lines f on f.line_id=sl.line_id cross join lateral jsonb_array_elements_text(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'else'[]'::jsonb end)u(value)where sl.reservation_id=r.request_id and f.request_id=p_source and p_kind='refund'
 union all
 select sl.line_id,sl.quantity,sl.points,(f.snapshot->>'previous_quantity')::integer+1,(f.snapshot->>'cumulative_quantity')::integer from private.mixed_points_spend_lines sl join private.cashier_partial_refund_lines f on f.line_id=sl.line_id where sl.reservation_id=r.request_id and f.request_id=p_source and p_kind='refund'and not(f.snapshot?'unit_numbers')
 union all
 select sl.line_id,sl.quantity,sl.points,1,sl.quantity from private.mixed_points_spend_lines sl where sl.reservation_id=r.request_id and p_kind='full'),candidates as(
 select v.line_id,u.unit_number,v.points,v.quantity from ranges v cross join lateral private.mixed_points_positive_units(v.points,v.quantity,v.first_unit,v.last_unit)u),inserted as(
 insert into private.mixed_points_returned_units(reservation_id,line_id,unit_number,source_id,source_kind,points,restored)
 select r.request_id,line_id,unit_number,p_source,p_kind,floor(points::numeric*unit_number/quantity)-floor(points::numeric*(unit_number-1)/quantity),restore from candidates
 on conflict(reservation_id,line_id,unit_number)do nothing returning points,restored)
 select coalesce(sum(points)filter(where restored),0)into amount from inserted;
 remaining:=amount;
 for lot in select a.lot_id,a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0)available from private.mixed_points_reservation_lots a where reservation_id=r.request_id order by a.lot_id loop
 part:=least(remaining,lot.available);if part>0 then insert into private.mixed_points_lot_restorations(reservation_id,lot_id,source_id,points)values(r.request_id,lot.lot_id,p_source,part);remaining:=remaining-part;end if;exit when remaining=0;end loop;
 if remaining<>0 then raise exception 'Restoration exceeds original points'using errcode='55000';end if;
 if p_kind='credit'and private.cashier_invoice_payable(p_invoice)=0 and not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and event_type='sale')then
 insert into private.mixed_points_reservation_releases(request_id,reservation_id,actor_id,reason)values(p_source,r.request_id,auth.uid(),'Canonical unpaid service cancellation leaves no collectible amount')on conflict(reservation_id)do nothing;end if;
end$$;
commit;
