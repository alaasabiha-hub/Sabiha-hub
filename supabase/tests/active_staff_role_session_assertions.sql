-- SOURCE ONLY: root executes on qa_typed_reward_* clone in an outer ROLLBACK.
-- Invoke with each real owner/manager/employee/customer's current claims.
create function pg_temp.assert_active_staff_role_session(p_foreign_session uuid) returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims');claims jsonb:=original_claims::jsonb;
 expected text;actual text;variant jsonb;cases integer:=0;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 if not private.has_live_invoice_session()then raise exception 'Actual current Auth session required';end if;
 if not exists(select 1 from auth.sessions where id=p_foreign_session and user_id<>auth.uid())then raise exception 'Actual foreign session required';end if;
 select sp.role into expected from public.staff_profiles sp where sp.user_id=auth.uid() and sp.is_active;
 set local role authenticated;actual:=private.active_staff_role();reset role;
 if actual is distinct from expected then raise exception 'Live DB role changed';end if;
 -- Editable metadata is never authority, even for a real customer.
 perform set_config('request.jwt.claims',jsonb_set(claims,'{user_metadata}','{"role":"owner","is_owner":true}'::jsonb)::text,true);
 set local role authenticated;actual:=private.active_staff_role();reset role;
 if actual is distinct from expected then raise exception 'Editable metadata changed DB role';end if;
 for variant in select x from jsonb_array_elements(jsonb_build_array(
 claims-'session_id',jsonb_set(claims,'{session_id}',to_jsonb(p_foreign_session::text)),
 jsonb_set(claims,'{session_id}',to_jsonb(gen_random_uuid()::text)),
 jsonb_set(claims,'{session_id}','"malformed"'::jsonb)))x loop
  perform set_config('request.jwt.claims',variant::text,true);
  begin
   set local role authenticated;perform private.active_staff_role();reset role;
   raise exception 'Invalid session reached role classification';
  exception when insufficient_privilege then
   reset role;
   if sqlerrm<>'Current authenticated session required' then raise;end if;
  end;
  cases:=cases+1;
 end loop;
 perform set_config('request.jwt.claims',original_claims,true);
 return jsonb_build_object('live_db_role_unchanged',true,'editable_metadata_ignored',true,'invalid_session_cases',cases);
end $$;

-- Actual owner claims and a supplied existing QA staff target; no new actor or Auth changes.
create function pg_temp.assert_cashier_permission_session(p_target uuid) returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims');claims jsonb:=original_claims::jsonb;
 before_staff jsonb;after_staff jsonb;before_audit jsonb;after_audit jsonb;new_value boolean;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 if private.active_staff_role()is distinct from 'owner' then raise exception 'Actual current owner required';end if;
 select to_jsonb(sp) into strict before_staff from public.staff_profiles sp where user_id=p_target;
 select coalesce(jsonb_agg(to_jsonb(a) order by to_jsonb(a)::text),'[]'::jsonb)into before_audit from public.business_audit_log a;
 new_value:=not coalesce(before_staff#>>'{permissions,cashier}'='true',false);
 perform set_config('request.jwt.claims',(claims-'session_id')::text,true);
 begin
  set local role authenticated;perform public.set_cashier_permission(p_target,new_value);reset role;
  raise exception 'Stale owner changed cashier permission';
 exception when insufficient_privilege then
  reset role;
  if sqlerrm<>'Current authenticated session required' then raise;end if;
 end;
 perform set_config('request.jwt.claims',original_claims,true);
 select to_jsonb(sp) into strict after_staff from public.staff_profiles sp where user_id=p_target;
 select coalesce(jsonb_agg(to_jsonb(a) order by to_jsonb(a)::text),'[]'::jsonb)into after_audit from public.business_audit_log a;
 if before_staff is distinct from after_staff or before_audit is distinct from after_audit then raise exception 'Denied permission call mutated data';end if;
 -- Legitimate public API remains functional; isolate and roll back its actual change/audit.
 begin
  set local role authenticated;perform public.set_cashier_permission(p_target,new_value);reset role;
  if not exists(select 1 from public.staff_profiles where user_id=p_target and permissions->>'cashier'=new_value::text)then raise exception 'Live owner permission call failed';end if;
  raise exception 'rollback valid owner probe'using errcode='P9R01';
 exception when sqlstate 'P9R01' then null;end;
 select to_jsonb(sp) into strict after_staff from public.staff_profiles sp where user_id=p_target;
 select coalesce(jsonb_agg(to_jsonb(a) order by to_jsonb(a)::text),'[]'::jsonb)into after_audit from public.business_audit_log a;
 if before_staff is distinct from after_staff or before_audit is distinct from after_audit then raise exception 'Valid permission probe not restored';end if;
 return jsonb_build_object('stale_owner_denied',true,'live_owner_api_works',true,'staff_audit_unchanged',true);
end $$;
