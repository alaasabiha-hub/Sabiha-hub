-- SOURCE helper only. Root runs on the isolated qa_typed_reward_* clone in an outer ROLLBACK.
-- Run once with a real legacy token, optionally separately with a real customer-owned legacy token.
-- p_foreign_session must be an ACTUAL session owned by another account.
create function pg_temp.assert_all_invoice_document_sessions(p_token uuid,p_foreign_session uuid)
returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims',true);
 claims jsonb:=current_setting('request.jwt.claims')::jsonb;
 live_session uuid; actor uuid:=auth.uid(); expected jsonb; observed jsonb;
 variant jsonb; denied integer:=0;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then
  raise exception 'Isolated typed reward clone and postgres required';end if;
 live_session:=(claims->>'session_id')::uuid;
 if not exists(select 1 from auth.sessions where id=p_foreign_session and user_id<>actor)then
  raise exception 'Actual foreign session required';end if;
 expected:=private.invoice_document_data_before_typed_session_guard(p_token,false);
 set local role authenticated;
 observed:=public.resolve_invoice_document(p_token);
 reset role;
 if observed is distinct from expected then raise exception 'Valid-session document changed';end if;
 for variant in select x from jsonb_array_elements(jsonb_build_array(
  claims-'session_id',jsonb_set(claims,'{session_id}','"not-a-uuid"'::jsonb),
  jsonb_set(claims,'{session_id}',to_jsonb(gen_random_uuid()::text)),
  jsonb_set(claims,'{session_id}',to_jsonb(p_foreign_session::text)))) x loop
  perform set_config('request.jwt.claims',variant::text,true);
  begin
   set local role authenticated;
   perform public.resolve_invoice_document(p_token);
   reset role;
   raise exception 'Invalid typed document session accepted';
  exception when insufficient_privilege then reset role;denied:=denied+1;end;
 end loop;
 perform set_config('request.jwt.claims',original_claims,true);
 -- Expiration and deletion are rollback-only negative tests on the actual QA session.
 begin
  update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=live_session and user_id=actor;
  begin
   set local role authenticated;perform public.resolve_invoice_document(p_token);reset role;
   raise exception 'Expired session accepted';
  exception when insufficient_privilege then reset role;end;
  raise exception 'rollback expired-session probe' using errcode='P9S01';
 exception when sqlstate 'P9S01' then null;end;
 begin
  delete from auth.sessions where id=live_session and user_id=actor;
  begin
   set local role authenticated;perform public.resolve_invoice_document(p_token);reset role;
   raise exception 'Deleted session accepted';
  exception when insufficient_privilege then reset role;end;
  raise exception 'rollback deleted-session probe' using errcode='P9S02';
 exception when sqlstate 'P9S02' then null;end;
 set local role authenticated;observed:=public.resolve_invoice_document(p_token);reset role;
 if observed is distinct from expected then raise exception 'QA session was not restored';end if;
 return jsonb_build_object('valid_session_allowed',true,'invalid_session_cases',denied,
 'expired_session_denied',true,'deleted_session_denied',true);
end $$;

-- Supply actual OTHER customer's claims with an actual live session, no fabricated token.
create function pg_temp.assert_other_customer_invoice_denied(p_token uuid) returns void language plpgsql as $$
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 begin
  set local role authenticated;perform public.resolve_invoice_document(p_token);reset role;
  raise exception 'Unrelated customer read invoice';
 exception when insufficient_privilege then reset role;end;
end $$;

-- A genuinely claimable existing QA print job is needed to prove denial happens after
-- the original claim body tentatively updates its lease, and all such changes roll back.
create function pg_temp.assert_invoice_print_invalid_session_rollback(p_job uuid) returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims'); claims jsonb:=original_claims::jsonb;
 before_job jsonb;after_job jsonb; before_attempts jsonb;after_attempts jsonb;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 select to_jsonb(j) into strict before_job from public.business_print_jobs j where job_id=p_job;
 -- First prove the supplied real job is claimable by this actor, then roll back the lease.
 begin
  set local role authenticated;perform public.claim_invoice_print(p_job);reset role;
  raise exception 'rollback valid print probe' using errcode='P9S03';
 exception when sqlstate 'P9S03' then null;end;
 select coalesce(jsonb_agg(to_jsonb(a) order by attempt_id),'[]'::jsonb) into before_attempts
 from public.business_print_attempts a where job_id=p_job;
 perform set_config('request.jwt.claims',(claims-'session_id')::text,true);
 begin
  set local role authenticated;perform public.claim_invoice_print(p_job);reset role;
  raise exception 'Print claimed without persisted session';
 exception when insufficient_privilege then reset role;end;
 perform set_config('request.jwt.claims',original_claims,true);
 select to_jsonb(j) into strict after_job from public.business_print_jobs j where job_id=p_job;
 select coalesce(jsonb_agg(to_jsonb(a) order by attempt_id),'[]'::jsonb) into after_attempts
 from public.business_print_attempts a where job_id=p_job;
 if before_job is distinct from after_job or before_attempts is distinct from after_attempts then
  raise exception 'Failed print claim retained lease or attempt';end if;
 return jsonb_build_object('invalid_session_denied',true,'job_unchanged',true,'attempts_unchanged',true);
end $$;
