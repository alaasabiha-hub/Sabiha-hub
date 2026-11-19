begin;
-- Private owner-only adapter, no public RPC or runtime activation. Canonical
-- reservation claims remain the ONLY allocator, including after quote expiry.
create table private.mixed_visit_issue_authorizations(request_id uuid primary key,group_id uuid not null unique references private.mixed_visit_groups(request_id),consent_id uuid not null unique references private.mixed_visit_verbal_consents(request_id),actor_id uuid not null references public.staff_profiles(user_id),creator_xid bigint not null);
create table private.mixed_visit_invoice_bindings(invoice_id text primary key references private.cashier_invoice_postings(invoice_id),group_id uuid not null unique references private.mixed_visit_groups(request_id),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.mixed_visit_collection_commits(group_id uuid primary key references private.mixed_visit_groups(request_id),payment_id uuid not null unique references public.business_payment_events(payment_id),created_at timestamptz not null default clock_timestamp());
do $$declare n text;begin foreach n in array array['mixed_visit_issue_authorizations','mixed_visit_invoice_bindings','mixed_visit_collection_commits']loop execute format('alter table private.%I enable row level security',n);execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);execute format('create trigger immutable_visit_bridge before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',n);end loop;end$$;
create function private.mixed_visit_component_pinned(p_reservation uuid)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select exists(select 1 from private.mixed_visit_components c join private.mixed_visit_invoice_bindings b using(group_id)where c.reservation_id=p_reservation)$$;
create function private.lock_mixed_visit_backing(p_group uuid)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare g private.mixed_visit_groups;begin
 select *into strict g from private.mixed_visit_groups where request_id=p_group and actor_id=auth.uid();
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 -- Same lock order as canonical sync: profile, then actual source invoices.
 perform 1 from public.business_invoices i where exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id where c.group_id=p_group and h.released_at is null and e.invoice_id=i.invoice_id)order by i.invoice_id for update of i;
 if exists(select 1 from private.mixed_visit_components c join private.offline_reward_reservation_commands d on d.request_id=c.reservation_id where c.group_id=p_group and(d.state<>'active'or(select count(*)from private.reward_credit_claims h where h.reserve_request_id=c.reservation_id and h.released_at is null)<>(select threshold_visits from private.service_reward_quotes where quote_id=c.quote_id)))or exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id where c.group_id=p_group and h.released_at is null and(e.offline_profile_id is distinct from g.profile_id or private.reward_credit_refund(e.id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund')))then raise exception 'Original visit backing changed; canonical review/cancellation required'using errcode='55000';end if;
 if exists(select 1 from private.reward_refund_reviews v where v.offline_profile_id=g.profile_id and v.closed_at is null and not exists(select 1 from private.reward_credit_claims h where h.debt_id=v.review_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is null))then raise exception 'Outstanding canonical source refund review required'using errcode='55000';end if;
end$$;
create function private.apply_mixed_visit_issuing_quote(p_request uuid,p_quote jsonb)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;begin
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;if not found then return p_quote;end if;
 if a.actor_id<>auth.uid()or a.creator_xid<>txid_current()then raise exception 'Same transaction visit authorization required'using errcode='42501';end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 perform private.lock_mixed_visit_backing(g.request_id);
 if not private.mixed_visit_verbal_current(a.consent_id)or(p_quote-'as_of')is distinct from(i.witness->'quote')then raise exception 'Current exact sealed quote and independent verbal assent required'using errcode='40001';end if;
 -- Pin current policy/session while issuer completes, recheck AFTER every wait.
 perform 1 from private.owner_mixed_visit_policy_current where branch_id=g.branch_id and rules_version_id=g.rules_version_id and version_id=g.policy_id for share;
 if not found then raise exception 'Current owner visit policy required'using errcode='40001';end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 perform 1 from auth.sessions where id=(auth.jwt()->>'session_id')::uuid and user_id=auth.uid()and(not_after is null or not_after>clock_timestamp())for share skip locked;
 if not found or not private.mixed_visit_verbal_current(a.consent_id)then raise exception 'Current consenting cashier session required'using errcode='42501';end if;
 return g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id);
end$$;
create function private.bind_mixed_visit_invoice()returns trigger language plpgsql volatile security definer set search_path=pg_catalog as $$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;begin
 select *into a from private.mixed_visit_issue_authorizations where request_id=new.request_id;
 if not found then
 if new.quote?'visit_reward'then raise exception 'Visit quote requires atomic issuer authorization'using errcode='42501';end if;return new;end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;
 if a.actor_id<>new.actor_id or a.creator_xid<>txid_current()or new.creator_xid<>txid_current()or new.branch_id<>g.branch_id or new.draft_id<>(select draft_id from private.cashier_loyalty_draft_intents where request_id=g.intent_id)or new.quote is distinct from(g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id))then raise exception 'Exact atomic visit invoice binding required'using errcode='55000';end if;
 insert into private.mixed_visit_invoice_bindings(invoice_id,group_id,creator_xid)values(new.invoice_id,g.request_id,txid_current());return new;
