begin;
do $$declare own uuid;sid uuid;customer uuid;expected jsonb;actual jsonb;denied boolean;begin
 select s.user_id into strict own from public.staff_profiles s where s.role='owner'and s.is_active and exists(select 1 from auth.sessions a where a.user_id=s.user_id and(a.not_after is null or a.not_after>clock_timestamp()))limit 1;
 select id into strict sid from auth.sessions where user_id=own and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 select c.id into strict customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 perform set_config('request.jwt.claim.sub',own::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',own,'session_id',sid,'role','authenticated')::text,true);
 expected:=private.owner_business_insights(current_date-7,current_date);
 execute 'set local role authenticated';actual:=public.get_owner_business_insights(current_date-7,current_date);assert actual=expected,'Accepted evidence payload/aggregation changed';
 denied:=false;begin perform private.owner_business_insights(current_date-7,current_date);exception when insufficient_privilege then denied:=true;end;assert denied,'Old private aggregate bypass remained callable';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',own,'session_id',gen_random_uuid(),'role','authenticated')::text,true);
 denied:=false;begin perform public.get_owner_business_insights(current_date-7,current_date);exception when insufficient_privilege then denied:=true;end;assert denied,'Unknown session allowed';
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',sid,'user_metadata',jsonb_build_object('role','owner'))::text,true);
 denied:=false;begin perform public.get_owner_business_insights(current_date-7,current_date);exception when insufficient_privilege then denied:=true;end;assert denied,'Foreign owner session or metadata spoof allowed';
 execute 'reset role';perform set_config('request.jwt.claim.sub',own::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',own,'session_id',sid,'role','authenticated')::text,true);
 -- Real existing Auth session removed ONLY within this outer rollback. No logout/reset API.
 delete from auth.sessions where id=sid;
 execute 'set local role authenticated';denied:=false;begin perform public.get_owner_business_insights(current_date-7,current_date);exception when insufficient_privilege then denied:=true;end;assert denied,'Revoked session retained financial evidence access';
 execute 'reset role';
 assert not has_function_privilege('anon','public.get_owner_business_insights(date,date)','EXECUTE');
end$$;
rollback;
