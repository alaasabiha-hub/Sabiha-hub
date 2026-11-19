begin;
-- Private integration kernel: no client grants, no runtime activation and no legacy conversion.
create table private.mixed_points_review_decisions(
 request_id uuid primary key,lot_id uuid not null unique references private.mixed_points_refund_reviews(lot_id),
 actor_id uuid not null references auth.users(id),decision text not null check(decision in('preserve_rights','offset_points')),reason text not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_reservations(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),wallet_id uuid not null references private.mixed_points_wallets(wallet_id),
 intent_id uuid not null unique references private.cashier_loyalty_draft_intents(request_id),
 earning_policy_id uuid not null references private.mixed_points_policy_versions(version_id),
 spending_policy_id uuid not null references private.mixed_points_policy_versions(version_id),
 points bigint not null check(points>0),quote jsonb not null,fingerprint text not null,expires_at timestamptz not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_reservation_lots(
 reservation_id uuid not null references private.mixed_points_reservations(request_id),lot_id uuid not null references private.mixed_points_earned_lots(lot_id),points bigint not null check(points>0),primary key(reservation_id,lot_id));
create index mixed_reserved_lot_lookup on private.mixed_points_reservation_lots(lot_id,reservation_id);
create table private.mixed_points_reservation_consents(
 request_id uuid primary key,reservation_id uuid not null unique references private.mixed_points_reservations(request_id),
 actor_id uuid not null references auth.users(id),session_id uuid not null,link_id uuid references private.offline_customer_trusted_links(link_id),
 fingerprint text not null,language text not null check(language in('ar','en')),notice text not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_reservation_releases(
 request_id uuid primary key,reservation_id uuid not null unique references private.mixed_points_reservations(request_id),actor_id uuid not null references auth.users(id),reason text not null,created_at timestamptz not null default clock_timestamp());
do $$declare n text;begin foreach n in array array['mixed_points_review_decisions','mixed_points_reservations','mixed_points_reservation_lots','mixed_points_reservation_consents','mixed_points_reservation_releases']loop
 execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger immutable_points_reservation before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end loop;end$$;
create function private.decide_mixed_points_refund_review(p_request uuid,p_lot uuid,p_decision text,p_reason text)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;wallet private.mixed_points_wallets;old private.mixed_points_review_decisions;begin
 select w.*into wallet from private.mixed_points_wallets w join private.mixed_points_earned_lots l using(wallet_id)where l.lot_id=p_lot;
 if not found then raise exception 'Review unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(wallet.branch_id);if private.active_staff_role()is distinct from'owner'then raise exception 'Owner review required'using errcode='42501';end if;
 if p_request is null or p_decision is null or p_decision not in('preserve_rights','offset_points')or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit reviewed decision required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-review-command:'||p_request,0));
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||wallet.wallet_id,0));
 select *into old from private.mixed_points_review_decisions where request_id=p_request;
 if found then if old.actor_id<>actor or old.lot_id<>p_lot or old.decision<>p_decision or old.reason<>trim(p_reason)then raise exception 'Immutable review decision'using errcode='22023';end if;
 else
 if not exists(select 1 from private.mixed_points_refund_reviews where lot_id=p_lot)then raise exception 'Actual refund review required'using errcode='22023';end if;
 if exists(select 1 from private.mixed_points_review_decisions where lot_id=p_lot)then raise exception 'Review already decided'using errcode='40001';end if;
 perform private.cashier_cart_actor(wallet.branch_id);if private.active_staff_role()is distinct from'owner'then raise exception 'Current owner required'using errcode='42501';end if;
 insert into private.mixed_points_review_decisions values(p_request,p_lot,actor,p_decision,trim(p_reason),clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'mixed_points_refund_reviewed','mixed_points_lot',p_lot::text,wallet.branch_id,jsonb_build_object('decision',p_decision,'reason',trim(p_reason),'request',p_request));end if;
 return jsonb_build_object('lot',p_lot,'decision',p_decision,'redemption_enabled',false);