end$$;
create trigger bind_atomic_mixed_visit_invoice after insert on private.cashier_invoice_postings for each row execute function private.bind_mixed_visit_invoice();
create function private.issue_mixed_visit_invoice(p_request uuid,p_branch uuid,p_group uuid,p_consent uuid,p_start timestamptz)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;a private.mixed_visit_issue_authorizations;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own actual visit group required'using errcode='42501';end if;
 perform private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 if p_request is null or p_consent is null then raise exception 'Exact issuance request and assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-issue:'||p_request,0));
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;
 if found then
 if a.actor_id<>auth.uid()or a.group_id<>p_group or a.consent_id<>p_consent then raise exception 'Immutable visit invoice request'using errcode='22023';end if;
 return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);end if;
 if(private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'or not exists(select 1 from private.mixed_visit_verbal_consents c where c.request_id=p_consent and c.group_id=p_group and c.actor_id=auth.uid())then raise exception 'Own current sealed draft and exact consent required'using errcode='42501';end if;
 perform private.lock_mixed_visit_backing(p_group);
 if not private.mixed_visit_verbal_current(p_consent)then raise exception 'Current independently verified verbal approval required'using errcode='42501';end if;
 insert into private.mixed_visit_issue_authorizations values(p_request,p_group,p_consent,auth.uid(),txid_current());
 return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start)||jsonb_build_object('visit_balance_reserved',true,'visit_collection_committed',false);
end$$;
create function private.commit_mixed_visit_collection()returns trigger language plpgsql volatile security definer set search_path=pg_catalog as $$
declare g private.mixed_visit_groups;begin
 if new.event_type<>'sale'then return new;end if;
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);perform private.lock_mixed_visit_backing(g.request_id);
 if new.amount<>private.cashier_invoice_payable(new.invoice_id)or new.method not in('cash','card_terminal')or(new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.amount=new.amount))then raise exception 'Actual full cash or verified terminal collection required'using errcode='55000';end if;
 insert into private.mixed_visit_collection_commits(group_id,payment_id)values(g.request_id,new.payment_id);return new;
end$$;
create trigger commit_mixed_visit_after_collection after insert on public.business_payment_events for each row execute function private.commit_mixed_visit_collection();
create function private.guard_pinned_visit_claim_release()returns trigger language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if old.released_at is null and new.released_at is not null and private.mixed_visit_component_pinned(old.reserve_request_id)then raise exception 'Issued visit claim requires canonical returned-unit authorization'using errcode='55000';end if;return new;end$$;
create trigger a_guard_pinned_visit_release before update on private.reward_credit_claims for each row execute function private.guard_pinned_visit_claim_release();
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
 current_quote:=private.apply_mixed_visit_issuing_quote(p_request,current_quote);
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
CREATE OR REPLACE FUNCTION private.release_offline_reward_reservation(p_request uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare c private.offline_reward_reservation_commands;q private.service_reward_quotes;actor uuid;terminal text;
begin
 actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable reservation and audit reason required'using errcode='22023';end if;
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if not found then raise exception 'Reservation unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||c.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request for update;
 if c.state<>'active'then return private.offline_reward_reservation_snapshot(p_request);end if;
 if private.mixed_visit_component_pinned(p_request)then return private.offline_reward_reservation_snapshot(p_request)||jsonb_build_object('pinned_by_issued_invoice',true,'released',false);end if;
 select *into q from private.service_reward_quotes where quote_id=c.quote_id;
 terminal:=case when exists(select 1 from private.reward_credit_claims hold where hold.reserve_request_id=c.request_id and(private.reward_credit_refund(hold.earning_id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=hold.earning_id and rev.kind='refund')))then'refunded'when q.expires_at<=clock_timestamp()then'expired'else'released'end;
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,reason,creator_xid)values('release:'||p_request,p_request,terminal,actor,trim(p_reason),txid_current());
 update private.reward_credit_claims set released_at=clock_timestamp()where reserve_request_id=p_request and released_at is null;
 update private.offline_reward_reservation_commands set state=terminal,result=jsonb_build_object('state',terminal,'consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$function$;
CREATE OR REPLACE FUNCTION private.mixed_visit_group_snapshot(p_group uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare g private.mixed_visit_groups;held bigint;live boolean;begin
 select *into g from private.mixed_visit_groups where request_id=p_group;
 if not found or g.actor_id<>auth.uid()then raise exception 'Visit group unavailable'using errcode='42501';end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 select count(*)into held from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=p_group and h.released_at is null;
 live:=(exists(select 1 from private.mixed_visit_invoice_bindings where group_id=p_group)or g.expires_at>clock_timestamp())and held=g.required_visits and not exists(select 1 from private.mixed_visit_group_releases where group_id=p_group)and not exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=p_group and(c.state<>'active'or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is not null)));
 return jsonb_build_object('group_id',p_group,'unit','service_visits','covered_units',g.covered_units,'required_visits',g.required_visits,'held_visits',held,'reservation_live',live,'fingerprint',g.fingerprint,'expires_at',g.expires_at,'quote',g.quote,'released',exists(select 1 from private.mixed_visit_group_releases where group_id=p_group),'consent_authorized',false,'invoice_issued',exists(select 1 from private.mixed_visit_invoice_bindings where group_id=p_group),'invoice_id',(select invoice_id from private.mixed_visit_invoice_bindings where group_id=p_group),'visit_collection_committed',exists(select 1 from private.mixed_visit_collection_commits where group_id=p_group),'redemption_enabled',false);
end$function$;
revoke all on function private.mixed_visit_component_pinned(uuid),private.lock_mixed_visit_backing(uuid),private.apply_mixed_visit_issuing_quote(uuid,jsonb),private.bind_mixed_visit_invoice(),private.issue_mixed_visit_invoice(uuid,uuid,uuid,uuid,timestamptz),private.commit_mixed_visit_collection(),private.guard_pinned_visit_claim_release()from public,anon,authenticated,service_role;
commit;
