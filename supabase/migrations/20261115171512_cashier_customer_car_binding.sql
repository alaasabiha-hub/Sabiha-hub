begin;
-- A cashier's operational choice is not identity verification or permission to redeem loyalty.
create table private.cashier_draft_subjects(
 draft_id uuid primary key references private.cashier_reviewed_drafts(draft_id),actor_id uuid not null references auth.users(id),
 branch_id uuid not null references public.business_branches(branch_id),draft_version integer not null check(draft_version>0),
 version integer not null check(version>0),subject_kind text not null check(subject_kind in('app_customer','offline_profile')),
 subject_id uuid not null,car_id uuid not null,subject_snapshot jsonb not null,updated_at timestamptz not null default clock_timestamp());
create table private.cashier_draft_subject_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null);
alter table private.cashier_draft_subjects enable row level security;
alter table private.cashier_draft_subject_commands enable row level security;
revoke all on private.cashier_draft_subjects,private.cashier_draft_subject_commands from public,anon,authenticated,service_role;
create function private.cashier_subject_snapshot(p_branch uuid,p_kind text,p_subject uuid,p_car uuid)returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$declare result jsonb;begin
 if p_kind='app_customer'then
  select jsonb_build_object('kind',p_kind,'id',c.id,'name',c.full_name,'car',jsonb_build_object('id',v.id,'plate_number',v.plate_number,'brand',v.brand,'model',v.model,'year',v.year,'color',v.color))into result
  from public.customers c join public.vehicles v on v.customer_id=c.id and v.id=p_car where c.id=p_subject;
 elsif p_kind='offline_profile'then
  select jsonb_build_object('kind',p_kind,'id',c.profile_id,'name',c.full_name,'car',v.car_snapshot||jsonb_build_object('id',v.car_ref_id))into result
  from private.offline_customer_profiles c join private.offline_customer_car_refs v on v.profile_id=c.profile_id and v.car_ref_id=p_car
  where c.profile_id=p_subject and c.created_branch_id=p_branch;
 else raise exception 'Explicit supported customer source required'using errcode='22023';end if;
 if result is null then raise exception 'Customer and owned car unavailable'using errcode='42501';end if;
 return result||jsonb_build_object('identity_verified_by_selection',false,'loyalty_redemption_authorized',false,'automatic_account_link',false);
end$$;
revoke all on function private.cashier_subject_snapshot(uuid,text,uuid,uuid)from public,anon,authenticated,service_role;
create function private.find_cashier_customers(p_branch uuid,p_phone text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;v_phone text;rows jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);v_phone:=private.offline_phone_key(p_phone,'EG');
 if v_phone is null then raise exception 'Complete valid Egyptian phone required'using errcode='22023';end if;
 select coalesce(jsonb_agg(x.data order by x.kind,x.id),'[]')into rows from(
  select 'app_customer'kind,c.id,jsonb_build_object('kind','app_customer','id',c.id,'name',c.full_name,
   'cars',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'plate_number',v.plate_number,'brand',v.brand,'model',v.model,'year',v.year,'color',v.color)order by v.id)from public.vehicles v where v.customer_id=c.id),'[]'::jsonb))data
   from public.customers c where private.offline_phone_key(c.phone,'EG')=v_phone
  union all
  select 'offline_profile',c.profile_id,jsonb_build_object('kind','offline_profile','id',c.profile_id,'name',c.full_name,
   'cars',coalesce((select jsonb_agg(v.car_snapshot||jsonb_build_object('id',v.car_ref_id)order by v.car_ref_id)from private.offline_customer_car_refs v where v.profile_id=c.profile_id),'[]'::jsonb))
   from private.offline_customer_profiles c where c.created_branch_id=p_branch and exists(select 1 from private.offline_customer_contacts t where t.profile_id=c.profile_id and t.phone_e164=v_phone)
 )x;
 -- No email, password/Auth metadata, historical invoice, wallet, claim or secret is disclosed.
 return jsonb_build_object('candidates',rows,'requires_explicit_selection',true,'identity_verified_by_phone_match',false,'loyalty_redemption_authorized',false,'automatic_account_link',false);
