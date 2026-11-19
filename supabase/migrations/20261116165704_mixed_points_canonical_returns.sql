begin;
create table private.mixed_points_spend_lines(reservation_id uuid not null references private.mixed_points_reservations(request_id),line_id text not null,quantity integer not null check(quantity>0),points bigint not null check(points>=0),primary key(reservation_id,line_id));
create table private.mixed_points_returned_units(reservation_id uuid not null,line_id text not null,unit_number integer not null check(unit_number>0),source_id uuid not null,source_kind text not null check(source_kind in('refund','credit','full')),points bigint not null check(points>=0),restored boolean not null,created_at timestamptz not null default clock_timestamp(),primary key(reservation_id,line_id,unit_number),foreign key(reservation_id,line_id)references private.mixed_points_spend_lines(reservation_id,line_id));
create table private.mixed_points_lot_restorations(reservation_id uuid not null,lot_id uuid not null,source_id uuid not null,points bigint not null check(points>0),created_at timestamptz not null default clock_timestamp(),primary key(reservation_id,lot_id,source_id),foreign key(reservation_id,lot_id)references private.mixed_points_reservation_lots(reservation_id,lot_id));
create index restored_points_by_lot on private.mixed_points_lot_restorations(lot_id,reservation_id);
do $$declare n text;begin foreach n in array array['mixed_points_spend_lines','mixed_points_returned_units','mixed_points_lot_restorations']loop
 execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);execute format('create trigger immutable_point_returns before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end loop;end$$;
create function private.capture_mixed_points_spend_lines()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare r private.mixed_points_reservations;begin select *into strict r from private.mixed_points_reservations where request_id=new.reservation_id;
 with source as(select v->>'line_id'id,(v->>'quantity')::integer q,(v->>'loyalty_gross_discount_exact')::numeric weight from jsonb_array_elements(r.quote->'lines')v),shares as(select *,r.points*weight/sum(weight)over()raw from source),ranked as(select *,floor(raw)whole,row_number()over(order by raw-floor(raw)desc,id)priority,sum(floor(raw))over()allocated from shares)
 insert into private.mixed_points_spend_lines select r.request_id,id,q,whole+case when priority<=r.points-allocated then 1 else 0 end from ranked;return new;end$$;
create trigger capture_original_point_unit_allocation after insert on private.mixed_points_invoice_bindings for each row execute function private.capture_mixed_points_spend_lines();
create function private.restore_mixed_points_units(p_invoice text,p_source uuid,p_kind text)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare r private.mixed_points_reservations;policy private.mixed_points_policy_versions;amount bigint;remaining bigint;part bigint;lot record;restore boolean;begin
 select x.*into r from private.mixed_points_reservations x join private.mixed_points_invoice_bindings b on b.reservation_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 select *into strict policy from private.mixed_points_policy_versions where version_id=r.spending_policy_id;restore:=policy.rules->>'cancellation'='restore_points';
 if p_kind='credit'then
 if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid credit required'using errcode='55000';end if;
 elsif p_kind='refund'then
 if not exists(select 1 from private.mixed_points_spend_commits where reservation_id=r.request_id)or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.refund_part_id=f.request_id and e.invoice_id=p_invoice and e.event_type='refund'and e.amount=f.amount)))then raise exception 'Confirmed canonical refund required'using errcode='55000';end if;
 elsif p_kind='full'then
 if not exists(select 1 from private.mixed_points_spend_commits where reservation_id=r.request_id)or not exists(select 1 from public.business_payment_events where payment_id=p_source and invoice_id=p_invoice and event_type='refund'and refund_part_id is null)then raise exception 'Confirmed full refund required'using errcode='55000';end if;
 else raise exception 'Canonical returns only'using errcode='22023';end if;
 with candidates as(
 select sl.line_id,n.unit_number,sl.points,sl.quantity from private.mixed_points_spend_lines sl cross join lateral generate_series(1,sl.quantity)n(unit_number)
 where sl.reservation_id=r.request_id and(p_kind='full'or p_kind='credit'and exists(select 1 from private.cashier_unpaid_service_credits c where c.request_id=p_source and c.line_id=sl.line_id and c.unit_number=n.unit_number)or p_kind='refund'and exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=p_source and f.line_id=sl.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[n.unit_number])else n.unit_number>(f.snapshot->>'previous_quantity')::integer and n.unit_number<=(f.snapshot->>'cumulative_quantity')::integer end)))),inserted as(
 insert into private.mixed_points_returned_units(reservation_id,line_id,unit_number,source_id,source_kind,points,restored)
 select r.request_id,line_id,unit_number,p_source,p_kind,floor(points::numeric*unit_number/quantity)-floor(points::numeric*(unit_number-1)/quantity),restore from candidates
 on conflict(reservation_id,line_id,unit_number)do nothing returning points,restored)
 select coalesce(sum(points)filter(where restored),0)into amount from inserted;
 remaining:=amount;
 for lot in select a.lot_id,a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0)available from private.mixed_points_reservation_lots a where reservation_id=r.request_id order by a.lot_id loop
 part:=least(remaining,lot.available);if part>0 then insert into private.mixed_points_lot_restorations(reservation_id,lot_id,source_id,points)values(r.request_id,lot.lot_id,p_source,part);remaining:=remaining-part;end if;exit when remaining=0;end loop;
 if remaining<>0 then raise exception 'Restoration exceeds original points'using errcode='55000';end if;
 if p_kind='credit'and private.cashier_invoice_payable(p_invoice)=0 and not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and event_type='sale')then
 insert into private.mixed_points_reservation_releases(request_id,reservation_id,actor_id,reason)values(p_source,r.request_id,auth.uid(),'Canonical unpaid service cancellation leaves no collectible amount')on conflict(reservation_id)do nothing;end if;
