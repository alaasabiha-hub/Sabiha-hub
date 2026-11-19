-- Prepared locally. No production data or schema is changed by creating this file.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;
-- Private helper avoids recursive staff_profiles policies. Identity always comes from Auth.
create function private.active_staff_role() returns text language sql stable security definer
set search_path = pg_catalog as $$
  select sp.role from public.staff_profiles sp where auth.uid() is not null
    and sp.user_id = auth.uid() and sp.is_active;
$$;
revoke all on function private.active_staff_role() from public, anon;
grant execute on function private.active_staff_role() to authenticated, service_role;

alter table public.bookings add column assigned_staff_ids uuid[] not null default '{}';
alter table public.business_orders add column assigned_staff_ids uuid[] not null default '{}';
-- Names are retained as display snapshots only. Only uniquely matched active profiles are backfilled.
update public.bookings b set assigned_staff_ids = coalesce((select array_agg(sp.user_id order by sp.user_id)
 from public.staff_profiles sp where sp.is_active and b.assigned_workers @> jsonb_build_array(sp.full_name)
 and (select count(*) from public.staff_profiles other where other.is_active and other.full_name=sp.full_name)=1),'{}');
update public.business_orders b set assigned_staff_ids = coalesce((select array_agg(sp.user_id order by sp.user_id)
 from public.staff_profiles sp where sp.is_active and b.assigned_workers @> jsonb_build_array(sp.full_name)
 and (select count(*) from public.staff_profiles other where other.is_active and other.full_name=sp.full_name)=1),'{}');

grant select (assigned_staff_ids) on public.bookings, public.business_orders to authenticated;
grant update (assigned_staff_ids) on public.bookings, public.business_orders to authenticated;
create policy "Management reads staff directory" on public.staff_profiles for select to authenticated
using ((select private.active_staff_role()) in ('owner','manager'));

drop policy "Assigned employees read their bookings" on public.bookings;
create policy "Assigned employees read their bookings" on public.bookings for select to authenticated
using ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids));
drop policy "Assigned employees progress their bookings" on public.bookings;
create policy "Assigned employees progress their bookings" on public.bookings for update to authenticated
using ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids) and status in ('confirmed','in_progress'))
with check ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids) and status in ('in_progress','completed'));
drop policy "Assigned employees read their work orders" on public.business_orders;
create policy "Assigned employees read their work orders" on public.business_orders for select to authenticated
using ((select private.active_staff_role()) in ('owner','manager') or
 ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids)));
drop policy "Authorized staff update work progress" on public.business_orders;
create policy "Authorized staff update work progress" on public.business_orders for update to authenticated
using ((select private.active_staff_role()) in ('owner','manager') or
 ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids) and status in ('received','in_progress','quality_check')))
with check ((select private.active_staff_role()) in ('owner','manager') or
 ((select private.active_staff_role())='employee' and (select auth.uid())=any(assigned_staff_ids) and status in ('in_progress','quality_check','completed')));

create function public.guard_staff_assignment() returns trigger language plpgsql security invoker
set search_path = pg_catalog as $$
begin
 if tg_op='UPDATE' and (new.assigned_staff_ids is distinct from old.assigned_staff_ids or new.assigned_workers is distinct from old.assigned_workers)
    and coalesce(private.active_staff_role(),'') not in ('owner','manager')
    and coalesce(auth.role(),'') <> 'service_role' and current_user not in ('postgres','supabase_admin') then
    raise exception 'Only management can assign staff';
 end if;
 if exists (select 1 from unnest(new.assigned_staff_ids) id where not exists (
    select 1 from public.staff_profiles sp where sp.user_id=id and sp.is_active)) then
    raise exception 'Assignments require active staff accounts';
 end if;
 -- Compatibility for existing server-side POS name snapshots: ambiguous names never grant access.
 if cardinality(new.assigned_staff_ids)=0 and jsonb_array_length(new.assigned_workers)>0
    and (tg_op='INSERT' or new.assigned_workers is distinct from old.assigned_workers) then
    select coalesce(array_agg(sp.user_id order by sp.user_id),'{}') into new.assigned_staff_ids
    from public.staff_profiles sp where sp.is_active and new.assigned_workers @> jsonb_build_array(sp.full_name)
      and (select count(*) from public.staff_profiles other where other.is_active and other.full_name=sp.full_name)=1;
 end if;
 return new;
