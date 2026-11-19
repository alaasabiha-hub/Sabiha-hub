begin;
create or replace function private.require_cashier_points_enabled(p_branch uuid)returns void language plpgsql security definer set search_path=pg_catalog as $$begin
 perform private.cashier_cart_actor(p_branch);
 perform 1 from private.mixed_points_runtime where singleton and redemption_enabled for share;
 if not found then raise exception 'Mixed points redemption is not activated'using errcode='55000';end if;
 perform 1 from private.mixed_points_verbal_policy_current c join private.mixed_points_verbal_policy_versions p on p.request_id=c.version_id where c.branch_id=p_branch and p.allowed for share of c;
 if not found then raise exception 'Owner has not allowed verbal redemption'using errcode='55000';end if;
end$$;
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
 select v.*into spending from private.mixed_points_policy_versions v join private.mixed_points_policy_current c on c.version_id=v.version_id where c.branch_id=p_branch for share of c;
 if not found or spending.rules->>'allow_walk_in'is distinct from'true'then raise exception 'Current owner spending permission required'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||wallet.wallet_id,0));
 if exists(select 1 from private.mixed_points_reservations x where x.intent_id=p_intent and private.mixed_points_hold_live(x.request_id))then raise exception 'Recover the current reservation before selecting points again'using errcode='40001';end if;
 select coalesce(sum(l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0))from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)),0)into funded
 from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=wallet.wallet_id and l.policy_id=p_earning_policy;
 if funded<p_points then raise exception 'Insufficient unreserved earned points'using errcode='22023';end if;
 if exists(select 1 from private.mixed_points_refund_reviews v join private.mixed_points_earned_lots l using(lot_id)where l.wallet_id=wallet.wallet_id and not exists(select 1 from private.mixed_points_review_decisions x where x.lot_id=v.lot_id))then raise exception 'Wallet requires independent owner refund review'using errcode='55000';end if;
 select *into earning from private.mixed_points_policy_versions where version_id=p_earning_policy and branch_id=p_branch;
 if not found then raise exception 'Original earning terms required'using errcode='22023';end if;
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
create or replace function private.lock_mixed_points_consent(p_reservation uuid,p_consent uuid)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.mixed_points_verbal_consents;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;begin
 select *into c from private.mixed_points_verbal_consents where request_id=p_consent;
 if not found then perform private.lock_mixed_points_customer_consent(p_reservation,p_consent);return;end if;
 select *into r from private.mixed_points_reservations where request_id=p_reservation;
 if not found or c.reservation_id<>p_reservation or r.actor_id<>auth.uid()or c.actor_id<>auth.uid()then raise exception 'Own exact verbal approval required'using errcode='42501';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id;
 if private.cashier_cart_actor(i.branch_id)<>c.actor_id or c.session_id is distinct from(auth.jwt()->>'session_id')::uuid then raise exception 'Live actual approving cashier required'using errcode='42501';end if;
 perform 1 from auth.sessions where id=c.session_id and user_id=c.actor_id and(not_after is null or not_after>clock_timestamp())for share;
 if not found then raise exception 'Approving cashier session expired'using errcode='42501';end if;
 perform 1 from private.mixed_points_verbal_policy_current x join private.mixed_points_verbal_policy_versions p on p.request_id=x.version_id where x.branch_id=i.branch_id and x.version_id=c.policy_id and p.allowed for share of x;
 if not found then raise exception 'Owner verbal permission changed'using errcode='42501';end if;
 if not exists(select 1 from private.mixed_points_verbal_policy_current x join private.mixed_points_verbal_policy_versions p on p.request_id=x.version_id where x.branch_id=i.branch_id and x.version_id=c.policy_id and p.allowed)or c.fingerprint<>r.fingerprint or c.notice is distinct from private.mixed_points_verbal_notice(c.language,private.mixed_loyalty_customer_terms(r.quote))then raise exception 'Current owner permission and exact verbal terms required'using errcode='42501';end if;
end$$;
create or replace function private.issue_mixed_points_invoice(p_request uuid,p_branch uuid,p_reservation uuid,p_consent uuid,p_start timestamptz)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;a private.mixed_points_issue_authorizations;result jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);if p_request is null or p_reservation is null or p_consent is null then raise exception 'Exact points issuance required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-issue:'||p_request,0));
 select *into a from private.mixed_points_issue_authorizations where request_id=p_request;
 if found then
 if a.actor_id<>actor or a.reservation_id<>p_reservation or a.consent_id<>p_consent then raise exception 'Immutable points issuance'using errcode='22023';end if;
 select *into strict r from private.mixed_points_reservations where request_id=p_reservation;select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id;
 return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);end if;
 perform private.lock_mixed_points_consent(p_reservation,p_consent);
 select *into r from private.mixed_points_reservations where request_id=p_reservation and actor_id=actor;
 if not found then raise exception 'Own exact reservation required'using errcode='42501';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id and branch_id=p_branch;
 if(private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'then raise exception 'Original sealed draft changed'using errcode='40001';end if;
 perform 1 from private.mixed_points_policy_current where branch_id=p_branch and version_id=r.spending_policy_id for share;
 if not found then raise exception 'Owner spending terms changed'using errcode='40001';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 if not private.mixed_points_hold_live(r.request_id)or not exists(select 1 from private.mixed_points_policy_current where branch_id=p_branch and version_id=r.spending_policy_id)or exists(select 1 from private.mixed_points_refund_reviews v join private.mixed_points_earned_lots l using(lot_id)where l.wallet_id=r.wallet_id and not exists(select 1 from private.mixed_points_review_decisions x where x.lot_id=v.lot_id))then raise exception 'Current funded reservation and reviewed wallet required'using errcode='55000';end if;
 if exists(select 1 from private.mixed_points_earned_lots l where l.wallet_id=r.wallet_id and coalesce((select sum(x.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=x.reservation_id and z.lot_id=x.lot_id),0))from private.mixed_points_reservation_lots x where x.lot_id=l.lot_id and private.mixed_points_hold_live(x.reservation_id)),0)>l.points-coalesce((select o.points from private.mixed_points_refund_offsets o where o.lot_id=l.lot_id),0)-case when exists(select 1 from private.mixed_points_review_decisions z where z.lot_id=l.lot_id and z.decision='offset_points')then l.points else 0 end)then raise exception 'Earned backing changed; new consent required'using errcode='55000';end if;
 insert into private.mixed_points_issue_authorizations values(p_request,p_reservation,p_consent,actor,txid_current());
 result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 return result||jsonb_build_object('loyalty_reserved',true,'loyalty_committed',false);
end$$;

commit;
