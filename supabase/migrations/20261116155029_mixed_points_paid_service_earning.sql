begin;
-- Independent future program. No legacy visit/points conversion and no activation API.
create table private.mixed_points_runtime(singleton boolean primary key default true check(singleton),earning_enabled boolean not null default false,redemption_enabled boolean not null default false check(not redemption_enabled));
insert into private.mixed_points_runtime values(true,false,false);
create table private.mixed_points_invoice_terms(
 invoice_id text primary key references private.cashier_invoice_postings(invoice_id),branch_id uuid not null references public.business_branches(branch_id),
 policy_id uuid not null references private.mixed_points_policy_versions(version_id),subject_kind text not null check(subject_kind in('app_customer','offline_profile')),subject_id uuid not null,
 earning_authorized_at_issue boolean not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_wallets(wallet_id uuid primary key default gen_random_uuid(),branch_id uuid not null references public.business_branches(branch_id),subject_kind text not null check(subject_kind in('app_customer','offline_profile')),subject_id uuid not null,unit text not null default 'reward_points_v1'check(unit='reward_points_v1'),unique(branch_id,subject_kind,subject_id));
create table private.mixed_points_earned_lots(
 lot_id uuid primary key default gen_random_uuid(),wallet_id uuid not null references private.mixed_points_wallets(wallet_id),
 invoice_id text not null references private.mixed_points_invoice_terms(invoice_id),order_id uuid not null unique references private.cashier_service_worklines(order_id),
 policy_id uuid not null references private.mixed_points_policy_versions(version_id),points bigint not null check(points between 1 and 1000000),
 sale_payment_id uuid not null references public.business_payment_events(payment_id),completed_event uuid not null references private.service_work_ledger(event_id),
 created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_refund_offsets(lot_id uuid primary key references private.mixed_points_earned_lots(lot_id),payment_id uuid not null references public.business_payment_events(payment_id),points bigint not null check(points>0),created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_refund_reviews(lot_id uuid primary key references private.mixed_points_earned_lots(lot_id),payment_id uuid not null references public.business_payment_events(payment_id),reason text not null,created_at timestamptz not null default clock_timestamp());
do $$declare n text;begin foreach n in array array['mixed_points_runtime','mixed_points_invoice_terms','mixed_points_wallets','mixed_points_earned_lots','mixed_points_refund_offsets','mixed_points_refund_reviews']loop
 execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);
 if n<>'mixed_points_runtime'then execute format('create trigger immutable_future_points before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end if;
end loop;end$$;
create index mixed_points_wallet_lots on private.mixed_points_earned_lots(wallet_id,policy_id);
create function private.capture_mixed_points_invoice_terms()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare p private.cashier_invoice_postings;policy private.mixed_points_policy_versions;enabled boolean;
begin
 select *into p from private.cashier_invoice_postings where invoice_id=new.invoice_id and creator_xid=txid_current();if not found then return new;end if;
 select v.*into policy from private.mixed_points_policy_current c join private.mixed_points_policy_versions v on v.version_id=c.version_id where c.branch_id=new.branch_id for share of c;
 if not found then return new;end if;
 select earning_enabled into enabled from private.mixed_points_runtime where singleton for share;
 insert into private.mixed_points_invoice_terms values(new.invoice_id,new.branch_id,policy.version_id,p.subject->>'kind',(p.subject->>'id')::uuid,
 coalesce(enabled,false)and policy.rules->>'allow_walk_in'='true'and policy.rules->>'unit'='reward_points_v1'and policy.rules->>'point_value_basis'in('gross_payable','pre_tax_base'),clock_timestamp());
 return new;
end$$;
create trigger capture_future_mixed_points after insert on public.business_invoices for each row execute function private.capture_mixed_points_invoice_terms();
-- Reconcile only new, originally authorized invoice terms. Payment order and work order are interchangeable.
create function private.reconcile_mixed_points_earning(p_invoice text,p_order uuid default null)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare terms private.mixed_points_invoice_terms;policy private.mixed_points_policy_versions;sale public.business_payment_events;wallet uuid;work record;points bigint;event uuid;enabled boolean;
begin
 select earning_enabled into enabled from private.mixed_points_runtime where singleton for share;if not coalesce(enabled,false)then return;end if;
 select *into terms from private.mixed_points_invoice_terms where invoice_id=p_invoice and earning_authorized_at_issue;if not found then return;end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice and status='active'for update;if not found then return;end if;
 select *into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
 if not found or sale.amount<>private.cashier_invoice_payable(p_invoice)or sale.method not in('cash','card_terminal')or(sale.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=sale.payment_id and c.invoice_id=p_invoice and c.amount=sale.amount))then return;end if;
 select *into strict policy from private.mixed_points_policy_versions where version_id=terms.policy_id;
 if sale.amount<(policy.rules->>'minimum_invoice_egp')::numeric then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet:'||terms.branch_id||':'||terms.subject_kind||':'||terms.subject_id,0));
 for work in select w.*from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings b on b.id=w.booking_id
 where w.invoice_id=p_invoice and(p_order is null or w.order_id=p_order)and o.status in('completed','delivered')and b.status in('completed','delivered')and w.allocated_payable>0
 and exists(select 1 from private.cashier_service_earnings e where e.order_id=w.order_id)
 and not exists(select 1 from private.mixed_points_earned_lots l where l.order_id=w.order_id)
 and not exists(select 1 from private.cashier_unpaid_service_credits c where c.invoice_id=w.invoice_id and c.line_id=w.line_id and c.unit_number=w.unit_number)
 and not exists(select 1 from public.business_payment_events e where e.invoice_id=w.invoice_id and e.event_type='refund'and(e.refund_part_id is null or exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=e.refund_part_id and f.line_id=w.line_id and coalesce(f.snapshot->'unit_numbers','[]')@>to_jsonb(array[w.unit_number]))))
 order by w.order_id loop
 select(value->>'points_per_completed_unit')::bigint into points from jsonb_array_elements(policy.rules->'earning_rates')where value->>'item_id'=work.item_id::text;
 if coalesce(points,0)<=0 then continue;end if;
 if wallet is null then
 insert into private.mixed_points_wallets(branch_id,subject_kind,subject_id)values(terms.branch_id,terms.subject_kind,terms.subject_id)on conflict(branch_id,subject_kind,subject_id)do nothing;
 select wallet_id into strict wallet from private.mixed_points_wallets where branch_id=terms.branch_id and subject_kind=terms.subject_kind and subject_id=terms.subject_id;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||wallet,0));
 select work_event into strict event from private.cashier_service_earnings where order_id=work.order_id order by staff_id limit 1;
 insert into private.mixed_points_earned_lots(wallet_id,invoice_id,order_id,policy_id,points,sale_payment_id,completed_event)values(wallet,p_invoice,work.order_id,terms.policy_id,points,sale.payment_id,event)on conflict(order_id)do nothing;
 end loop;
