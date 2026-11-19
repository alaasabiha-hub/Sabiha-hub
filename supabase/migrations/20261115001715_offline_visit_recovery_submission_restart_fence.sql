begin;
-- Retained cancellation fence for an UNKNOWN nonce only. Never deletes/undoes a
-- submitted case, canonical claim, accepted receipt or notification.
create table private.visit_recovery_submission_closures(
 request_id uuid primary key,actor_id uuid not null references public.customers(id),
 closed_at timestamptz not null default clock_timestamp());
alter table private.visit_recovery_submission_closures enable row level security;
revoke all on private.visit_recovery_submission_closures from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_submission_closure before update or delete on private.visit_recovery_submission_closures
 for each row execute function private.immutable_visit_recovery_submission();

create function private.get_my_visit_recovery_submission(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare ident record;prior private.visit_recovery_submission_requests;closed_actor uuid;begin
 if p_request is null then raise exception 'Exact own submission nonce required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Recovery receipt requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-submit:'||p_request::text,0));
 select * into strict ident from private.visit_recovery_request_identity();
 select * into prior from private.visit_recovery_submission_requests where request_id=p_request;
 if found then
 if prior.actor_id<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','accepted','request_id',p_request,'payload',prior.payload,'result',private.get_my_visit_recovery_request(prior.case_id),'definitive_failure',false);
 end if;
 select actor_id into closed_actor from private.visit_recovery_submission_closures where request_id=p_request;
 if found then
 if closed_actor<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','closed','request_id',p_request,'payload',null,'result',null,'definitive_failure',true);
 end if;
 -- No reconstruction from current notice or latest case: absence may race an
 -- in-flight producer. Explicit CLOSE must fence this exact nonce first.
 return jsonb_build_object('state','absent','request_id',p_request,'payload',null,'result',null,'definitive_failure',false);
end$$;
create function private.close_my_visit_recovery_submission(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare ident record;prior private.visit_recovery_submission_requests;closed_actor uuid;begin
 if p_request is null then raise exception 'Exact own submission nonce required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Recovery close requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-submit:'||p_request::text,0));
 select * into strict ident from private.visit_recovery_request_identity();
 select * into prior from private.visit_recovery_submission_requests where request_id=p_request;
 if found then
 if prior.actor_id<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 -- A committed producer wins: return its actual exact receipt; never cancel it.
 return private.get_my_visit_recovery_submission(p_request);
 end if;
 select actor_id into closed_actor from private.visit_recovery_submission_closures where request_id=p_request;
 if found then
 if closed_actor<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 else
 insert into private.visit_recovery_submission_closures(request_id,actor_id)values(p_request,ident.actor_id);
 end if;
 return jsonb_build_object('state','closed','request_id',p_request,'payload',null,'result',null,'definitive_failure',true);
end$$;

-- Exact final APPLIED225809 source SHA256 a0a4b10742e1f6e57f3d036b7f877213bc40e1ba654563ab7f439b56c1a517d3.
-- Only added closed_actor declaration + close-fence block; all prior logic preserved.
create or replace function private.submit_visit_recovery_request(p_request uuid,p_consent jsonb)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare ident record;prior private.visit_recovery_submission_requests;c private.visit_recovery_customer_requests;
 normalized jsonb;language_code text;created boolean:=false;closed_actor uuid;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Recovery submissions require READ COMMITTED'using errcode='25001';end if;
 if p_request is null or p_consent is null or jsonb_typeof(p_consent)<>'object'
 or not(p_consent?&array['accepted','version','language','text'])or p_consent-array['accepted','version','language','text']<>'{}'::jsonb
 or not(p_consent @> '{"accepted":true,"version":"visit-recovery-v1"}'::jsonb)then
 raise exception 'Explicit recovery request consent required'using errcode='22023';end if;
 language_code:=p_consent->>'language';
 if language_code is null or language_code not in('ar','en')or p_consent->>'text'is distinct from private.visit_recovery_request_notice(language_code)then
 raise exception 'Actual recovery request notice required'using errcode='22023';end if;
 normalized:=jsonb_build_object('consent',p_consent);
 -- One global request identity, then actual identity locks, then one actor envelope.
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-submit:'||p_request::text,0));
 select * into strict ident from private.visit_recovery_request_identity();
 select * into prior from private.visit_recovery_submission_requests where request_id=p_request;
 if found then
 if prior.actor_id<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 if prior.payload<>normalized then raise exception 'Recovery request identity reused with changed consent'using errcode='22023';end if;
 return private.get_my_visit_recovery_request(prior.case_id);
 end if;
 -- New unknown-nonce close fence. Existing accepted replay above is unchanged.
 select actor_id into closed_actor from private.visit_recovery_submission_closures where request_id=p_request;
 if found then
 if closed_actor<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','closed','request_id',p_request,'payload',null,'result',null,'definitive_failure',true);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||ident.actor_id::text,0));
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and status in('awaiting_matching','more_info');
 if not found then
 insert into private.visit_recovery_customer_requests(requester_id,email_hash,email_confirmed_at,phone_hash,consent)
 values(ident.actor_id,ident.email_hash,ident.email_confirmed_at,ident.phone_hash,p_consent)returning * into c;created:=true;
 end if;
 insert into private.visit_recovery_submission_requests(request_id,actor_id,payload,case_id)values(p_request,ident.actor_id,normalized,c.case_id);
 if created then
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'customer',ident.actor_id,'recovery_received');
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'active_owner_pool',null,'recovery_submitted');
 end if;
 -- Existing open case is returned, never silently replaced or re-fingerprinted.
 return private.get_my_visit_recovery_request(c.case_id);
end$$;

revoke all on function private.get_my_visit_recovery_submission(uuid),private.close_my_visit_recovery_submission(uuid)from public,anon,service_role;
grant execute on function private.get_my_visit_recovery_submission(uuid),private.close_my_visit_recovery_submission(uuid)to authenticated;
create function public.get_my_visit_recovery_submission(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_visit_recovery_submission(p_request)$$;
create function public.close_my_visit_recovery_submission(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_my_visit_recovery_submission(p_request)$$;
revoke all on function public.get_my_visit_recovery_submission(uuid),public.close_my_visit_recovery_submission(uuid)from public,anon,service_role;
grant execute on function public.get_my_visit_recovery_submission(uuid),public.close_my_visit_recovery_submission(uuid)to authenticated;
-- Existing submit EXECUTE boundaries, request/case rows, owner/canonical bridge,
-- actual-session resolver, actor envelope and notifications remain unchanged.
notify pgrst,'reload schema';
commit;
