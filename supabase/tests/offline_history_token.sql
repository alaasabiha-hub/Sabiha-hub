-- SOURCE ONLY token-reader follow-up acceptance. Root controls LOCAL execution.
-- All fixtures, including test sessions, consent and runtime enablement roll back.
begin;
do $$
declare v_owner uuid;v_manager uuid;v_worker uuid;v_customer uuid;v_other uuid;
 v_branch uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_session uuid:=gen_random_uuid();v_other_session uuid:=gen_random_uuid();
 v_intake jsonb;v_foreign jsonb;v_reg jsonb;v_claim_consent jsonb;v_scope jsonb;v_claim uuid:=gen_random_uuid();v_link uuid;
 v_registration uuid:=gen_random_uuid();v_cmd uuid:=gen_random_uuid();v_cmd2 uuid:=gen_random_uuid();v_consent_request uuid:=gen_random_uuid();v_receipt jsonb;v_result jsonb;v_doc jsonb;v_context jsonb;v_history jsonb;
 v_invoice text;v_invoice2 text;v_order uuid;v_order2 uuid;v_denied boolean;v_pre text;v_post text;v_snapshot jsonb;v_scope_result jsonb;
 v_now timestamp:=clock_timestamp()at time zone'Africa/Cairo';
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_manager from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active and user_id<>v_manager limit 1;
 select c.id into strict v_customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<clock_timestamp())
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)and not exists(select 1 from private.offline_customer_trusted_links l where l.auth_user_id=c.id and l.revoked_at is null)
 order by(select count(*)from private.offline_claim_requests r where r.actor_id=c.id and r.created_at>clock_timestamp()-interval'1 hour'),c.id limit 1;
 select c.id into strict v_other from public.customers c join auth.users u on u.id=c.id where c.id<>v_customer and u.email_confirmed_at is not null and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 -- Existing Auth accounts only; synthetic persisted SQL-test sessions, no Auth creation or quota reset.
 insert into auth.sessions(id,user_id,created_at,updated_at,not_after)values(v_session,v_customer,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval'1 hour'),(v_other_session,v_other,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval'1 hour');
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار خصوصية السجل','History privacy QA');
 update public.business_branch_hours set is_open=true,opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 insert into public.staff_branch_access(user_id,branch_id)values(v_manager,v_branch),(v_worker,v_branch);
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on)values(v_worker,0,15,'EGP',v_now::date-1)
 on conflict(staff_id)do update set commission_percent=15,currency='EGP',starts_on=v_now::date-1,ends_on=null,updated_at=clock_timestamp();
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_service,v_branch,'service','History QA actual service','sedan',120,5,'wash',true,true);
 assert not(select enabled from private.offline_history_runtime where id),'Migration must ship disabled';
 assert not has_table_privilege('authenticated','private.offline_history_scope_consents','SELECT');
 assert not has_table_privilege('service_role','private.offline_history_runtime','UPDATE');
 assert not has_function_privilege('authenticated','private.resolve_my_offline_history_link()','EXECUTE');
 assert not has_function_privilege('anon','public.get_my_offline_invoice_document(text)','EXECUTE');
 v_reg:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 v_claim_consent:=jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en'));
 v_scope:=jsonb_build_object('accepted',true,'version','offline-history-v1','language','en','text',private.offline_history_notice('en'));
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_intake:=public.register_offline_customer(v_registration,v_branch,'History linked QA','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"HISTORY QA1","brand":"QA"}',v_reg);
 v_foreign:=public.register_offline_customer(gen_random_uuid(),v_branch,'History foreign QA','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"HISTORY QA2"}',v_reg);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform public.prepare_offline_walk_in(v_cmd,v_registration,v_service,120,v_manager,array[v_worker]);
 perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_receipt:=public.place_offline_walk_in(v_cmd);v_invoice:=v_receipt#>>'{result,invoice_id}';v_order:=(v_receipt#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(v_cmd);
 perform set_config('request.jwt.claim.sub',v_customer::text,true);
 v_result:=public.request_offline_customer_claim(v_claim,(v_intake->>'enrollment_receipt_id')::uuid,v_intake->>'enrollment_secret','original_receipt',v_claim_consent);assert v_result->>'status'='pending_owner_review';
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.decide_offline_customer_claim(gen_random_uuid(),v_claim,'approve_with_secret','Original receipt checked for history privacy rollback');v_link:=(v_result->>'link_id')::uuid;
 -- Missing session cannot read or consent, including owner/metadata forgery.
 perform set_config('request.jwt.claim.sub',v_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'user_metadata',jsonb_build_object('owner',true))::text,true);
 assert public.get_my_offline_history_context()->>'state'='review_required';
 v_denied:=false;begin perform public.accept_my_offline_history_scope(v_consent_request,v_scope);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_session)::text,true);
 v_context:=public.get_my_offline_history_context();assert v_context->>'state'='consent_required'and v_context->'cars'='[]'::jsonb;
 v_denied:=false;begin perform public.accept_my_offline_history_scope(v_consent_request,v_claim_consent);exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 v_scope_result:=public.accept_my_offline_history_scope(v_consent_request,v_scope);assert v_scope_result->>'state'='consent_recorded';assert public.accept_my_offline_history_scope(v_consent_request,v_scope)=v_scope_result;
 v_denied:=false;begin perform public.accept_my_offline_history_scope(v_consent_request,v_scope||'{"text":"changed"}');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 assert public.get_my_offline_history_context()->>'state'='acceptance_pending';
 v_denied:=false;begin perform public.get_my_offline_visit_history();exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Runtime gate must block actual data';
 execute 'reset role';update private.offline_history_runtime set enabled=true where id; -- transaction-only acceptance
 select document_snapshot into strict v_snapshot from public.business_invoices where invoice_id=v_invoice;
 select md5(string_agg(x::text,''order by x::text))into v_pre from(select to_jsonb(t)x from public.business_invoices t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.business_payment_events t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from private.canonical_loyalty_visits t union all select to_jsonb(t)from private.reward_credit_claims t)x;
 execute 'set local role authenticated';
 v_context:=public.get_my_offline_history_context();assert v_context->>'state'='available'and jsonb_array_length(v_context->'cars')=1;
 assert v_context->'capabilities' @>'{"linked_visit_history":true,"wallet_access":false,"walk_in_loyalty_accrual":false,"guest_redemption":false,"vehicle_management":false,"qr_reader_bridge":true}';
 assert not(v_context?'profile_id')and not(v_context?'link_id');
 v_history:=public.get_my_offline_visit_history(null,null,1);assert jsonb_array_length(v_history->'items')=1 and v_history#>>'{items,0,invoice_id}'=v_invoice and v_history#>>'{items,0,service_status}'='received'and v_history#>>'{items,0,payment_status}'='unpaid';
 v_doc:=public.get_my_offline_invoice_document(v_invoice);assert v_doc->>'schema_version'='offline-customer-invoice-v1'and (v_doc#>>'{snapshot,total}')::numeric=120;
 assert v_doc#>'{snapshot,tax_amount}'='null'::jsonb and v_doc#>>'{snapshot,tax_configuration}'='not_recorded_in_legacy_invoice';
 assert public.get_my_offline_invoice_by_token((v_doc->>'document_token')::uuid)=v_doc;
 assert v_doc->>'qr_reader_bridge'='true'and v_doc->>'branch_id'=v_branch::text;
 v_denied:=false;begin perform public.get_my_offline_invoice_by_token(gen_random_uuid());exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 assert not(v_doc->'snapshot'?'workers')and not(v_doc?'customer_phone')and not(v_doc?'commission_total')and not(v_doc?'secret_hash');
 assert not(v_doc::text~'(employment_snapshot|commission_percent|secret_hash|contact_hash|secret_proved)');
 v_denied:=false;begin perform public.get_my_offline_invoice_document('unknown');exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.get_my_offline_visit_history(null,null,51);exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 execute 'reset role';
 select md5(string_agg(x::text,''order by x::text))into v_post from(select to_jsonb(t)x from public.business_invoices t union all select to_jsonb(t)from public.business_orders t union all select to_jsonb(t)from public.business_payment_events t union all select to_jsonb(t)from public.vehicles t union all select to_jsonb(t)from private.canonical_loyalty_visits t union all select to_jsonb(t)from private.reward_credit_claims t)x;
 assert v_pre=v_post,'Reader must not mutate financial/vehicle/reward facts';
 -- Post-link same-profile visit is included; foreign typed invoice is denied uniformly.
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);perform set_config('request.jwt.claims','{}',true);
 perform public.prepare_offline_walk_in(v_cmd2,v_registration,v_service,120,v_manager,array[v_worker]);
 perform set_config('request.jwt.claim.sub',v_manager::text,true);v_receipt:=public.place_offline_walk_in(v_cmd2);v_invoice2:=v_receipt#>>'{result,invoice_id}';v_order2:=(v_receipt#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(v_cmd2);
 perform set_config('request.jwt.claim.sub',v_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_session)::text,true);
 v_history:=public.get_my_offline_visit_history(null,null,1);assert v_history->'next_cursor'<>'null'::jsonb;
 v_result:=public.get_my_offline_visit_history((v_history#>>'{next_cursor,created_at}')::timestamptz,(v_history#>>'{next_cursor,order_id}')::uuid,1);
 assert jsonb_array_length(v_result->'items')=1 and v_result#>>'{items,0,invoice_id}'<>v_history#>>'{items,0,invoice_id}';
 perform set_config('request.jwt.claim.sub',v_other::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other,'session_id',v_other_session)::text,true);
 assert public.get_my_offline_history_context()->>'state'='review_required';
 v_denied:=false;begin perform public.get_my_offline_invoice_by_token((v_doc->>'document_token')::uuid);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.get_my_offline_invoice_document(v_invoice);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_other_session)::text,true);
 assert public.get_my_offline_history_context()->>'state'='review_required','Foreign session must not authorize current user';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_session)::text,true);
 execute 'reset role';
 begin
 update auth.sessions set not_after=clock_timestamp()-interval'1 second'where id=v_session;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback expired session'using errcode='PZ031';
 exception when sqlstate'PZ031'then null;end;
 begin
 delete from auth.sessions where id=v_session;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback removed session'using errcode='PZ032';
 exception when sqlstate'PZ032'then null;end;
 begin
 update auth.users set email='qa-history-'||gen_random_uuid()::text||'@invalid.test'where id=v_customer;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback email change'using errcode='PZ037';
 exception when sqlstate'PZ037'then null;end;
 begin
 update public.business_invoices set document_link_enabled=false where invoice_id=v_invoice;
 execute 'set local role authenticated';v_denied:=false;begin perform public.get_my_offline_invoice_document(v_invoice);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;raise exception 'rollback disabled document'using errcode='PZ038';
 exception when sqlstate'PZ038'then null;end;
 begin
 update auth.users set email_confirmed_at=email_confirmed_at+interval'1 second'where id=v_customer;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback confirmation change'using errcode='PZ033';
 exception when sqlstate'PZ033'then null;end;
 begin
 update auth.users set banned_until=clock_timestamp()+interval'1 day'where id=v_customer;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback ban'using errcode='PZ034';
 exception when sqlstate'PZ034'then null;end;
 begin
 update auth.users set deleted_at=clock_timestamp()where id=v_customer;
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback deletion'using errcode='PZ035';
 exception when sqlstate'PZ035'then null;end;
 begin
 insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values((v_intake->>'offline_profile_id')::uuid,'+20212345678','EG');
 execute 'set local role authenticated';assert public.get_my_offline_history_context()->>'state'='review_required';raise exception 'rollback contact append'using errcode='PZ036';
 exception when sqlstate'PZ036'then null;end;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);perform set_config('request.jwt.claims','{}',true);
 perform public.cancel_offline_walk_in(gen_random_uuid(),v_order2,'Rollback owner cancellation for reader state');
 perform set_config('request.jwt.claim.sub',v_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_session)::text,true);
 assert public.get_my_offline_invoice_document(v_invoice2)->>'payment_status'='cancelled';
 perform set_config('request.jwt.claim.sub',v_owner::text,true);perform set_config('request.jwt.claims','{}',true);
 perform public.revoke_offline_customer_link(gen_random_uuid(),v_link,'Rollback owner revocation immediately removes history');
 perform set_config('request.jwt.claim.sub',v_customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'session_id',v_session)::text,true);
 assert public.get_my_offline_history_context()->>'state'='review_required';
 v_denied:=false;begin perform public.get_my_offline_invoice_by_token((v_doc->>'document_token')::uuid);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.get_my_offline_invoice_document(v_invoice);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform public.accept_my_offline_history_scope(v_consent_request,v_scope);exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Successful consent replay must still check current link';
 execute 'reset role';assert(select document_snapshot from public.business_invoices where invoice_id=v_invoice)=v_snapshot,'No old issued snapshot mutation';
end$$;
rollback;
