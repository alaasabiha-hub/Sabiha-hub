begin;
create table private.mixed_points_issue_authorizations(request_id uuid primary key,reservation_id uuid not null unique references private.mixed_points_reservations(request_id),consent_id uuid not null unique references private.mixed_points_reservation_consents(request_id),actor_id uuid not null references auth.users(id),creator_xid bigint not null);
create table private.mixed_points_invoice_bindings(invoice_id text primary key references private.cashier_invoice_postings(invoice_id),reservation_id uuid not null unique references private.mixed_points_reservations(request_id),created_at timestamptz not null default clock_timestamp());
create table private.mixed_points_spend_commits(reservation_id uuid primary key references private.mixed_points_reservations(request_id),payment_id uuid not null unique references public.business_payment_events(payment_id),created_at timestamptz not null default clock_timestamp());
do $$declare n text;begin foreach n in array array['mixed_points_issue_authorizations','mixed_points_invoice_bindings','mixed_points_spend_commits']loop
 execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);execute format('create trigger immutable_points_bridge before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end loop;end$$;
create or replace function private.mixed_points_hold_live(p_reservation uuid)returns boolean
language sql volatile security invoker set search_path=pg_catalog as $$select exists(select 1 from private.mixed_points_reservations r where r.request_id=p_reservation and not exists(select 1 from private.mixed_points_reservation_releases x where x.reservation_id=r.request_id)and(exists(select 1 from private.mixed_points_invoice_bindings z where z.reservation_id=r.request_id)or r.expires_at>clock_timestamp()and exists(select 1 from private.cashier_loyalty_draft_intents i join private.cashier_reviewed_drafts d on d.draft_id=i.draft_id and d.version=i.draft_version join private.cashier_draft_subjects b on b.draft_id=d.draft_id and b.version=i.binding_version and b.draft_version=d.version where i.request_id=r.intent_id and not exists(select 1 from private.cashier_invoice_postings p where p.draft_id=d.draft_id))))$$;
-- Called before draft/catalogue/wallet locks. Do not impersonate the consenting customer.
create function private.lock_mixed_points_consent(p_reservation uuid,p_consent uuid)returns void
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.mixed_points_reservation_consents;r private.mixed_points_reservations;w private.mixed_points_wallets;l private.offline_customer_trusted_links;a auth.users;begin
 select *into c from private.mixed_points_reservation_consents where request_id=p_consent and reservation_id=p_reservation;
 if not found then raise exception 'Actual independent financial consent required'using errcode='42501';end if;
 select *into strict r from private.mixed_points_reservations where request_id=p_reservation;select *into strict w from private.mixed_points_wallets where wallet_id=r.wallet_id;
 if c.link_id is not null then
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||c.actor_id,0));perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||w.subject_id,0));
 select *into l from private.offline_customer_trusted_links where link_id=c.link_id and auth_user_id=c.actor_id and profile_id=w.subject_id and revoked_at is null for share;
 if not found or w.subject_kind<>'offline_profile'then raise exception 'Current independently approved link required'using errcode='42501';end if;
 lock table private.offline_customer_contacts in share mode;
 if private.offline_claim_contact_hash(l.profile_id)is distinct from l.contact_hash then raise exception 'Contact evidence changed'using errcode='42501';end if;
 if not exists(select 1 from private.offline_claim_requests cr join private.offline_claim_decisions de on de.claim_id=cr.request_id where cr.request_id=l.claim_id and cr.actor_id=c.actor_id and cr.profile_id=w.subject_id and cr.receipt_key=l.receipt_id and cr.outcome='pending_owner_review'and cr.email_hash=l.email_hash and cr.email_confirmed_at=l.email_confirmed_at and cr.contact_hash=l.contact_hash and de.owner_id=l.approved_by and de.result->>'link_id'=l.link_id::text and(de.decision='approve_with_secret'and cr.secret_proved or de.decision='approve_exception'and cr.mode='lost_secret_review'and de.evidence_type in('in_person_original_service_documents','in_person_independent_continuity_witness')))then raise exception 'Original owner continuity evidence required'using errcode='42501';end if;
 elsif w.subject_kind<>'app_customer'or w.subject_id<>c.actor_id then raise exception 'Own actual customer required'using errcode='42501';end if;
 select *into a from auth.users where id=c.actor_id for share;
 if not found or a.deleted_at is not null or a.email_confirmed_at is null or(a.banned_until is not null and a.banned_until>clock_timestamp())or(c.link_id is not null and(a.email_confirmed_at is distinct from l.email_confirmed_at or extensions.digest(lower(trim(a.email)),'sha256')is distinct from l.email_hash))or exists(select 1 from public.staff_profiles where user_id=c.actor_id and is_active)then raise exception 'Current independent confirmed customer required'using errcode='42501';end if;
 perform 1 from auth.sessions where id=c.session_id and user_id=c.actor_id and(not_after is null or not_after>clock_timestamp())for share;if not found then raise exception 'Consenting session expired'using errcode='42501';end if;
 if c.fingerprint<>r.fingerprint or c.notice is distinct from private.mixed_points_reservation_notice(c.language,private.mixed_loyalty_customer_terms(r.quote))then raise exception 'Exact unchanged financial assent required'using errcode='42501';end if;
