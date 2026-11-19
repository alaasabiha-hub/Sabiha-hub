-- Include inside canonical_reward_checkout.sql after BEGIN when testing the additive references migration.
create function pg_temp.assert_reward_review_owner_references(p_owner uuid,p_customer uuid,p_branch uuid,p_review uuid,p_invoice text)returns void language plpgsql as $$
declare rows jsonb;item jsonb;denied boolean;i public.business_invoices;d private.service_reward_redemptions;b public.bookings;
begin
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 select * into strict d from private.service_reward_redemptions where invoice_id=p_invoice;
 select * into b from public.bookings where id=d.booking_id;
 perform set_config('request.jwt.claim.sub',p_owner::text,true);execute 'set local role authenticated';rows:=public.list_reward_refund_reviews(p_branch);execute 'reset role';
 select x into strict item from jsonb_array_elements(rows)x where x->>'review_id'=p_review::text;
 assert item->>'invoice_number'=coalesce(i.display_number,i.invoice_id)and item->>'booking_number'is not distinct from b.display_number;
 assert item->>'customer_name'=(select full_name from public.customers where id=p_customer)and(item->>'created_at')::timestamptz is not null;
 perform set_config('request.jwt.claim.sub',p_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_customer,'user_metadata',jsonb_build_object('role','owner'))::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.list_reward_refund_reviews(p_branch);exception when insufficient_privilege then denied:=true;end;assert denied,'Customer metadata exposed owner review identities';execute 'reset role';
end $$;
