-- SOURCE ONLY: standalone rollback checks require an existing current owner session.
-- No Auth creation, fake credits, financial writes or runtime-flag relaxation.
begin;
do $$
declare v_owner uuid;v_nonce uuid:=gen_random_uuid();v_result jsonb;v_denied boolean;v_actor_claims text;
begin
 assert not has_table_privilege('authenticated','private.offline_reward_consumption_preparations','SELECT');
 assert not has_table_privilege('service_role','private.offline_reward_consumption_closures','INSERT');
 assert not has_function_privilege('authenticated','private.prepare_offline_reward_consumption(uuid,uuid,text)','EXECUTE');
 assert not has_function_privilege('service_role','private.lock_offline_reward_hold_witness(uuid)','EXECUTE');
 select s.user_id into strict v_owner from public.staff_profiles s where s.role='owner'and s.is_active
 and exists(select 1 from auth.sessions session where session.user_id=s.user_id and(session.not_after is null or session.not_after>clock_timestamp()))limit 1;
 v_actor_claims:=jsonb_build_object('sub',v_owner,'session_id',(select session.id from auth.sessions session where session.user_id=v_owner and(session.not_after is null or session.not_after>clock_timestamp())order by created_at desc limit 1))::text;
 perform set_config('request.jwt.claims',v_actor_claims,true);perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=private.get_offline_reward_consumption_preparation(v_nonce);
 assert v_result->>'state'='absent'and not(v_result->>'definitive_failure')::boolean;
 v_result:=private.close_offline_reward_consumption(v_nonce,'Explicitly fence unknown prerequisite nonce');
 assert v_result->>'state'='closed'and(v_result->>'definitive_failure')::boolean;
 assert private.close_offline_reward_consumption(v_nonce,'Repeated close retains original audit record')=v_result;
 assert private.prepare_offline_reward_consumption(v_nonce,gen_random_uuid(),repeat('a',64))=v_result,'Late prepare must be fenced before unknown hold lookup';
 assert(select count(*)from private.offline_reward_consumption_closures where request_id=v_nonce)=1;
 assert not exists(select 1 from private.offline_reward_consumption_preparations where request_id=v_nonce);
 v_denied:=false;begin delete from private.offline_reward_consumption_closures where request_id=v_nonce;exception when others then v_denied:=true;end;assert v_denied,'Closure history cannot be deleted';
 v_denied:=false;begin update private.offline_reward_consumption_closures set reason='Rewrite forbidden original closure'where request_id=v_nonce;exception when others then v_denied:=true;end;assert v_denied;
 -- Dropped role/session evidence cannot reuse cached closed receipts.
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 v_denied:=false;begin perform private.get_offline_reward_consumption_preparation(v_nonce);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
end$$;
rollback;
