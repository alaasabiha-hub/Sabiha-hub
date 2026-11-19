begin;
-- Bundle B: complete PRIVATE creator/read/cancel/debt paths. Public spend stays OFF.
create function private.offline_reward_invoice_terms_match(p_invoice text,p_order uuid,p_snapshot jsonb,p_total numeric,p_discount numeric)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;c private.offline_reward_issue_commands;s private.offline_walk_in_subjects;v_ids uuid[];v_expected uuid[];
begin
 select *into d from private.service_reward_redemptions where invoice_id=p_invoice and owner_kind='offline_profile';
 select *into q from private.service_reward_quotes where quote_id=d.quote_id;
 select *into c from private.offline_reward_issue_commands where request_id=d.offline_issue_id;
 select *into s from private.offline_walk_in_subjects where invoice_id=p_invoice;
 if d.redemption_id is null or q.owner_kind is distinct from'offline_profile'or d.customer_id is not null or q.customer_id is not null or d.booking_id is not null
 or d.order_id is distinct from p_order or d.coverage_snapshot is distinct from p_snapshot or p_total<>0 or p_discount is distinct from q.gross_amount
 or d.offline_profile_id is distinct from q.offline_profile_id or d.offline_channel_version_id is distinct from q.offline_channel_version_id or d.branch_id is distinct from q.branch_id
 or d.rules_version_id is distinct from q.rules_version_id or d.policy_version_id is distinct from q.policy_version_id
 or s.reward_issue_id is distinct from c.request_id or s.order_id is distinct from d.order_id or s.profile_id is distinct from d.offline_profile_id or s.gross is distinct from q.gross_amount
 or(c.state<>'issued'and not(c.state='prepared'and d.creator_xid=txid_current()and q.expires_at>clock_timestamp()))
 or not exists(select 1 from private.offline_reward_financial_consents a join private.offline_reward_financial_proposals proposal on proposal.proposal_id=a.proposal_id join private.offline_reward_consumption_preparations prep on prep.request_id=proposal.preparation_id
 where a.request_id=c.consent_request_id and prep.request_id=c.preparation_id and prep.reservation_id=q.reserve_request_id and proposal.witness=prep.witness and a.fingerprint=proposal.fingerprint
 and a.actor_id::text=d.consent->>'customer_id'and a.request_id::text=d.consent->>'financial_consent_request_id'and a.proposal_id::text=d.consent->>'proposal_id'and a.fingerprint=d.consent->>'financial_fingerprint')
 or not exists(select 1 from private.offline_reward_issue_events event where event.event_key='consume:'||d.redemption_id and event.request_id=c.request_id and event.redemption_id=d.redemption_id and event.profile_id=d.offline_profile_id and event.action='consume'and(event.data->>'authorized_xid')::bigint=event.creator_xid)
 or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id and redemption_id=d.redemption_id)
 or exists(select 1 from public.business_payment_events where invoice_id=p_invoice)then return false;end if;
 select array_agg(earning_id order by earning_id)into v_ids from private.reward_credit_claims where redemption_id=d.redemption_id and quote_id=q.quote_id and kind='reward'and owner_kind='offline_profile'and offline_profile_id=d.offline_profile_id and(d.state='restored'or released_at is null);
 select array_agg(x order by x)into v_expected from unnest(q.earning_ids)x;
 return coalesce(v_ids=v_expected,false);
