begin;
-- Runtime stays false. Only deployment/database administration can change it; no activation endpoint.
alter table private.mixed_points_runtime drop constraint mixed_points_runtime_redemption_enabled_check;
create function private.require_cashier_points_enabled(p_branch uuid)returns void language plpgsql security definer set search_path=pg_catalog as $$begin
 perform private.cashier_cart_actor(p_branch);
 if not coalesce((select redemption_enabled from private.mixed_points_runtime where singleton),false)or not exists(select 1 from private.mixed_points_verbal_policy_current c join private.mixed_points_verbal_policy_versions p on p.request_id=c.version_id where c.branch_id=p_branch and p.allowed)then raise exception 'Mixed points redemption is not activated'using errcode='55000';end if;
end$$;
create function private.get_cashier_mixed_points_context(p_branch uuid,p_draft uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;w private.mixed_points_wallets;buckets jsonb;docs jsonb;frozen boolean;begin
 actor:=private.cashier_cart_actor(p_branch);
 if not coalesce((select redemption_enabled from private.mixed_points_runtime where singleton),false)or not exists(select 1 from private.mixed_points_verbal_policy_current c join private.mixed_points_verbal_policy_versions p on p.request_id=c.version_id where c.branch_id=p_branch and p.allowed)then return jsonb_build_object('enabled',false,'buckets','[]'::jsonb,'documents','[]'::jsonb);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and branch_id=p_branch and actor_id=actor;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor and branch_id=p_branch;
 if d.draft_id is null or b.draft_id is null or b.draft_version<>d.version or exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then return jsonb_build_object('enabled',true,'state','binding_required','buckets','[]'::jsonb,'documents','[]'::jsonb);end if;
 select *into w from private.mixed_points_wallets where branch_id=p_branch and subject_kind=b.subject_kind and subject_id=b.subject_id;
 if not found then return jsonb_build_object('enabled',true,'state','no_earned_points','buckets','[]'::jsonb,'documents','[]'::jsonb);end if;
 select exists(select 1 from private.mixed_points_refund_reviews r join private.mixed_points_earned_lots l using(lot_id)where l.wallet_id=w.wallet_id and not exists(select 1 from private.mixed_points_review_decisions z where z.lot_id=r.lot_id))into frozen;
 with available as(select l.policy_id,l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0))from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)points from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=w.wallet_id),totals as(select policy_id,sum(points)points from available group by policy_id)
 select coalesce(jsonb_agg(jsonb_build_object('earning_policy_id',t.policy_id,'available_points',t.points::text,'point_value_egp',p.rules->'point_value_egp','point_value_basis',p.rules->'point_value_basis')order by p.version),'[]')into buckets from totals t join private.mixed_points_policy_versions p on p.version_id=t.policy_id;
 select coalesce(jsonb_agg(x.data order by x.created_at desc),'[]')into docs from(select i.invoice_id,max(l.created_at)created_at,jsonb_build_object('invoice_id',i.invoice_id,'number',i.display_number) data from private.mixed_points_earned_lots l join public.business_invoices i using(invoice_id)where l.wallet_id=w.wallet_id group by i.invoice_id,i.display_number order by max(l.created_at)desc limit 50)x;
 return jsonb_build_object('enabled',true,'state',case when frozen then'owner_review_required'else'ready'end,'buckets',buckets,'documents',docs,'draft_version',d.version,'binding_version',b.version,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal');
end$$;
create function private.reserve_cashier_mixed_points(p_request uuid,p_branch uuid,p_intent uuid,p_earning_policy uuid,p_points bigint)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare x jsonb;begin
 perform private.require_cashier_points_enabled(p_branch);x:=private.reserve_mixed_points(p_request,p_branch,p_intent,p_earning_policy,p_points);
 return x||jsonb_build_object('verbal_notice_ar',private.mixed_points_verbal_notice('ar',private.mixed_loyalty_customer_terms(x->'quote')),'verbal_notice_en',private.mixed_points_verbal_notice('en',private.mixed_loyalty_customer_terms(x->'quote')));
end$$;
create function private.confirm_cashier_mixed_points_verbal(p_request uuid,p_branch uuid,p_reservation uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_evidence_note text,p_language text,p_notice text,p_confirmed boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 perform private.require_cashier_points_enabled(p_branch);return private.attest_mixed_points_verbal_consent(p_request,p_branch,p_reservation,p_fingerprint,p_identity_method,p_identity_invoice,p_evidence_note,p_language,p_notice,p_confirmed);end$$;
create function private.issue_cashier_points_invoice(p_request uuid,p_branch uuid,p_reservation uuid,p_consent uuid,p_start timestamptz)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 perform private.require_cashier_points_enabled(p_branch);return private.issue_mixed_points_invoice(p_request,p_branch,p_reservation,p_consent,p_start);end$$;
create function public.get_cashier_mixed_points_context(p_branch uuid,p_draft uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_mixed_points_context(p_branch,p_draft)$$;
create function public.reserve_cashier_mixed_points(p_request uuid,p_branch uuid,p_intent uuid,p_earning_policy uuid,p_points bigint)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.reserve_cashier_mixed_points(p_request,p_branch,p_intent,p_earning_policy,p_points)$$;
create function public.confirm_cashier_mixed_points_verbal(p_request uuid,p_branch uuid,p_reservation uuid,p_fingerprint text,p_identity_method text,p_identity_invoice text,p_evidence_note text,p_language text,p_notice text,p_confirmed boolean)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_mixed_points_verbal(p_request,p_branch,p_reservation,p_fingerprint,p_identity_method,p_identity_invoice,p_evidence_note,p_language,p_notice,p_confirmed)$$;
create function public.issue_cashier_points_invoice(p_request uuid,p_branch uuid,p_reservation uuid,p_consent uuid,p_start timestamptz)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.issue_cashier_points_invoice(p_request,p_branch,p_reservation,p_consent,p_start)$$;
create function public.release_cashier_mixed_points(p_request uuid,p_reservation uuid,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.release_mixed_points_reservation(p_request,p_reservation,p_reason)$$;
create function public.save_owner_mixed_points_verbal_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_allowed boolean,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_mixed_points_verbal_policy(p_request,p_branch,p_expected_version,p_allowed,p_reason)$$;
-- Explicit public invokers plus only their guarded private implementation grants.

revoke all on function private.get_cashier_mixed_points_context(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_mixed_points_context(uuid,uuid)to authenticated;

revoke all on function public.get_cashier_mixed_points_context(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function public.get_cashier_mixed_points_context(uuid,uuid)to authenticated;

revoke all on function private.reserve_cashier_mixed_points(uuid,uuid,uuid,uuid,bigint)from public,anon,authenticated,service_role;
grant execute on function private.reserve_cashier_mixed_points(uuid,uuid,uuid,uuid,bigint)to authenticated;

revoke all on function public.reserve_cashier_mixed_points(uuid,uuid,uuid,uuid,bigint)from public,anon,authenticated,service_role;
grant execute on function public.reserve_cashier_mixed_points(uuid,uuid,uuid,uuid,bigint)to authenticated;

revoke all on function private.confirm_cashier_mixed_points_verbal(uuid,uuid,uuid,text,text,text,text,text,text,boolean)from public,anon,authenticated,service_role;
grant execute on function private.confirm_cashier_mixed_points_verbal(uuid,uuid,uuid,text,text,text,text,text,text,boolean)to authenticated;

revoke all on function public.confirm_cashier_mixed_points_verbal(uuid,uuid,uuid,text,text,text,text,text,text,boolean)from public,anon,authenticated,service_role;
grant execute on function public.confirm_cashier_mixed_points_verbal(uuid,uuid,uuid,text,text,text,text,text,text,boolean)to authenticated;

revoke all on function private.issue_cashier_points_invoice(uuid,uuid,uuid,uuid,timestamptz)from public,anon,authenticated,service_role;
grant execute on function private.issue_cashier_points_invoice(uuid,uuid,uuid,uuid,timestamptz)to authenticated;

revoke all on function public.issue_cashier_points_invoice(uuid,uuid,uuid,uuid,timestamptz)from public,anon,authenticated,service_role;
grant execute on function public.issue_cashier_points_invoice(uuid,uuid,uuid,uuid,timestamptz)to authenticated;

revoke all on function private.save_mixed_points_verbal_policy(uuid,uuid,integer,boolean,text)from public,anon,authenticated,service_role;
grant execute on function private.save_mixed_points_verbal_policy(uuid,uuid,integer,boolean,text)to authenticated;

revoke all on function public.save_owner_mixed_points_verbal_policy(uuid,uuid,integer,boolean,text)from public,anon,authenticated,service_role;
grant execute on function public.save_owner_mixed_points_verbal_policy(uuid,uuid,integer,boolean,text)to authenticated;

revoke all on function private.release_mixed_points_reservation(uuid,uuid,text)from public,anon,authenticated,service_role;
grant execute on function private.release_mixed_points_reservation(uuid,uuid,text)to authenticated;

revoke all on function public.release_cashier_mixed_points(uuid,uuid,text)from public,anon,authenticated,service_role;
grant execute on function public.release_cashier_mixed_points(uuid,uuid,text)to authenticated;
revoke all on function private.require_cashier_points_enabled(uuid)from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