end$$;
create function private.mixed_points_source_changed()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare invoice text;
begin
 if tg_table_name='cashier_service_earnings'then
 select invoice_id into invoice from private.cashier_service_worklines where order_id=new.order_id;perform private.reconcile_mixed_points_earning(invoice,new.order_id);
 elsif new.event_type='sale'then perform private.reconcile_mixed_points_earning(new.invoice_id,null);
 end if;return new;
end$$;
create trigger future_points_after_work after insert on private.cashier_service_earnings for each row execute function private.mixed_points_source_changed();
create trigger future_points_after_collection after insert on public.business_payment_events for each row execute function private.mixed_points_source_changed();
-- Refunds never remove a completed service or a previously earned commission.
create function private.mixed_points_refund_received()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare lot record;
begin
 if new.event_type<>'refund'then return new;end if;
 for lot in select l.*,w.line_id,w.unit_number,p.rules from private.mixed_points_earned_lots l join private.cashier_service_worklines w using(order_id)join private.mixed_points_policy_versions p on p.version_id=l.policy_id
 where l.invoice_id=new.invoice_id and(new.refund_part_id is null or exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=new.refund_part_id and f.line_id=w.line_id and coalesce(f.snapshot->'unit_numbers','[]')@>to_jsonb(array[w.unit_number])))order by l.wallet_id,l.lot_id loop
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||lot.wallet_id,0));
 if lot.rules->>'refunded_contribution'='offset_future_points'then insert into private.mixed_points_refund_offsets values(lot.lot_id,new.payment_id,lot.points,clock_timestamp())on conflict(lot_id)do nothing;
 else insert into private.mixed_points_refund_reviews values(lot.lot_id,new.payment_id,'Owner review required by frozen earning terms',clock_timestamp())on conflict(lot_id)do nothing;end if;
 end loop;return new;
end$$;
create trigger future_points_after_refund after insert on public.business_payment_events for each row execute function private.mixed_points_refund_received();
revoke all on function private.capture_mixed_points_invoice_terms(),private.reconcile_mixed_points_earning(text,uuid),private.mixed_points_source_changed(),private.mixed_points_refund_received()from public,anon,authenticated,service_role;
commit;
