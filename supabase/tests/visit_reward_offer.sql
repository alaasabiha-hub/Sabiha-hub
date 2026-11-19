begin;
do $$
<<qa>>
declare own uuid;customer uuid;b uuid:=gen_random_uuid();other_branch uuid:=gen_random_uuid();reward uuid:=gen_random_uuid();foreign_service uuid:=gen_random_uuid();request uuid:=gen_random_uuid();v jsonb;again jsonb;offer uuid;denied boolean;audit_count bigint;legacy_count bigint;
begin
 select user_id into strict own from public.staff_profiles where role='owner' and is_active limit 1;
 select c.id into strict customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id) limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en) values(b,'عرض اختبار معزول','Isolated offer QA'),(other_branch,'فرع اختبار آخر','Other offer QA');
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,category,price,is_active,is_public) values(reward,b,'service','Actual QA reward service','QA',50,true,true),(foreign_service,other_branch,'service','Other branch service','QA',50,true,true);
 select count(*) into legacy_count from public.business_loyalty_transactions;
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'user_metadata',jsonb_build_object('role','owner'))::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.save_visit_reward_offer(request,b,'Owner provided QA offer',7,false,reward);exception when insufficient_privilege then denied:=true;end;assert denied,'Applicant metadata granted offer publication';
 perform set_config('request.jwt.claim.sub',own::text,true);
 assert not exists(select 1 from jsonb_array_elements(public.get_loyalty_policy(b)->'offers') x where x->>'branch_id'=b::text),'Isolated branch unexpectedly has branch-specific seed';
 denied:=false;begin perform public.save_visit_reward_offer(request,b,'Owner provided QA offer',null,false,reward);exception when raise_exception then denied:=true;end;assert denied,'Missing threshold defaulted';
 denied:=false;begin perform public.save_visit_reward_offer(request,b,'',7,false,reward);exception when raise_exception then denied:=true;end;assert denied,'Missing actual name accepted';
 denied:=false;begin perform public.save_visit_reward_offer(request,b,'Owner provided QA offer',7,true,foreign_service);exception when raise_exception then denied:=true;end;assert denied,'Foreign reward service accepted';
 v:=public.save_visit_reward_offer(request,b,'Owner provided QA offer',7,false,reward);again:=public.save_visit_reward_offer(request,b,'Owner provided QA offer',7,false,reward);assert v=again,'Create retry created a second offer';offer:=(v->>'offer_id')::uuid;
 assert v->>'is_active'='false' and v->>'is_public'='false','Draft offer auto-published';assert v->>'visits_required'='7';assert v->>'unit'='service_visits';
 assert public.get_loyalty_policy(b)->'current'='null'::jsonb,'Offer creation auto-enabled policy';
 denied:=false;begin perform public.save_visit_reward_offer(request,b,'Owner provided QA offer',8,false,reward);exception when raise_exception then denied:=true;end;assert denied,'Changed request reused';
 v:=public.save_visit_reward_offer(gen_random_uuid(),b,'Owner provided QA offer',7,true,reward,null,offer);assert v->>'is_public'='true' and v->>'is_active'='true','Explicit owner publication failed';
 assert public.get_loyalty_policy(b)->'current'='null'::jsonb,'Publication auto-enabled policy';
 perform public.save_loyalty_policy(gen_random_uuid(),b,offer,array[reward],true);
 execute 'reset role';assert exists(select 1 from private.managed_visit_reward_offers where offer_id=offer and managed_by=own),'Created/edited offer marker missing';assert (select count(*) from public.business_offers where offer_id=offer)=1;
 select count(*) into audit_count from public.business_audit_log where action='save_visit_reward_offer' and entity_id=offer::text;assert audit_count=2,'Create/publish audit not exactly once each';
 assert (select count(*) from public.business_loyalty_transactions)=legacy_count,'Offer setup awarded fake points';
 execute 'set local role anon';denied:=false;begin perform public.save_visit_reward_offer(gen_random_uuid(),b,'Untrusted offer',7,true,reward);exception when insufficient_privilege then denied:=true;end;assert denied,'Anonymous published offer';
 execute 'reset role';update public.staff_profiles set is_active=false where user_id=own;execute 'set local role authenticated';denied:=false;begin perform public.save_visit_reward_offer(request,b,'Owner provided QA offer',7,false,reward);exception when insufficient_privilege then denied:=true;end;assert denied,'Deactivated owner replayed offer write';
 raise notice 'PASS actual owner visit-offer creation without seed/default threshold, draft/publication choice, branch/reward validation, audit/idempotency and no automatic policy/points';
end $$;
rollback;