end$$;
create function private.typed_offline_reward_invoice_coverage(p_invoice text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;i public.business_invoices;c private.offline_reward_issue_commands;
begin
 select *into d from private.service_reward_redemptions where invoice_id=p_invoice and owner_kind='offline_profile';
 select *into q from private.service_reward_quotes where quote_id=d.quote_id;select *into i from public.business_invoices where invoice_id=p_invoice;select *into c from private.offline_reward_issue_commands where request_id=d.offline_issue_id;
 if not coalesce(private.offline_reward_invoice_terms_match(p_invoice,i.order_id,i.reward_snapshot,i.total,i.discount),false)then return null;end if;
 if c.state='prepared'and d.creator_xid=txid_current()then
 if d.state<>'covered'or i.status<>'active'then return null;end if;
 elsif not coalesce(private.offline_reward_receipt_coherent(d.redemption_id),false)then return null;end if;
 return jsonb_build_object('state',case when d.state='covered'then'covered_by_reward'else'cancelled_reward'end,'quote_id',q.quote_id,'rules_version_id',q.rules_version_id,'policy_version_id',q.policy_version_id,'threshold_visits',q.threshold_visits,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','rules',q.terms_snapshot->'rules','redemption_status',d.state,'source_channel','walk_in','owner_kind','offline_profile');
end$$;

create function private.get_offline_reward_issue(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_c private.offline_reward_issue_commands;v_invoice text;v_quote jsonb;v_result jsonb;
begin
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null then raise exception 'Exact issue nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-issue:'||p_request::text,0));
 select *into v_c from private.offline_reward_issue_commands where request_id=p_request;
 if not found then return jsonb_build_object('state','absent','definitive_failure',false,'issuer_public_enabled',false);end if;
 if v_c.operator_id<>v_actor then raise exception 'Issue receipt unavailable'using errcode='42501';end if;
 v_result:=v_c.result;
 if v_c.state='issued'then
 select invoice_id into v_invoice from private.service_reward_redemptions where redemption_id=v_c.redemption_id;
 v_quote:=private.invoice_payment_quote(v_invoice);
 v_result:=v_result||jsonb_build_object('work_status',(select status from public.business_orders where order_id=(v_c.result->>'order_id')::uuid),'invoice_status',(select status from public.business_invoices where invoice_id=v_invoice),'payment_status',v_quote->>'payment_status','collectible',false,'amount_due',0);
 end if;
 return jsonb_build_object('state',v_c.state,'request_id',p_request,'payload',v_c.payload,'result',v_result,'definitive_failure',v_c.state='closed','acknowledged',v_c.acknowledged_at is not null,'issuer_public_enabled',false);
end$$;
create function private.prepare_offline_reward_issue(p_request uuid,p_preparation uuid,p_consent uuid,p_registration uuid,p_staff uuid[])returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_c private.offline_reward_issue_commands;v_proof jsonb;v_payload jsonb;v_staff uuid[];v_cashier uuid;v_facts jsonb;v_backing jsonb;
begin
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null or p_preparation is null or p_consent is null or p_registration is null then raise exception 'Exact issue preparation required'using errcode='22023';end if;
 select array_agg(x order by x)into v_staff from unnest(p_staff)x;
 v_payload:=jsonb_build_object('preparation',p_preparation,'consent',p_consent,'registration',p_registration,'staff',v_staff);
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-issue:'||p_request::text,0));
 select *into v_c from private.offline_reward_issue_commands where request_id=p_request;
 if found then
 if v_c.operator_id<>v_actor then raise exception 'Issue receipt unavailable'using errcode='42501';end if;
 if v_c.state='closed'then return private.get_offline_reward_issue(p_request);end if;
 if v_c.payload<>v_payload then raise exception 'Issue nonce payload changed'using errcode='22023';end if;return private.get_offline_reward_issue(p_request);end if;
 if not exists(select 1 from private.offline_reward_issuer_runtime where singleton and kernel_installed)then raise exception 'Private issuer bundle incomplete'using errcode='55000';end if;
 v_proof:=private.lock_linked_offline_reward_issuer_consent(p_preparation,p_consent);
 perform private.sync_offline_profile_rewards((v_proof->>'offline_profile_id')::uuid);
 if not private.offline_reward_debt_clear((v_proof->>'offline_profile_id')::uuid,(v_proof#>>'{witness,rules_version_id}')::uuid)then raise exception 'Actual typed refund debt/review must resolve before issue'using errcode='55000';end if;
 select actor_id into v_cashier from private.offline_customer_registration_requests where request_id=p_registration;
 v_backing:=private.prepare_offline_walk_in(p_request,p_registration,(v_proof#>>'{witness,service_id}')::uuid,(v_proof#>>'{witness,gross_amount}')::numeric,v_cashier,v_staff,null);
 if(v_backing->>'status')is distinct from'prepared'then raise exception 'Fresh exact received service command required'using errcode='55000';end if;
 select financial_snapshot into v_facts from private.offline_walk_in_commands where request_id=p_request;
 if v_facts->>'profile_id'<>v_proof->>'offline_profile_id'or v_facts->>'car_ref_id'<>v_proof#>>'{witness,car_reference}'or v_facts->>'branch_id'<>v_proof#>>'{witness,branch_id}'then raise exception 'Exact consented intake/car/branch required'using errcode='42501';end if;
 insert into private.offline_reward_issue_commands(request_id,operator_id,preparation_id,consent_request_id,payload,state)values(p_request,v_actor,p_preparation,p_consent,v_payload,'prepared');
 return private.get_offline_reward_issue(p_request);
end$$;

create function private.place_offline_reward_issue(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_c private.offline_reward_issue_commands;v_back private.offline_walk_in_commands;v_proof jsonb;v_f jsonb;v_q private.service_reward_quotes;v_staff uuid[];
 v_oid uuid:=gen_random_uuid();v_iid text;v_rid uuid:=gen_random_uuid();v_invoice public.business_invoices;v_snapshot jsonb;v_consent jsonb;v_total numeric;v_share numeric;v_workers jsonb;v_result jsonb;v_reservation uuid;
begin
 v_actor:=private.require_offline_reservation_operator();
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-issue:'||p_request::text,0));
 select *into v_c from private.offline_reward_issue_commands where request_id=p_request;
 if not found or v_c.operator_id<>v_actor then raise exception 'Own exact issue command required'using errcode='42501';end if;
 if v_c.state='issued'then return private.get_offline_reward_issue(p_request);end if;
 if v_c.state='closed'then return private.get_offline_reward_issue(p_request);end if;
 v_proof:=private.lock_linked_offline_reward_issuer_consent(v_c.preparation_id,v_c.consent_request_id);
 perform private.sync_offline_profile_rewards((v_proof->>'offline_profile_id')::uuid);
 if not private.offline_reward_debt_clear((v_proof->>'offline_profile_id')::uuid,(v_proof#>>'{witness,rules_version_id}')::uuid)then raise exception 'Actual typed refund debt/review must resolve'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 select *into v_back from private.offline_walk_in_commands where request_id=p_request for update;
 if v_back.state<>'prepared'or v_back.prepared_by<>v_actor then raise exception 'Backing command closed or changed'using errcode='55000';end if;
 select array_agg(x::uuid order by x::uuid)into v_staff from jsonb_array_elements_text(v_back.payload->'staff_ids')x;
 v_f:=private.walk_in_service_facts((v_back.payload->>'registration_request_id')::uuid,(v_back.payload->>'service_id')::uuid,(v_back.payload->>'expected_price')::numeric,v_staff,v_back.actor_id);
 if v_f is distinct from v_back.financial_snapshot then raise exception 'Actual service price/worker/rate/intake changed'using errcode='40001';end if;
 -- Revalidate expiry/consent after the HR/source fact lock wait, still same actor.
 v_proof:=private.lock_linked_offline_reward_issuer_consent(v_c.preparation_id,v_c.consent_request_id);
 select *into v_q from private.service_reward_quotes where quote_id=(v_proof#>>'{witness,quote_id}')::uuid;
 v_reservation:=(v_proof->>'reservation_id')::uuid;v_iid:='REWARD-WALKIN-'||v_oid::text;
 insert into private.offline_reward_issue_events(event_key,request_id,redemption_id,profile_id,action,actor_id,data,creator_xid)
 values('consume:'||v_rid,p_request,v_rid,(v_proof->>'offline_profile_id')::uuid,'consume',v_actor,jsonb_build_object('authorized_xid',txid_current(),'consent_request_id',v_c.consent_request_id,'proposal_id',v_proof->>'proposal_id','fingerprint',v_proof->>'fingerprint','order_id',v_oid,'invoice_id',v_iid),txid_current());
 insert into private.offline_walk_in_subjects(order_id,invoice_id,command_id,registration_request_id,profile_id,car_ref_id,branch_id,service_id,gross,duration_minutes,resource_key,staff_ids,consent_hash,creator_xid,reward_issue_id)
 values(v_oid,v_iid,p_request,(v_back.payload->>'registration_request_id')::uuid,(v_f->>'profile_id')::uuid,(v_f->>'car_ref_id')::uuid,v_back.branch_id,(v_f->>'service_id')::uuid,(v_f->>'gross')::numeric,(v_f->>'duration_minutes')::integer,v_f->>'resource_key',v_staff,v_f->>'consent_hash',txid_current(),p_request);
 insert into private.offline_walk_in_commissions(invoice_id,staff_id,staff_name,rate_percent,assigned_count,gross,amount,employment_snapshot)
 select v_iid,(x->>'staff_id')::uuid,x->>'staff_name',(x->>'rate_percent')::numeric,(x->>'assigned_count')::integer,(x->>'gross')::numeric,(x->>'amount')::numeric,x->'employment_snapshot'from jsonb_array_elements(v_f->'lines')x;
 select sum(amount),case when count(distinct rate_percent)=1 then min(amount)end,jsonb_agg(staff_name order by staff_id)into v_total,v_share,v_workers from private.offline_walk_in_commissions where invoice_id=v_iid;
 insert into public.business_orders(order_id,order_number,branch_id,customer_id,booking_id,customer_name,customer_phone,plate_number,vehicle_type,service_name,order_type,status,assigned_staff_ids,assigned_workers,created_by)
 values(v_oid,v_iid,v_back.branch_id,null,null,v_f->>'customer_name',v_f->>'customer_phone',v_f->>'plate_number',v_f->>'vehicle_type',v_f->>'service_name','service','received',v_staff,v_workers,'offline_reward_walk_in');
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(v_oid,(v_f->>'service_id')::uuid,v_f->>'service_name',1,v_q.gross_amount,v_q.gross_amount);
 insert into private.offline_walk_in_reception(order_id,branch_id)values(v_oid,v_back.branch_id);
 v_snapshot:=jsonb_build_object('state','covered_by_reward','quote_id',v_q.quote_id,'quote_fingerprint',v_q.fingerprint,'policy_version_id',v_q.policy_version_id,'rules_version_id',v_q.rules_version_id,'threshold_visits',v_q.threshold_visits,'gross_amount',v_q.gross_amount,'reward_discount',v_q.gross_amount,'amount_due',0,'currency','EGP','rules',v_q.terms_snapshot->'rules','source_channel','walk_in','owner_kind','offline_profile','order_id',v_oid,'booking_id',null,'reward_service',jsonb_build_object('id',v_q.service_id,'name',v_f->>'service_name'),'original_credit_expiry_preserved',true);
 v_consent:=jsonb_build_object('accept_terms',true,'financial_consent_request_id',v_c.consent_request_id,'customer_id',v_proof->>'customer_id','proposal_id',v_proof->>'proposal_id','financial_fingerprint',v_proof->>'fingerprint','accepted_at',v_proof->>'consent_recorded_at');
 insert into private.service_reward_redemptions(redemption_id,customer_id,request_id,quote_id,source_channel,branch_id,order_id,booking_id,invoice_id,rules_version_id,policy_version_id,consent,coverage_snapshot,creator_xid,owner_kind,offline_profile_id,offline_channel_version_id,requested_by,offline_issue_id)
 values(v_rid,null,p_request,v_q.quote_id,'walk_in',v_q.branch_id,v_oid,null,v_iid,v_q.rules_version_id,v_q.policy_version_id,v_consent,v_snapshot,txid_current(),'offline_profile',v_q.offline_profile_id,v_q.offline_channel_version_id,v_actor,p_request);
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,reason,creator_xid)values('consume:'||v_reservation,v_reservation,'consumed',v_actor,'Actual independently consented typed reward invoice',txid_current());
 update private.reward_credit_claims set released_at=clock_timestamp()where reserve_request_id=v_reservation and released_at is null;
 insert into private.reward_credit_claims(earning_id,customer_id,kind,redemption_id,quote_id,owner_kind,offline_profile_id,offline_channel_version_id)
 select x,null,'reward',v_rid,v_q.quote_id,'offline_profile',v_q.offline_profile_id,v_q.offline_channel_version_id from unnest(v_q.earning_ids)x;
 update private.offline_reward_reservation_commands set state='consumed',result=jsonb_build_object('state','consumed','redemption_id',v_rid,'consumption_enabled',false)where request_id=v_reservation;
 insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data,offline_creator_xid)values('cover:'||v_rid,v_rid,v_actor,v_snapshot,txid_current());
 insert into public.business_invoices(invoice_id,order_id,branch_id,plate_number,service_name,vehicle_type,total,discount,sale_type,payment_method,commission_model,commission_total,commission_share,workers,created_by,reward_snapshot)
 values(v_iid,v_oid,v_back.branch_id,v_f->>'plate_number',v_f->>'service_name',v_f->>'vehicle_type',0,v_q.gross_amount,'service','reward_coverage','walk_in_frozen_workers',v_total,v_share,v_workers,'offline_reward_walk_in',v_snapshot)returning *into v_invoice;
 update public.business_orders set order_number=v_invoice.display_number where order_id=v_oid;
 v_result:=jsonb_build_object('order_id',v_oid,'invoice_id',v_iid,'work_reference',v_invoice.display_number,'invoice_number',v_invoice.display_number,'invoice_token',v_invoice.document_token,'gross_amount',v_q.gross_amount,'reward_discount',v_q.gross_amount,'amount_due',0,'currency','EGP','payment_status','covered_by_reward','collectible',false,'work_status','received','redemption_id',v_rid,'visits_consumed',v_q.threshold_visits,'reward_public_enabled',false);
 update private.service_reward_redemptions set result=v_result where redemption_id=v_rid;
 update private.offline_walk_in_commands set state='succeeded',order_id=v_oid,executed_by=v_actor,result=v_result,resolved_at=clock_timestamp()where request_id=p_request;
 update private.offline_reward_issue_commands set state='issued',redemption_id=v_rid,result=v_result,resolved_at=clock_timestamp()where request_id=p_request;
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,v_actor,'place',jsonb_build_object('bound_cashier',v_back.actor_id,'reward_issue',true),v_result,txid_current());
 return private.get_offline_reward_issue(p_request);
end$$;
create function private.close_offline_reward_issue(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_c private.offline_reward_issue_commands;begin
 v_actor:=private.require_offline_reservation_operator();if p_request is null then raise exception 'Exact issue nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-issue:'||p_request::text,0));
 select *into v_c from private.offline_reward_issue_commands where request_id=p_request;
 if not found then insert into private.offline_reward_issue_commands(request_id,operator_id,state,resolved_at,result)values(p_request,v_actor,'closed',clock_timestamp(),'{"closed":true}');
 else
 if v_c.operator_id<>v_actor then raise exception 'Issue receipt unavailable'using errcode='42501';end if;
 if v_c.state='prepared'then
 perform private.close_offline_walk_in_command(p_request);
 perform private.close_offline_reward_consumption(v_c.preparation_id,'Explicitly close unissued exact reward command');
 update private.offline_reward_issue_commands set state='closed',resolved_at=clock_timestamp(),result='{"closed":true}'where request_id=p_request;
 end if;end if;return private.get_offline_reward_issue(p_request);
end$$;
create function private.ack_offline_reward_issue(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_c private.offline_reward_issue_commands;begin
 v_actor:=private.require_offline_reservation_operator();
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-issue:'||p_request::text,0));
 select *into v_c from private.offline_reward_issue_commands where request_id=p_request;
 if not found or v_c.operator_id<>v_actor then raise exception 'Own issue receipt required'using errcode='42501';end if;
 if v_c.state='prepared'then raise exception 'Unresolved issue cannot acknowledge'using errcode='55000';end if;
 update private.offline_reward_issue_commands set acknowledged_at=coalesce(acknowledged_at,clock_timestamp())where request_id=p_request;
 -- Current highest-authority original operator can release this exact backing
 -- terminal receipt slot; this is not an arbitrary cashier acknowledgment API.
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 update private.offline_walk_in_commands set acknowledged_at=coalesce(acknowledged_at,clock_timestamp())where request_id=p_request and prepared_by=v_actor and state in('succeeded','closed');
 return private.get_offline_reward_issue(p_request);
end$$;

create function private.cancel_offline_reward_issue(p_request uuid,p_issue uuid,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_c private.offline_reward_issue_commands;v_a private.offline_reward_financial_consents;v_profile uuid;v_order uuid;v_result jsonb;
begin
 perform private.require_offline_reservation_operator();
 select *into v_c from private.offline_reward_issue_commands where request_id=p_issue and state='issued';
 if not found then raise exception 'Actual issued typed reward required'using errcode='55000';end if;
 select *into v_a from private.offline_reward_financial_consents where request_id=v_c.consent_request_id;
 select offline_profile_id,order_id into v_profile,v_order from private.service_reward_redemptions where redemption_id=v_c.redemption_id;
 -- Cancellation must still work after link/session revocation, without importing
 -- a new identity. Derive/lock the original financial subject, no phone matching.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_a.actor_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_profile::text,0));
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||v_profile::text,0));
 perform private.sync_offline_profile_rewards(v_profile);
 v_result:=private.cancel_offline_walk_in(p_request,v_order,p_reason);
 perform private.sync_offline_profile_rewards(v_profile);
 return v_result||jsonb_build_object('reward_coverage',private.typed_offline_reward_invoice_coverage(v_result->>'invoice_id'),'collectible',false);
end$$;
create function private.resolve_offline_reward_refund_review(p_request uuid,p_review uuid,p_note text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_r private.reward_refund_reviews;v_d private.service_reward_redemptions;v_a private.offline_reward_financial_consents;v_prior private.reward_command_requests;v_payload jsonb;v_result jsonb;
begin
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null or p_review is null or length(trim(coalesce(p_note,'')))not between 2 and 1000 then raise exception 'Exact review nonce and note required'using errcode='22023';end if;
 v_payload:=jsonb_build_object('review',p_review,'note',p_note,'action','offline_acknowledge_without_debt_waiver');
 perform pg_advisory_xact_lock(hashtextextended('reward-command:'||p_request::text,0));
 select *into v_prior from private.reward_command_requests where request_id=p_request;
 if found then if v_prior.actor_id<>v_actor or v_prior.payload<>v_payload then raise exception 'Review nonce mismatch'using errcode='22023';end if;return v_prior.result;end if;
 select *into v_r from private.reward_refund_reviews where review_id=p_review and owner_kind='offline_profile';
 if not found then raise exception 'Actual typed review required'using errcode='55000';end if;
 select *into v_d from private.service_reward_redemptions where redemption_id=v_r.redemption_id;
 select a.*into v_a from private.offline_reward_issue_commands cmd join private.offline_reward_financial_consents a on a.request_id=cmd.consent_request_id where cmd.request_id=v_d.offline_issue_id;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_a.actor_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_r.offline_profile_id::text,0));
 perform private.sync_offline_profile_rewards(v_r.offline_profile_id);
 insert into private.offline_reward_issue_events(event_key,redemption_id,profile_id,action,actor_id,data,creator_xid)values('ack:'||p_request,v_r.redemption_id,v_r.offline_profile_id,'ack',v_actor,v_payload,txid_current());
 update private.reward_refund_reviews set acknowledged_at=clock_timestamp(),acknowledged_by=v_actor where review_id=p_review and acknowledged_at is null;
 perform private.sync_offline_profile_rewards(v_r.offline_profile_id);
 v_result:=jsonb_build_object('review_id',p_review,'acknowledged',true,'debt_waived',false,'visits_minted',0);
 insert into private.reward_command_requests values(p_request,v_actor,v_payload,v_result,clock_timestamp());return v_result;
end$$;

-- Original Auth coverage body retained byte-for-byte under this private helper.
create function private.reward_invoice_coverage_auth_before_offline_issuer(p_invoice text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;i public.business_invoices;n bigint;
begin
 select * into d from private.service_reward_redemptions where invoice_id=p_invoice;if d.redemption_id is null then return null;end if;
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;select * into i from public.business_invoices where invoice_id=p_invoice;
 if i.invoice_id is null or i.order_id is distinct from d.order_id or i.branch_id is distinct from d.branch_id or i.total<>0 or i.discount is distinct from q.gross_amount or i.reward_snapshot is distinct from d.coverage_snapshot then return null;end if;
 if d.owner_kind<>'auth_customer'or q.owner_kind<>'auth_customer'or d.customer_id is null or q.customer_id is null then return null;end if;
 if q.quote_id is null or d.customer_id<>q.customer_id or d.branch_id<>q.branch_id or d.rules_version_id<>q.rules_version_id or d.policy_version_id<>q.policy_version_id or d.source_channel<>q.source_channel or not coalesce((d.consent->>'accept_terms')::boolean,false) then return null;end if;
 select count(distinct c.earning_id) into n from private.reward_credit_claims c where c.redemption_id=d.redemption_id and c.quote_id=q.quote_id and c.kind='reward' and c.customer_id=d.customer_id and c.earning_id=any(q.earning_ids) and(d.state='restored' or c.released_at is null);
 if n<>q.threshold_visits or not exists(select 1 from public.business_orders where order_id=d.order_id and customer_id=d.customer_id and branch_id=d.branch_id and(booking_id is not distinct from d.booking_id)) or exists(select 1 from public.business_payment_events where invoice_id=p_invoice) or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id and redemption_id=d.redemption_id) then return null;end if;
 if d.state='covered' and i.status<>'active' then return null;end if;
 if d.state in('restored','forfeited') and(i.status<>'void' or not exists(select 1 from public.business_orders where order_id=d.order_id and status='cancelled') or(d.source_channel='booking' and not exists(select 1 from public.bookings where id=d.booking_id and status='cancelled')))then return null;end if;
 return jsonb_build_object('state',case when d.state='covered' and i.status='active' then 'covered_by_reward' else 'cancelled_reward' end,'quote_id',q.quote_id,'rules_version_id',q.rules_version_id,'policy_version_id',q.policy_version_id,'threshold_visits',q.threshold_visits,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','rules',q.terms_snapshot->'rules','redemption_status',d.state,'source_channel',d.source_channel);
end $$;
create or replace function private.reward_invoice_coverage(p_invoice text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.service_reward_redemptions where invoice_id=p_invoice and owner_kind='offline_profile')then return private.typed_offline_reward_invoice_coverage(p_invoice);end if;
 return private.reward_invoice_coverage_auth_before_offline_issuer(p_invoice);end$$;
create or replace function private.guard_reward_invoice() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;n bigint;
begin
 if tg_op='UPDATE' then
 if new.reward_snapshot is distinct from old.reward_snapshot then raise exception 'Issued reward snapshot cannot be added or changed';end if;
 if old.reward_snapshot is not null and(new.total is distinct from old.total or new.discount is distinct from old.discount or new.order_id is distinct from old.order_id or new.branch_id is distinct from old.branch_id) then raise exception 'Issued reward financial amounts/identity are immutable';end if;return new;end if;
 if new.reward_snapshot is null then return new;end if;
 if exists(select 1 from private.service_reward_redemptions where invoice_id=new.invoice_id and owner_kind='offline_profile')then
 if not coalesce(private.offline_reward_invoice_terms_match(new.invoice_id,new.order_id,new.reward_snapshot,new.total,new.discount),false)then raise exception 'Actual allocated typed financial coverage required'using errcode='42501';end if;return new;end if;
 select * into d from private.service_reward_redemptions where invoice_id=new.invoice_id and creator_xid=txid_current() and state='covered';
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;
 if d.owner_kind is distinct from'auth_customer'or q.owner_kind is distinct from'auth_customer'or d.customer_id is null or q.customer_id is null then raise exception 'Offline coverage issuer is not installed'using errcode='42501';end if;
 select count(*) into n from private.reward_credit_claims where redemption_id=d.redemption_id and kind='reward' and released_at is null and customer_id=d.customer_id and earning_id=any(q.earning_ids);
 if d.redemption_id is null or q.quote_id is null or n<>q.threshold_visits or new.reward_snapshot is distinct from d.coverage_snapshot or new.total<>0 or new.discount is distinct from q.gross_amount or new.order_id is distinct from d.order_id or new.branch_id is distinct from d.branch_id or not coalesce((d.consent->>'accept_terms')::boolean,false) then raise exception 'Server-created consented reward coverage and actual allocated visits required' using errcode='42501';end if;
 return new;
end $$;
CREATE OR REPLACE FUNCTION private.guard_offline_walk_in_finance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_s private.offline_walk_in_subjects;v_total numeric;v_share numeric;v_rates integer;v_ids uuid[];v_workers jsonb;begin
 if tg_op='DELETE'then
  if tg_table_name='business_orders'then
   if exists(select 1 from private.offline_walk_in_subjects where order_id=old.order_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  else
   if exists(select 1 from private.offline_walk_in_subjects where invoice_id=old.invoice_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  end if;return old;
 end if;
 if tg_table_name='business_orders'then
  select * into v_s from private.offline_walk_in_subjects where order_id=new.order_id;
  if not found then return new;end if;
  if new.customer_id is not null or new.booking_id is not null or new.order_type<>'service'or new.branch_id<>v_s.branch_id or new.assigned_staff_ids<>v_s.staff_ids then raise exception 'Typed offline subject/assignment mismatch'using errcode='55000';end if;
  if tg_op='INSERT'then
   if new.status<>'received'or v_s.creator_xid<>txid_current()then raise exception 'Only canonical received creation supported'using errcode='55000';end if;
  else
   if new.order_number is distinct from old.order_number and not(v_s.creator_xid=txid_current()and old.order_number=v_s.invoice_id and new.order_number=(select display_number from public.business_invoices where invoice_id=v_s.invoice_id))then raise exception 'Issued work reference is immutable'using errcode='55000';end if;
   if(to_jsonb(new)-array['status','updated_at','order_number'])is distinct from(to_jsonb(old)-array['status','updated_at','order_number'])then raise exception 'Issued walk-in identity and assignment are immutable'using errcode='55000';end if;
   if new.status is distinct from old.status and not((old.status='received'and new.status='cancelled'and exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=new.order_id::text))or exists(select 1 from private.service_work_ledger e where e.target_kind='order'and e.order_id=new.order_id and e.expected_status=old.status and e.next_status=new.status and e.creator_xid=txid_current()and e.actor_id=auth.uid()and e.command_id is not null))then raise exception 'Exact authorized work witness required'using errcode='55000';end if;
  end if;return new;
 end if;
 select * into v_s from private.offline_walk_in_subjects where invoice_id=new.invoice_id;
 if not found then
  if exists(select 1 from private.offline_walk_in_subjects where order_id=new.order_id)then raise exception 'Typed work already has its canonical invoice'using errcode='55000';end if;
  if new.commission_model<>'legacy_scalar'or new.commission_share is null then raise exception 'Typed commission requires canonical sidecar proof'using errcode='55000';end if;return new;
 end if;
 select sum(c.amount),case when count(distinct c.rate_percent)=1 then min(c.amount)end,count(distinct c.rate_percent),array_agg(c.staff_id order by c.staff_id),jsonb_agg(c.staff_name order by c.staff_id)
 into v_total,v_share,v_rates,v_ids,v_workers from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id;
 if new.commission_model<>'walk_in_frozen_workers'or new.order_id is distinct from v_s.order_id or new.branch_id<>v_s.branch_id or not((v_s.reward_issue_id is null and new.total=v_s.gross and new.discount=0 and new.reward_snapshot is null)or(v_s.reward_issue_id is not null and coalesce(private.offline_reward_invoice_terms_match(new.invoice_id,new.order_id,new.reward_snapshot,new.total,new.discount),false)))or new.sale_type<>'service' or new.commission_total is distinct from v_total or new.commission_share is distinct from v_share or v_ids is distinct from v_s.staff_ids or new.workers is distinct from v_workers or exists(select 1 from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id and(c.gross<>v_s.gross or c.assigned_count<>cardinality(v_s.staff_ids)))then raise exception 'Complete truthful frozen worker commission proof required'using errcode='55000';end if;
 if tg_op='INSERT'and v_s.creator_xid<>txid_current()then raise exception 'Invoice must be issued with new canonical proof'using errcode='55000';end if;
 if tg_op='UPDATE'then
  if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued walk-in finance and commission facts are immutable'using errcode='55000';end if;
  if new.status='void'and old.status<>'void'and not exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=v_s.order_id::text)then raise exception 'Use canonical unpaid cancellation'using errcode='55000';end if;
 end if;return new;
end$function$;
create or replace function private.reserve_offline_reward_candidates(p_request uuid,p_profile uuid,p_car uuid,p_channel uuid,p_expected_gross numeric)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;c private.offline_reward_reservation_commands;channel private.offline_visit_channel_versions;rules private.loyalty_redemption_rule_versions;service public.business_catalog_items;
 payload jsonb;plan jsonb;fresh jsonb;ids uuid[];allocations jsonb;quote uuid:=gen_random_uuid();deadline timestamptz;threshold integer;fingerprint text;item jsonb;pending record;
begin
 actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or p_profile is null or p_car is null or p_channel is null or p_expected_gross is null or p_expected_gross<=0 or p_expected_gross::text in('NaN','Infinity','-Infinity')then raise exception 'Exact typed component request required'using errcode='22023';end if;
 payload:=jsonb_build_object('owner_kind','offline_profile','owner_id',p_profile,'car_reference',p_car,'channel',p_channel,'expected_gross',p_expected_gross,'operator',actor,'purpose','private_reservation_component');
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||p_profile::text,0));
 -- Free only actually expired/refunded UNCONSUMED holds before debt allocation;
 -- otherwise an expired reserve could prevent repayment and every later retry.
 for pending in select cmd.request_id from private.offline_reward_reservation_commands cmd join private.service_reward_quotes held_quote on held_quote.quote_id=cmd.quote_id where cmd.offline_profile_id=p_profile and cmd.state='active'and(held_quote.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims held_claim where held_claim.reserve_request_id=cmd.request_id and private.reward_credit_refund(held_claim.earning_id)is not null))order by cmd.request_id loop
 perform private.release_offline_reward_reservation(pending.request_id,'Release expired or refunded unconsumed hold before debt sync');end loop;
 perform private.sync_offline_profile_rewards(p_profile);
 if not exists(select 1 from private.offline_reward_reservation_commands where request_id=p_request)and not private.offline_reward_debt_clear(p_profile,(select rules_version_id from private.offline_visit_channel_versions where version_id=p_channel))then raise exception 'Typed consumed-source debt or owner review outstanding'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||p_request::text,0));
 select *into c from private.offline_reward_reservation_commands where request_id=p_request;
 if found then
 if c.requested_by<>actor or c.offline_profile_id<>p_profile then raise exception 'Reservation unavailable'using errcode='42501';end if;
 if c.payload<>payload then raise exception 'Reservation request changed'using errcode='22023';end if;
 if c.state='active'and exists(select 1 from private.service_reward_quotes q where q.quote_id=c.quote_id and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=c.request_id and private.reward_credit_refund(h.earning_id)is not null)))then return private.release_offline_reward_reservation(p_request,'Actual expiry or source refund invalidated unconsumed hold');end if;
 return private.offline_reward_reservation_snapshot(p_request);end if;
 -- Same owner lock is acquired BEFORE all request locks, including expired-hold release.
 for pending in select cmd.request_id from private.offline_reward_reservation_commands cmd join private.service_reward_quotes q on q.quote_id=cmd.quote_id where cmd.offline_profile_id=p_profile and cmd.state='active'and(q.expires_at<=clock_timestamp()or exists(select 1 from private.reward_credit_claims h where h.reserve_request_id=cmd.request_id and private.reward_credit_refund(h.earning_id)is not null))order by cmd.request_id loop
 perform private.release_offline_reward_reservation(pending.request_id,'Release expired or actually refunded unconsumed component hold');end loop;
 select *into channel from private.offline_visit_channel_versions where version_id=p_channel;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=channel.rules_version_id;
 select *into service from public.business_catalog_items where item_id=(rules.terms_snapshot#>>'{reward_service,id}')::uuid and branch_id=channel.branch_id and item_type='service'and is_active and is_public for share;
 if service.item_id is null or service.price is distinct from p_expected_gross or not exists(select 1 from private.offline_customer_car_refs car where car.car_ref_id=p_car and car.profile_id=p_profile)then raise exception 'Actual owner/car/reward service price changed'using errcode='40001';end if;
 plan:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if not coalesce((plan->>'threshold_met')::boolean,false)then raise exception 'Insufficient actual candidate credits'using errcode='55000';end if;
 select array_agg(candidate.value::uuid order by candidate.ordinality)into ids from jsonb_array_elements_text(plan->'candidate_ids')with ordinality candidate(value,ordinality);
 perform 1 from public.business_invoices i join private.canonical_loyalty_visits e on e.invoice_id=i.invoice_id where e.id=any(ids)order by i.invoice_id for update of i;
 fresh:=private.plan_reward_owner_candidates('offline_profile',p_profile,rules.rules_version_id,p_channel);
 if fresh->'candidate_ids'is distinct from plan->'candidate_ids'or fresh->'allocation_candidates'is distinct from plan->'allocation_candidates'then raise exception 'Candidate facts changed after financial lock wait'using errcode='40001';end if;
 allocations:=fresh->'allocation_candidates';threshold:=(fresh->>'required_visits')::integer;
 select least(clock_timestamp()+interval'5 minutes',min((entry#>>'{credit_terms,expires_at}')::timestamptz))into deadline from jsonb_array_elements(allocations)entry;
 if rules.rules->>'expiry'='snapshot_offer_end'then deadline:=least(deadline,(rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz);end if;
 if deadline is null or deadline<=clock_timestamp()then raise exception 'Original credit or selected benefit expiry passed'using errcode='55000';end if;
 fingerprint:=encode(extensions.digest(jsonb_build_object('payload',payload,'rules',rules.terms_snapshot,'earning_ids',ids,'allocations',allocations,'gross',service.price,'expires_at',deadline)::text,'sha256'),'hex');
 insert into private.offline_reward_reservation_commands(request_id,offline_profile_id,requested_by,quote_id,payload,state,creator_xid)values(p_request,p_profile,actor,quote,payload,'preparing',txid_current());
 insert into private.service_reward_quotes(quote_id,customer_id,source_channel,payload,branch_id,service_id,vehicle_id,booking_date,booking_time,policy_version_id,rules_version_id,threshold_visits,gross_amount,earning_ids,adoption_ids,allocation_snapshot,terms_snapshot,fingerprint,expires_at,owner_kind,offline_profile_id,offline_car_ref_id,offline_channel_version_id,requested_by,reserve_request_id)
 values(quote,null,'walk_in',payload,channel.branch_id,service.item_id,null,null,null,channel.policy_version_id,rules.rules_version_id,threshold,service.price,ids,'{}'::uuid[],allocations,rules.terms_snapshot||jsonb_build_object('source_channel','walk_in','component_reservation',true,'consumption_enabled',false),fingerprint,deadline,'offline_profile',p_profile,p_car,p_channel,actor,p_request);
 insert into private.offline_reward_reservation_events(event_key,request_id,action,actor_id,creator_xid)values('reserve:'||p_request,p_request,'reserve',actor,txid_current());
 for item in select value from jsonb_array_elements(allocations)loop
 insert into private.reward_credit_claims(earning_id,customer_id,kind,quote_id,owner_kind,offline_profile_id,offline_channel_version_id,reserve_request_id,hold_expires_at)
 values((item->>'earning_id')::uuid,null,'reserve',quote,'offline_profile',p_profile,p_channel,p_request,deadline);end loop;
 update private.offline_reward_reservation_commands set state='active',result=jsonb_build_object('state','active','consumption_enabled',false)where request_id=p_request;
 return private.offline_reward_reservation_snapshot(p_request);
end$$;

create table private.offline_reward_post_issue_withdrawals(request_id uuid primary key,consent_request_id uuid not null references private.offline_reward_financial_consents(request_id),actor_id uuid not null references public.customers(id),link_id uuid not null references private.offline_customer_trusted_links(link_id),result jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.offline_reward_post_issue_withdrawals enable row level security;
revoke all on private.offline_reward_post_issue_withdrawals from public,anon,authenticated,service_role;
create trigger immutable_post_issue_withdrawal before update or delete on private.offline_reward_post_issue_withdrawals for each row execute function private.immutable_canonical_visit();

-- Consent withdrawal and exact issuer consumption share the target mutex.
create or replace function private.offline_financial_proposal_view(p_proposal uuid,p_link uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_proposal private.offline_reward_financial_proposals;v_preparation private.offline_reward_consumption_preparations;v_current jsonb;v_ready boolean:=false;
begin
 select *into v_proposal from private.offline_reward_financial_proposals where proposal_id=p_proposal and customer_id=auth.uid()and link_id=p_link;
 if not found then return jsonb_build_object('state','unavailable','issuer_enabled',false,'redemption_enabled',false);end if;
 if exists(select 1 from private.offline_reward_issue_commands cmd join private.offline_reward_financial_consents consent on consent.request_id=cmd.consent_request_id where cmd.state='issued'and consent.proposal_id=p_proposal)then return jsonb_build_object('state','issued','proposal_id',p_proposal,'fingerprint',v_proposal.fingerprint,'terms',v_proposal.display_terms,'reward_issued',true,'issuer_enabled',false,'redemption_enabled',false);end if;
 select *into v_preparation from private.offline_reward_consumption_preparations where request_id=v_proposal.preparation_id;
 if v_proposal.expires_at>clock_timestamp()and not exists(select 1 from private.offline_reward_consumption_closures where request_id=v_proposal.preparation_id)then
 begin v_current:=private.lock_offline_reward_hold_witness(v_preparation.reservation_id);v_ready:=v_current=v_proposal.witness;
 exception when object_not_in_prerequisite_state then v_ready:=false;end;end if;
 return jsonb_build_object('state',case when v_ready then'proposal'else'inactive'end,'proposal_id',p_proposal,'fingerprint',v_proposal.fingerprint,'terms',v_proposal.display_terms,
 'consent',jsonb_build_object('version','offline-reward-financial-v1','notice_ar',private.offline_reward_financial_notice('ar',v_proposal.display_terms),'notice_en',private.offline_reward_financial_notice('en',v_proposal.display_terms)),
 'issuer_enabled',false,'redemption_enabled',false,'reward_issued',false);
end$$;
create or replace function private.get_my_offline_reward_financial_consent(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_consent private.offline_reward_financial_consents;v_revocation private.offline_reward_financial_revocations;v_view jsonb;
begin
 v_link:=private.require_offline_financial_customer();
 if p_request is null then raise exception 'Exact consent nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_request::text,0));
 select *into v_revocation from private.offline_reward_financial_revocations where consent_request_id=p_request order by created_at,request_id limit 1;
 select *into v_consent from private.offline_reward_financial_consents where request_id=p_request;
 if(v_revocation.request_id is not null and(v_revocation.actor_id<>auth.uid()or v_revocation.link_id<>v_link.link_id))or(v_consent.request_id is not null and(v_consent.actor_id<>auth.uid()or v_consent.link_id<>v_link.link_id))then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_revocation.request_id is not null then return jsonb_build_object('state','revoked','request_id',p_request,'definitive_failure',true,'issuer_enabled',false);end if;
 if v_consent.request_id is null then return jsonb_build_object('state','absent','request_id',p_request,'definitive_failure',false,'issuer_enabled',false);end if;
 v_view:=private.offline_financial_proposal_view(v_consent.proposal_id,v_link.link_id);
 return jsonb_build_object('state',case v_view->>'state'when'proposal'then'consent_recorded'when'issued'then'issued'else'inactive'end,'request_id',p_request,'proposal_id',v_consent.proposal_id,'fingerprint',v_consent.fingerprint,
 'consent',v_consent.consent,'proposal',v_view,'definitive_failure',false,'issuer_enabled',false,'redemption_enabled',false,'reward_issued',v_view->>'state'='issued');
end$$;
create or replace function private.revoke_my_offline_reward_financial_consent(p_request uuid,p_consent_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_prior private.offline_reward_financial_revocations;v_consent private.offline_reward_financial_consents;v_issued_receipt private.offline_reward_post_issue_withdrawals;v_withdrawal_result jsonb;
begin
 v_link:=private.require_offline_financial_customer();
 if p_request is null or p_consent_request is null then raise exception 'Exact revocation and consent nonce required'using errcode='22023';end if;
 -- Global revocation nonce then consent target. No reverse acquisition elsewhere.
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-revoke:'||p_request::text,0));
 select *into v_issued_receipt from private.offline_reward_post_issue_withdrawals where request_id=p_request;
 if found then
 if v_issued_receipt.actor_id<>auth.uid()or v_issued_receipt.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_issued_receipt.consent_request_id<>p_consent_request then raise exception 'Revocation nonce changed'using errcode='22023';end if;return v_issued_receipt.result;end if;
 select *into v_prior from private.offline_reward_financial_revocations where request_id=p_request;
 if found then
 if v_prior.actor_id<>auth.uid()or v_prior.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 if v_prior.consent_request_id<>p_consent_request then raise exception 'Revocation nonce changed'using errcode='22023';end if;
 return private.get_my_offline_reward_financial_consent(p_consent_request);end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-financial-consent:'||p_consent_request::text,0));
 select *into v_consent from private.offline_reward_financial_consents where request_id=p_consent_request;
 if found and(v_consent.actor_id<>auth.uid()or v_consent.link_id<>v_link.link_id)then raise exception 'Consent unavailable'using errcode='42501';end if;
 if exists(select 1 from private.offline_reward_issue_commands where consent_request_id=p_consent_request and state='issued')then
 v_withdrawal_result:=jsonb_build_object('state','already_issued','request_id',p_consent_request,'revoke_request_id',p_request,'withdrawal_applied',false,'reward_issued',true,'issuer_enabled',false);
 insert into private.offline_reward_post_issue_withdrawals(request_id,consent_request_id,actor_id,link_id,result)values(p_request,p_consent_request,auth.uid(),v_link.link_id,v_withdrawal_result);
 return v_withdrawal_result;end if;
 select *into v_prior from private.offline_reward_financial_revocations where consent_request_id=p_consent_request order by created_at,request_id limit 1;
 if found then
 if v_prior.actor_id<>auth.uid()or v_prior.link_id<>v_link.link_id then raise exception 'Consent unavailable'using errcode='42501';end if;
 end if;
 insert into private.offline_reward_financial_revocations(request_id,consent_request_id,actor_id,link_id)values(p_request,p_consent_request,auth.uid(),v_link.link_id);
 return private.get_my_offline_reward_financial_consent(p_consent_request);
end$$;
create or replace function private.get_offline_reward_consumption_preparation(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_command private.offline_reward_consumption_preparations;v_closed private.offline_reward_consumption_closures;v_current jsonb;v_usable boolean:=false;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 v_actor:=private.require_offline_reservation_operator();
 if p_request is null then raise exception 'Exact private nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_request::text,0));
 select *into v_closed from private.offline_reward_consumption_closures where request_id=p_request;
 select *into v_command from private.offline_reward_consumption_preparations where request_id=p_request;
 if(v_closed.request_id is not null and v_closed.closed_by<>v_actor)or(v_command.request_id is not null and v_command.requested_by<>v_actor)then raise exception 'Preparation unavailable'using errcode='42501';end if;
 if v_closed.request_id is not null then return jsonb_build_object('state','closed','request_id',p_request,'definitive_failure',true,'consumption_enabled',false,'issuer_enabled',false);end if;
 if v_command.request_id is null then return jsonb_build_object('state','absent','request_id',p_request,'definitive_failure',false,'consumption_enabled',false,'issuer_enabled',false);end if;
 if exists(select 1 from private.offline_reward_issue_commands where preparation_id=p_request and state='issued')then return jsonb_build_object('state','consumed','request_id',p_request,'payload',v_command.payload,'witness',v_command.witness,'hold_current',false,'definitive_failure',false,'consumption_enabled',false,'issuer_enabled',false);end if;
 begin
 v_current:=private.lock_offline_reward_hold_witness(v_command.reservation_id);
 v_usable:=v_current=v_command.witness;
 exception when object_not_in_prerequisite_state then v_usable:=false;end;
 return jsonb_build_object('state','prepared','request_id',p_request,'payload',v_command.payload,'witness',v_command.witness,'hold_current',v_usable,
 'definitive_failure',false,'consumption_enabled',false,'issuer_enabled',false,'financial_consent_recorded',false);
end$$;
create or replace function private.close_offline_reward_consumption(p_request uuid,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid;v_command private.offline_reward_consumption_preparations;v_closed private.offline_reward_consumption_closures;v_hold private.offline_reward_reservation_commands;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 v_actor:=private.require_offline_reservation_operator();
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact nonce and audit reason required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-consumption:'||p_request::text,0));
 select *into v_closed from private.offline_reward_consumption_closures where request_id=p_request;
 if found then
 if v_closed.closed_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 return private.get_offline_reward_consumption_preparation(p_request);end if;
 select *into v_command from private.offline_reward_consumption_preparations where request_id=p_request;
 if v_command.request_id is not null and exists(select 1 from private.offline_reward_issue_commands where preparation_id=p_request and state='issued')then
 if v_command.requested_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;return private.get_offline_reward_consumption_preparation(p_request);end if;
 if found then
 if v_command.requested_by<>v_actor then raise exception 'Preparation unavailable'using errcode='42501';end if;
 select *into strict v_hold from private.offline_reward_reservation_commands where request_id=v_command.reservation_id;
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||v_hold.offline_profile_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-reward-reserve:'||v_command.reservation_id::text,0));
 perform 1 from public.business_invoices invoice join private.canonical_loyalty_visits earning on earning.invoice_id=invoice.invoice_id
 join private.service_reward_quotes quote on earning.id=any(quote.earning_ids)
 where quote.quote_id=v_hold.quote_id order by invoice.invoice_id for update of invoice;
 -- Existing release accepts ONLY unconsumed reserve claims and has its own
 -- same-transaction event witness. No restore, debt forgiveness or new credit.
 perform private.release_offline_reward_reservation(v_command.reservation_id,trim(p_reason));
 end if;
 insert into private.offline_reward_consumption_closures(request_id,closed_by,reservation_id,reason)values(p_request,v_actor,v_command.reservation_id,trim(p_reason));
 return private.get_offline_reward_consumption_preparation(p_request);
end$$;
create function private.list_offline_reward_refund_reviews(p_profile uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$begin
 perform private.require_offline_reservation_operator();
 if p_profile is null or not exists(select 1 from private.offline_customer_profiles where profile_id=p_profile)then raise exception 'Actual typed profile required'using errcode='22023';end if;
 perform private.sync_offline_profile_rewards(p_profile);
 return coalesce((select jsonb_agg(jsonb_build_object('review_id',review.review_id,'invoice_number',invoice.display_number,'mode',review.mode,'created_at',review.created_at,'acknowledged_at',review.acknowledged_at,'closed_at',review.closed_at,'debt_outstanding',not exists(select 1 from private.reward_credit_claims claim where claim.debt_id=review.review_id and claim.released_at is null and private.reward_credit_refund(claim.earning_id)is null),'issued_reward_honored',true)order by review.created_at,review.review_id)
 from private.reward_refund_reviews review join private.service_reward_redemptions receipt on receipt.redemption_id=review.redemption_id join public.business_invoices invoice on invoice.invoice_id=receipt.invoice_id where review.owner_kind='offline_profile'and review.offline_profile_id=p_profile),'[]'::jsonb);
end$$;
revoke all on function private.list_offline_reward_refund_reviews(uuid)from public,anon,authenticated,service_role;
revoke all on function private.offline_reward_invoice_terms_match(text,uuid,jsonb,numeric,numeric),private.typed_offline_reward_invoice_coverage(text),private.get_offline_reward_issue(uuid),private.prepare_offline_reward_issue(uuid,uuid,uuid,uuid,uuid[]),private.place_offline_reward_issue(uuid),private.close_offline_reward_issue(uuid),private.ack_offline_reward_issue(uuid),private.cancel_offline_reward_issue(uuid,uuid,text),private.resolve_offline_reward_refund_review(uuid,uuid,text),private.reward_invoice_coverage_auth_before_offline_issuer(text)from public,anon,authenticated,service_role;
-- Installation witness only: not business activation or public spending. Verify
-- all coherent creator/sync/coverage/authorization pieces before lifting A's fence.
do $$begin
 if to_regprocedure('private.lock_linked_offline_reward_issuer_consent(uuid,uuid)')is null
 or to_regprocedure('private.sync_offline_profile_rewards(uuid)')is null
 or to_regprocedure('private.place_offline_reward_issue(uuid)')is null
 or to_regprocedure('private.cancel_offline_reward_issue(uuid,uuid,text)')is null
 or to_regprocedure('private.typed_offline_reward_invoice_coverage(text)')is null
 or not exists(select 1 from pg_trigger where tgname='offline_reward_receipt_commit'and not tgisinternal)
 then raise exception 'Complete private typed issuer dependencies required'using errcode='55000';end if;
 update private.offline_reward_issuer_runtime set kernel_installed=true where singleton;
end$$;
-- Existing public earning/read/spend flags and disabled CHECKs untouched.
commit;
