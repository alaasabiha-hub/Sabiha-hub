begin;
-- Master data only. No Auth company, billing, prices, credit, ETA or invoice writer.
create function private.fleet_require_owner(p_capability text)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if p_capability is null or p_capability not in('view','manage')then raise exception 'Unknown fleet capability'using errcode='22023';end if;
 return private.require_offline_channel_owner(); -- actual owner/session, never metadata permission
end$$;
create function private.fleet_text(p_value jsonb,p_max integer,p_required boolean default false)returns text language plpgsql immutable set search_path=pg_catalog as $$
declare v text;begin
 if p_value is null or p_value='null'::jsonb then if p_required then raise exception 'Explicit text required'using errcode='22023';end if;return null;end if;
 if jsonb_typeof(p_value)<>'string'then raise exception 'Text field required'using errcode='22023';end if;
 v:=nullif(trim(p_value#>>'{}'),'');if(p_required and v is null)or length(v)>p_max or v~'[[:cntrl:]]'then raise exception 'Invalid bounded text'using errcode='22023';end if;return v;
end$$;
create function private.fleet_country(p_value jsonb)returns text language plpgsql immutable set search_path=pg_catalog as $$
declare v text:=upper(private.fleet_text(p_value,2));begin if v is not null and v!~'^[A-Z]{2}$'then raise exception 'Explicit two-letter country format required'using errcode='22023';end if;return v;end$$;
create function private.fleet_party_terms(p_data jsonb)returns jsonb language plpgsql stable set search_path=pg_catalog as $$
declare legal text;trade text;country text;tax jsonb;address jsonb;representative jsonb;contacts jsonb:='[]'::jsonb;entry jsonb;key text;value text;kind text;seen text[]:='{}'::text[];begin
 if p_data is null or jsonb_typeof(p_data)<>'object'or not(p_data?&array['legal_name','trading_name','registration_country','tax','address','contacts','representative'])or p_data-array['legal_name','trading_name','registration_country','tax','address','contacts','representative']<>'{}'then raise exception 'Explicit party master-data fields required'using errcode='22023';end if;
 legal:=private.fleet_text(p_data->'legal_name',200);trade:=private.fleet_text(p_data->'trading_name',200);country:=private.fleet_country(p_data->'registration_country');
 if(legal is null and trade is null)or(legal is not null and length(legal)<2)or(trade is not null and length(trade)<2)then raise exception 'Actual legal or trading name required'using errcode='22023';end if;
 if p_data->'tax'<>'null'then
 entry:=p_data->'tax';if jsonb_typeof(entry)<>'object'or not(entry?&array['country','identifier_type','number'])or entry-array['country','identifier_type','number']<>'{}'then raise exception 'Explicit unverified tax identity required'using errcode='22023';end if;
 if private.fleet_country(entry->'country')is null then raise exception 'Tax country required'using errcode='22023';end if;
 tax:=jsonb_build_object('country',private.fleet_country(entry->'country'),'identifier_type',private.fleet_text(entry->'identifier_type',40,true),'number',private.fleet_text(entry->'number',80,true));
 end if;
 if p_data->'address'<>'null'then
 entry:=p_data->'address';if jsonb_typeof(entry)<>'object'or not(entry?&array['country','region','city','street','building','postal_code','additional'])or entry-array['country','region','city','street','building','postal_code','additional']<>'{}'then raise exception 'Structured address required'using errcode='22023';end if;
 address:=jsonb_build_object('country',private.fleet_country(entry->'country'));
 foreach key in array array['region','city','street','building','postal_code','additional']loop address:=address||jsonb_build_object(key,private.fleet_text(entry->key,case key when'additional'then 300 else 120 end));end loop;
 end if;
 if jsonb_typeof(p_data->'contacts')<>'array'or jsonb_array_length(p_data->'contacts')>25 then raise exception 'Bounded contact array required'using errcode='22023';end if;
 for entry in select x from jsonb_array_elements(p_data->'contacts')x loop
 if jsonb_typeof(entry)<>'object'or not(entry?&array['kind','value','label'])or entry-array['kind','value','label']<>'{}'then raise exception 'Explicit contact fields required'using errcode='22023';end if;
 kind:=entry->>'kind';if kind is null or kind not in('phone','email','other')then raise exception 'Unsupported recorded contact type'using errcode='22023';end if;
 value:=private.fleet_text(entry->'value',case when kind='phone'then 64 else 254 end,true);
 if kind='email'then value:=lower(value);if position('@'in value)<2 then raise exception 'Recorded email format required'using errcode='22023';end if;end if;
 key:=kind||':'||value;if key=any(seen)then raise exception 'Duplicate contact requires owner review'using errcode='23505';end if;seen:=array_append(seen,key);
 contacts:=contacts||jsonb_build_array(jsonb_build_object('kind',kind,'value',value,'label',private.fleet_text(entry->'label',80)));
 end loop;
 if p_data->'representative'<>'null'then
 entry:=p_data->'representative';if jsonb_typeof(entry)<>'object'or not(entry?&array['name','title','phone','email','verification'])or entry-array['name','title','phone','email','verification']<>'{}'or entry->>'verification'is distinct from'unverified'then raise exception 'Representative remains explicitly unverified'using errcode='22023';end if;
 representative:=jsonb_build_object('name',private.fleet_text(entry->'name',120,true),'title',private.fleet_text(entry->'title',120),'phone',private.fleet_text(entry->'phone',64),'email',private.fleet_text(entry->'email',254),'verification','unverified');
 end if;
 return jsonb_build_object('legal_name',legal,'trading_name',trade,'registration_country',country,'tax',tax,'address',address,'contacts',contacts,'representative',representative);
end$$;
create function private.fleet_vehicle_terms(p_data jsonb)returns jsonb language plpgsql stable set search_path=pg_catalog as $$
declare plate text;plate_key text;year_value integer;begin
 if p_data is null or jsonb_typeof(p_data)<>'object'or not(p_data?&array['plate_country','plate_number','make','model','year','color','fleet_reference'])or p_data-array['plate_country','plate_number','make','model','year','color','fleet_reference']<>'{}'then raise exception 'Explicit vehicle master-data fields required'using errcode='22023';end if;
 plate:=private.fleet_text(p_data->'plate_number',40,true);plate_key:=upper(regexp_replace(translate(trim(plate),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[[:space:]-]','','g'));
 if length(plate_key)not between 2 and 32 then raise exception 'Actual full plate required'using errcode='22023';end if;
 if p_data->'year'<>'null'then if jsonb_typeof(p_data->'year')<>'number'or(p_data->>'year')::numeric<>trunc((p_data->>'year')::numeric)or(p_data->>'year')::numeric not between 1000 and 9999 then raise exception 'Recorded year out of range'using errcode='22023';end if;year_value:=(p_data->>'year')::integer;end if;
 return jsonb_build_object('plate_country',private.fleet_country(p_data->'plate_country'),'plate_number',plate,'plate_key',plate_key,'make',private.fleet_text(p_data->'make',80),'model',private.fleet_text(p_data->'model',80),'year',year_value,'color',private.fleet_text(p_data->'color',40),'fleet_reference',private.fleet_text(p_data->'fleet_reference',80));
end$$;
create table private.fleet_catalog_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb,state text not null check(state in('open','succeeded','closed')),result jsonb,created_at timestamptz not null default clock_timestamp(),finished_at timestamptz,
 check((state='closed')or(payload is not null and jsonb_typeof(payload)='object')));
create table private.fleet_parties(
 party_id uuid primary key,version integer not null check(version>0),terms jsonb not null,archived boolean not null,verification_state text not null default'unverified'check(verification_state='unverified'),
 legal_name_key text,trading_name_key text,tax_country text,tax_type_key text,tax_number_key text,
 created_by uuid not null references auth.users(id),created_at timestamptz not null,updated_by uuid not null references auth.users(id),updated_at timestamptz not null,last_request uuid not null references private.fleet_catalog_commands(request_id));
create unique index fleet_observed_tax_key_once on private.fleet_parties(tax_country,tax_type_key,tax_number_key)where tax_number_key is not null;
create index fleet_party_cursor on private.fleet_parties(created_at desc,party_id desc);
create index fleet_party_legal_prefix on private.fleet_parties(legal_name_key text_pattern_ops);
create index fleet_party_trade_prefix on private.fleet_parties(trading_name_key text_pattern_ops);
create table private.fleet_vehicles(
 vehicle_id uuid primary key,party_id uuid not null references private.fleet_parties(party_id),version integer not null check(version>0),terms jsonb not null,archived boolean not null,
 plate_country text,plate_key text not null,make_key text,model_key text,fleet_reference_key text,
 created_by uuid not null references auth.users(id),created_at timestamptz not null,updated_by uuid not null references auth.users(id),updated_at timestamptz not null,last_request uuid not null references private.fleet_catalog_commands(request_id));
create unique index fleet_observed_plate_once on private.fleet_vehicles(coalesce(plate_country,''),plate_key);
create index fleet_vehicle_cursor on private.fleet_vehicles(party_id,created_at desc,vehicle_id desc);
create index fleet_vehicle_plate_prefix on private.fleet_vehicles(party_id,plate_key text_pattern_ops);
create index fleet_vehicle_make_prefix on private.fleet_vehicles(party_id,make_key text_pattern_ops);
create index fleet_vehicle_model_prefix on private.fleet_vehicles(party_id,model_key text_pattern_ops);
create index fleet_vehicle_reference_prefix on private.fleet_vehicles(party_id,fleet_reference_key text_pattern_ops);
create table private.fleet_catalog_versions(
 request_id uuid primary key references private.fleet_catalog_commands(request_id),entity_kind text not null check(entity_kind in('party','vehicle')),entity_id uuid not null,
 party_id uuid not null references private.fleet_parties(party_id)deferrable initially deferred,vehicle_id uuid references private.fleet_vehicles(vehicle_id)deferrable initially deferred,
 entity_version integer not null check(entity_version>0),operation text not null,actor_id uuid not null references auth.users(id),actor_role text not null check(actor_role='owner'),reason text not null,
 before_snapshot jsonb,after_snapshot jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),
 unique(entity_kind,entity_id,entity_version),check((entity_kind='party'and entity_id=party_id and vehicle_id is null)or(entity_kind='vehicle'and entity_id=vehicle_id)));
create function private.fleet_immutable()returns trigger language plpgsql set search_path=pg_catalog as $$begin raise exception 'Fleet catalogue history retained'using errcode='55000';end$$;
do $$declare t text;begin foreach t in array array['fleet_catalog_commands','fleet_parties','fleet_vehicles','fleet_catalog_versions']loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_fleet_catalog_versions before update or delete on private.fleet_catalog_versions for each row execute function private.fleet_immutable();
create function private.fleet_party_snapshot(p private.fleet_parties)returns jsonb language sql stable set search_path=pg_catalog as $$select jsonb_build_object('party_id',p.party_id,'version',p.version,'terms',p.terms,'archived',p.archived,'verification_state',p.verification_state)$$;
create function private.fleet_vehicle_snapshot(v private.fleet_vehicles)returns jsonb language sql stable set search_path=pg_catalog as $$select jsonb_build_object('vehicle_id',v.vehicle_id,'party_id',v.party_id,'version',v.version,'terms',v.terms,'archived',v.archived,'verification_state','unverified')$$;
create function private.fleet_command_snapshot(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.fleet_require_owner('manage');c private.fleet_catalog_commands;begin
 select *into c from private.fleet_catalog_commands where request_id=p_request;
 if not found then return jsonb_build_object('request_id',p_request,'state','absent','definitive_failure',false);end if;
 if c.actor_id<>actor then raise exception 'Own fleet command unavailable'using errcode='42501';end if;
 return jsonb_build_object('request_id',p_request,'state',c.state,'payload',c.payload,'result',c.result,'created_at',c.created_at,'finished_at',c.finished_at,'definitive_failure',c.state='closed');
end$$;
create function private.fleet_guard_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'or old.state<>'open'or new.state not in('succeeded','closed')or(to_jsonb(new)-array['state','result','finished_at'])is distinct from(to_jsonb(old)-array['state','result','finished_at'])then raise exception 'Fleet command payload/terminal state immutable'using errcode='55000';end if;
 if new.state='succeeded'and not exists(select 1 from private.fleet_catalog_versions e where e.request_id=new.request_id and e.actor_id=new.actor_id and e.creator_xid=txid_current())then raise exception 'Actual fleet change receipt required'using errcode='55000';end if;return new;end$$;
create trigger guard_fleet_command before update or delete on private.fleet_catalog_commands for each row execute function private.fleet_guard_command();
create function private.fleet_guard_version()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare c private.fleet_catalog_commands;actor uuid:=private.fleet_require_owner('manage');begin
 select *into c from private.fleet_catalog_commands where request_id=new.request_id;
 if c.request_id is null or c.state<>'open'or c.actor_id<>actor or new.actor_id<>actor or new.creator_xid<>txid_current()or new.actor_role<>'owner'
 or new.entity_kind is distinct from split_part(c.payload->>'kind','_',1)or c.payload->>'kind'<>new.operation or(c.payload->>'entity_id')::uuid<>new.entity_id or(c.payload->>'party_id')::uuid<>new.party_id
 or new.entity_version<>coalesce((c.payload->>'expected_version')::integer,0)+1 or new.reason is distinct from c.payload->>'reason'then raise exception 'Actual prepared owner fleet operation required'using errcode='55000';end if;return new;end$$;
create trigger guard_fleet_version before insert on private.fleet_catalog_versions for each row execute function private.fleet_guard_version();
create function private.fleet_guard_party()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.fleet_catalog_versions;before_value jsonb;after_value jsonb;actor uuid:=private.fleet_require_owner('manage');begin
 if tg_op='DELETE'then raise exception 'Archive fleet entities; never delete'using errcode='55000';end if;
 after_value:=private.fleet_party_snapshot(new);if tg_op='UPDATE'then before_value:=private.fleet_party_snapshot(old);end if;
 select *into e from private.fleet_catalog_versions where request_id=new.last_request;
 if e.request_id is null or e.entity_kind<>'party'or e.creator_xid<>txid_current()or e.actor_id<>actor or e.after_snapshot is distinct from after_value or e.before_snapshot is distinct from before_value or new.updated_by<>actor then raise exception 'Exact current transaction fleet history required'using errcode='55000';end if;
 if tg_op='UPDATE'and(new.party_id is distinct from old.party_id or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by or new.version<>old.version+1)then raise exception 'Fleet identity and history retained'using errcode='55000';end if;
 if tg_op='INSERT'and(new.version<>1 or new.created_by<>actor)then raise exception 'Initial owner fleet version required'using errcode='55000';end if;return new;end$$;
create trigger guard_fleet_party before insert or update or delete on private.fleet_parties for each row execute function private.fleet_guard_party();
create function private.fleet_guard_vehicle()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.fleet_catalog_versions;before_value jsonb;after_value jsonb;actor uuid:=private.fleet_require_owner('manage');begin
 if tg_op='DELETE'then raise exception 'Archive fleet entities; never delete'using errcode='55000';end if;
 after_value:=private.fleet_vehicle_snapshot(new);if tg_op='UPDATE'then before_value:=private.fleet_vehicle_snapshot(old);end if;
 select *into e from private.fleet_catalog_versions where request_id=new.last_request;
 if e.request_id is null or e.entity_kind<>'vehicle'or e.creator_xid<>txid_current()or e.actor_id<>actor or e.after_snapshot is distinct from after_value or e.before_snapshot is distinct from before_value or new.updated_by<>actor then raise exception 'Exact current transaction fleet history required'using errcode='55000';end if;
 if tg_op='UPDATE'and(new.vehicle_id is distinct from old.vehicle_id or new.party_id is distinct from old.party_id or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by or new.version<>old.version+1)then raise exception 'Fleet identity and history retained'using errcode='55000';end if;
 if tg_op='INSERT'and(new.version<>1 or new.created_by<>actor)then raise exception 'Initial owner fleet version required'using errcode='55000';end if;return new;end$$;
create trigger guard_fleet_vehicle before insert or update or delete on private.fleet_vehicles for each row execute function private.fleet_guard_vehicle();
create function private.fleet_validate_target(p_kind text,p_entity uuid,p_party uuid,p_expected integer)returns void language plpgsql volatile security definer set search_path=pg_catalog as $$
declare party_row private.fleet_parties;vehicle_row private.fleet_vehicles;begin
 if p_kind like'party_%'then
 if p_entity<>p_party then raise exception 'Party identity mismatch'using errcode='22023';end if;
 select *into party_row from private.fleet_parties where party_id=p_party;
 if p_kind='party_create'then if p_expected is not null then raise exception 'Create has no prior version'using errcode='22023';end if;if found then raise exception 'Party already exists; never merge'using errcode='23505';end if;
 else
 if party_row.party_id is null then raise exception 'Party unavailable'using errcode='42501';end if;
 if p_expected is null or p_expected<>party_row.version then raise exception 'Party version changed'using errcode='40001';end if;
 if(p_kind='party_archive'and party_row.archived)or(p_kind='party_reenable'and not party_row.archived)then raise exception 'Party state already changed'using errcode='55000';end if;
 end if;
 else
 select *into party_row from private.fleet_parties where party_id=p_party;
 if not found then raise exception 'Actual party required'using errcode='42501';end if;
 if party_row.archived and p_kind<>'vehicle_archive'then raise exception 'Re-enable actual party first'using errcode='55000';end if;
 select *into vehicle_row from private.fleet_vehicles where vehicle_id=p_entity;
 if p_kind='vehicle_create'then if p_expected is not null then raise exception 'Create has no prior version'using errcode='22023';end if;if found then raise exception 'Vehicle already exists; never merge'using errcode='23505';end if;
 else
 if vehicle_row.vehicle_id is null or vehicle_row.party_id<>p_party then raise exception 'Vehicle unavailable in selected party'using errcode='42501';end if;
 if p_expected is null or p_expected<>vehicle_row.version then raise exception 'Vehicle version changed'using errcode='40001';end if;
 if(p_kind='vehicle_archive'and vehicle_row.archived)or(p_kind='vehicle_reenable'and not vehicle_row.archived)then raise exception 'Vehicle state already changed'using errcode='55000';end if;
 end if;end if;
end$$;
create function private.prepare_fleet_catalog_command(p_request uuid,p_kind text,p_entity uuid,p_party uuid,p_expected_version integer,p_data jsonb,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;canonical jsonb;data_value jsonb;c private.fleet_catalog_commands;begin
 if p_request is null or p_entity is null or p_party is null or p_kind is null or p_kind not in('party_create','party_edit','party_archive','party_reenable','vehicle_create','vehicle_edit','vehicle_archive','vehicle_reenable')or length(trim(coalesce(p_reason,'')))not between 10 and 500 or(p_expected_version is not null and p_expected_version<1)then raise exception 'Explicit fleet operation/identity/version/reason required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 if p_kind in('party_create','party_edit')then data_value:=private.fleet_party_terms(p_data);
 elsif p_kind in('vehicle_create','vehicle_edit')then data_value:=private.fleet_vehicle_terms(p_data);
 else if p_data is distinct from'{}'::jsonb then raise exception 'State-only operation requires empty data object'using errcode='22023';end if;data_value:='{}';end if;
 canonical:=jsonb_build_object('kind',p_kind,'entity_id',p_entity,'party_id',p_party,'expected_version',p_expected_version,'data',data_value,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('fleet-command:'||p_request::text,0));actor:=private.fleet_require_owner('manage');
 select *into c from private.fleet_catalog_commands where request_id=p_request;
 if found then if c.actor_id<>actor then raise exception 'Own fleet command unavailable'using errcode='42501';end if;if c.payload is not null and c.payload is distinct from canonical then raise exception 'Fleet command identity changed'using errcode='22023';end if;return private.fleet_command_snapshot(p_request);end if;
 perform private.fleet_validate_target(p_kind,p_entity,p_party,p_expected_version);
 insert into private.fleet_catalog_commands(request_id,actor_id,payload,state)values(p_request,actor,canonical,'open');
 return private.fleet_command_snapshot(p_request);
end$$;
create function private.get_fleet_catalog_command(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$begin
 if p_request is null then raise exception 'Exact command reference required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('fleet-command:'||p_request::text,0));return private.fleet_command_snapshot(p_request);end$$;
create function private.close_fleet_catalog_command(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;c private.fleet_catalog_commands;begin
 if p_request is null then raise exception 'Exact command reference required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('fleet-command:'||p_request::text,0));actor:=private.fleet_require_owner('manage');
 select *into c from private.fleet_catalog_commands where request_id=p_request;
 if found then
 if c.actor_id<>actor then raise exception 'Own fleet command unavailable'using errcode='42501';end if;
 if c.state='open'then update private.fleet_catalog_commands set state='closed',result='{"status":"closed"}',finished_at=clock_timestamp()where request_id=p_request;end if;
 else insert into private.fleet_catalog_commands(request_id,actor_id,state,result,finished_at)values(p_request,actor,'closed','{"status":"closed"}',clock_timestamp());end if;
 return private.fleet_command_snapshot(p_request);
end$$;
create function private.apply_fleet_catalog_command(p_request uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;c private.fleet_catalog_commands;kind text;entity uuid;party uuid;expected integer;data_value jsonb;before_value jsonb;after_value jsonb;entity_kind text;
 party_row private.fleet_parties;vehicle_row private.fleet_vehicles;creating boolean;observed timestamptz;begin
 if p_request is null then raise exception 'Exact prepared command reference required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('fleet-command:'||p_request::text,0));actor:=private.fleet_require_owner('manage');
 select *into c from private.fleet_catalog_commands where request_id=p_request for update;
 if not found or c.actor_id<>actor then raise exception 'Own prepared command unavailable'using errcode='42501';end if;
 if c.state<>'open'then return private.fleet_command_snapshot(p_request);end if;
 kind:=c.payload->>'kind';entity:=(c.payload->>'entity_id')::uuid;party:=(c.payload->>'party_id')::uuid;expected:=(c.payload->>'expected_version')::integer;data_value:=c.payload->'data';entity_kind:=split_part(kind,'_',1);creating:=kind in('party_create','vehicle_create');
 -- Shared parent-first order serializes vehicle creation/edit against party
 -- archive; all callers recheck live owner/session AFTER any entity wait.
 perform pg_advisory_xact_lock(hashtextextended('fleet-party:'||party::text,0));
 if entity_kind='vehicle'then perform pg_advisory_xact_lock(hashtextextended('fleet-vehicle:'||entity::text,0));end if;
 actor:=private.fleet_require_owner('manage');perform private.fleet_validate_target(kind,entity,party,expected);observed:=clock_timestamp();
 if entity_kind='party'then
 select *into party_row from private.fleet_parties where party_id=party for update;
 if not creating then before_value:=private.fleet_party_snapshot(party_row);end if;
 if creating then party_row.party_id:=party;party_row.created_by:=actor;party_row.created_at:=observed;party_row.archived:=false;party_row.verification_state:='unverified';end if;
 party_row.version:=coalesce(expected,0)+1;
 if kind in('party_create','party_edit')then party_row.terms:=data_value;end if;
 if kind='party_archive'then party_row.archived:=true;elsif kind='party_reenable'then party_row.archived:=false;end if;
 party_row.legal_name_key:=lower(regexp_replace(party_row.terms->>'legal_name','[[:space:]]+',' ','g'));party_row.trading_name_key:=lower(regexp_replace(party_row.terms->>'trading_name','[[:space:]]+',' ','g'));
 party_row.tax_country:=party_row.terms#>>'{tax,country}';party_row.tax_type_key:=lower(party_row.terms#>>'{tax,identifier_type}');party_row.tax_number_key:=lower(regexp_replace(party_row.terms#>>'{tax,number}','[[:space:]]','','g'));
 party_row.updated_by:=actor;party_row.updated_at:=observed;party_row.last_request:=p_request;after_value:=private.fleet_party_snapshot(party_row);
 else
 select *into vehicle_row from private.fleet_vehicles where vehicle_id=entity for update;
 if not creating then before_value:=private.fleet_vehicle_snapshot(vehicle_row);end if;
 if creating then vehicle_row.vehicle_id:=entity;vehicle_row.party_id:=party;vehicle_row.created_by:=actor;vehicle_row.created_at:=observed;vehicle_row.archived:=false;end if;
 vehicle_row.version:=coalesce(expected,0)+1;
 if kind in('vehicle_create','vehicle_edit')then vehicle_row.terms:=data_value;end if;
 if kind='vehicle_archive'then vehicle_row.archived:=true;elsif kind='vehicle_reenable'then vehicle_row.archived:=false;end if;
 vehicle_row.plate_country:=vehicle_row.terms->>'plate_country';vehicle_row.plate_key:=vehicle_row.terms->>'plate_key';vehicle_row.make_key:=lower(vehicle_row.terms->>'make');vehicle_row.model_key:=lower(vehicle_row.terms->>'model');vehicle_row.fleet_reference_key:=lower(vehicle_row.terms->>'fleet_reference');
 vehicle_row.updated_by:=actor;vehicle_row.updated_at:=observed;vehicle_row.last_request:=p_request;after_value:=private.fleet_vehicle_snapshot(vehicle_row);
 end if;
 insert into private.fleet_catalog_versions(request_id,entity_kind,entity_id,party_id,vehicle_id,entity_version,operation,actor_id,actor_role,reason,before_snapshot,after_snapshot,creator_xid)
 values(p_request,entity_kind,entity,party,case when entity_kind='vehicle'then entity end,coalesce(expected,0)+1,kind,actor,'owner',c.payload->>'reason',before_value,after_value,txid_current());
 if entity_kind='party'then
 if creating then insert into private.fleet_parties select(party_row).*;
 else update private.fleet_parties set version=party_row.version,terms=party_row.terms,archived=party_row.archived,legal_name_key=party_row.legal_name_key,trading_name_key=party_row.trading_name_key,tax_country=party_row.tax_country,tax_type_key=party_row.tax_type_key,tax_number_key=party_row.tax_number_key,updated_by=actor,updated_at=observed,last_request=p_request where party_id=party;end if;
 else
 if creating then insert into private.fleet_vehicles select(vehicle_row).*;
 else update private.fleet_vehicles set version=vehicle_row.version,terms=vehicle_row.terms,archived=vehicle_row.archived,plate_country=vehicle_row.plate_country,plate_key=vehicle_row.plate_key,make_key=vehicle_row.make_key,model_key=vehicle_row.model_key,fleet_reference_key=vehicle_row.fleet_reference_key,updated_by=actor,updated_at=observed,last_request=p_request where vehicle_id=entity;end if;
 end if;
 update private.fleet_catalog_commands set state='succeeded',result=jsonb_build_object('entity_kind',entity_kind,'entity',after_value,'verification_state','unverified','billing_enabled',false,'eta_submission_enabled',false),finished_at=clock_timestamp()where request_id=p_request;
 return private.fleet_command_snapshot(p_request);
end$$;
create function private.fleet_like_prefix(p_search text)returns text language sql immutable set search_path=pg_catalog as $$select replace(replace(replace(lower(trim(coalesce(p_search,''))),chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%'$$;
create function private.get_fleet_catalogue_context()returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 perform private.fleet_require_owner('view');
 return jsonb_build_object('module','companies_fleets','owner_only',true,'view_allowed',true,'manage_allowed',true,'verification_state','unverified','company_auth_accounts',false,
 'billing_enabled',false,'contracts_enabled',false,'pricing_enabled',false,'bulk_work_enabled',false,'receivables_enabled',false,'eta_submission_enabled',false,'tax_rate',null,'actual_profit',null);
end$$;
create function private.get_fleet_party(p_party uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare item private.fleet_parties;duplicates jsonb;begin
 perform private.fleet_require_owner('view');select *into item from private.fleet_parties where party_id=p_party;
 if not found then raise exception 'Party unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(party_id),'[]')into duplicates from(select x.party_id from private.fleet_parties x where x.party_id<>p_party
 and((item.legal_name_key is not null and(item.legal_name_key=x.legal_name_key or item.legal_name_key=x.trading_name_key))or(item.trading_name_key is not null and(item.trading_name_key=x.legal_name_key or item.trading_name_key=x.trading_name_key)))order by x.party_id limit 10)matches;
 return private.fleet_party_snapshot(item)||jsonb_build_object('created_at',item.created_at,'updated_at',item.updated_at,'effective_active',not item.archived,'possible_same_name_parties',duplicates,'name_match_is_identity_proof',false,
 'vehicle_count',(select count(*)from private.fleet_vehicles where party_id=p_party),'billing_enabled',false,'eta_submission_enabled',false);
end$$;
create function private.get_fleet_vehicle(p_party uuid,p_vehicle uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare item private.fleet_vehicles;parent private.fleet_parties;begin
 perform private.fleet_require_owner('view');select *into item from private.fleet_vehicles where vehicle_id=p_vehicle and party_id=p_party;
 if not found then raise exception 'Vehicle unavailable in selected party'using errcode='42501';end if;select *into strict parent from private.fleet_parties where party_id=p_party;
 return private.fleet_vehicle_snapshot(item)||jsonb_build_object('created_at',item.created_at,'updated_at',item.updated_at,'effective_active',not item.archived and not parent.archived,'party_archived',parent.archived,'plate_is_ownership_proof',false);
end$$;
create function private.list_fleet_parties(p_search text default'',p_include_archived boolean default false,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare pattern text;items jsonb;more boolean;last_item jsonb;begin
 perform private.fleet_require_owner('view');
 if length(coalesce(p_search,''))>120 or p_include_archived is null or p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_id is null)then raise exception 'Valid bounded catalogue cursor/search required'using errcode='22023';end if;
 pattern:=private.fleet_like_prefix(p_search);
 with page as(select x.*from private.fleet_parties x where(p_include_archived or not x.archived)and(p_before_created_at is null or(x.created_at,x.party_id)<(p_before_created_at,p_before_id))
 and(trim(coalesce(p_search,''))=''or x.legal_name_key like pattern escape chr(92)or x.trading_name_key like pattern escape chr(92))order by x.created_at desc,x.party_id desc limit p_limit+1),
 limited as(select *from page order by created_at desc,party_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('party_id',party_id,'version',version,'legal_name',terms->'legal_name','trading_name',terms->'trading_name','archived',archived,'verification_state','unverified','created_at',created_at)order by created_at desc,party_id desc),'[]'),(select count(*)>p_limit from page)into items,more from limited;
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'next_cursor',case when more then jsonb_build_object('created_at',last_item->'created_at','entity_id',last_item->'party_id')end,'verification_state','unverified');
end$$;
create function private.list_fleet_vehicles(p_party uuid,p_search text default'',p_include_archived boolean default false,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare pattern text;plate_pattern text;items jsonb;more boolean;last_item jsonb;parent private.fleet_parties;begin
 perform private.fleet_require_owner('view');select *into parent from private.fleet_parties where party_id=p_party;
 if not found then raise exception 'Actual party required'using errcode='42501';end if;
 if length(coalesce(p_search,''))>120 or p_include_archived is null or p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_id is null)then raise exception 'Valid bounded vehicle cursor/search required'using errcode='22023';end if;
 pattern:=private.fleet_like_prefix(p_search);plate_pattern:=upper(private.fleet_like_prefix(regexp_replace(translate(trim(coalesce(p_search,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[[:space:]-]','','g')));
 with page as(select x.*from private.fleet_vehicles x where x.party_id=p_party and(p_include_archived or not x.archived)and(p_before_created_at is null or(x.created_at,x.vehicle_id)<(p_before_created_at,p_before_id))
 and(trim(coalesce(p_search,''))=''or x.plate_key like plate_pattern escape chr(92)or x.make_key like pattern escape chr(92)or x.model_key like pattern escape chr(92)or x.fleet_reference_key like pattern escape chr(92))order by x.created_at desc,x.vehicle_id desc limit p_limit+1),
 limited as(select *from page order by created_at desc,vehicle_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('vehicle_id',vehicle_id,'party_id',party_id,'version',version,'plate_country',terms->'plate_country','plate_number',terms->'plate_number','make',terms->'make','model',terms->'model','year',terms->'year','color',terms->'color','fleet_reference',terms->'fleet_reference','archived',archived,'effective_active',not archived and not parent.archived,'created_at',created_at)order by created_at desc,vehicle_id desc),'[]'),(select count(*)>p_limit from page)into items,more from limited;
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'next_cursor',case when more then jsonb_build_object('created_at',last_item->'created_at','entity_id',last_item->'vehicle_id')end,'party_archived',parent.archived,'verification_state','unverified','vehicle_capacity_limit',null);
end$$;
create function private.list_fleet_catalogue_history(p_entity_kind text,p_entity uuid,p_before_version integer default null,p_limit integer default 25)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare items jsonb;more boolean;last_item jsonb;begin
 perform private.fleet_require_owner('view');
 if p_entity_kind is null or p_entity_kind not in('party','vehicle')or p_entity is null or p_limit is null or p_limit not between 1 and 50 or(p_before_version is not null and p_before_version<1)then raise exception 'Exact bounded entity history required'using errcode='22023';end if;
 if(p_entity_kind='party'and not exists(select 1 from private.fleet_parties where party_id=p_entity))or(p_entity_kind='vehicle'and not exists(select 1 from private.fleet_vehicles where vehicle_id=p_entity))then raise exception 'Entity unavailable'using errcode='42501';end if;
 with page as(select e.*from private.fleet_catalog_versions e where e.entity_kind=p_entity_kind and e.entity_id=p_entity and(p_before_version is null or e.entity_version<p_before_version)order by e.entity_version desc limit p_limit+1),
 limited as(select *from page order by entity_version desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('request_id',request_id,'version',entity_version,'operation',operation,'actor_id',actor_id,'actor_role',actor_role,'reason',reason,'before',before_snapshot,'after',after_snapshot,'created_at',created_at)order by entity_version desc),'[]'),(select count(*)>p_limit from page)into items,more from limited;
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'next_before_version',case when more then last_item->'version'end,'entity_kind',p_entity_kind,'entity_id',p_entity);
end$$;

revoke all on function private.fleet_require_owner(text)from public,anon,authenticated,service_role;
revoke all on function private.fleet_text(jsonb,integer,boolean)from public,anon,authenticated,service_role;
revoke all on function private.fleet_country(jsonb)from public,anon,authenticated,service_role;
revoke all on function private.fleet_party_terms(jsonb)from public,anon,authenticated,service_role;
revoke all on function private.fleet_vehicle_terms(jsonb)from public,anon,authenticated,service_role;
revoke all on function private.fleet_immutable()from public,anon,authenticated,service_role;
revoke all on function private.fleet_party_snapshot(private.fleet_parties)from public,anon,authenticated,service_role;
revoke all on function private.fleet_vehicle_snapshot(private.fleet_vehicles)from public,anon,authenticated,service_role;
revoke all on function private.fleet_command_snapshot(uuid)from public,anon,authenticated,service_role;
revoke all on function private.fleet_guard_command()from public,anon,authenticated,service_role;
revoke all on function private.fleet_guard_version()from public,anon,authenticated,service_role;
revoke all on function private.fleet_guard_party(),private.fleet_guard_vehicle()from public,anon,authenticated,service_role;
revoke all on function private.fleet_validate_target(text,uuid,uuid,integer)from public,anon,authenticated,service_role;
revoke all on function private.prepare_fleet_catalog_command(uuid,text,uuid,uuid,integer,jsonb,text)from public,anon,authenticated,service_role;
revoke all on function private.get_fleet_catalog_command(uuid)from public,anon,authenticated,service_role;
revoke all on function private.close_fleet_catalog_command(uuid)from public,anon,authenticated,service_role;
revoke all on function private.apply_fleet_catalog_command(uuid)from public,anon,authenticated,service_role;
revoke all on function private.fleet_like_prefix(text)from public,anon,authenticated,service_role;
revoke all on function private.get_fleet_catalogue_context()from public,anon,authenticated,service_role;
revoke all on function private.get_fleet_party(uuid)from public,anon,authenticated,service_role;
revoke all on function private.get_fleet_vehicle(uuid,uuid)from public,anon,authenticated,service_role;
revoke all on function private.list_fleet_parties(text,boolean,timestamptz,uuid,integer)from public,anon,authenticated,service_role;
revoke all on function private.list_fleet_vehicles(uuid,text,boolean,timestamptz,uuid,integer)from public,anon,authenticated,service_role;
revoke all on function private.list_fleet_catalogue_history(text,uuid,integer,integer)from public,anon,authenticated,service_role;
grant execute on function private.get_fleet_catalogue_context()to authenticated;
create function public.get_fleet_catalogue_context()returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_fleet_catalogue_context()$$;
revoke all on function public.get_fleet_catalogue_context()from public,anon,service_role;
grant execute on function public.get_fleet_catalogue_context()to authenticated;
grant execute on function private.get_fleet_party(uuid)to authenticated;
create function public.get_fleet_party(p_party uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_fleet_party(p_party)$$;
revoke all on function public.get_fleet_party(uuid)from public,anon,service_role;
grant execute on function public.get_fleet_party(uuid)to authenticated;
grant execute on function private.get_fleet_vehicle(uuid,uuid)to authenticated;
create function public.get_fleet_vehicle(p_party uuid,p_vehicle uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_fleet_vehicle(p_party,p_vehicle)$$;
revoke all on function public.get_fleet_vehicle(uuid,uuid)from public,anon,service_role;
grant execute on function public.get_fleet_vehicle(uuid,uuid)to authenticated;
grant execute on function private.list_fleet_parties(text,boolean,timestamptz,uuid,integer)to authenticated;
create function public.list_fleet_parties(p_search text default'',p_include_archived boolean default false,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.list_fleet_parties(p_search,p_include_archived,p_before_created_at,p_before_id,p_limit)$$;
revoke all on function public.list_fleet_parties(text,boolean,timestamptz,uuid,integer)from public,anon,service_role;
grant execute on function public.list_fleet_parties(text,boolean,timestamptz,uuid,integer)to authenticated;
grant execute on function private.list_fleet_vehicles(uuid,text,boolean,timestamptz,uuid,integer)to authenticated;
create function public.list_fleet_vehicles(p_party uuid,p_search text default'',p_include_archived boolean default false,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.list_fleet_vehicles(p_party,p_search,p_include_archived,p_before_created_at,p_before_id,p_limit)$$;
revoke all on function public.list_fleet_vehicles(uuid,text,boolean,timestamptz,uuid,integer)from public,anon,service_role;
grant execute on function public.list_fleet_vehicles(uuid,text,boolean,timestamptz,uuid,integer)to authenticated;
grant execute on function private.list_fleet_catalogue_history(text,uuid,integer,integer)to authenticated;
create function public.list_fleet_catalogue_history(p_entity_kind text,p_entity uuid,p_before_version integer default null,p_limit integer default 25)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.list_fleet_catalogue_history(p_entity_kind,p_entity,p_before_version,p_limit)$$;
revoke all on function public.list_fleet_catalogue_history(text,uuid,integer,integer)from public,anon,service_role;
grant execute on function public.list_fleet_catalogue_history(text,uuid,integer,integer)to authenticated;
grant execute on function private.prepare_fleet_catalog_command(uuid,text,uuid,uuid,integer,jsonb,text)to authenticated;
create function public.prepare_fleet_catalog_command(p_request uuid,p_kind text,p_entity uuid,p_party uuid,p_expected_version integer,p_data jsonb,p_reason text)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.prepare_fleet_catalog_command(p_request,p_kind,p_entity,p_party,p_expected_version,p_data,p_reason)$$;
revoke all on function public.prepare_fleet_catalog_command(uuid,text,uuid,uuid,integer,jsonb,text)from public,anon,service_role;
grant execute on function public.prepare_fleet_catalog_command(uuid,text,uuid,uuid,integer,jsonb,text)to authenticated;
grant execute on function private.get_fleet_catalog_command(uuid)to authenticated;
create function public.get_fleet_catalog_command(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_fleet_catalog_command(p_request)$$;
revoke all on function public.get_fleet_catalog_command(uuid)from public,anon,service_role;
grant execute on function public.get_fleet_catalog_command(uuid)to authenticated;
grant execute on function private.close_fleet_catalog_command(uuid)to authenticated;
create function public.close_fleet_catalog_command(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.close_fleet_catalog_command(p_request)$$;
revoke all on function public.close_fleet_catalog_command(uuid)from public,anon,service_role;
grant execute on function public.close_fleet_catalog_command(uuid)to authenticated;
grant execute on function private.apply_fleet_catalog_command(uuid)to authenticated;
create function public.apply_fleet_catalog_command(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.apply_fleet_catalog_command(p_request)$$;
revoke all on function public.apply_fleet_catalog_command(uuid)from public,anon,service_role;
grant execute on function public.apply_fleet_catalog_command(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
