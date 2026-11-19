begin;
-- Add actual owner-only references; no entitlement, claim, invoice or balance changes.
create or replace function private.list_reward_refund_reviews(p_branch uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare customer_key uuid;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 for customer_key in select distinct customer_id from private.service_reward_redemptions where(p_branch is null or branch_id=p_branch)order by customer_id loop perform private.sync_customer_rewards(customer_key);end loop;
 select coalesce(jsonb_agg(jsonb_build_object('review_id',r.review_id,'customer_id',r.customer_id,'customer_name',customer.full_name,'invoice_number',coalesce(invoice.display_number,invoice.invoice_id),'booking_number',booking.display_number,'created_at',r.created_at,'service_name',invoice.service_name,'redemption_status',redemption.state,'branch_id',r.branch_id,'offer_id',r.offer_id,'mode',r.mode,'acknowledged_at',r.acknowledged_at,'closed_at',r.closed_at,'debt_outstanding',not exists(select 1 from private.reward_credit_claims c where c.debt_id=r.review_id and c.released_at is null and private.reward_credit_refund(c.earning_id) is null))order by r.created_at),'[]') into result from private.reward_refund_reviews r join private.service_reward_redemptions redemption on redemption.redemption_id=r.redemption_id join public.business_invoices invoice on invoice.invoice_id=redemption.invoice_id left join public.bookings booking on booking.id=redemption.booking_id join public.customers customer on customer.id=r.customer_id where p_branch is null or r.branch_id=p_branch;return result;
end $$;
notify pgrst,'reload schema';
commit;
