begin;
-- Either paired record can be the final one. Never infer completion from one alone.
create function private.reconcile_completed_booking_points()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare work private.cashier_service_worklines;
begin
 if new.status is distinct from old.status and new.status in('completed','delivered')then
 select *into work from private.cashier_service_worklines where booking_id=new.id;
 if found then perform private.reconcile_mixed_points_earning(work.invoice_id,work.order_id);end if;
 end if;return new;
end$$;
revoke all on function private.reconcile_completed_booking_points()from public,anon,authenticated,service_role;
create trigger future_points_after_final_booking after update of status on public.bookings for each row execute function private.reconcile_completed_booking_points();
commit;
