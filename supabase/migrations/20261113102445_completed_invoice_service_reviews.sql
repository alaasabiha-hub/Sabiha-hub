-- Overall service review complements (does not replace) per-employee reviews.
create table public.completed_service_reviews(
 review_id uuid primary key default gen_random_uuid(),invoice_id text not null references public.business_invoices(invoice_id),booking_id uuid not null references public.bookings(id),
 customer_id uuid not null references public.customers(id),branch_id uuid not null references public.business_branches(branch_id),
 stars integer not null check(stars between 1 and 5),comment text not null default '' check(length(comment)<=1000),
 comment_published boolean not null default false,moderation_reason text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(booking_id,customer_id));
create index completed_service_reviews_branch_idx on public.completed_service_reviews(branch_id,created_at desc);
alter table public.completed_service_reviews enable row level security;
revoke all on public.completed_service_reviews from anon,authenticated;
grant select on public.completed_service_reviews to authenticated;
grant all on public.completed_service_reviews to service_role;
create policy "Own or owner service review reads" on public.completed_service_reviews for select to authenticated using(customer_id=(select auth.uid()) or (select private.active_staff_role())='owner');
create function private.invoice_review_context(p_token uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare doc jsonb;b public.bookings%rowtype;r public.completed_service_reviews%rowtype;begin
 doc:=private.resolve_invoice_document(p_token);
 select * into b from public.bookings where id=(doc->>'booking_id')::uuid and customer_id=auth.uid() and status='completed';
 if not found or doc->>'payment_status'='cancelled' then return jsonb_build_object('can_review',false);end if;
 select * into r from public.completed_service_reviews where booking_id=b.id and customer_id=auth.uid();
 return jsonb_build_object('can_review',true,'booking_id',b.id,'stars',r.stars,'comment',r.comment,'editable',r.review_id is null or r.created_at>=now()-interval '7 days','employees',public.review_targets(b.id));
end; $$;
create function private.save_invoice_service_review(p_token uuid,p_stars integer,p_comment text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare context jsonb;r public.completed_service_reviews%rowtype;v_id uuid;v_invoice text;v_booking uuid;v_branch uuid;begin
 context:=private.invoice_review_context(p_token);
 if coalesce((context->>'can_review')::boolean,false) is not true then raise exception 'Only the customer of a completed invoiced service can review';end if;
 if p_stars is null or p_stars not between 1 and 5 or length(coalesce(p_comment,''))>1000 then raise exception 'Invalid review';end if;
 v_booking:=(context->>'booking_id')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('overall_review:'||v_booking::text||auth.uid()::text,0));
 select * into r from public.completed_service_reviews where booking_id=v_booking and customer_id=auth.uid();
 if found and r.created_at<now()-interval '7 days' then raise exception 'Reviews can be edited for seven days';end if;
 select invoice_id,branch_id into strict v_invoice,v_branch from public.business_invoices where document_token=p_token and document_link_enabled;
 insert into public.completed_service_reviews(invoice_id,booking_id,customer_id,branch_id,stars,comment) values(v_invoice,v_booking,auth.uid(),v_branch,p_stars,trim(coalesce(p_comment,'')))
 on conflict(booking_id,customer_id) do update set stars=excluded.stars,comment=excluded.comment,comment_published=false,moderation_reason=null,updated_at=now() returning review_id into v_id;
 return v_id;end; $$;
create function private.moderate_invoice_service_review(p_review uuid,p_publish boolean,p_reason text) returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is distinct from 'owner' or p_publish is null or length(trim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Owner and moderation reason required';end if;
 update public.completed_service_reviews set comment_published=p_publish,moderation_reason=trim(p_reason) where review_id=p_review;if not found then raise exception 'Review unavailable';end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,reason,after_data) values(auth.uid()::text,auth.uid(),'moderate_service_comment','completed_service_reviews',p_review::text,trim(p_reason),jsonb_build_object('published',p_publish));
end; $$;

revoke all on function private.invoice_review_context(uuid) from public,anon;grant execute on function private.invoice_review_context(uuid) to authenticated;
create function public.invoice_review_context(p_token uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.invoice_review_context(p_token); $$;
revoke all on function public.invoice_review_context(uuid) from public,anon;grant execute on function public.invoice_review_context(uuid) to authenticated;

revoke all on function private.save_invoice_service_review(uuid,integer,text) from public,anon;grant execute on function private.save_invoice_service_review(uuid,integer,text) to authenticated;
create function public.save_invoice_service_review(p_token uuid,p_stars integer,p_comment text default '') returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.save_invoice_service_review(p_token,p_stars,p_comment); $$;
revoke all on function public.save_invoice_service_review(uuid,integer,text) from public,anon;grant execute on function public.save_invoice_service_review(uuid,integer,text) to authenticated;

revoke all on function private.moderate_invoice_service_review(uuid,boolean,text) from public,anon;grant execute on function private.moderate_invoice_service_review(uuid,boolean,text) to authenticated;
create function public.moderate_invoice_service_review(p_review uuid,p_publish boolean,p_reason text) returns void language sql security invoker set search_path=pg_catalog as $$ select private.moderate_invoice_service_review(p_review,p_publish,p_reason); $$;
revoke all on function public.moderate_invoice_service_review(uuid,boolean,text) from public,anon;grant execute on function public.moderate_invoice_service_review(uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
