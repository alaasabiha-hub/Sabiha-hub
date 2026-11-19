begin;
create table private.cashier_draft_cancellations(request_id uuid primary key,draft_id uuid not null unique references private.cashier_reviewed_drafts(draft_id),actor_id uuid not null references auth.users(id),branch_id uuid not null references public.business_branches(branch_id),draft_version integer not null,reason text not null,created_at timestamptz not null default clock_timestamp());
alter table private.cashier_draft_cancellations enable row level security;
revoke all on private.cashier_draft_cancellations from public,anon,authenticated,service_role;
create trigger immutable_draft_cancellation before update or delete on private.cashier_draft_cancellations for each row execute function private.immutable_loyalty_policy();
create function private.cancel_cashier_draft(p_request uuid,p_branch uuid,p_draft uuid,p_version integer,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;d private.cashier_reviewed_drafts;prior private.cashier_draft_cancellations;
begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_version is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Exact draft version and reason required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('draft-cancel:'||p_request,0));
 select *into prior from private.cashier_draft_cancellations where request_id=p_request;
 if found then
 if prior.actor_id<>actor or prior.branch_id<>p_branch then raise exception 'Cancellation unavailable'using errcode='42501';end if;
 if prior.draft_id<>p_draft or prior.draft_version<>p_version or prior.reason<>trim(p_reason)then raise exception 'Immutable cancellation request'using errcode='22023';end if;
 return jsonb_build_object('draft_id',p_draft,'state','cancelled','financial_operation',false);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Own branch draft required'using errcode='42501';end if;
 if d.version<>p_version then raise exception 'Draft version changed'using errcode='40001';end if;
 if exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then raise exception 'Issued invoice requires its canonical cancellation/refund route'using errcode='55000';end if;
 if exists(select 1 from private.cashier_draft_cancellations where draft_id=p_draft)then raise exception 'Draft already cancelled'using errcode='40001';end if;
 perform private.cashier_cart_actor(p_branch);
 insert into private.cashier_draft_cancellations values(p_request,p_draft,actor,p_branch,p_version,trim(p_reason),clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'cashier_draft_cancelled','cashier_reviewed_draft',p_draft::text,p_branch,jsonb_build_object('version',p_version,'reason',trim(p_reason),'request_id',p_request));
 return jsonb_build_object('draft_id',p_draft,'state','cancelled','financial_operation',false);
end$$;
create function private.guard_cancelled_cashier_draft()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if exists(select 1 from private.cashier_draft_cancellations where draft_id=case when tg_op='INSERT'then new.draft_id else old.draft_id end)then raise exception 'Cancelled draft is sealed'using errcode='55000';end if;
 if tg_op='DELETE'then return old;end if;return new;
end$$;
create trigger stop_cancelled_draft before update or delete on private.cashier_reviewed_drafts for each row execute function private.guard_cancelled_cashier_draft();
create trigger stop_cancelled_subject before insert or update or delete on private.cashier_draft_subjects for each row execute function private.guard_cancelled_cashier_draft();
create trigger stop_cancelled_issue before insert on private.cashier_invoice_postings for each row execute function private.guard_cancelled_cashier_draft();
create function public.cancel_cashier_draft(p_request uuid,p_branch uuid,p_draft uuid,p_version integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.cancel_cashier_draft(p_request,p_branch,p_draft,p_version,p_reason)$$;
revoke all on function private.cancel_cashier_draft(uuid,uuid,uuid,integer,text),public.cancel_cashier_draft(uuid,uuid,uuid,integer,text),private.guard_cancelled_cashier_draft()from public,anon,authenticated,service_role;
grant execute on function private.cancel_cashier_draft(uuid,uuid,uuid,integer,text),public.cancel_cashier_draft(uuid,uuid,uuid,integer,text)to authenticated;
create or replace function private.list_cashier_open_drafts(p_branch uuid,p_before_time timestamptz default null,p_before_id uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;rows jsonb;more boolean;
begin
 actor:=private.cashier_cart_actor(p_branch);
 if(p_before_time is null)<>(p_before_id is null)then raise exception 'Complete cursor required'using errcode='22023';end if;
 with candidates as(select d.*,b.subject_snapshot,p.invoice_id,i.display_number,i.status invoice_status from private.cashier_reviewed_drafts d
 left join private.cashier_draft_subjects b on b.draft_id=d.draft_id and b.actor_id=actor
 left join private.cashier_invoice_postings p on p.draft_id=d.draft_id
 left join public.business_invoices i on i.invoice_id=p.invoice_id
 where d.actor_id=actor and d.branch_id=p_branch and not exists(select 1 from private.cashier_draft_cancellations x where x.draft_id=d.draft_id) and(p_before_time is null or(d.updated_at,d.draft_id)<(p_before_time,p_before_id))
 order by d.updated_at desc,d.draft_id desc limit 51),page as(select *from candidates order by updated_at desc,draft_id desc limit 50)
 select coalesce((select jsonb_agg(jsonb_build_object('draft_id',draft_id,'version',version,'updated_at',updated_at,'customer_name',subject_snapshot->>'name','car',subject_snapshot->'car','total',quote->'total','currency','EGP','line_count',jsonb_array_length(payload->'items'),'state',case when invoice_id is null then'open'else'issued'end,'invoice_number',display_number,'invoice_status',invoice_status,'requires_server_review',invoice_id is null)order by updated_at desc,draft_id desc)from page),'[]'),(select count(*)>50 from candidates)into rows,more;
 return jsonb_build_object('drafts',rows,'has_more',more,'scope','own_cashier_branch','payment_status_requires_checkout',true,'loyalty_authorized',false);
end$$;
create or replace function private.get_cashier_reviewed_draft(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;d private.cashier_reviewed_drafts;begin
 actor:=private.cashier_cart_actor(p_branch);
 select *into d from private.cashier_reviewed_drafts d0 where not exists(select 1 from private.cashier_draft_cancellations x where x.draft_id=d0.draft_id) and actor_id=actor and branch_id=p_branch and(p_draft is null or draft_id=p_draft)order by updated_at desc,draft_id desc limit 1;
 if not found then return jsonb_build_object('state','absent');end if;
 return jsonb_build_object('state','draft','draft_id',d.draft_id,'version',d.version,'payload',d.payload,'quote',d.quote,'updated_at',d.updated_at,'quote_only',true,'can_issue',false);
end$$;
commit;