end$$;
create function private.mixed_points_canonical_return_received()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_table_name='cashier_unpaid_service_credits'then perform private.restore_mixed_points_units(new.invoice_id,new.request_id,'credit');
 elsif tg_table_name='cashier_partial_refund_lines'then
 if exists(select 1 from private.cashier_partial_refunds f where f.request_id=new.request_id and f.amount=0)then perform private.restore_mixed_points_units(new.invoice_id,new.request_id,'refund');end if;
 elsif new.event_type='refund'then perform private.restore_mixed_points_units(new.invoice_id,coalesce(new.refund_part_id,new.payment_id),case when new.refund_part_id is null then'full'else'refund'end);end if;return new;end$$;
create trigger points_return_after_verified_refund after insert on public.business_payment_events for each row execute function private.mixed_points_canonical_return_received();
create trigger points_return_after_unpaid_credit after insert on private.cashier_unpaid_service_credits for each row execute function private.mixed_points_canonical_return_received();
create constraint trigger points_return_after_zero_refund after insert on private.cashier_partial_refund_lines deferrable initially deferred for each row execute function private.mixed_points_canonical_return_received();
-- Only actual returned units release their original lot rights; no current-rate repricing.
create or replace function private.reserve_mixed_points(p_request uuid,p_branch uuid,p_intent uuid,p_earning_policy uuid,p_points bigint)returns jsonb
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
 for lot in select l.lot_id,l.points-coalesce(o.points,0)-case when x.decision='offset_points'then l.points else 0 end-coalesce((select sum(a.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=a.reservation_id and z.lot_id=a.lot_id),0))from private.mixed_points_reservation_lots a where a.lot_id=l.lot_id and private.mixed_points_hold_live(a.reservation_id)),0)available
 from private.mixed_points_earned_lots l left join private.mixed_points_refund_offsets o using(lot_id)left join private.mixed_points_review_decisions x using(lot_id)where l.wallet_id=wallet.wallet_id and l.policy_id=p_earning_policy order by l.created_at,l.lot_id loop
 part:=least(remaining,greatest(lot.available,0));if part>0 then insert into private.mixed_points_reservation_lots values(p_request,lot.lot_id,part);remaining:=remaining-part;end if;exit when remaining=0;end loop;
 if remaining<>0 then raise exception 'Insufficient unreserved earned points'using errcode='22023';end if;
 if (private.get_cashier_loyalty_draft_intent(p_branch,p_intent))->>'state'is distinct from'current'then raise exception 'Seal expired while reserving'using errcode='40001';end if;
 return jsonb_build_object('reservation_id',p_request,'fingerprint',fp,'expires_at',i.expires_at,'balance_reserved',true,'payment_confirmed',false,'quote',plan);
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
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 if not private.mixed_points_hold_live(r.request_id)or not exists(select 1 from private.mixed_points_policy_current where branch_id=p_branch and version_id=r.spending_policy_id)or exists(select 1 from private.mixed_points_refund_reviews v join private.mixed_points_earned_lots l using(lot_id)where l.wallet_id=r.wallet_id and not exists(select 1 from private.mixed_points_review_decisions x where x.lot_id=v.lot_id))then raise exception 'Current funded reservation and reviewed wallet required'using errcode='55000';end if;
 if exists(select 1 from private.mixed_points_earned_lots l where l.wallet_id=r.wallet_id and coalesce((select sum(x.points-coalesce((select sum(z.points)from private.mixed_points_lot_restorations z where z.reservation_id=x.reservation_id and z.lot_id=x.lot_id),0))from private.mixed_points_reservation_lots x where x.lot_id=l.lot_id and private.mixed_points_hold_live(x.reservation_id)),0)>l.points-coalesce((select o.points from private.mixed_points_refund_offsets o where o.lot_id=l.lot_id),0)-case when exists(select 1 from private.mixed_points_review_decisions z where z.lot_id=l.lot_id and z.decision='offset_points')then l.points else 0 end)then raise exception 'Earned backing changed; new consent required'using errcode='55000';end if;
 insert into private.mixed_points_issue_authorizations values(p_request,p_reservation,p_consent,actor,txid_current());
 result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 return result||jsonb_build_object('loyalty_reserved',true,'loyalty_committed',false);
end$$;

revoke all on function private.capture_mixed_points_spend_lines(),private.restore_mixed_points_units(text,uuid,text),private.mixed_points_canonical_return_received()from public,anon,authenticated,service_role;
create function private.release_points_for_cancelled_draft()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 insert into private.mixed_points_reservation_releases(request_id,reservation_id,actor_id,reason)
 select gen_random_uuid(),r.request_id,new.actor_id,'Canonical draft cancellation: '||new.request_id::text from private.mixed_points_reservations r join private.cashier_loyalty_draft_intents i on i.request_id=r.intent_id
 where i.draft_id=new.draft_id and not exists(select 1 from private.mixed_points_invoice_bindings b where b.reservation_id=r.request_id)on conflict(reservation_id)do nothing;return new;end$$;
revoke all on function private.release_points_for_cancelled_draft()from public,anon,authenticated,service_role;
do $$begin if to_regclass('private.cashier_draft_cancellations')is not null then execute 'create trigger release_points_after_draft_cancel after insert on private.cashier_draft_cancellations for each row execute function private.release_points_for_cancelled_draft()';end if;end$$;
commit;
