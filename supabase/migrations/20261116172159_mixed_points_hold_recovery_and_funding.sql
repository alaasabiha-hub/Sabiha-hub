begin;
alter table private.mixed_points_reservations drop constraint mixed_points_reservations_intent_id_key;
create or replace function private.reserve_mixed_points(p_request uuid,p_branch uuid,p_intent uuid,p_earning_policy uuid,p_points bigint)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;i private.cashier_loyalty_draft_intents;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;wallet private.mixed_points_wallets;old private.mixed_points_reservations;
 earning private.mixed_points_policy_versions;spending private.mixed_points_policy_versions;plan jsonb;rules jsonb;fp text;remaining bigint;part bigint;funded numeric;lot record;
begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_intent is null or p_earning_policy is null or p_points is null or p_points<=0 then raise exception 'Exact reservation operands required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-reservation-command:'||p_request,0));
 select *into old from private.mixed_points_reservations where request_id=p_request;
 if found then
 if old.actor_id<>actor then raise exception 'Reservation unavailable'using errcode='42501';end if;
 if old.intent_id<>p_intent or old.earning_policy_id<>p_earning_policy or old.points<>p_points then raise exception 'Immutable reservation request'using errcode='22023';end if;
 if not exists(select 1 from private.mixed_points_wallets where wallet_id=old.wallet_id and branch_id=p_branch)then raise exception 'Branch mismatch'using errcode='42501';end if;
 return jsonb_build_object('reservation_id',p_request,'fingerprint',old.fingerprint,'expires_at',old.expires_at,'balance_reserved',private.mixed_points_hold_live(p_request),'payment_confirmed',false,'quote',old.quote);end if;
 select *into i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=actor and branch_id=p_branch;
 if not found then raise exception 'Own sealed draft required'using errcode='42501';end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=i.draft_id for update;
 select *into b from private.cashier_draft_subjects where draft_id=i.draft_id for share;
 if (private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Current draft required'using errcode='40001';end if;
 select *into wallet from private.mixed_points_wallets where branch_id=p_branch and subject_kind=b.subject_kind and subject_id=b.subject_id;
 if not found then raise exception 'No funded point wallet'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||wallet.wallet_id,0));
 if exists(select 1 from private.mixed_points_reservations x where x.intent_id=p_intent and private.mixed_points_hold_live(x.request_id))then raise exception 'Recover the current reservation before selecting points again'using errcode='40001';end if;
 select coalesce(sum(l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0))from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)),0)into funded
 from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=wallet.wallet_id and l.policy_id=p_earning_policy;
 if funded<p_points then raise exception 'Insufficient unreserved earned points'using errcode='22023';end if;
 if exists(select 1 from private.mixed_points_refund_reviews v join private.mixed_points_earned_lots l using(lot_id)where l.wallet_id=wallet.wallet_id and not exists(select 1 from private.mixed_points_review_decisions x where x.lot_id=v.lot_id))then raise exception 'Wallet requires independent owner refund review'using errcode='55000';end if;
 select *into earning from private.mixed_points_policy_versions where version_id=p_earning_policy and branch_id=p_branch;
 if not found then raise exception 'Original earning terms required'using errcode='22023';end if;
 select v.*into spending from private.mixed_points_policy_versions v join private.mixed_points_policy_current c on c.version_id=v.version_id where c.branch_id=p_branch for share of c;
 if not found or spending.rules->>'allow_walk_in'is distinct from'true'then raise exception 'Current owner spending permission required'using errcode='42501';end if;
 -- Never revalue earned rights using today's point value. Today's eligibility/ceilings still apply.
 rules:=spending.rules||jsonb_build_object('point_value_egp',earning.rules->'point_value_egp','point_value_basis',earning.rules->'point_value_basis');
 plan:=private.mixed_loyalty_discount_core(i.witness->'quote',rules,p_points);
 fp:=encode(extensions.digest(jsonb_build_object('request',p_request,'wallet',wallet.wallet_id,'seal',i.fingerprint,'earning_policy',p_earning_policy,'spending_policy',spending.version_id,'points',p_points,'plan',plan)::text,'sha256'),'hex');
 insert into private.mixed_points_reservations values(p_request,actor,wallet.wallet_id,p_intent,p_earning_policy,spending.version_id,p_points,plan,fp,i.expires_at,clock_timestamp());remaining:=p_points;
 for lot in select l.lot_id,l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0))from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)available
 from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=wallet.wallet_id and l.policy_id=p_earning_policy order by l.created_at,l.lot_id loop
 part:=least(remaining,greatest(lot.available,0));if part>0 then insert into private.mixed_points_reservation_lots values(p_request,lot.lot_id,part);remaining:=remaining-part;end if;exit when remaining=0;end loop;
 if remaining<>0 then raise exception 'Insufficient unreserved earned points'using errcode='22023';end if;
 if (private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Seal expired while reserving'using errcode='40001';end if;
 return jsonb_build_object('reservation_id',p_request,'fingerprint',fp,'expires_at',i.expires_at,'balance_reserved',true,'payment_confirmed',false,'quote',plan);
end$$;
create or replace function private.get_cashier_mixed_points_context(p_branch uuid,p_draft uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
 return jsonb_build_object('enabled',true,'state',case when frozen then'owner_review_required'else'ready'end,'buckets',buckets,'documents',docs,'draft_version',d.version,'binding_version',b.version,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal')||jsonb_build_object(
 'intent_id',(select i.request_id from private.cashier_loyalty_draft_intents i where i.draft_id=p_draft and i.draft_version=d.version and i.binding_version=b.version),
 'seal_expired',coalesce((select i.expires_at<=clock_timestamp()from private.cashier_loyalty_draft_intents i where i.draft_id=p_draft and i.draft_version=d.version and i.binding_version=b.version),false),
 'hold',(select jsonb_build_object('reservation_id',r.request_id,'fingerprint',r.fingerprint,'quote',r.quote,'expires_at',r.expires_at,'balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_points_verbal_notice('ar',private.mixed_loyalty_customer_terms(r.quote)),'verbal_notice_en',private.mixed_points_verbal_notice('en',private.mixed_loyalty_customer_terms(r.quote)))from private.mixed_points_reservations r join private.cashier_loyalty_draft_intents i on i.request_id=r.intent_id where i.draft_id=p_draft and r.actor_id=actor and private.mixed_points_hold_live(r.request_id)limit 1),
 'approval',(select jsonb_build_object('reservation_id',r.request_id,'consent_id',c.request_id)from private.mixed_points_reservations r join private.cashier_loyalty_draft_intents i on i.request_id=r.intent_id join private.mixed_points_verbal_consents c on c.reservation_id=r.request_id where i.draft_id=p_draft and r.actor_id=actor and c.session_id=(auth.jwt()->>'session_id')::uuid and private.mixed_points_hold_live(r.request_id)limit 1));
end$$;
notify pgrst,'reload schema';
commit;