end; $$;
revoke all on function public.guard_staff_assignment() from public;
create trigger guard_booking_staff_assignment before insert or update on public.bookings for each row execute function public.guard_staff_assignment();
create trigger guard_order_staff_assignment before insert or update on public.business_orders for each row execute function public.guard_staff_assignment();

-- Read-only owner aggregation needs access to server-only expense and commission fields.
-- Keep the privileged implementation private and require a live owner profile, never user_metadata.
create function private.owner_report(p_from date, p_to date, p_zone text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_start timestamptz; v_end timestamptz; v_sales numeric; v_refunds numeric;
 v_commission numeric; v_expenses numeric; v_count bigint; v_daily jsonb; v_payments jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then
   raise exception 'Active owner access required' using errcode='42501';
 end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to 367 days'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Unknown report time zone'; end if;
 v_start:=p_from::timestamp at time zone p_zone;
 v_end:=(p_to+1)::timestamp at time zone p_zone;
 select coalesce(sum(total) filter(where status='active'),0),coalesce(sum(total) filter(where status='refunded'),0),
   coalesce(sum(commission_total) filter(where status='active'),0),count(*) filter(where status='active')
 into v_sales,v_refunds,v_commission,v_count from public.business_invoices where issued_at>=v_start and issued_at<v_end;
 select coalesce(sum(amount),0) into v_expenses from public.business_expenses where expense_date between p_from and p_to;
 select coalesce(jsonb_agg(to_jsonb(d) order by d.day),'[]') into v_daily from (
   select (issued_at at time zone p_zone)::date as day, sum(total) as sales,count(*) as invoices
   from public.business_invoices where issued_at>=v_start and issued_at<v_end and status='active' group by 1) d;
 select coalesce(jsonb_agg(to_jsonb(p)),'[]') into v_payments from (
   select coalesce(payment_method,'unspecified') as method,sum(total) as total from public.business_invoices
   where issued_at>=v_start and issued_at<v_end and status='active' group by 1) p;
 return jsonb_build_object('from',p_from,'to',p_to,'time_zone',p_zone,'sales',v_sales,'refunded_total',v_refunds,
   'commissions',v_commission,'expenses',v_expenses,'net_before_tax',v_sales-v_commission-v_expenses,
   'invoice_count',v_count,'daily',v_daily,'payments',v_payments);
end; $$;
revoke all on function private.owner_report(date,date,text) from public,anon;
grant execute on function private.owner_report(date,date,text) to authenticated;
create function public.get_owner_report(p_from date,p_to date,p_zone text default 'Africa/Cairo')
returns jsonb language sql security invoker set search_path=pg_catalog as $$
 select private.owner_report(p_from,p_to,p_zone);
$$;
revoke all on function public.get_owner_report(date,date,text) from public,anon;
grant execute on function public.get_owner_report(date,date,text) to authenticated;

-- Explicit privileges work on projects with automatic API exposure disabled.
revoke select on public.customers from authenticated;
revoke select(password_hash) on public.customers from authenticated;
grant select(id,full_name,phone,email,date_of_birth,email_verified,created_at) on public.customers to authenticated;
grant update(full_name,phone,date_of_birth) on public.customers to authenticated;
revoke insert,update,delete on public.staff_profiles from authenticated;
revoke all on public.business_catalog_items,public.business_offers,public.business_loyalty_transactions,public.business_documents,public.business_document_alerts,public.business_order_items,public.customer_marketing_preferences,public.push_device_tokens,public.marketing_campaigns,public.marketing_campaign_runs,public.marketing_campaign_recipients,public.marketing_campaign_delivery_attempts,public.marketing_campaign_events,public.business_product_ads,public.business_product_ad_customer_state,public.business_product_ad_events,public.business_coupons,public.business_coupon_redemptions from anon;
grant all on public.business_catalog_items,public.business_offers,public.business_loyalty_transactions,public.business_documents,public.business_document_alerts,public.business_order_items,public.customer_marketing_preferences,public.push_device_tokens,public.marketing_campaigns,public.marketing_campaign_runs,public.marketing_campaign_recipients,public.marketing_campaign_delivery_attempts,public.marketing_campaign_events,public.business_product_ads,public.business_product_ad_customer_state,public.business_product_ad_events,public.business_coupons,public.business_coupon_redemptions to service_role;
grant select on public.business_loyalty_balances to service_role;
