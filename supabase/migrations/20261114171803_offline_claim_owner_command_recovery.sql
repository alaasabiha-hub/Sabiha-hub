begin;
-- Private, current-owner-only command recovery. No identity/financial bridge or old-row backfill.
create table private.offline_claim_owner_commands(
 request_id uuid primary key,owner_id uuid not null references auth.users(id),kind text check(kind in('decide','revoke')),payload jsonb,
 state text not null check(state in('open','succeeded','closed')),result jsonb,created_at timestamptz not null default clock_timestamp(),finished_at timestamptz,
 check((kind is null)=(payload is null)),check(payload is null or jsonb_typeof(payload)='object'),
 check((state='open'and kind is not null and result is null and finished_at is null)or(state='succeeded'and kind is not null and result is not null and finished_at is not null)or(state='closed'and result is null and finished_at is not null)));
alter table private.offline_claim_owner_commands enable row level security;
revoke all on private.offline_claim_owner_commands from public,anon,authenticated,service_role;
create function private.guard_offline_claim_owner_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE' then raise exception 'Owner commands and tombstones are retained'using errcode='55000';end if;
 if old.state<>'open' or new.state not in('succeeded','closed') or (to_jsonb(new)-array['state','result','finished_at'])is distinct from(to_jsonb(old)-array['state','result','finished_at'])then raise exception 'Prepared owner command fields and terminal results are immutable'using errcode='55000';end if;
 return new;
end$$;
revoke all on function private.guard_offline_claim_owner_command()from public,anon,authenticated,service_role;
create trigger guard_offline_claim_owner_command before update or delete on private.offline_claim_owner_commands for each row execute function private.guard_offline_claim_owner_command();

create function private.normalize_offline_claim_command(p_kind text,p_payload jsonb)returns jsonb language plpgsql immutable set search_path=pg_catalog as $$
declare target uuid;reason text;decision text;evidence text;begin
 if p_payload is null or jsonb_typeof(p_payload)<>'object' or length(p_payload::text)>8000 then raise exception 'Exact supported owner command payload required'using errcode='22023';end if;
 if p_kind='decide'then
  if not p_payload?&array['p_claim','p_decision','p_reason']or p_payload-array['p_claim','p_decision','p_reason','p_evidence_type']<>'{}'::jsonb or jsonb_typeof(p_payload->'p_claim')<>'string'or jsonb_typeof(p_payload->'p_decision')<>'string'or jsonb_typeof(p_payload->'p_reason')<>'string'or(p_payload?'p_evidence_type'and jsonb_typeof(p_payload->'p_evidence_type')not in('string','null'))then raise exception 'Exact decision fields required'using errcode='22023';end if;
  begin target:=(p_payload->>'p_claim')::uuid;exception when invalid_text_representation then raise exception 'Actual claim UUID required'using errcode='22023';end;
  decision:=p_payload->>'p_decision';evidence:=p_payload->>'p_evidence_type';reason:=trim(p_payload->>'p_reason');
  if decision not in('approve_with_secret','approve_exception','reject','hold')or length(reason)not between 10 and 500 then raise exception 'Supported explicit decision and reason required'using errcode='22023';end if;
  if decision='approve_exception'and coalesce(evidence,'')not in('in_person_original_service_documents','in_person_independent_continuity_witness')or decision<>'approve_exception'and evidence is not null then raise exception 'Evidence belongs only to explicit independent continuity exceptions'using errcode='22023';end if;
  return jsonb_build_object('p_claim',target,'p_decision',decision,'p_reason',reason,'p_evidence_type',evidence);
 elsif p_kind='revoke'then
  if not p_payload?&array['p_link','p_reason']or p_payload-array['p_link','p_reason']<>'{}'::jsonb or jsonb_typeof(p_payload->'p_link')<>'string'or jsonb_typeof(p_payload->'p_reason')<>'string'then raise exception 'Exact revocation fields required'using errcode='22023';end if;
  begin target:=(p_payload->>'p_link')::uuid;exception when invalid_text_representation then raise exception 'Actual link UUID required'using errcode='22023';end;
  reason:=trim(p_payload->>'p_reason');if length(reason)not between 10 and 500 then raise exception 'Explicit revocation reason required'using errcode='22023';end if;
  return jsonb_build_object('p_link',target,'p_reason',reason);
 end if;
 raise exception 'Supported owner command kind required'using errcode='22023';
end$$;
revoke all on function private.normalize_offline_claim_command(text,jsonb)from public,anon,authenticated,service_role;

