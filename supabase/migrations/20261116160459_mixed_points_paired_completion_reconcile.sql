begin;
-- The paired booking may earn staff commissions before its order is completed.
-- Reconcile at either final event; the unique service lot makes both paths idempotent.
create function private.reconcile_completed_order_points()returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare invoice text;
begin
 if new.status is distinct from old.status and new.status in('completed','delivered')then
 select invoice_id into invoice from private.cashier_service_worklines where order_id=new.order_id;
 if found then perform private.reconcile_mixed_points_earning(invoice,new.order_id);end if;
 end if;return new;
end$$;
revoke all on function private.reconcile_completed_order_points()from public,anon,authenticated,service_role;
create trigger future_points_after_final_order after update of status on public.business_orders for each row execute function private.reconcile_completed_order_points();
commit;
