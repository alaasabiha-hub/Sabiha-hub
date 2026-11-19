begin;
create function private.get_owner_mixed_points_operations(p_branch uuid,p_before_time timestamptz default null,p_before_lot uuid default null)returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare page jsonb;more boolean;policy jsonb;begin
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Owner only'using errcode='42501';end if;
 if(p_before_time is null)<>(p_before_lot is null)or(p_before_time is not null and not isfinite(p_before_time))then raise exception 'Complete finite review cursor required'using errcode='22023';end if;
 select jsonb_build_object('version',c.version,'allowed',v.allowed,'reason',v.reason,'updated_at',v.created_at)into policy from private.mixed_points_verbal_policy_current c join private.mixed_points_verbal_policy_versions v on v.request_id=c.version_id where c.branch_id=p_branch;
 with candidates as(select r.lot_id,r.created_at,jsonb_build_object('lot_id',r.lot_id,'created_at',r.created_at,'invoice_number',i.display_number,'invoice_id',i.invoice_id,'points',l.points::text,'point_value_egp',p.rules->'point_value_egp','refund_amount',e.amount,'currency','EGP','decision',d.decision,'decision_reason',d.reason,'decided_at',d.created_at)entry
 from private.mixed_points_refund_reviews r join private.mixed_points_earned_lots l using(lot_id)join private.mixed_points_wallets w using(wallet_id)join private.mixed_points_policy_versions p on p.version_id=l.policy_id join public.business_invoices i on i.invoice_id=l.invoice_id join public.business_payment_events e on e.payment_id=r.payment_id left join private.mixed_points_review_decisions d using(lot_id)
 where w.branch_id=p_branch and(p_before_time is null or(r.created_at,r.lot_id)<(p_before_time,p_before_lot))order by r.created_at desc,r.lot_id desc limit 51),limited as(select *from candidates order by created_at desc,lot_id desc limit 50)
 select coalesce((select jsonb_agg(entry order by created_at desc,lot_id desc)from limited),'[]'),(select count(*)>50 from candidates)into page,more;
 return jsonb_build_object('verbal_policy',coalesce(policy,jsonb_build_object('version',0,'allowed',false)),'reviews',page,'has_more',more,'redemption_runtime_enabled',(select redemption_enabled from private.mixed_points_runtime where singleton),'earning_runtime_enabled',(select earning_enabled from private.mixed_points_runtime where singleton),'activation_supported',false);
end$$;
create function public.get_owner_mixed_points_operations(p_branch uuid,p_before_time timestamptz default null,p_before_lot uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_mixed_points_operations(p_branch,p_before_time,p_before_lot)$$;
create function public.decide_owner_mixed_points_refund_review(p_request uuid,p_lot uuid,p_decision text,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.decide_mixed_points_refund_review(p_request,p_lot,p_decision,p_reason)$$;
revoke all on function private.get_owner_mixed_points_operations(uuid,timestamptz,uuid),public.get_owner_mixed_points_operations(uuid,timestamptz,uuid),private.decide_mixed_points_refund_review(uuid,uuid,text,text),public.decide_owner_mixed_points_refund_review(uuid,uuid,text,text)from public,anon,authenticated,service_role;
grant execute on function private.get_owner_mixed_points_operations(uuid,timestamptz,uuid),public.get_owner_mixed_points_operations(uuid,timestamptz,uuid),private.decide_mixed_points_refund_review(uuid,uuid,text,text),public.decide_owner_mixed_points_refund_review(uuid,uuid,text,text)to authenticated;
notify pgrst,'reload schema';
commit;
