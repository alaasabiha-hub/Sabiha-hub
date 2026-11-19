-- SOURCE ONLY; root runs reviewed migration + this focused outer rollback.
begin;
create function pg_temp.fleet_actor(p_actor uuid,p_session uuid)returns void language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'session_id',p_session,'user_metadata',jsonb_build_object('role','owner','fleet_manage',true))::text,true);end$$;
create function pg_temp.fleet_apply(p_request uuid,p_kind text,p_entity uuid,p_party uuid,p_expected integer,p_data jsonb)returns jsonb language plpgsql as $$
declare prepared jsonb;result jsonb;begin
 prepared:=public.prepare_fleet_catalog_command(p_request,p_kind,p_entity,p_party,p_expected,p_data,'QA actual isolated catalogue change');
 assert prepared->>'state'='open';
 result:=public.apply_fleet_catalog_command(p_request);assert result->>'state'='succeeded';
 assert public.apply_fleet_catalog_command(p_request)=result;assert public.close_fleet_catalog_command(p_request)=result;return result;
end$$;
do $$
declare own uuid;sid uuid;other uuid;other_sid uuid;company uuid:=gen_random_uuid();company2 uuid:=gen_random_uuid();car uuid:=gen_random_uuid();car2 uuid:=gen_random_uuid();car3 uuid:=gen_random_uuid();
 req uuid:=gen_random_uuid();closed_req uuid:=gen_random_uuid();stale_req uuid:=gen_random_uuid();name text:='QA fleet catalogue '||gen_random_uuid()::text;
 party_terms jsonb;vehicle_terms jsonb;value jsonb;before_value jsonb;history jsonb;cursor jsonb;denied boolean;money_before jsonb;auth_before text;vehicle_ids uuid[]:='{}';begin
 select s.user_id,a.id into strict own,sid from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id where s.role='owner'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 select a.user_id,a.id into strict other,other_sid from auth.sessions a join auth.users u on u.id=a.user_id where u.deleted_at is null and(a.not_after is null or a.not_after>clock_timestamp())and not exists(select 1 from public.staff_profiles s where s.user_id=a.user_id and s.is_active and s.role='owner')order by a.created_at desc limit 1;
 select jsonb_build_object('invoices',count(*),'total',coalesce(sum(total),0),'discount',coalesce(sum(discount),0))into money_before from public.business_invoices;
 select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))into auth_before from auth.users u;
 party_terms:=jsonb_build_object('legal_name',name,'trading_name',null,'registration_country',null,'tax',null,'address',null,'contacts','[]'::jsonb,'representative',null);
 vehicle_terms:=jsonb_build_object('plate_country','EG','plate_number','QA-'||left(replace(car::text,'-',''),12),'make','Recorded maker','model','Recorded model','year',2020,'color',null,'fleet_reference','QA asset 1');
 perform pg_temp.fleet_actor(own,null);denied:=false;begin perform public.get_fleet_catalogue_context();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.fleet_actor(own,other_sid);denied:=false;begin perform public.get_fleet_catalogue_context();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.fleet_actor(other,other_sid);denied:=false;begin perform public.prepare_fleet_catalog_command(req,'party_create',company,company,null,party_terms,'QA denied forged metadata');exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.fleet_actor(own,sid);execute 'set local role authenticated';
 value:=public.get_fleet_catalogue_context();assert value->>'owner_only'='true'and value->>'eta_submission_enabled'='false'and value->'tax_rate'='null';
 denied:=false;begin perform public.prepare_fleet_catalog_command(gen_random_uuid(),'party_create',company,company,null,party_terms||'{"legal_name":null}','QA actual missing name');exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_fleet_catalog_command(gen_random_uuid(),'party_create',company,company,null,party_terms||'{"tax":{"country":null,"identifier_type":"unverified","number":"001"}}','QA missing explicit tax country');exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.prepare_fleet_catalog_command(gen_random_uuid(),'party_create',company,company,null,party_terms||'{"representative":{"name":"QA","title":null,"phone":null,"email":null,"verification":"verified"}}','QA no fabricated representative proof');exception when invalid_parameter_value then denied:=true;end;assert denied;
 value:=public.close_fleet_catalog_command(closed_req);assert value->>'state'='closed'and value->>'definitive_failure'='true';
 value:=public.prepare_fleet_catalog_command(closed_req,'party_create',company,company,null,party_terms,'QA fenced delayed create');assert value->>'state'='closed';
 value:=public.apply_fleet_catalog_command(closed_req);assert value->>'state'='closed';
 value:=pg_temp.fleet_apply(req,'party_create',company,company,null,party_terms);assert value#>>'{result,entity,version}'='1'and value#>>'{result,verification_state}'='unverified';
 before_value:=value;
 assert public.prepare_fleet_catalog_command(req,'party_create',company,company,null,party_terms,'QA actual isolated catalogue change')=before_value;
 denied:=false;begin perform public.prepare_fleet_catalog_command(req,'party_create',company,company,null,party_terms||'{"trading_name":"Changed"}','QA actual isolated catalogue change');exception when invalid_parameter_value then denied:=true;end;assert denied;
 -- Freeze version1 edit, then actual edit version2; stale apply must not overwrite.
 value:=public.prepare_fleet_catalog_command(stale_req,'party_edit',company,company,1,party_terms||'{"trading_name":"Stale prepared value"}','QA prepared expected version');
 value:=pg_temp.fleet_apply(gen_random_uuid(),'party_edit',company,company,1,party_terms||'{"trading_name":"Current recorded trade"}');assert value#>>'{result,entity,version}'='2';
 denied:=false;begin perform public.apply_fleet_catalog_command(stale_req);exception when serialization_failure then denied:=true;end;assert denied;
 assert public.close_fleet_catalog_command(stale_req)->>'state'='closed';
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_create',car,company,null,vehicle_terms);
 assert value#>>'{result,entity,version}'='1';assert value#>>'{result,entity,terms,plate_key}'=upper(replace(vehicle_terms->>'plate_number','-',''));
 -- Same recorded plate/country cannot silently merge or create another vehicle,
 -- including under another new company. Same names are warnings, not identity.
 value:=pg_temp.fleet_apply(gen_random_uuid(),'party_create',company2,company2,null,party_terms);
 value:=public.get_fleet_party(company2);assert value->>'name_match_is_identity_proof'='false'and value->'possible_same_name_parties'@>jsonb_build_array(company);
 value:=pg_temp.fleet_apply(gen_random_uuid(),'party_edit',company2,company2,1,party_terms||jsonb_build_object('tax',jsonb_build_object('country','EG','identifier_type','QA_UNVERIFIED','number',company2::text)));
 
 declare duplicate_party uuid:=gen_random_uuid();duplicate_command uuid:=gen_random_uuid();begin
 perform public.prepare_fleet_catalog_command(duplicate_command,'party_create',duplicate_party,duplicate_party,null,party_terms||jsonb_build_object('tax',jsonb_build_object('country','EG','identifier_type','QA_UNVERIFIED','number',company2::text)),'QA duplicate recorded tax requires review');
 denied:=false;begin perform public.apply_fleet_catalog_command(duplicate_command);exception when unique_violation then denied:=true;end;assert denied;perform public.close_fleet_catalog_command(duplicate_command);end;

 value:=public.prepare_fleet_catalog_command(gen_random_uuid(),'vehicle_create',car2,company2,null,vehicle_terms,'QA duplicate plate requires review');
 denied:=false;begin perform public.apply_fleet_catalog_command((value->>'request_id')::uuid);exception when unique_violation then denied:=true;end;assert denied;
 perform public.close_fleet_catalog_command((value->>'request_id')::uuid);
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_edit',car,company,1,vehicle_terms||'{"model":"Updated recorded model"}');assert value#>>'{result,entity,version}'='2';
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_archive',car,company,2,'{}');assert value#>>'{result,entity,archived}'='true';
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_reenable',car,company,3,'{}');assert value#>>'{result,entity,version}'='4';
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_create',car2,company,null,vehicle_terms||jsonb_build_object('plate_number','QB'||left(replace(car2::text,'-',''),12),'fleet_reference','QA asset 2'));
 value:=pg_temp.fleet_apply(gen_random_uuid(),'vehicle_create',car3,company,null,vehicle_terms||jsonb_build_object('plate_number','QC'||left(replace(car3::text,'-',''),12),'fleet_reference','QA asset 3'));
 -- Unlimited row catalogue, bounded stable cursor; no fixed vehicle array cap.
 value:=public.list_fleet_vehicles(company,'',false,null,null,1);assert jsonb_array_length(value->'items')=1;cursor:=value->'next_cursor';assert cursor<>'null';
 vehicle_ids:=array_append(vehicle_ids,(value#>>'{items,0,vehicle_id}')::uuid);
 value:=public.list_fleet_vehicles(company,'',false,(cursor->>'created_at')::timestamptz,(cursor->>'entity_id')::uuid,1);assert jsonb_array_length(value->'items')=1 and not((value#>>'{items,0,vehicle_id}')::uuid=any(vehicle_ids));cursor:=value->'next_cursor';
 vehicle_ids:=array_append(vehicle_ids,(value#>>'{items,0,vehicle_id}')::uuid);
 value:=public.list_fleet_vehicles(company,'',false,(cursor->>'created_at')::timestamptz,(cursor->>'entity_id')::uuid,1);assert not((value#>>'{items,0,vehicle_id}')::uuid=any(vehicle_ids))and value->'next_cursor'='null';
 value:=public.list_fleet_vehicles(company,'%',false,null,null,25);assert jsonb_array_length(value->'items')=0;
 denied:=false;begin perform public.get_fleet_vehicle(company2,car);exception when insufficient_privilege then denied:=true;end;assert denied;
 value:=pg_temp.fleet_apply(gen_random_uuid(),'party_archive',company,company,2,'{}');assert value#>>'{result,entity,archived}'='true';
 value:=public.get_fleet_vehicle(company,car);assert value->>'effective_active'='false'and value->>'archived'='false';
 denied:=false;begin perform public.prepare_fleet_catalog_command(gen_random_uuid(),'vehicle_edit',car,company,4,vehicle_terms,'QA parent archived blocks edit');exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 value:=pg_temp.fleet_apply(gen_random_uuid(),'party_reenable',company,company,3,'{}');assert value#>>'{result,entity,version}'='4';
 value:=public.get_fleet_vehicle(company,car);assert value->>'effective_active'='true';
 history:=public.list_fleet_catalogue_history('party',company,null,2);assert jsonb_array_length(history->'items')=2 and history->>'next_before_version'='3';
 value:=public.list_fleet_catalogue_history('party',company,3,2);assert value#>>'{items,1,version}'='1'and value#>>'{items,1,after,terms,legal_name}'=name and value#>'{items,1,after,terms,tax}'='null';
 denied:=false;begin perform public.list_fleet_vehicles(company,'',false,null,car,25);exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.list_fleet_vehicles(company,'',false,null,null,51);exception when invalid_parameter_value then denied:=true;end;assert denied;
 execute 'reset role';
 assert(select count(*)from private.fleet_catalog_versions where entity_kind='party'and entity_id=company)=4;
 assert(select count(*)from private.fleet_catalog_versions where entity_kind='vehicle'and entity_id=car)=4;
 denied:=false;begin delete from private.fleet_parties where party_id=company;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 denied:=false;begin update private.fleet_catalog_versions set reason='QA cannot rewrite old history'where entity_id=company;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not has_table_privilege('authenticated','private.fleet_parties','SELECT');assert not has_table_privilege('service_role','private.fleet_vehicles','INSERT');
 assert not has_function_privilege('anon','public.get_fleet_party(uuid)','EXECUTE');assert not has_function_privilege('authenticated','private.fleet_party_terms(jsonb)','EXECUTE');
 assert(select jsonb_build_object('invoices',count(*),'total',coalesce(sum(total),0),'discount',coalesce(sum(discount),0))from public.business_invoices)=money_before;
 assert(select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u)=auth_before;
 set constraints all immediate;
end$$;
rollback;
