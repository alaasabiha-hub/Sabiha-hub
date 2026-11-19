begin;
-- Versioned company contract DRAFTS only. No billing, receivable, ETA or active pricing.
create table private.fleet_contract_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb,
 state text not null check(state in('succeeded','closed')),result jsonb not null,
 creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),
 check((state='succeeded'and payload is not null)or(state='closed'and payload is null)));
create table private.fleet_contracts(
 contract_id uuid primary key,party_id uuid not null references private.fleet_parties(party_id),
 branch_id uuid not null references public.business_branches(branch_id),version integer not null check(version>0),
 state text not null check(state in('draft','archived')),terms jsonb not null,
 created_at timestamptz not null,created_by uuid not null references auth.users(id),
 updated_at timestamptz not null,updated_by uuid not null references auth.users(id),
 last_request uuid not null references private.fleet_contract_commands(request_id)deferrable initially deferred);
create index fleet_contract_party_cursor on private.fleet_contracts(party_id,created_at desc,contract_id desc);
create table private.fleet_contract_versions(
 request_id uuid primary key references private.fleet_contract_commands(request_id)deferrable initially deferred,
 contract_id uuid not null references private.fleet_contracts(contract_id),version integer not null,
 actor_id uuid not null references auth.users(id),reason text not null,before_snapshot jsonb,after_snapshot jsonb not null,
 creator_xid bigint not null,created_at timestamptz not null,unique(contract_id,version));
do $$declare t text;begin foreach t in array array['fleet_contract_commands','fleet_contracts','fleet_contract_versions']loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_fleet_contract_command before update or delete on private.fleet_contract_commands for each row execute function private.fleet_immutable();
create trigger immutable_fleet_contract_version before update or delete on private.fleet_contract_versions for each row execute function private.fleet_immutable();
create function private.fleet_contract_owner()returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if not private.has_live_invoice_session()then raise exception 'Current confirmed owner session required'using errcode='42501';end if;
 return private.fleet_require_owner('manage');end$$;
create function private.fleet_contract_snapshot(c private.fleet_contracts)returns jsonb language sql stable set search_path=pg_catalog as $$
 select jsonb_build_object('contract_id',c.contract_id,'party_id',c.party_id,'branch_id',c.branch_id,'version',c.version,'state',c.state,'terms',c.terms,'created_at',c.created_at,'created_by',c.created_by,'updated_at',c.updated_at,'updated_by',c.updated_by,'last_request',c.last_request)$$;
create function private.fleet_contract_coherence()returns trigger language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Contract drafts and history retained'using errcode='55000';end if;
 if not exists(select 1 from private.fleet_contract_versions v join private.fleet_contract_commands c using(request_id)
 where v.request_id=new.last_request and v.contract_id=new.contract_id and v.version=new.version
 and v.actor_id=new.updated_by and v.creator_xid=txid_current()and c.creator_xid=txid_current()
 and c.actor_id=v.actor_id and c.state='succeeded'and v.after_snapshot=private.fleet_contract_snapshot(new)
 and c.result->'entity'=v.after_snapshot)then raise exception 'Actual same-transaction contract revision required'using errcode='55000';end if;
 return new;end$$;