end$$;
create function private.bind_cashier_draft_subject(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer,p_kind text,p_subject uuid,p_car uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;c private.cashier_draft_subject_commands;payload jsonb;snapshot jsonb;result jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_subject is null or p_car is null or p_expected_draft_version is null or p_expected_draft_version<1 or p_expected_binding_version is null or p_expected_binding_version<0 then raise exception 'Exact saved draft, binding version and owned car required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'draft',p_draft,'draft_version',p_expected_draft_version,'binding_version',p_expected_binding_version,'kind',p_kind,'subject',p_subject,'car',p_car);
 perform pg_advisory_xact_lock(hashtextextended('cashier-subject-request:'||p_request,0));select *into c from private.cashier_draft_subject_commands where request_id=p_request;
 if found then if c.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if c.payload<>payload then raise exception 'Immutable request'using errcode='22023';end if;return c.result;end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Draft unavailable'using errcode='42501';end if;
 if d.version<>p_expected_draft_version then raise exception 'Draft version conflict'using errcode='40001';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft for update;
 if coalesce(b.version,0)<>p_expected_binding_version then raise exception 'Binding version conflict'using errcode='40001';end if;
 snapshot:=private.cashier_subject_snapshot(p_branch,p_kind,p_subject,p_car);
 insert into private.cashier_draft_subjects values(p_draft,actor,p_branch,d.version,p_expected_binding_version+1,p_kind,p_subject,p_car,snapshot,clock_timestamp())on conflict(draft_id)do update set draft_version=excluded.draft_version,version=excluded.version,subject_kind=excluded.subject_kind,subject_id=excluded.subject_id,car_id=excluded.car_id,subject_snapshot=excluded.subject_snapshot,updated_at=excluded.updated_at;
 result:=jsonb_build_object('draft_id',p_draft,'draft_version',d.version,'binding_version',p_expected_binding_version+1,'subject',snapshot,'quote_only',true,'can_issue',false);
 insert into private.cashier_draft_subject_commands values(p_request,actor,payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'cashier_draft_subject_bound','cashier_reviewed_draft',p_draft::text,p_branch,to_jsonb(b),jsonb_build_object('subject_kind',p_kind,'subject_id',p_subject,'car_id',p_car,'draft_version',d.version,'binding_version',p_expected_binding_version+1));return result;
end$$;
create function private.get_cashier_draft_subject(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;begin
 actor:=private.cashier_cart_actor(p_branch);select *into d from private.cashier_reviewed_drafts where draft_id=p_draft;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Draft unavailable'using errcode='42501';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft;
 if not found then return jsonb_build_object('state','unbound','binding_version',0);end if;
 return jsonb_build_object('state',case when b.draft_version=d.version then'bound'else'stale'end,'draft_version',d.version,'bound_draft_version',b.draft_version,'binding_version',b.version,'subject',b.subject_snapshot,'can_issue',false);
end$$;
create function public.find_cashier_customers(p_branch uuid,p_phone text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.find_cashier_customers(p_branch,p_phone)$$;
create function public.bind_cashier_draft_subject(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer,p_kind text,p_subject uuid,p_car uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.bind_cashier_draft_subject(p_request,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version,p_kind,p_subject,p_car)$$;
create function public.get_cashier_draft_subject(p_branch uuid,p_draft uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_draft_subject(p_branch,p_draft)$$;
revoke all on function private.find_cashier_customers(uuid,text),public.find_cashier_customers(uuid,text),private.bind_cashier_draft_subject(uuid,uuid,uuid,integer,integer,text,uuid,uuid),public.bind_cashier_draft_subject(uuid,uuid,uuid,integer,integer,text,uuid,uuid),private.get_cashier_draft_subject(uuid,uuid),public.get_cashier_draft_subject(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.find_cashier_customers(uuid,text),public.find_cashier_customers(uuid,text),private.bind_cashier_draft_subject(uuid,uuid,uuid,integer,integer,text,uuid,uuid),public.bind_cashier_draft_subject(uuid,uuid,uuid,integer,integer,text,uuid,uuid),private.get_cashier_draft_subject(uuid,uuid),public.get_cashier_draft_subject(uuid,uuid)to authenticated;
notify pgrst,'reload schema';
commit;
