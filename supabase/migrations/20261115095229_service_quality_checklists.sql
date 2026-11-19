begin;
-- Explicit owner checklist policies apply only to physical starts after this migration.
-- No backfill, historical document changes, money, delivery or public reward activation.
create table private.service_quality_policies(
 request_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),
 version integer not null check(version>0),actor_id uuid not null references auth.users(id),
 payload jsonb not null,enabled boolean not null,items jsonb not null,reason text not null,
 created_at timestamptz not null default clock_timestamp(),unique(branch_id,version));
create table private.service_quality_bindings(
 order_id uuid primary key references public.business_orders(order_id),branch_id uuid not null references public.business_branches(branch_id),
 policy_request uuid references private.service_quality_policies(request_id),required boolean not null,items jsonb not null,
 started_at timestamptz not null default clock_timestamp(),check(not required or policy_request is not null));
create table private.service_quality_checks(
 request_id uuid primary key,order_id uuid not null references private.service_quality_bindings(order_id),
 actor_id uuid not null references auth.users(id),payload jsonb not null,passed boolean not null,
 crew_snapshot jsonb not null,created_at timestamptz not null default clock_timestamp());
create index service_quality_checks_order on private.service_quality_checks(order_id,created_at desc,request_id desc);
create function private.quality_immutable()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 raise exception 'Quality versions, start snapshots and inspection results are immutable'using errcode='55000';end$$;
do $$declare n text;begin foreach n in array array['service_quality_policies','service_quality_bindings','service_quality_checks']loop
 execute format('alter table private.%I enable row level security',n);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger quality_immutable before update or delete on private.%I for each row execute function private.quality_immutable()',n);
 end loop;end$$;
create function private.quality_actor(p_branch uuid,p_owner boolean default false)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$declare role_name text;begin
 if not private.has_live_invoice_session()then raise exception 'Current verified staff session required'using errcode='42501';end if;
 role_name:=private.active_staff_role();
 if role_name is null or role_name not in('owner','manager','employee')or not coalesce(private.can_access_branch(p_branch),false)or(p_owner and role_name<>'owner')then raise exception 'Quality permission required'using errcode='42501';end if;
 return auth.uid();end$$;
create function private.quality_crew(o public.business_orders)returns jsonb language sql stable set search_path=pg_catalog as $$
 select jsonb_build_object('order',to_jsonb(o.assigned_staff_ids),'booking',(select to_jsonb(b.assigned_staff_ids)from public.bookings b where b.id=o.booking_id))$$;
create function private.save_quality_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_enabled boolean,p_items jsonb,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;old private.service_quality_policies;latest integer;entry jsonb;ids text[]:='{}'::text[];payload jsonb;begin
 actor:=private.quality_actor(p_branch,true);
 if p_request is null or p_enabled is null or p_expected_version is null or p_expected_version<0 or length(trim(coalesce(p_reason,'')))not between 5 and 500 or jsonb_typeof(p_items)is distinct from'array'or jsonb_array_length(p_items)>30 or(p_enabled and jsonb_array_length(p_items)=0)then raise exception 'Explicit checklist, expected version and reason required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_items)loop
 if jsonb_typeof(entry)is distinct from'object'or (select count(*)from jsonb_object_keys(entry))<>3 or not(entry ?& array['id','ar','en'])or jsonb_typeof(entry->'id')is distinct from'string'or jsonb_typeof(entry->'ar')is distinct from'string'or jsonb_typeof(entry->'en')is distinct from'string'or(entry->>'id')!~'^[a-z][a-z0-9_]{0,39}$'or length(trim(entry->>'ar'))not between 1 and 200 or length(trim(entry->>'en'))not between 1 and 200 or entry->>'id'=any(ids)then raise exception 'Unique bilingual checklist items required'using errcode='22023';end if;
 ids:=array_append(ids,entry->>'id');end loop;
 payload:=jsonb_build_object('branch',p_branch,'expected_version',p_expected_version,'enabled',p_enabled,'items',p_items,'reason',trim(p_reason));
 -- Nonce lock must precede policy lock; exact replay never creates another version.
 perform pg_advisory_xact_lock(hashtextextended('quality-command:'||p_request::text,0));
 select *into old from private.service_quality_policies where request_id=p_request;
 if found then if old.actor_id<>actor or old.payload<>payload then raise exception 'Quality command conflicts'using errcode='22023';end if;return jsonb_build_object('request_id',old.request_id,'version',old.version);end if;
 perform pg_advisory_xact_lock(hashtextextended('quality-policy:'||p_branch::text,0));
 select coalesce(max(version),0)into latest from private.service_quality_policies where branch_id=p_branch;
 if latest<>p_expected_version then raise exception 'Quality policy version changed'using errcode='40001';end if;
 insert into private.service_quality_policies(request_id,branch_id,version,actor_id,payload,enabled,items,reason)values(p_request,p_branch,latest+1,actor,payload,p_enabled,p_items,trim(p_reason));
 return jsonb_build_object('request_id',p_request,'version',latest+1);end$$;
