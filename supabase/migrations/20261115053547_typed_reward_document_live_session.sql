begin;
-- Preserve the exact installed body, including its existing invoice authorization.
alter function private.invoice_document_data(uuid,boolean) rename to invoice_document_data_before_typed_session_guard;
revoke all on function private.invoice_document_data_before_typed_session_guard(uuid,boolean) from public,anon,authenticated,service_role;

create function private.require_typed_reward_document_session(p_branch uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid:=auth.uid(); sid uuid;
begin
 begin sid:=(auth.jwt()->>'session_id')::uuid;
 exception when invalid_text_representation then
  raise exception 'Invoice unavailable or not authorized' using errcode='42501';
 end;
 if actor is null or sid is null then
  raise exception 'Invoice unavailable or not authorized' using errcode='42501';
 end if;
 -- Session deletion/sign-out and identity mutations serialize with this read.
 perform 1 from auth.users u join auth.sessions sess on sess.user_id=u.id
 where u.id=actor and sess.id=sid and u.email_confirmed_at is not null
 and u.deleted_at is null and (u.banned_until is null or u.banned_until<=clock_timestamp())
 and (sess.not_after is null or sess.not_after>clock_timestamp()) for share of u,sess;
 if not found then raise exception 'Invoice unavailable or not authorized' using errcode='42501';end if;
 -- Lock existing authorization facts without imposing an owner-only restriction.
 perform 1 from public.staff_profiles where user_id=actor for share;
 perform 1 from public.staff_branch_access where user_id=actor and branch_id=p_branch for share;
end $$;
revoke all on function private.require_typed_reward_document_session(uuid) from public,anon,authenticated,service_role;

create function private.invoice_document_data(p_token uuid,p_allow_revoked boolean) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare typed_branch uuid;
begin
 select i.branch_id into typed_branch
 from public.business_invoices i join private.offline_walk_in_subjects subj on subj.invoice_id=i.invoice_id
 where i.document_token=p_token and subj.reward_issue_id is not null;
 if found then perform private.require_typed_reward_document_session(typed_branch);end if;
 return private.invoice_document_data_before_typed_session_guard(p_token,p_allow_revoked);
end $$;
revoke all on function private.invoice_document_data(uuid,boolean) from public,anon,authenticated,service_role;
-- Reparse the published resolver's delegation after the rename; retain its OID/ACL.
create or replace function private.resolve_invoice_document(p_token uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog
as $$select private.invoice_document_data(p_token,false)$$;
notify pgrst,'reload schema';
commit;
