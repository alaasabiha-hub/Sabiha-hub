begin;
-- Free evidence-backed MANUAL review tasks. No provider, money or business mutation.
create table private.owner_evidence_tasks(
 task_id uuid primary key,action text not null check(action in('reconcile_invoices','review_expense_records','verify_stock_counts','review_appointment_workload','review_feedback_coverage')),
 period_from date not null,period_to date not null,branch_id uuid not null references public.business_branches(branch_id),
 evidence jsonb not null,evidence_hash text not null,state text not null check(state in('proposed','approved','dismissed','completed')),
 version integer not null check(version>0),created_by uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 updated_by uuid not null references auth.users(id),updated_at timestamptz not null default clock_timestamp());
create table private.owner_evidence_task_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
create table private.owner_evidence_task_events(
 request_id uuid primary key references private.owner_evidence_task_commands(request_id)deferrable initially deferred,
 task_id uuid not null references private.owner_evidence_tasks(task_id),version integer not null,actor_id uuid not null references auth.users(id),
 before_state text,after_state text not null,reason text not null check(length(reason)between 3 and 1000),created_at timestamptz not null default clock_timestamp(),unique(task_id,version));
create index owner_evidence_task_created on private.owner_evidence_tasks(created_at desc,task_id desc);
do $$declare t text;begin foreach t in array array['owner_evidence_tasks','owner_evidence_task_commands','owner_evidence_task_events']loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger owner_evidence_commands_immutable before update or delete on private.owner_evidence_task_commands for each row execute function private.fleet_immutable();
create trigger owner_evidence_events_immutable before update or delete on private.owner_evidence_task_events for each row execute function private.fleet_immutable();
create function private.evidence_task_owner()returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if not private.has_live_invoice_session()or private.active_staff_role()is distinct from'owner'then raise exception 'Current owner session required'using errcode='42501';end if;
 return auth.uid();end$$;
create function private.owner_evidence_task_snapshot(t private.owner_evidence_tasks)returns jsonb language sql stable set search_path=pg_catalog as $$select jsonb_build_object(
 'task_id',t.task_id,'action',t.action,'from',t.period_from,'to',t.period_to,'branch_id',t.branch_id,'state',t.state,'version',t.version,
 'evidence',t.evidence,'evidence_hash',t.evidence_hash,'created_by',t.created_by,'created_at',t.created_at,'updated_by',t.updated_by,'updated_at',t.updated_at,
 'execution_mode','manual_review_only','paid_provider_allowed',false,'business_mutation_supported',false)$$;
create function private.save_owner_evidence_task(p_request uuid,p_action text,p_from date,p_to date,p_task uuid default null,p_expected_version integer default null,p_state text default 'proposed',p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.evidence_task_owner();payload jsonb;old_command private.owner_evidence_task_commands;task private.owner_evidence_tasks;prior_state text;result jsonb;evidence jsonb;branch uuid;
begin
 if p_request is null or p_reason is null or length(trim(p_reason))not between 3 and 1000 then raise exception 'Request and review reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('action',p_action,'from',p_from,'to',p_to,'task',p_task,'expected_version',p_expected_version,'state',p_state,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('owner-evidence-task:'||p_request::text,0));
 select *into old_command from private.owner_evidence_task_commands where request_id=p_request;
 if found then
 if old_command.actor_id<>actor or old_command.payload<>payload then raise exception 'Review request already used'using errcode='22023';end if;
 return old_command.result;end if;
 if p_task is null then
  if p_expected_version is not null or p_state is distinct from'proposed' or p_action is null or p_action not in('reconcile_invoices','review_expense_records','verify_stock_counts','review_appointment_workload','review_feedback_coverage')
   or p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Invalid review proposal'using errcode='22023';end if;
  -- Always capture authoritative aggregate evidence on the server, never client facts.
  evidence:=public.get_owner_business_insights(p_from,p_to);
  if jsonb_typeof(evidence->'metrics')is distinct from'array'or jsonb_array_length(evidence->'metrics')=0 then raise exception 'Insufficient recorded evidence'using errcode='55000';end if;
  branch:=public.default_branch_id();
  insert into private.owner_evidence_tasks(task_id,action,period_from,period_to,branch_id,evidence,evidence_hash,state,version,created_by,updated_by)
   values(p_request,p_action,p_from,p_to,branch,evidence,md5(evidence::text),'proposed',1,actor,actor)returning *into task;
 else
  select *into task from private.owner_evidence_tasks where task_id=p_task for update;
  if not found then raise exception 'Review task unavailable'using errcode='42501';end if;
  if p_expected_version is distinct from task.version then raise exception 'Review task changed; reload'using errcode='40001';end if;
  if p_action is distinct from task.action or p_from is distinct from task.period_from or p_to is distinct from task.period_to then raise exception 'Proposal evidence is immutable'using errcode='22023';end if;
  if not((task.state='proposed'and p_state in('approved','dismissed'))or(task.state='approved'and p_state in('completed','dismissed')))then raise exception 'Invalid review transition'using errcode='22023';end if;
  prior_state:=task.state;
  update private.owner_evidence_tasks set state=p_state,version=version+1,updated_by=actor,updated_at=clock_timestamp()where task_id=p_task returning *into task;
 end if;
 result:=private.owner_evidence_task_snapshot(task);
 insert into private.owner_evidence_task_events(request_id,task_id,version,actor_id,before_state,after_state,reason)values(p_request,task.task_id,task.version,actor,prior_state,task.state,trim(p_reason));
 insert into private.owner_evidence_task_commands(request_id,actor_id,payload,result)values(p_request,actor,payload,result);
 return result;
end$$;
create function private.list_owner_evidence_tasks()returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 perform private.evidence_task_owner();
 return coalesce((select jsonb_agg(private.owner_evidence_task_snapshot(t)order by t.created_at desc,t.task_id desc)from(select *from private.owner_evidence_tasks order by created_at desc,task_id desc limit 100)t),'[]'::jsonb);end$$;
create function private.get_owner_evidence_task_history(p_task uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 perform private.evidence_task_owner();
 if not exists(select 1 from private.owner_evidence_tasks where task_id=p_task)then raise exception 'Review task unavailable'using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(v)order by version)from private.owner_evidence_task_events v where task_id=p_task),'[]'::jsonb);end$$;
create function public.save_owner_evidence_task(p_request uuid,p_action text,p_from date,p_to date,p_task uuid default null,p_expected_version integer default null,p_state text default 'proposed',p_reason text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_evidence_task(p_request,p_action,p_from,p_to,p_task,p_expected_version,p_state,p_reason)$$;
create function public.list_owner_evidence_tasks()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_owner_evidence_tasks()$$;
create function public.get_owner_evidence_task_history(p_task uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_evidence_task_history(p_task)$$;
revoke all on function private.evidence_task_owner(),private.owner_evidence_task_snapshot(private.owner_evidence_tasks),private.save_owner_evidence_task(uuid,text,date,date,uuid,integer,text,text),private.list_owner_evidence_tasks(),private.get_owner_evidence_task_history(uuid),public.save_owner_evidence_task(uuid,text,date,date,uuid,integer,text,text),public.list_owner_evidence_tasks(),public.get_owner_evidence_task_history(uuid)from public,anon;
grant execute on function private.save_owner_evidence_task(uuid,text,date,date,uuid,integer,text,text),private.list_owner_evidence_tasks(),private.get_owner_evidence_task_history(uuid),public.save_owner_evidence_task(uuid,text,date,date,uuid,integer,text,text),public.list_owner_evidence_tasks(),public.get_owner_evidence_task_history(uuid)to authenticated;
commit;
