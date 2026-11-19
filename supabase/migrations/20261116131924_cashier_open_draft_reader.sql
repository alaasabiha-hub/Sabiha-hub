begin;
create function private.list_cashier_open_drafts(p_branch uuid,p_before_time timestamptz default null,p_before_id uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;rows jsonb;more boolean;
begin
 actor:=private.cashier_cart_actor(p_branch);
 if(p_before_time is null)<>(p_before_id is null)then raise exception 'Complete cursor required'using errcode='22023';end if;
 with candidates as(select d.*,b.subject_snapshot,p.invoice_id,i.display_number,i.status invoice_status from private.cashier_reviewed_drafts d
 left join private.cashier_draft_subjects b on b.draft_id=d.draft_id and b.actor_id=actor
 left join private.cashier_invoice_postings p on p.draft_id=d.draft_id
 left join public.business_invoices i on i.invoice_id=p.invoice_id
 where d.actor_id=actor and d.branch_id=p_branch and(p_before_time is null or(d.updated_at,d.draft_id)<(p_before_time,p_before_id))
 order by d.updated_at desc,d.draft_id desc limit 51),page as(select *from candidates order by updated_at desc,draft_id desc limit 50)
 select coalesce((select jsonb_agg(jsonb_build_object('draft_id',draft_id,'version',version,'updated_at',updated_at,'customer_name',subject_snapshot->>'name','car',subject_snapshot->'car','total',quote->'total','currency','EGP','line_count',jsonb_array_length(payload->'items'),'state',case when invoice_id is null then'open'else'issued'end,'invoice_number',display_number,'invoice_status',invoice_status,'requires_server_review',invoice_id is null)order by updated_at desc,draft_id desc)from page),'[]'),(select count(*)>50 from candidates)into rows,more;
 return jsonb_build_object('drafts',rows,'has_more',more,'scope','own_cashier_branch','payment_status_requires_checkout',true,'loyalty_authorized',false);
end$$;
create function public.list_cashier_open_drafts(p_branch uuid,p_before_time timestamptz default null,p_before_id uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_cashier_open_drafts(p_branch,p_before_time,p_before_id)$$;
revoke all on function private.list_cashier_open_drafts(uuid,timestamptz,uuid),public.list_cashier_open_drafts(uuid,timestamptz,uuid)from public,anon,authenticated,service_role;
grant execute on function private.list_cashier_open_drafts(uuid,timestamptz,uuid),public.list_cashier_open_drafts(uuid,timestamptz,uuid)to authenticated;
commit;