-- Internal shared lock/reconciliation. Historical business timestamps remain historical;
-- created_at below describes this new recovery metadata, never the original decision time.
create function private.offline_claim_command_snapshot(p_request uuid)returns jsonb language plpgsql set search_path=pg_catalog as $$
declare c private.offline_claim_owner_commands;d private.offline_claim_decisions;r private.offline_claim_revocations;k text;p jsonb;outcome jsonb;finished timestamptz;begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_request is null then raise exception 'Stable owner command UUID required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Owner commands require READ COMMITTED'using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-owner-command:'||p_request::text,0));
 select * into c from private.offline_claim_owner_commands where request_id=p_request;
 select * into d from private.offline_claim_decisions where request_id=p_request;
 select * into r from private.offline_claim_revocations where request_id=p_request;
 if(c.request_id is not null and c.owner_id<>auth.uid())or(d.request_id is not null and d.owner_id<>auth.uid())or(r.request_id is not null and r.owner_id<>auth.uid())then raise exception 'Owner command unavailable'using errcode='42501';end if;
 if d.request_id is not null and r.request_id is not null then return jsonb_build_object('state','manual_review_required','request_id',p_request,'kind',null,'payload',null,'result',null,'created_at',null,'finished_at',null);end if;
 if d.request_id is not null then
  k:='decide';p:=private.normalize_offline_claim_command(k,jsonb_build_object('p_claim',d.claim_id,'p_decision',d.decision,'p_reason',d.reason,'p_evidence_type',d.evidence_type));outcome:=d.result;finished:=d.created_at;
 elsif r.request_id is not null then
  k:='revoke';p:=private.normalize_offline_claim_command(k,jsonb_build_object('p_link',r.link_id,'p_reason',r.reason));outcome:=jsonb_build_object('link_id',r.link_id,'status','revoked','capabilities',private.offline_claim_flags());finished:=r.created_at;
 end if;
 if k is not null then
  if c.request_id is not null and(c.state='closed'or c.kind<>k or c.payload<>p or(c.state='succeeded'and(c.result<>outcome or c.finished_at<>finished)))then return jsonb_build_object('state','manual_review_required','request_id',p_request,'kind',null,'payload',null,'result',null,'created_at',null,'finished_at',null);end if;
  if c.request_id is null then insert into private.offline_claim_owner_commands(request_id,owner_id,kind,payload,state,result,finished_at)values(p_request,auth.uid(),k,p,'succeeded',outcome,finished)returning * into c;
  elsif c.state='open'then update private.offline_claim_owner_commands set state='succeeded',result=outcome,finished_at=finished where request_id=p_request returning * into c;end if;
 end if;
 if c.request_id is null then return jsonb_build_object('state','absent','request_id',p_request,'kind',null,'payload',null,'result',null,'created_at',null,'finished_at',null,'definitive_failure',false);end if;
 return jsonb_build_object('state',c.state,'request_id',p_request,'kind',c.kind,'payload',c.payload,'result',c.result,'created_at',c.created_at,'finished_at',c.finished_at,'definitive_failure',c.state='closed');
end$$;
revoke all on function private.offline_claim_command_snapshot(uuid)from public,anon,authenticated,service_role;