end$$;
create function private.apply_mixed_points_issuing_quote(p_request uuid,p_quote jsonb)returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare permit private.mixed_points_issue_authorizations;r private.mixed_points_reservations;i private.cashier_loyalty_draft_intents;begin
 select *into permit from private.mixed_points_issue_authorizations where request_id=p_request;
 if not found then return p_quote;end if;
 if permit.creator_xid<>txid_current()or permit.actor_id<>auth.uid()then raise exception 'Same transaction issuer authorization required'using errcode='42501';end if;
 select *into strict r from private.mixed_points_reservations where request_id=permit.reservation_id;select *into strict i from private.cashier_loyalty_draft_intents where request_id=r.intent_id;
 if not private.mixed_points_hold_live(r.request_id)or(p_quote-'as_of')is distinct from(i.witness->'quote')then raise exception 'Unchanged funded quote required'using errcode='40001';end if;
 return r.quote||jsonb_build_object('quote_only',false,'consent_authorized',true,'balance_reserved',true,'loyalty_reservation_id',r.request_id);
end$$;
create function private.bind_mixed_points_invoice()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare a private.mixed_points_issue_authorizations;begin
 select *into a from private.mixed_points_issue_authorizations where request_id=new.request_id;
 if found then
 if a.creator_xid<>txid_current()or new.creator_xid<>txid_current()or a.actor_id<>new.actor_id or (new.quote->>'loyalty_reservation_id')is distinct from a.reservation_id::text then raise exception 'Atomic points invoice binding required'using errcode='55000';end if;
 insert into private.mixed_points_invoice_bindings(invoice_id,reservation_id)values(new.invoice_id,a.reservation_id);end if;return new;
end$$;
create trigger bind_atomic_mixed_points_invoice after insert on private.cashier_invoice_postings for each row execute function private.bind_mixed_points_invoice();
create function private.issue_mixed_points_invoice(p_request uuid,p_branch uuid,p_reservation uuid,p_consent uuid,p_start timestamptz)returns jsonb
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
 if exists(select 1 from private.mixed_points_earned_lots l where l.wallet_id=r.wallet_id and coalesce((select sum(x.points)from private.mixed_points_reservation_lots x where x.lot_id=l.lot_id and private.mixed_points_hold_live(x.reservation_id)),0)>l.points-coalesce((select o.points from private.mixed_points_refund_offsets o where o.lot_id=l.lot_id),0)-case when exists(select 1 from private.mixed_points_review_decisions z where z.lot_id=l.lot_id and z.decision='offset_points')then l.points else 0 end)then raise exception 'Earned backing changed; new consent required'using errcode='55000';end if;
 insert into private.mixed_points_issue_authorizations values(p_request,p_reservation,p_consent,actor,txid_current());
 result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 return result||jsonb_build_object('loyalty_reserved',true,'loyalty_committed',false);
end$$;
create function private.commit_mixed_points_collection()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare r private.mixed_points_reservations;begin
 if new.event_type<>'sale'then return new;end if;
 select x.*into r from private.mixed_points_reservations x join private.mixed_points_invoice_bindings b on b.reservation_id=x.request_id where b.invoice_id=new.invoice_id;if not found then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-wallet-id:'||r.wallet_id,0));
 if not private.mixed_points_hold_live(r.request_id)or new.amount<>private.cashier_invoice_payable(new.invoice_id)or new.method not in('cash','card_terminal')or(new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.amount=new.amount))then raise exception 'Trusted full collection required for points commitment'using errcode='55000';end if;
 insert into private.mixed_points_spend_commits values(r.request_id,new.payment_id,clock_timestamp())on conflict(reservation_id)do nothing;return new;
end$$;
create trigger commit_mixed_points_after_collection after insert on public.business_payment_events for each row execute function private.commit_mixed_points_collection();
-- A discount on an issued invoice stays backed while unpaid. No silent hold expiry or customer withdrawal.
create function private.guard_bound_points_release()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare invoice text;begin select invoice_id into invoice from private.mixed_points_invoice_bindings where reservation_id=new.reservation_id;
 if found and(exists(select 1 from public.business_payment_events where invoice_id=invoice and event_type='sale')or private.cashier_invoice_payable(invoice)>0)then raise exception 'Issued discount remains reserved; use canonical cancellation/refund'using errcode='55000';end if;return new;end$$;