end$$;
create function private.mixed_points_hold_live(p_reservation uuid)returns boolean
language sql volatile security invoker set search_path=pg_catalog as $$select exists(select 1 from private.mixed_points_reservations r join private.cashier_loyalty_draft_intents i on i.request_id=r.intent_id join private.cashier_reviewed_drafts d on d.draft_id=i.draft_id and d.version=i.draft_version join private.cashier_draft_subjects b on b.draft_id=d.draft_id and b.version=i.binding_version and b.draft_version=d.version where r.request_id=p_reservation and r.expires_at>clock_timestamp()and not exists(select 1 from private.cashier_invoice_postings p where p.draft_id=d.draft_id)and not exists(select 1 from private.mixed_points_reservation_releases x where x.reservation_id=r.request_id))$$;
create function private.reserve_mixed_points(p_request uuid,p_branch uuid,p_intent uuid,p_earning_policy uuid,p_points bigint)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;i private.cashier_loyalty_draft_intents;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;wallet private.mixed_points_wallets;old private.mixed_points_reservations;
 earning private.mixed_points_policy_versions;spending private.mixed_points_policy_versions;plan jsonb;rules jsonb;fp text;remaining bigint;part bigint;lot record;
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
 for lot in select l.lot_id,l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points)from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)available
 from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=wallet.wallet_id and l.policy_id=p_earning_policy order by l.created_at,l.lot_id loop
 part:=least(remaining,greatest(lot.available,0));if part>0 then insert into private.mixed_points_reservation_lots values(p_request,lot.lot_id,part);remaining:=remaining-part;end if;exit when remaining=0;end loop;
 if remaining<>0 then raise exception 'Insufficient unreserved earned points'using errcode='22023';end if;
 if (private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Seal expired while reserving'using errcode='40001';end if;
 return jsonb_build_object('reservation_id',p_request,'fingerprint',fp,'expires_at',i.expires_at,'balance_reserved',true,'payment_confirmed',false,'quote',plan);
end$$;
create function private.mixed_points_reservation_customer(p_reservation uuid)returns uuid
language plpgsql security definer set search_path=pg_catalog as $$
declare w private.mixed_points_wallets;link private.offline_customer_trusted_links;begin
 if not coalesce(private.has_live_invoice_session(),false)or private.active_staff_role()is not null or not exists(select 1 from auth.users where id=auth.uid()and email_confirmed_at is not null)then raise exception 'Actual confirmed customer session required'using errcode='42501';end if;
 select x.*into w from private.mixed_points_wallets x join private.mixed_points_reservations r using(wallet_id)where r.request_id=p_reservation;
 if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 if w.subject_kind='app_customer'then if w.subject_id<>auth.uid()then raise exception 'Reservation unavailable'using errcode='42501';end if;return null;end if;
 link:=private.require_offline_financial_customer();if link.profile_id<>w.subject_id then raise exception 'Reservation unavailable'using errcode='42501';end if;return link.link_id;
end$$;
create function private.mixed_points_reservation_notice(p_language text,p_terms jsonb)returns text
language sql immutable set search_path=pg_catalog as $$select case p_language when'ar'then 'أوافق على استبدال '||(p_terms->>'points')||' نقطة لهذه الفاتورة فقط، بخصم '||(p_terms->>'payable_discount')||' جنيه والمبلغ المطلوب '||(p_terms->>'amount_due')||' جنيه. لا تعد هذه الموافقة تأكيدًا للدفع. يمكن سحبها قبل إصدار الفاتورة.'when'en'then 'I agree to redeem '||(p_terms->>'points')||' points for this invoice only, with a discount of '||(p_terms->>'payable_discount')||' EGP and amount due '||(p_terms->>'amount_due')||' EGP. This does not confirm payment. I can withdraw before invoice issuance.'end$$;
create function private.accept_mixed_points_reservation(p_request uuid,p_reservation uuid,p_fingerprint text,p_language text,p_notice text)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v private.mixed_points_reservations;prior private.mixed_points_reservation_consents;link uuid;terms jsonb;begin
 if p_request is null or p_language is null or p_language not in('ar','en')or p_fingerprint is null or p_notice is null then raise exception 'Explicit financial consent required'using errcode='22023';end if;
 link:=private.mixed_points_reservation_customer(p_reservation);
 select *into strict v from private.mixed_points_reservations where request_id=p_reservation;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||v.wallet_id,0));
 select *into prior from private.mixed_points_reservation_consents where request_id=p_request;
 if found then
 if prior.actor_id<>auth.uid()or prior.reservation_id<>p_reservation or prior.fingerprint<>p_fingerprint or prior.language<>p_language or prior.notice<>p_notice then raise exception 'Immutable financial consent'using errcode='22023';end if;
 return jsonb_build_object('consent_id',p_request,'accepted',private.mixed_points_hold_live(p_reservation),'payment_confirmed',false);end if;
 terms:=private.mixed_loyalty_customer_terms(v.quote);
 if not private.mixed_points_hold_live(p_reservation)or v.fingerprint<>p_fingerprint or p_notice is distinct from private.mixed_points_reservation_notice(p_language,terms)then raise exception 'Exact current financial terms required'using errcode='40001';end if;
 if exists(select 1 from private.mixed_points_reservation_consents where reservation_id=p_reservation)then raise exception 'Already consented'using errcode='40001';end if;
 insert into private.mixed_points_reservation_consents values(p_request,p_reservation,auth.uid(),(auth.jwt()->>'session_id')::uuid,link,p_fingerprint,p_language,p_notice,clock_timestamp());
 return jsonb_build_object('consent_id',p_request,'accepted',true,'payment_confirmed',false);
end$$;
create function private.release_mixed_points_reservation(p_request uuid,p_reservation uuid,p_reason text)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v private.mixed_points_reservations;w private.mixed_points_wallets;old private.mixed_points_reservation_releases;begin
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Release request and reason required'using errcode='22023';end if;
 select *into v from private.mixed_points_reservations where request_id=p_reservation;if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 select *into strict w from private.mixed_points_wallets where wallet_id=v.wallet_id;
 if private.active_staff_role()is not null then if private.cashier_cart_actor(w.branch_id)<>v.actor_id then raise exception 'Own operator reservation required'using errcode='42501';end if;
 else perform private.mixed_points_reservation_customer(p_reservation);end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||v.wallet_id,0));
 select *into old from private.mixed_points_reservation_releases where request_id=p_request;
 if found then if old.actor_id<>auth.uid()or old.reservation_id<>p_reservation or old.reason<>trim(p_reason)then raise exception 'Immutable release request'using errcode='22023';end if;
 elsif not exists(select 1 from private.mixed_points_reservation_releases where reservation_id=p_reservation)then
 insert into private.mixed_points_reservation_releases values(p_request,p_reservation,auth.uid(),trim(p_reason),clock_timestamp());end if;
 return jsonb_build_object('reservation_id',p_reservation,'released',true,'payment_confirmed',false);
end$$;
revoke all on function private.decide_mixed_points_refund_review(uuid,uuid,text,text),private.mixed_points_hold_live(uuid),private.reserve_mixed_points(uuid,uuid,uuid,uuid,bigint),private.mixed_points_reservation_customer(uuid),private.mixed_points_reservation_notice(text,jsonb),private.accept_mixed_points_reservation(uuid,uuid,text,text,text),private.release_mixed_points_reservation(uuid,uuid,text)from public,anon,authenticated,service_role;
commit;