create function private.prepare_offline_claim_command(p_request uuid,p_kind text,p_payload jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare view jsonb;p jsonb;begin
 view:=private.offline_claim_command_snapshot(p_request);
 if view->>'state'in('closed','manual_review_required')then return view;end if;
 p:=private.normalize_offline_claim_command(p_kind,p_payload);
 if view->>'state'in('open','succeeded')then
  if view->>'kind'<>p_kind or view->'payload'<>p then raise exception 'Owner command kind or payload changed'using errcode='22023';end if;return view;
 end if;
 insert into private.offline_claim_owner_commands(request_id,owner_id,kind,payload,state)values(p_request,auth.uid(),p_kind,p,'open');
 return private.offline_claim_command_snapshot(p_request);
end$$;
create function private.get_offline_customer_claim_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin return private.offline_claim_command_snapshot(p_request);end$$;
create function private.close_offline_claim_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare view jsonb;begin
 view:=private.offline_claim_command_snapshot(p_request);
 if view->>'state'in('closed','succeeded','manual_review_required')then return view;end if;
 if view->>'state'='absent'then insert into private.offline_claim_owner_commands(request_id,owner_id,state,finished_at)values(p_request,auth.uid(),'closed',clock_timestamp());
 else update private.offline_claim_owner_commands set state='closed',finished_at=clock_timestamp()where request_id=p_request;end if;
 return private.offline_claim_command_snapshot(p_request);
end$$;
revoke all on function private.prepare_offline_claim_command(uuid,text,jsonb),private.get_offline_customer_claim_command(uuid),private.close_offline_claim_command(uuid)from public,anon,service_role;
grant execute on function private.prepare_offline_claim_command(uuid,text,jsonb),private.get_offline_customer_claim_command(uuid),private.close_offline_claim_command(uuid)to authenticated;
create function public.prepare_offline_claim_command(p_request uuid,p_kind text,p_payload jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_offline_claim_command(p_request,p_kind,p_payload)$$;
create function public.get_offline_customer_claim_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_offline_customer_claim_command(p_request)$$;
create function public.close_offline_claim_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_offline_claim_command(p_request)$$;
revoke all on function public.prepare_offline_claim_command(uuid,text,jsonb),public.get_offline_customer_claim_command(uuid),public.close_offline_claim_command(uuid)from public,anon,service_role;
grant execute on function public.prepare_offline_claim_command(uuid,text,jsonb),public.get_offline_customer_claim_command(uuid),public.close_offline_claim_command(uuid)to authenticated;

create or replace function private.list_offline_customer_claim_reviews(p_branch uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 return coalesce((select jsonb_agg(v.item order by v.created_at desc)from(select r.created_at,jsonb_build_object('claim_id',r.request_id,'link_id',(select l.link_id from private.offline_customer_trusted_links l where l.claim_id=r.request_id),'claimant_id',r.actor_id,'branch_id',p.created_branch_id,'profile_reference',p.profile_id,'name',p.full_name,'mode',r.mode,'secret_proved',r.secret_proved,'created_at',r.created_at,'expires_at',r.expires_at,'status',case when exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=r.request_id and l.revoked_at is not null)then 'revoked' when exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=r.request_id)then 'approved_pending_reader_bridge' when exists(select 1 from private.offline_claim_decisions d where d.claim_id=r.request_id and d.decision='reject')then 'rejected' when r.expires_at<=clock_timestamp()then 'expired'else 'pending_owner_review'end,'confirmed_account_current',exists(select 1 from auth.users u where u.id=r.actor_id and u.email_confirmed_at=r.email_confirmed_at and u.email_confirmed_at is not null and extensions.digest(lower(trim(u.email)),'sha256')=r.email_hash and u.deleted_at is null and(u.banned_until is null or u.banned_until<clock_timestamp())),'contact_current',private.offline_claim_contact_hash(p.profile_id)=r.contact_hash,'capabilities',private.offline_claim_flags())item
 from private.offline_claim_requests r join private.offline_customer_profiles p on p.profile_id=r.profile_id where r.outcome='pending_owner_review'and(p_branch is null or p.created_branch_id=p_branch)order by r.created_at desc limit 100)v),'[]'::jsonb);
end$$;
create or replace function private.decide_offline_customer_claim(p_request uuid,p_claim uuid,p_decision text,p_reason text,p_evidence_type text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_r private.offline_claim_requests;v_a auth.users;v_prior private.offline_claim_decisions;v_payload jsonb;v_result jsonb;v_link uuid;v_command jsonb;begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_request is null or p_claim is null or p_decision is null or p_decision not in('approve_with_secret','approve_exception','reject','hold')or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Explicit supported decision and review reason required'using errcode='22023';end if;
 if p_decision='approve_exception'and coalesce(p_evidence_type,'')not in('in_person_original_service_documents','in_person_independent_continuity_witness')then raise exception 'Independent in-person continuity evidence required; phone matching is insufficient'using errcode='22023';end if;
 if p_decision<>'approve_exception'and p_evidence_type is not null then raise exception 'Evidence type is only for explicit continuity exception'using errcode='22023';end if;
 perform set_config('lock_timeout','20s',true);
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Claim review requires READ COMMITTED'using errcode='55000';end if;
 v_command:=private.offline_claim_command_snapshot(p_request);
 if v_command->>'state'in('closed','manual_review_required')then raise exception 'Owner command closed or requires manual review'using errcode='55000';end if;
 if v_command->>'state'in('open','succeeded')then
  if v_command->>'kind'<>'decide'or v_command->'payload'<>private.normalize_offline_claim_command('decide',jsonb_build_object('p_claim',p_claim,'p_decision',p_decision,'p_reason',p_reason,'p_evidence_type',p_evidence_type))then raise exception 'Prepared owner command changed'using errcode='22023';end if;
  if v_command->>'state'='succeeded'then return v_command->'result';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-decision:'||p_request::text,0));
 v_payload:=jsonb_build_object('claim',p_claim,'decision',p_decision,'reason',trim(p_reason),'evidence_type',p_evidence_type);
 select * into v_prior from private.offline_claim_decisions where request_id=p_request;
 if found then
  if v_prior.owner_id<>auth.uid()then raise exception 'Review receipt unavailable'using errcode='42501';end if;
  if v_prior.payload<>v_payload then raise exception 'Review request changed'using errcode='22023';end if;return v_prior.result;
 end if;
 select * into v_r from private.offline_claim_requests where request_id=p_claim;
 if not found or v_r.profile_id is null or v_r.outcome<>'pending_owner_review'then raise exception 'Review unavailable'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_r.actor_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_r.profile_id::text,0));
 if exists(select 1 from private.offline_claim_decisions where claim_id=p_claim and decision<>'hold')then raise exception 'Claim already resolved'using errcode='55000';end if;
 if p_decision in('approve_with_secret','approve_exception')then
  -- Block concurrent contact appends until the approval TX commits (no writer bridge yet).
  lock table private.offline_customer_contacts in share mode;
  select * into v_a from auth.users where id=v_r.actor_id for share;
  if v_r.expires_at<=clock_timestamp()or v_a.email_confirmed_at is null or v_a.email_confirmed_at is distinct from v_r.email_confirmed_at or extensions.digest(lower(trim(v_a.email)),'sha256')is distinct from v_r.email_hash or v_a.deleted_at is not null or(v_a.banned_until is not null and v_a.banned_until>clock_timestamp())or not exists(select 1 from public.customers where id=v_r.actor_id)or private.offline_claim_contact_hash(v_r.profile_id)is distinct from v_r.contact_hash then raise exception 'Current confirmed account, consent and contact set required; submit fresh review'using errcode='55000';end if;
  if p_decision='approve_with_secret'and not v_r.secret_proved then raise exception 'Original receipt proof required'using errcode='55000';end if;
  if p_decision='approve_exception'and v_r.mode<>'lost_secret_review'then raise exception 'Explicit lost-secret consent mode required'using errcode='55000';end if;
  if exists(select 1 from private.offline_customer_trusted_links where receipt_id=v_r.receipt_key or(profile_id=v_r.profile_id and revoked_at is null)or(auth_user_id=v_r.actor_id and revoked_at is null))then raise exception 'Conflicting or consumed identity evidence requires owner-assisted review; no automatic transfer'using errcode='55000';end if;
  v_link:=gen_random_uuid();
  insert into private.offline_customer_trusted_links(link_id,profile_id,auth_user_id,claim_id,receipt_id,email_hash,email_confirmed_at,contact_hash,approved_by)values(v_link,v_r.profile_id,v_r.actor_id,p_claim,v_r.receipt_key,v_r.email_hash,v_r.email_confirmed_at,v_r.contact_hash,auth.uid());
 end if;
 v_result:=jsonb_build_object('claim_id',p_claim,'decision',p_decision,'link_id',v_link,'status',case when v_link is not null then 'approved_pending_reader_bridge'else p_decision end,'capabilities',private.offline_claim_flags());
 insert into private.offline_claim_decisions(request_id,claim_id,owner_id,decision,evidence_type,reason,payload,result)values(p_request,p_claim,auth.uid(),p_decision,p_evidence_type,trim(p_reason),v_payload,v_result);
 perform private.offline_claim_command_snapshot(p_request);
 return v_result;