create trigger guard_issued_points_release before insert on private.mixed_points_reservation_releases for each row execute function private.guard_bound_points_release();
revoke all on function private.lock_mixed_points_consent(uuid,uuid),private.apply_mixed_points_issuing_quote(uuid,jsonb),private.bind_mixed_points_invoice(),private.issue_mixed_points_invoice(uuid,uuid,uuid,uuid,timestamptz),private.commit_mixed_points_collection(),private.guard_bound_points_release()from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION private.issue_cashier_mixed_invoice(p_request uuid, p_branch uuid, p_draft uuid, p_expected_draft_version integer, p_expected_binding_version integer, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;prior private.cashier_invoice_postings;
 payload jsonb;current_quote jsonb;subject jsonb;invoice text;work uuid;line jsonb;number text;stock record;service public.business_catalog_items;next_slot timestamptz;zone text;unit integer;child uuid;booking uuid;staff uuid[];names jsonb;unit_base numeric;unit_payable numeric;resource text;customer_ref uuid;vehicle_ref uuid;contact_phone text;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_draft_version is null or p_expected_binding_version is null then raise exception 'Saved draft and subject versions required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'draft',p_draft,'draft_version',p_expected_draft_version,'binding_version',p_expected_binding_version,'service_start',p_start);
 perform pg_advisory_xact_lock(hashtextextended('cashier-issue:'||p_request,0));select *into prior from private.cashier_invoice_postings where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable issuance request'using errcode='22023';end if;
 return jsonb_build_object('invoice_id',prior.invoice_id,'order_id',prior.order_id,'invoice_number',(select display_number from public.business_invoices where invoice_id=prior.invoice_id),'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Draft unavailable'using errcode='42501';end if;
 if d.version<>p_expected_draft_version or exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then raise exception 'Draft changed or already issued'using errcode='40001';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft for update;
 if not found or b.version<>p_expected_binding_version or b.draft_version<>d.version then raise exception 'Current customer/car confirmation required'using errcode='40001';end if;
 if b.subject_kind='app_customer'then customer_ref:=b.subject_id;vehicle_ref:=b.car_id;
 elsif b.subject_kind='offline_profile'then
 perform 1 from private.offline_customer_profiles where profile_id=b.subject_id and created_branch_id=p_branch for share;
 if not found then raise exception 'Typed offline customer unavailable'using errcode='42501';end if;
 perform 1 from private.offline_customer_car_refs where profile_id=b.subject_id and car_ref_id=b.car_id for share;
 if not found then raise exception 'Owned offline car unavailable'using errcode='42501';end if;
 else raise exception 'Explicit supported customer source required'using errcode='22023';end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by c.item_id for update;
 perform 1 from private.owner_tax_active t where t.branch_id=p_branch and t.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by t.item_id for share;
 current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->'items',d.payload->>'discount_mode',(d.payload->>'discount_value')::numeric);
 if(current_quote-'as_of')is distinct from(d.quote-'as_of')then raise exception 'Prices, stock or classification changed; save and confirm again'using errcode='40001';end if;
 current_quote:=private.apply_mixed_points_issuing_quote(p_request,current_quote);
 if not exists(select 1 from jsonb_array_elements(current_quote->'lines')where value->>'item_type'='service')then raise exception 'Use the existing product issuing endpoint'using errcode='22023';end if;
 if p_start is null or not isfinite(p_start)or p_start<=clock_timestamp()or current_quote->>'staff_configuration_complete'<>'true'then raise exception 'Future service start and configured service workers required'using errcode='22023';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(current_quote->'lines')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'One-visit work must fit a business day; plan separate visits'using errcode='22023';end if;
 if exists(select 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(current_quote->'lines'))and c.item_type='product'and c.stock_quantity is null)then raise exception 'Tracked product stock required'using errcode='55000';end if;
 if(current_quote->>'total')::numeric<=0 then raise exception 'Positive payable invoice required; use the separately authorized reward route'using errcode='55000';end if;
 perform 1 from public.customers where id=b.subject_id for share;
 perform 1 from public.vehicles where id=b.car_id for share;
 subject:=private.cashier_subject_snapshot(p_branch,b.subject_kind,b.subject_id,b.car_id);
 if subject<>b.subject_snapshot then raise exception 'Customer or car changed; confirm again'using errcode='40001';end if;
 if b.subject_kind='app_customer'then select phone into contact_phone from public.customers where id=b.subject_id;
 else select phone_e164 into contact_phone from private.offline_customer_contacts where profile_id=b.subject_id order by created_at desc,contact_id limit 1;end if;
 invoice:=gen_random_uuid()::text;work:=gen_random_uuid();
 insert into private.cashier_invoice_postings values(p_request,actor,payload,p_draft,invoice,work,p_branch,current_quote,subject,txid_current(),clock_timestamp());
 if b.subject_kind='offline_profile'then insert into private.cashier_offline_invoice_subjects values(invoice,b.subject_id,b.car_id,p_branch,txid_current());end if;
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,order_type,branch_id,created_by)
 values(work,invoice,customer_ref,subject->>'name',contact_phone,subject->'car'->>'plate_number','خدمات ومنتجات / Services and products','mixed',p_branch,actor::text);
 for line in select value from jsonb_array_elements(current_quote->'lines')loop
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(work,(line->>'item_id')::uuid,line->>'name',(line->>'quantity')::integer,(line->>'unit_price')::numeric,(line->>'catalog_amount')::numeric);
 end loop;
 select time_zone into zone from public.business_branches where branch_id=p_branch;
 perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||b.car_id,0));
 for resource in select distinct c.resource_key from jsonb_array_elements(current_quote->'lines')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service'order by c.resource_key loop
 perform private.lock_service_resource_days(p_branch,resource,array[(p_start at time zone zone)::date,(p_start at time zone zone)::date+1]);end loop;
 next_slot:=p_start;
 for line in select value from jsonb_array_elements(current_quote->'lines')where value->>'item_type'='service'order by value->>'line_id'loop
 select *into strict service from public.business_catalog_items where item_id=(line->>'item_id')::uuid;
 select array_agg(value::uuid order by value::uuid)into staff from jsonb_array_elements_text(line->'staff_ids');
 select jsonb_agg(full_name order by user_id)into names from public.staff_profiles where user_id=any(staff);
 for unit in 1..(line->>'quantity')::integer loop
 if(((next_slot at time zone zone)::date+(next_slot at time zone zone)::time)at time zone zone)<>next_slot then raise exception 'Ambiguous local service time requires review'using errcode='22023';end if;
 child:=gen_random_uuid();booking:=gen_random_uuid();
 unit_base:=round((line->>'base_before_discount_exact')::numeric*unit/(line->>'quantity')::numeric,5)-round((line->>'base_before_discount_exact')::numeric*(unit-1)/(line->>'quantity')::numeric,5);
 unit_payable:=(private.cashier_refund_slice_core(current_quote,line->>'line_id',unit-1,1)->>'amount')::numeric;
 insert into private.cashier_service_worklines values(child,booking,invoice,line->>'line_id',unit,p_branch,service.item_id,unit_base,unit_payable,txid_current());
 if b.subject_kind='offline_profile'then insert into private.cashier_offline_work_subjects values(child,booking,invoice);end if;
 insert into public.bookings(id,customer_id,branch_id,vehicle_id,catalog_item_id,service_name,booking_date,booking_time,status,assigned_staff_ids,assigned_workers,duration_minutes,resource_key)
 values(booking,customer_ref,p_branch,vehicle_ref,service.item_id,service.name,(next_slot at time zone zone)::date,(next_slot at time zone zone)::time,'confirmed',staff,names,service.duration_minutes,service.resource_key);
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,booking_id,order_type,branch_id,assigned_staff_ids,assigned_workers,created_by)
 values(child,'WORK-'||booking,customer_ref,subject->>'name',contact_phone,subject->'car'->>'plate_number',service.name,booking,'service',p_branch,staff,names,actor::text);
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(child,service.item_id,service.name,1,service.price,service.price);
 next_slot:=next_slot+make_interval(mins=>service.duration_minutes);
 end loop;end loop;
 insert into public.business_invoices(invoice_id,order_id,plate_number,service_name,total,discount,sale_type,payment_method,commission_total,commission_share,workers,branch_id,created_by,commission_model)
 values(invoice,work,subject->'car'->>'plate_number','خدمات ومنتجات / Services and products',(current_quote->>'total')::numeric,(current_quote->>'invoice_discount_exact')::numeric,'mixed','cash_on_receipt',0,0,'[]',p_branch,actor::text,'cashier_frozen_lines');
 for stock in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(current_quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid where c.item_type='product'group by c.item_id,c.stock_quantity order by c.item_id loop
 if stock.quantity>stock.stock_quantity then raise exception 'Insufficient stock'using errcode='55000';end if;
 update public.business_catalog_items set stock_quantity=stock.stock_quantity-stock.quantity,updated_at=clock_timestamp()where item_id=stock.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(p_request,p_branch,stock.item_id,'pos_sale',stock.stock_quantity,stock.stock_quantity-stock.quantity,'Issued cashier product invoice',actor,invoice);
 end loop;
 select display_number into number from public.business_invoices where invoice_id=invoice;
 update public.business_orders set order_number=number where order_id=work;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'cashier_invoice_issued','business_invoices',invoice,p_branch,jsonb_build_object('draft_id',p_draft,'order_id',work,'total',current_quote->'total','payment_confirmed',false));
 return jsonb_build_object('invoice_id',invoice,'order_id',work,'invoice_number',number,'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);
end$function$;
commit;
