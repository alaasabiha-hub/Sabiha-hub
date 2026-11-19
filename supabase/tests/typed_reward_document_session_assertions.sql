-- SOURCE helper only. Root runs on the isolated qa_typed_reward_* clone in an outer ROLLBACK.
-- p_foreign_session must be an ACTUAL session owned by another account.
create function pg_temp.assert_typed_reward_document_sessions(p_token uuid,p_foreign_session uuid,p_legacy_token uuid default null)
returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims',true);
 claims jsonb:=current_setting('request.jwt.claims')::jsonb;
 live_session uuid; actor uuid:=auth.uid(); expected jsonb; observed jsonb;
 variant jsonb; denied integer:=0; legacy_expected jsonb;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then
  raise exception 'Isolated typed reward clone and postgres required';end if;
 live_session:=(claims->>'session_id')::uuid;
 if not exists(select 1 from auth.sessions where id=p_foreign_session and user_id<>actor)then
  raise exception 'Actual foreign session required';end if;
 if not exists(select 1 from public.business_invoices i join private.offline_walk_in_subjects s on s.invoice_id=i.invoice_id
 where i.document_token=p_token and s.reward_issue_id is not null)then raise exception 'Actual typed reward document required';end if;
 expected:=private.invoice_document_data_before_typed_session_guard(p_token,false);
 set local role authenticated;
 observed:=public.resolve_invoice_document(p_token);
 reset role;
 if observed is distinct from expected then raise exception 'Valid-session document changed';end if;
 if p_legacy_token is not null then
  if exists(select 1 from public.business_invoices i join private.offline_walk_in_subjects s on s.invoice_id=i.invoice_id
   where i.document_token=p_legacy_token and s.reward_issue_id is not null)then raise exception 'Legacy token is typed reward';end if;
  legacy_expected:=private.invoice_document_data_before_typed_session_guard(p_legacy_token,false);
 end if;
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
  if p_legacy_token is not null then
   set local role authenticated;
   observed:=public.resolve_invoice_document(p_legacy_token);
   reset role;
   if observed is distinct from legacy_expected then raise exception 'Legacy delegation changed';end if;
  end if;
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
 'expired_session_denied',true,'deleted_session_denied',true,'legacy_golden_checked',p_legacy_token is not null);
end $$;
