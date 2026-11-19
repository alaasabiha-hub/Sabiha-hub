-- Include inside the root-owned rollback reward-checkout fixture. No fixture commits.
-- Root calls this after creating actual coverage with canonical quote/booking RPCs.
create temp table if not exists reward_reader_assertion_fixture(marker boolean);
create function pg_temp.assert_reward_invoice_readers(p_invoice text,p_customer uuid,p_owner uuid,p_legacy_zero text default null) returns void language plpgsql as $$
declare i public.business_invoices;coverage jsonb;document jsonb;payment jsonb;history jsonb;options jsonb;before_row jsonb;legacy_document jsonb;legacy_invoice public.business_invoices;has_booking boolean;
begin
 if current_user<>'postgres' then raise exception 'Local rollback QA must run as postgres';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 select exists(select 1 from public.business_orders where order_id=i.order_id and booking_id is not null) into has_booking;
 assert i.total=0 and i.discount>0 and i.status='active';before_row:=to_jsonb(i);
 coverage:=private.reward_invoice_coverage(p_invoice);assert coverage->>'state'='covered_by_reward';
 assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice),'Reward created a synthetic sale';
 assert i.document_snapshot->'reward'=i.reward_snapshot,'Initial issued document missed its frozen reward snapshot';
 assert i.document_snapshot->>'payment_status'='covered_by_reward' and i.document_snapshot->>'payment_method'='reward_coverage','AFTER INSERT froze an unpaid reward document';
 assert i.document_snapshot->'reward_coverage'->>'state'='covered_by_reward','Canonical cover-event witness was missing at INSERT stamp';
 perform set_config('request.jwt.claim.sub',p_customer::text,true);execute 'set local role authenticated';
 document:=public.resolve_invoice_document(i.document_token);payment:=public.invoice_payment_quote(p_invoice);
 assert document->>'payment_status'='covered_by_reward' and document->>'payment_method'='reward_coverage';
 assert document->>'document_token'=i.document_token::text and document->>'invoice_number'=coalesce(i.display_number,i.invoice_id);
 assert (document->'snapshot'->>'total')::numeric=0 and (document->'snapshot'->>'discount')::numeric=i.discount;
 assert payment->>'payment_status'='covered_by_reward' and payment->>'collectible'='false' and (payment->>'amount_due')::numeric=0;
 assert (payment->>'gross_amount')::numeric=i.total+i.discount;
 if has_booking then
  history:=public.get_customer_booking_history();
  assert exists(select 1 from jsonb_array_elements(history) h where h->>'invoice_id'=p_invoice and h->>'payment_status'='covered_by_reward' and (h->>'invoice_total')::numeric=0 and (h->>'invoice_discount')::numeric=i.discount and (h->>'quoted_price')::numeric=i.total+i.discount),'Own history lost true due or changed gross quote';
 end if;
 execute 'reset role';perform set_config('request.jwt.claim.sub',p_owner::text,true);execute 'set local role authenticated';
 options:=public.shift_invoice_options(i.branch_id);assert not exists(select 1 from jsonb_array_elements(options) q where q->>'invoice_id'=p_invoice),'Covered invoice offered for cashier collection';
 if p_legacy_zero is not null then
  execute 'reset role';select * into strict legacy_invoice from public.business_invoices where invoice_id=p_legacy_zero;assert legacy_invoice.total=0 and legacy_invoice.reward_snapshot is null;
  assert private.reward_invoice_coverage(p_legacy_zero) is null;
  execute 'set local role authenticated';legacy_document:=public.resolve_invoice_document(legacy_invoice.document_token);
  assert legacy_document->>'payment_status'<>'covered_by_reward' and legacy_document->>'payment_method'<>'reward_coverage','Ordinary zero invoice falsely became a reward';
 end if;
 execute 'reset role';assert (select to_jsonb(x) from public.business_invoices x where invoice_id=p_invoice)=before_row,'Reader changed issued invoice/commission/QR snapshot';
 raise notice 'PASS actual reward document/history/payment/cashier truth, no synthetic sale, unchanged gross/discount/commission/QR and ordinary zero isolation';
end;$$;

-- Use a positive, canonical-bound qualifying invoice to prove the legacy
-- unmanaged/global fallback cannot award a second ledger visit.
create function pg_temp.assert_canonical_order_excludes_legacy(p_invoice text,p_customer uuid) returns void language plpgsql as $$
declare i public.business_invoices;before_row jsonb;before_count bigint;before_balance bigint;actual record;
begin
 if current_user<>'postgres' then raise exception 'Local rollback QA must run as postgres';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 assert i.total>0 and exists(select 1 from public.business_orders o join private.loyalty_earning_snapshot_bindings eb on eb.booking_id=o.booking_id where o.order_id=i.order_id and o.customer_id=p_customer);
 assert not exists(select 1 from public.business_loyalty_transactions where order_id=i.order_id and customer_id=p_customer),'Use a new canonical fixture, not a legacy replay';
 before_row:=to_jsonb(i);select count(*),coalesce(sum(points),0) into before_count,before_balance from public.business_loyalty_transactions where customer_id=p_customer;
 insert into public.business_offers(name,offer_type,visits_required,is_active,is_public) values('Isolated unmanaged fallback QA','visit_reward',100000,true,true);
 execute 'set local role service_role';select * into actual from public.finalize_service_loyalty(p_customer,i.order_id,p_invoice);execute 'reset role';
 assert actual.reward_applied=false and actual.points_balance=before_balance;
 assert (select count(*) from public.business_loyalty_transactions where customer_id=p_customer)=before_count,'Canonical order minted legacy points';
 assert (select to_jsonb(x) from public.business_invoices x where invoice_id=p_invoice)=before_row,'Legacy fallback changed canonical financial/commission snapshot';
 raise notice 'PASS reachable service-role legacy finalizer cannot process a new canonical earning order via unmanaged/global offer';
