begin;
-- Minimal owned-receipt discovery only. No profile, contact, allocation or token.
create function private.owner_reward_issue_list(p_before_created_at timestamptz,p_before_request uuid,p_limit integer) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;items jsonb;begin
 actor:=private.owner_reward_issuer_actor();
 if p_limit is null or p_limit<1 or p_limit>50 or (p_before_created_at is null)<>(p_before_request is null) then
  raise exception 'Bounded paired receipt cursor required'using errcode='22023';
 end if;
 select coalesce(jsonb_agg(row_data order by created_at desc,request_id desc),'[]'::jsonb)into items
 from(select c.created_at,c.request_id,jsonb_build_object('request_id',c.request_id,'created_at',c.created_at,
 'state',c.state,'invoice_number',c.result->>'invoice_number','acknowledged',c.acknowledged_at is not null)row_data
 from private.offline_reward_issue_commands c where c.operator_id=actor
 and(p_before_created_at is null or(c.created_at,c.request_id)<(p_before_created_at,p_before_request))
 order by c.created_at desc,c.request_id desc limit p_limit)rows;
 return jsonb_build_object('items',items,'limit',p_limit,'spending_enabled',false);
end $$;
create function public.list_owner_reward_issues(p_before_created_at timestamptz default null,p_before_request uuid default null,p_limit integer default 25) returns jsonb
language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_reward_issue_list(p_before_created_at,p_before_request,p_limit)$$;
revoke all on function private.owner_reward_issue_list(timestamptz,uuid,integer),public.list_owner_reward_issues(timestamptz,uuid,integer)from public,anon,authenticated,service_role;
grant execute on function private.owner_reward_issue_list(timestamptz,uuid,integer),public.list_owner_reward_issues(timestamptz,uuid,integer)to authenticated;
notify pgrst,'reload schema';
commit;