end$$;
create or replace function private.revoke_offline_customer_link(p_request uuid,p_link uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_l private.offline_customer_trusted_links;v_prior private.offline_claim_revocations;v_command jsonb;begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_request is null or p_link is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable revocation request and explicit reason required'using errcode='22023';end if;
 perform set_config('lock_timeout','20s',true);
 v_command:=private.offline_claim_command_snapshot(p_request);
 if v_command->>'state'in('closed','manual_review_required')then raise exception 'Owner command closed or requires manual review'using errcode='55000';end if;
 if v_command->>'state'in('open','succeeded')then
  if v_command->>'kind'<>'revoke'or v_command->'payload'<>private.normalize_offline_claim_command('revoke',jsonb_build_object('p_link',p_link,'p_reason',p_reason))then raise exception 'Prepared owner command changed'using errcode='22023';end if;
  if v_command->>'state'='succeeded'then return v_command->'result';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-revoke:'||p_request::text,0));
 select * into v_prior from private.offline_claim_revocations where request_id=p_request;
 if found then
  if v_prior.owner_id<>auth.uid()or v_prior.link_id<>p_link or v_prior.reason<>trim(p_reason)then raise exception 'Revocation request changed'using errcode='22023';end if;
  return jsonb_build_object('link_id',p_link,'status','revoked','capabilities',private.offline_claim_flags());
 end if;
 select * into v_l from private.offline_customer_trusted_links where link_id=p_link;
 if not found then raise exception 'Link unavailable'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_l.auth_user_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_l.profile_id::text,0));
 update private.offline_customer_trusted_links set revoked_at=coalesce(revoked_at,clock_timestamp())where link_id=p_link and revoked_at is null;
 insert into private.offline_claim_revocations(request_id,link_id,owner_id,reason)values(p_request,p_link,auth.uid(),trim(p_reason));
 perform private.offline_claim_command_snapshot(p_request);
 return jsonb_build_object('link_id',p_link,'status','revoked','capabilities',private.offline_claim_flags());
end$$;
notify pgrst,'reload schema';
commit;