create constraint trigger fleet_contract_revision_coherent after insert or update or delete on private.fleet_contracts deferrable initially deferred for each row execute function private.fleet_contract_coherence();
create function private.validate_fleet_contract_terms(p_terms jsonb,p_branch uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare start_date date;end_date date;days integer;entry jsonb;service uuid;price numeric;item public.business_catalog_items;services jsonb:='[]'::jsonb;ids uuid[]:='{}'::uuid[];v jsonb;
begin
 if p_terms is null or jsonb_typeof(p_terms)<>'object'or not(p_terms?&array['name_ar','name_en','starts_on','ends_on','billing_cycle','payment_method','due_days','services','notes_ar','notes_en'])or p_terms-array['name_ar','name_en','starts_on','ends_on','billing_cycle','payment_method','due_days','services','notes_ar','notes_en']<>'{}'::jsonb then raise exception 'Exact bilingual draft terms required'using errcode='22023';end if;
 v:=jsonb_build_object('name_ar',private.fleet_text(p_terms->'name_ar',160,true),'name_en',private.fleet_text(p_terms->'name_en',160,true),
 'notes_ar',private.fleet_text(p_terms->'notes_ar',1000),'notes_en',private.fleet_text(p_terms->'notes_en',1000));
 if coalesce(p_terms->>'starts_on','')!~'^\d{4}-\d{2}-\d{2}$'or(p_terms->'ends_on'<>'null'::jsonb and coalesce(p_terms->>'ends_on','')!~'^\d{4}-\d{2}-\d{2}$')then raise exception 'Explicit ISO contract dates required'using errcode='22023';end if;
 begin start_date:=(p_terms->>'starts_on')::date;end_date:=(p_terms->>'ends_on')::date;
 exception when datetime_field_overflow or invalid_datetime_format then raise exception 'Valid contract dates required'using errcode='22023';end;
 if end_date is not null and end_date<start_date then raise exception 'Contract date range reversed'using errcode='22023';end if;
 if p_terms->>'billing_cycle'not in('per_visit','weekly','monthly')or p_terms->>'payment_method'not in('cash','electronic','bank_transfer','credit')or p_terms->>'billing_cycle'is null or p_terms->>'payment_method'is null then raise exception 'Explicit billing intent and payment intent required'using errcode='22023';end if;
 if jsonb_typeof(p_terms->'due_days')<>'number'or(p_terms->>'due_days')!~'^\d{1,3}$'then raise exception 'Explicit integer due days required'using errcode='22023';end if;
 days:=(p_terms->>'due_days')::integer;if days>365 or(p_terms->>'payment_method'<>'credit'and days<>0)then raise exception 'Unsupported credit days'using errcode='22023';end if;
 if jsonb_typeof(p_terms->'services')<>'array'or jsonb_array_length(p_terms->'services')not between 1 and 100 then raise exception 'One to one hundred explicit service prices required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_terms->'services')loop
 if jsonb_typeof(entry)<>'object'or not(entry?&array['service_id','price_egp'])or entry-array['service_id','price_egp']<>'{}'then raise exception 'Exact service price fields required'using errcode='22023';end if;
 begin service:=(entry->>'service_id')::uuid;exception when invalid_text_representation then raise exception 'Actual service identifier required'using errcode='22023';end;
 if service is null or service=any(ids)or jsonb_typeof(entry->'price_egp')<>'number'then raise exception 'Unique services and numeric prices required'using errcode='22023';end if;
 price:=(entry->>'price_egp')::numeric;if price<0 or price>999999999.99 or price<>round(price,2)then raise exception 'Exact nonnegative EGP cents required'using errcode='22023';end if;
 select *into item from public.business_catalog_items where item_id=service and branch_id=p_branch and item_type='service'and is_active for share;
 if not found then raise exception 'Actual active branch service required'using errcode='22023';end if;
 services:=services||jsonb_build_array(jsonb_build_object('service_id',service,'price_egp',price,'name_ar',item.name,'name_en',item.name_en));ids:=array_append(ids,service);
 end loop;
 return v||jsonb_build_object('starts_on',start_date,'ends_on',end_date,'billing_cycle',p_terms->>'billing_cycle','payment_method',p_terms->>'payment_method','due_days',days,'services',services,'currency','EGP','tax_configuration','unconfigured','pricing_active',false);
end$$;
create function private.get_fleet_contract_command(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.fleet_contract_owner();c private.fleet_contract_commands;begin
 if p_request is null then raise exception 'Exact contract request required'using errcode='22023';end if;
 select *into c from private.fleet_contract_commands where request_id=p_request;
 if not found then return jsonb_build_object('request_id',p_request,'state','absent','definitive_failure',false);end if;
 if c.actor_id<>actor then raise exception 'Own contract command required'using errcode='42501';end if;return c.result;end$$;
create function private.save_fleet_contract_draft(p_request uuid,p_party uuid,p_branch uuid,p_contract uuid,p_expected_version integer,p_terms jsonb,p_archive boolean,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid:=private.fleet_contract_owner();c private.fleet_contract_commands;old private.fleet_contracts;changed private.fleet_contracts;company private.fleet_parties;payload jsonb;normalized_terms jsonb;before_value jsonb;result_value jsonb;stamp timestamptz:=clock_timestamp();newid uuid;
begin
 if p_request is null then raise exception 'Exact stable nonce required'using errcode='22023';end if;
 payload:=jsonb_build_object('party',p_party,'branch',p_branch,'contract',p_contract,'expected_version',p_expected_version,'terms',p_terms,'archive',p_archive,'reason',p_reason);
 perform pg_advisory_xact_lock(hashtextextended('fleet-contract:'||p_request::text,0));
 select *into c from private.fleet_contract_commands where request_id=p_request;
 if found then
 if c.actor_id<>actor then raise exception 'Own contract command required'using errcode='42501';end if;
 if c.state='closed'then return c.result;end if;
 if c.payload is distinct from payload then raise exception 'Contract request payload changed'using errcode='22023';end if;return c.result;end if;
 if p_party is null or p_branch is null or p_archive is null or p_reason is null or length(trim(p_reason))not between 10 and 500 then raise exception 'Explicit scope, reason and archive intent required'using errcode='22023';end if;
 if p_contract is null then
 if p_expected_version is not null or p_archive then raise exception 'New draft cannot be archived or versioned'using errcode='22023';end if;newid:=gen_random_uuid();
 else
 select *into old from private.fleet_contracts where contract_id=p_contract for update;
 if not found or old.party_id<>p_party or old.branch_id<>p_branch then raise exception 'Exact company and branch contract required'using errcode='42501';end if;
 if p_expected_version is null or old.version<>p_expected_version then raise exception 'Contract version changed'using errcode='40001';end if;
 if old.state<>'draft'then raise exception 'Archived draft cannot be edited'using errcode='55000';end if;
 newid:=old.contract_id;before_value:=private.fleet_contract_snapshot(old);
 end if;
 select *into company from private.fleet_parties where party_id=p_party for share;
 if not found or(company.archived and not p_archive)then raise exception 'Active actual company required'using errcode='55000';end if;
 perform 1 from public.business_branches where branch_id=p_branch and is_active for share;if not found and not p_archive then raise exception 'Actual active branch required'using errcode='22023';end if;
 if p_archive then
 if p_terms is not null then raise exception 'Archive does not edit terms'using errcode='22023';end if;normalized_terms:=old.terms;
 else normalized_terms:=private.validate_fleet_contract_terms(p_terms,p_branch);end if;
 if p_contract is null then
 insert into private.fleet_contracts values(newid,p_party,p_branch,1,'draft',normalized_terms,stamp,actor,stamp,actor,p_request)returning *into changed;
 else update private.fleet_contracts set version=version+1,state=case when p_archive then'archived'else'draft'end,terms=normalized_terms,updated_at=stamp,updated_by=actor,last_request=p_request where contract_id=newid returning *into changed;
 end if;
 result_value:=jsonb_build_object('request_id',p_request,'state','succeeded','entity',private.fleet_contract_snapshot(changed),'draft_only',true,'pricing_active',false,'billing_enabled',false);
 insert into private.fleet_contract_commands values(p_request,actor,payload,'succeeded',result_value,txid_current(),stamp);
 insert into private.fleet_contract_versions values(p_request,newid,changed.version,actor,trim(p_reason),before_value,private.fleet_contract_snapshot(changed),txid_current(),stamp);
 return result_value;
end$$;
create function private.close_fleet_contract_command(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.fleet_contract_owner();c private.fleet_contract_commands;result_value jsonb;begin
 if p_request is null then raise exception 'Exact contract request required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('fleet-contract:'||p_request::text,0));select *into c from private.fleet_contract_commands where request_id=p_request;
 if found then if c.actor_id<>actor then raise exception 'Own contract command required'using errcode='42501';end if;return c.result;end if;
 result_value:=jsonb_build_object('request_id',p_request,'state','closed','definitive_failure',true,'draft_only',true);
 insert into private.fleet_contract_commands values(p_request,actor,null,'closed',result_value,txid_current(),clock_timestamp());return result_value;end$$;
create function private.list_fleet_contracts(p_party uuid,p_before_created_at timestamptz,p_before_id uuid,p_limit integer)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare items jsonb;begin perform private.fleet_contract_owner();
 if p_party is null or p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_id is null)then raise exception 'Actual party and bounded paired cursor required'using errcode='22023';end if;
 if not exists(select 1 from private.fleet_parties where party_id=p_party)then raise exception 'Company unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(snapshot order by created_at desc,contract_id desc),'[]')into items from(select c.created_at,c.contract_id,private.fleet_contract_snapshot(c)snapshot from private.fleet_contracts c where c.party_id=p_party and(p_before_created_at is null or(c.created_at,c.contract_id)<(p_before_created_at,p_before_id))order by c.created_at desc,c.contract_id desc limit p_limit)rows;
 return jsonb_build_object('items',items,'draft_only',true,'pricing_active',false,'billing_enabled',false,'eta_submission_enabled',false);end$$;
create function public.get_fleet_contract_command(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_fleet_contract_command(p_request)$$;
create function public.save_fleet_contract_draft(p_request uuid,p_party uuid,p_branch uuid,p_contract uuid,p_expected_version integer,p_terms jsonb,p_archive boolean,p_reason text)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.save_fleet_contract_draft(p_request,p_party,p_branch,p_contract,p_expected_version,p_terms,p_archive,p_reason)$$;
create function public.close_fleet_contract_command(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.close_fleet_contract_command(p_request)$$;
create function public.list_fleet_contracts(p_party uuid,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.list_fleet_contracts(p_party,p_before_created_at,p_before_id,p_limit)$$;
revoke all on function private.fleet_contract_owner(),private.fleet_contract_snapshot(private.fleet_contracts),private.fleet_contract_coherence(),private.validate_fleet_contract_terms(jsonb,uuid),private.get_fleet_contract_command(uuid),private.save_fleet_contract_draft(uuid,uuid,uuid,uuid,integer,jsonb,boolean,text),private.close_fleet_contract_command(uuid),private.list_fleet_contracts(uuid,timestamptz,uuid,integer),public.get_fleet_contract_command(uuid),public.save_fleet_contract_draft(uuid,uuid,uuid,uuid,integer,jsonb,boolean,text),public.close_fleet_contract_command(uuid),public.list_fleet_contracts(uuid,timestamptz,uuid,integer)from public,anon,authenticated,service_role;
grant execute on function private.get_fleet_contract_command(uuid),private.save_fleet_contract_draft(uuid,uuid,uuid,uuid,integer,jsonb,boolean,text),private.close_fleet_contract_command(uuid),private.list_fleet_contracts(uuid,timestamptz,uuid,integer),public.get_fleet_contract_command(uuid),public.save_fleet_contract_draft(uuid,uuid,uuid,uuid,integer,jsonb,boolean,text),public.close_fleet_contract_command(uuid),public.list_fleet_contracts(uuid,timestamptz,uuid,integer)to authenticated;
notify pgrst,'reload schema';
commit;