create function private.get_quality_policy(p_branch uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare v private.service_quality_policies;begin
 perform private.quality_actor(p_branch,true);select *into v from private.service_quality_policies where branch_id=p_branch order by version desc limit 1;
 return jsonb_build_object('version',coalesce(v.version,0),'enabled',coalesce(v.enabled,false),'items',coalesce(v.items,'[]'::jsonb),'reason',v.reason,'actor_id',v.actor_id,'created_at',v.created_at,'future_starts_only',true);end$$;
create function private.quality_start_snapshot()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare v private.service_quality_policies;begin
 if new.order_type='service'and old.status is distinct from new.status and new.status='in_progress'and not exists(select 1 from private.service_quality_bindings where order_id=new.order_id)then
 perform pg_advisory_xact_lock(hashtextextended('quality-policy:'||new.branch_id::text,0));
 select *into v from private.service_quality_policies where branch_id=new.branch_id order by version desc limit 1;
 insert into private.service_quality_bindings(order_id,branch_id,policy_request,required,items)values(new.order_id,new.branch_id,v.request_id,coalesce(v.enabled,false),case when coalesce(v.enabled,false)then v.items else'[]'::jsonb end);
 end if;return new;end$$;
create trigger service_quality_start_snapshot after update of status on public.business_orders for each row execute function private.quality_start_snapshot();
create function private.quality_completion_guard()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if old.status is distinct from new.status and new.status in('completed','delivered')and exists(select 1 from private.service_quality_bindings where order_id=new.order_id and required)and not exists(select 1 from private.service_quality_checks c where c.order_id=new.order_id and c.passed and c.crew_snapshot=private.quality_crew(new))then raise exception 'Required quality checklist must pass for the current service crew'using errcode='55000';end if;
 return new;end$$;
create trigger service_quality_completion_guard before update of status on public.business_orders for each row execute function private.quality_completion_guard();
create function private.quality_work_order(p_order uuid)returns public.business_orders language plpgsql volatile security definer set search_path=pg_catalog as $$declare o public.business_orders;begin
 select *into o from public.business_orders where order_id=p_order and order_type='service';
 if not found then raise exception 'Service quality context unavailable'using errcode='42501';end if;
 perform private.quality_actor(o.branch_id);
 if not coalesce(private.service_work_authorized(o.order_id,'completed'),false)then raise exception 'Assigned service quality permission required'using errcode='42501';end if;
 return o;end$$;
create function private.get_service_quality(p_order uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare o public.business_orders;b private.service_quality_bindings;checks jsonb;begin
 o:=private.quality_work_order(p_order);select *into b from private.service_quality_bindings where order_id=o.order_id;
 select coalesce(jsonb_agg(v order by created_at desc,request_id desc),'[]'::jsonb)into checks from(select jsonb_build_object('request_id',c.request_id,'passed',c.passed,'answers',c.payload->'answers','note',c.payload->'note','actor_id',c.actor_id,'created_at',c.created_at,'current_crew',c.crew_snapshot=private.quality_crew(o))v,c.created_at,c.request_id from private.service_quality_checks c where c.order_id=o.order_id order by c.created_at desc,c.request_id desc limit 25)s;
 return jsonb_build_object('order_id',o.order_id,'status',o.status,'start_snapshot_exists',b.order_id is not null,'required',coalesce(b.required,false),'items',coalesce(b.items,'[]'::jsonb),'policy_request',b.policy_request,'can_submit',coalesce(b.required,false) and o.status='quality_check','checks',checks);end$$;
create function private.submit_service_quality(p_request uuid,p_order uuid,p_answers jsonb,p_note text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare o public.business_orders;b private.service_quality_bindings;c private.service_quality_checks;payload jsonb;ok boolean;begin
 o:=private.quality_work_order(p_order);
 if p_request is null or jsonb_typeof(p_answers)is distinct from'object'or length(coalesce(p_note,''))>1000 then raise exception 'Exact checklist answers required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('quality-command:'||p_request::text,0));
 select *into o from public.business_orders where order_id=p_order for update;
 -- Recheck authorization after waiting on the order, not just before it.
 perform private.quality_work_order(p_order);
 payload:=jsonb_build_object('order',p_order,'answers',p_answers,'note',trim(coalesce(p_note,'')));
 select *into c from private.service_quality_checks where request_id=p_request;
 if found then if c.actor_id<>auth.uid()or c.payload<>payload then raise exception 'Quality command conflicts'using errcode='22023';end if;return jsonb_build_object('request_id',c.request_id,'passed',c.passed);end if;
 select *into b from private.service_quality_bindings where order_id=p_order;
 if not found or not b.required or o.status<>'quality_check'then raise exception 'Required active quality phase expected'using errcode='55000';end if;
 if(select count(*)from jsonb_object_keys(p_answers))<>jsonb_array_length(b.items)or exists(select 1 from jsonb_array_elements(b.items)i where jsonb_typeof(p_answers->(i->>'id'))is distinct from'boolean')then raise exception 'Every frozen checklist item must have one boolean answer'using errcode='22023';end if;
 select bool_and(value='true'::jsonb)into ok from jsonb_each(p_answers);
 insert into private.service_quality_checks(request_id,order_id,actor_id,payload,passed,crew_snapshot)values(p_request,p_order,auth.uid(),payload,ok,private.quality_crew(o));
 return jsonb_build_object('request_id',p_request,'passed',ok);end$$;
create function public.get_service_quality_policy(p_branch uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_quality_policy(p_branch)$$;
create function public.save_service_quality_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_enabled boolean,p_items jsonb,p_reason text)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.save_quality_policy(p_request,p_branch,p_expected_version,p_enabled,p_items,p_reason)$$;
create function public.get_service_quality(p_order uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_service_quality(p_order)$$;
create function public.submit_service_quality(p_request uuid,p_order uuid,p_answers jsonb,p_note text)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.submit_service_quality(p_request,p_order,p_answers,p_note)$$;
revoke all on function private.quality_immutable(),private.quality_actor(uuid,boolean),private.quality_crew(public.business_orders),private.quality_start_snapshot(),private.quality_completion_guard(),private.quality_work_order(uuid)from public,anon,authenticated,service_role;
revoke all on function private.get_quality_policy(uuid),private.save_quality_policy(uuid,uuid,integer,boolean,jsonb,text),private.get_service_quality(uuid),private.submit_service_quality(uuid,uuid,jsonb,text),public.get_service_quality_policy(uuid),public.save_service_quality_policy(uuid,uuid,integer,boolean,jsonb,text),public.get_service_quality(uuid),public.submit_service_quality(uuid,uuid,jsonb,text)from public,anon,authenticated,service_role;
grant execute on function private.get_quality_policy(uuid),private.save_quality_policy(uuid,uuid,integer,boolean,jsonb,text),private.get_service_quality(uuid),private.submit_service_quality(uuid,uuid,jsonb,text),public.get_service_quality_policy(uuid),public.save_service_quality_policy(uuid,uuid,integer,boolean,jsonb,text),public.get_service_quality(uuid),public.submit_service_quality(uuid,uuid,jsonb,text)to authenticated;
commit;