end;$$;

create function pg_temp.assert_reward_reader_readiness(p_policy uuid,p_owner uuid) returns void language plpgsql as $$
declare backend jsonb;context jsonb;mapping record;expected boolean;
begin
 if current_user<>'postgres' then raise exception 'Local rollback QA must run as postgres';end if;
 backend:=private.reward_backend_readiness(p_policy);
 perform set_config('request.jwt.claim.sub',p_owner::text,true);execute 'set local role authenticated';context:=public.get_loyalty_redemption_rules(p_policy);execute 'reset role';
 for mapping in select * from(values
  ('earning_rules_binding_implemented','earning_rules_binding_not_implemented'),
  ('quote_implemented','redemption_quote_not_implemented'),('booking_implemented','booking_redemption_not_implemented'),
  ('allocation_implemented','visit_reservation_not_implemented'),('consumption_implemented','visit_consumption_not_implemented'),
  ('release_implemented','visit_release_not_implemented'),('readers_integrated','reward_invoice_document_state_not_implemented'),
  ('refund_resolution_implemented','refunded_contribution_resolution_not_implemented')
 )as checks(flag,blocker) loop
  expected:=coalesce((backend->>mapping.flag)::boolean,false);
  assert (context->'blockers' @> jsonb_build_array(mapping.blocker))=(not expected),'Readiness misreported actual backend capability';
 end loop;
 assert (context->>'redemption_enabled')::boolean=(coalesce((backend->>'redemption_enabled')::boolean,false) and coalesce((backend->>'current_rules_activated')::boolean,false)),'A previously activated version silently enabled newly saved rules';
 raise notice 'PASS truthful capability/binding readiness and explicit latest-rule activation gate';
end;$$;

create function pg_temp.assert_cancelled_reward_invoice_readers(p_invoice text,p_customer uuid,p_owner uuid) returns void language plpgsql as $$
declare i public.business_invoices;doc jsonb;payment jsonb;history jsonb;before_row jsonb;has_booking boolean;
begin
 if current_user<>'postgres' then raise exception 'Local rollback QA must run as postgres';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;before_row:=to_jsonb(i);
 select exists(select 1 from public.business_orders where order_id=i.order_id and booking_id is not null) into has_booking;
 assert i.status='void' and i.total=0 and private.reward_invoice_coverage(p_invoice)->>'state'='cancelled_reward';
 assert i.document_snapshot->>'payment_status'='covered_by_reward','Cancellation rewrote the immutable original issuance state';
 perform set_config('request.jwt.claim.sub',p_customer::text,true);execute 'set local role authenticated';
 doc:=public.resolve_invoice_document(i.document_token);payment:=public.invoice_payment_quote(p_invoice);history:=public.get_customer_booking_history();
 assert doc->>'payment_status'='cancelled' and doc->>'payment_method'='reward_coverage','Live cancellation failed to take priority over original coverage';
 assert payment->>'payment_status'='cancelled' and payment->>'collectible'='false';
 if has_booking then assert exists(select 1 from jsonb_array_elements(history) h where h->>'invoice_id'=p_invoice and h->>'payment_status'='cancelled' and (h->>'invoice_total')::numeric=0);end if;
 execute 'reset role';assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice),'Reward cancellation fabricated a cash/card refund';
 assert (select to_jsonb(x) from public.business_invoices x where invoice_id=p_invoice)=before_row;
 raise notice 'PASS cancelled reward live state wins, original issuance snapshot retained, zero collection and no synthetic refund';
end;$$;

create function pg_temp.assert_existing_legacy_reward_replay(p_customer uuid,p_branch uuid) returns void language plpgsql as $$
declare oid uuid:=gen_random_uuid();iid text:='QA-LEGACY-REPLAY-'||gen_random_uuid()::text;before_row jsonb;balance bigint;reply record;
begin
 if current_user<>'postgres' then raise exception 'Local rollback QA must run as postgres';end if;
 -- A nested rollback preserves the caller's global legacy-ledger fingerprint;
 -- no test cleanup deletes records and no historical business row is rewritten.
 begin
  insert into public.business_orders(order_id,order_number,customer_id,branch_id,service_name,order_type,status) values(oid,iid,p_customer,p_branch,'Isolated old reward replay','service','received');
  insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total,discount,commission_total,payment_method) values(iid,oid,p_branch,'Isolated old reward replay',0,100,7,'cash_on_receipt');
  insert into public.business_loyalty_transactions(customer_id,points,reason,order_id) values(p_customer,-1,'Wash reward redeemed',oid);
  select to_jsonb(i) into before_row from public.business_invoices i where invoice_id=iid;
  select coalesce(sum(points),0) into balance from public.business_loyalty_transactions where customer_id=p_customer;
  execute 'set local role service_role';select * into reply from public.finalize_service_loyalty(p_customer,oid,iid);execute 'reset role';
  assert reply.reward_applied=true and reply.points_balance=balance,'Existing legacy reward replay was suppressed';
  assert (select to_jsonb(i) from public.business_invoices i where invoice_id=iid)=before_row,'Legacy replay changed financial/commission/QR snapshot';
  raise exception 'Rollback synthetic legacy replay proof' using errcode='PZ001';
 exception when sqlstate 'PZ001' then null;
 end;
 assert not exists(select 1 from public.business_invoices where invoice_id=iid);
 raise notice 'PASS pre-existing legacy reward replay remains idempotent and commissions/QR unchanged; synthetic proof rolled back';
end;$$;
