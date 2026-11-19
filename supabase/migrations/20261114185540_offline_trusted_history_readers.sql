begin;
-- Source-only, acceptance-disabled. No ownership or invoice authorization rewrite.
create table private.offline_history_runtime(id boolean primary key default true check(id),enabled boolean not null default false);
insert into private.offline_history_runtime(id,enabled)values(true,false);
create table private.offline_history_scope_consents(
 request_id uuid primary key,link_id uuid not null references private.offline_customer_trusted_links(link_id),
 actor_id uuid not null references auth.users(id),version text not null check(version='offline-history-v1'),
 consent jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.offline_history_runtime enable row level security;
alter table private.offline_history_scope_consents enable row level security;
revoke all on private.offline_history_runtime,private.offline_history_scope_consents from public,anon,authenticated,service_role;
create trigger immutable_offline_history_consent before update or delete on private.offline_history_scope_consents for each row execute function private.immutable_loyalty_policy();

create function private.offline_history_notice(p_language text)returns text language sql immutable set search_path=pg_catalog as $$select case p_language
when 'en'then 'I agree to view past and future reception visits, car records and invoices associated with my owner-reviewed receipt in this app account. This does not transfer car ownership or grant rewards. Access ends if the link is revoked or identity evidence changes.'
when 'ar'then 'أوافق على عرض زيارات الاستقبال السابقة والمستقبلية وسجلات السيارات والفواتير المرتبطة بإيصالي الذي راجعه المالك في حساب التطبيق هذا. لا ينقل ذلك ملكية السيارة ولا يمنح مكافآت. ينتهي الوصول عند إلغاء الربط أو تغير إثبات الهوية.'end$$;
create function private.offline_history_capabilities(p_available boolean)returns jsonb language sql stable set search_path=pg_catalog as $$select jsonb_build_object(
'linked_visit_history',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'linked_invoice_documents',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'offline_car_reference_read',p_available and coalesce((select enabled from private.offline_history_runtime where id),false),
'wallet_access',false,'walk_in_loyalty_accrual',false,'guest_redemption',false,'vehicle_management',false,'qr_reader_bridge',false)$$;

create function private.resolve_my_offline_history_link()returns private.offline_customer_trusted_links
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_actor uuid:=auth.uid();v_session uuid;v_link private.offline_customer_trusted_links;v_auth auth.users;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'History requires READ COMMITTED'using errcode='55000';end if;
 if v_actor is null then raise exception 'History unavailable'using errcode='42501';end if;
 begin v_session:=(auth.jwt()->>'session_id')::uuid;exception when invalid_text_representation then raise exception 'History unavailable'using errcode='42501';end;
 if v_session is null then raise exception 'History unavailable'using errcode='42501';end if;
 -- Same order as approval/revocation; no table-wide contact lock.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_actor::text,0));
 select * into v_link from private.offline_customer_trusted_links where auth_user_id=v_actor and revoked_at is null;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_link.profile_id::text,0));
 select * into v_link from private.offline_customer_trusted_links where link_id=v_link.link_id and auth_user_id=v_actor and revoked_at is null for share;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_auth from auth.users where id=v_actor for share;
 if not found or v_auth.email_confirmed_at is null or v_auth.email is null or v_auth.deleted_at is not null
 or(v_auth.banned_until is not null and v_auth.banned_until>clock_timestamp())
 or v_auth.email_confirmed_at is distinct from v_link.email_confirmed_at
 or extensions.digest(lower(trim(v_auth.email)),'sha256')is distinct from v_link.email_hash then raise exception 'History unavailable'using errcode='42501';end if;
 perform 1 from auth.sessions s where s.id=v_session and s.user_id=v_actor and(s.not_after is null or s.not_after>clock_timestamp())for share;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 perform 1 from public.customers c where c.id=v_actor for share;
 if not found or private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash
 or not exists(select 1 from private.offline_claim_requests r join private.offline_claim_decisions d on d.claim_id=r.request_id
 where r.request_id=v_link.claim_id and r.actor_id=v_actor and r.profile_id=v_link.profile_id and r.receipt_key=v_link.receipt_id
 and r.outcome='pending_owner_review'and r.email_hash=v_link.email_hash and r.email_confirmed_at=v_link.email_confirmed_at
 and r.contact_hash=v_link.contact_hash and d.owner_id=v_link.approved_by and d.result->>'link_id'=v_link.link_id::text
 and(d.decision='approve_with_secret'and r.secret_proved or d.decision='approve_exception'and r.mode='lost_secret_review'
 and d.evidence_type in('in_person_original_service_documents','in_person_independent_continuity_witness')))
 then raise exception 'History unavailable'using errcode='42501';end if;
 return v_link;
end$$;

create function private.accept_my_offline_history_scope(p_request uuid,p_consent jsonb)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_prior private.offline_history_scope_consents;v_language text;
begin
 v_link:=private.resolve_my_offline_history_link();
 if p_request is null or jsonb_typeof(p_consent)<>'object' or p_consent-array['accepted','version','language','text']<>'{}'::jsonb
 or not(p_consent @> '{"accepted":true,"version":"offline-history-v1"}')then raise exception 'Explicit history scope consent required'using errcode='22023';end if;
 v_language:=p_consent->>'language';
 if v_language is null or v_language not in('ar','en')or p_consent->>'text'is distinct from private.offline_history_notice(v_language)then raise exception 'Actual fixed history notice required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-history-consent:'||p_request::text,0));
 select * into v_prior from private.offline_history_scope_consents where request_id=p_request;
 if found then
 if v_prior.actor_id<>auth.uid()then raise exception 'History unavailable'using errcode='42501';end if;
 if v_prior.link_id<>v_link.link_id or v_prior.consent<>p_consent then raise exception 'Consent request changed'using errcode='22023';end if;
 else
 insert into private.offline_history_scope_consents(request_id,link_id,actor_id,version,consent)
 values(p_request,v_link.link_id,auth.uid(),'offline-history-v1',p_consent)returning * into v_prior;
 end if;
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','consent_recorded','request_id',v_prior.request_id,'version',v_prior.version,'capabilities',private.offline_history_capabilities(true));
end$$;

create function private.get_my_offline_history_context()returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_consented boolean;v_enabled boolean;v_cars jsonb;
begin
 begin v_link:=private.resolve_my_offline_history_link();exception when insufficient_privilege then return jsonb_build_object('state','review_required','cars','[]'::jsonb,'capabilities',private.offline_history_capabilities(false));end;
 select exists(select 1 from private.offline_history_scope_consents c where c.link_id=v_link.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')into v_consented;
 select enabled into v_enabled from private.offline_history_runtime where id;
 if v_consented and coalesce(v_enabled,false)then
 select coalesce(jsonb_agg(jsonb_build_object('car_reference',c.car_ref_id,'plate_number',c.car_snapshot->'plate_number','brand',c.car_snapshot->'brand','model',c.car_snapshot->'model','year',c.car_snapshot->'year','color',c.car_snapshot->'color','record_kind','reception_reference')order by c.created_at,c.car_ref_id),'[]'::jsonb)
 into v_cars from private.offline_customer_car_refs c where c.profile_id=v_link.profile_id;
 end if;
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('state',case when not v_consented then 'consent_required'when not coalesce(v_enabled,false)then 'acceptance_pending'else 'available'end,
 'consent',jsonb_build_object('version','offline-history-v1','recorded',v_consented,'notice_ar',private.offline_history_notice('ar'),'notice_en',private.offline_history_notice('en')),
 'cars',coalesce(v_cars,'[]'::jsonb),'history_scope','past_and_future_typed_reception_records','capabilities',private.offline_history_capabilities(v_consented));
end$$;

create function private.offline_history_payment_status(p_invoice text)returns text language sql stable set search_path=pg_catalog as $$
select case when i.status='void'then 'cancelled'when i.status='refunded'then 'refunded'
when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale'and e.method='cash')then 'paid'
when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale'and e.method='electronic')then 'verification_required'else 'unpaid'end
from public.business_invoices i where i.invoice_id=p_invoice$$;

create function private.get_my_offline_visit_history(p_before_created_at timestamptz default null,p_before_order uuid default null,p_limit integer default 25)returns jsonb
language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_items jsonb;v_last jsonb;v_more boolean;
begin
 v_link:=private.resolve_my_offline_history_link();
 if p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_order is null)then raise exception 'Valid bounded cursor required'using errcode='22023';end if;
 if not coalesce((select enabled from private.offline_history_runtime where id),false)or not exists(select 1 from private.offline_history_scope_consents c where c.link_id=v_link.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')then raise exception 'History unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(q.item order by q.created_at desc,q.order_id desc),'[]'::jsonb)into v_items from(
 select s.created_at,s.order_id,jsonb_build_object('source_kind','offline_walk_in','order_id',s.order_id,'invoice_id',s.invoice_id,
 'work_reference',i.display_number,'invoice_number',i.display_number,'branch',jsonb_build_object('name_ar',i.document_snapshot#>'{branch,name_ar}','name_en',i.document_snapshot#>'{branch,name_en}'),
 'service_name',i.service_name,'created_at',s.created_at,'arrived_at',r.arrived_at,'service_status',o.status,
 'car',jsonb_build_object('plate_number',c.car_snapshot->'plate_number','brand',c.car_snapshot->'brand','model',c.car_snapshot->'model','year',c.car_snapshot->'year','color',c.car_snapshot->'color'),
 'gross_amount',s.gross,'invoice_total',i.total,'invoice_discount',i.discount,'currency','EGP','payment_status',private.offline_history_payment_status(i.invoice_id),
 'collectible_amount',case when i.status<>'active'or private.offline_history_payment_status(i.invoice_id)in('paid','verification_required')then 0 else i.total end,'loyalty_earning_supported',false) item
 from private.offline_walk_in_subjects s join public.business_orders o on o.order_id=s.order_id and o.branch_id=s.branch_id and o.customer_id is null and o.booking_id is null
 join public.business_invoices i on i.invoice_id=s.invoice_id and i.order_id=s.order_id and i.branch_id=s.branch_id and i.commission_model='walk_in_frozen_workers'
 join private.offline_customer_car_refs c on c.car_ref_id=s.car_ref_id and c.profile_id=s.profile_id
 left join private.offline_walk_in_reception r on r.order_id=s.order_id
 where s.profile_id=v_link.profile_id and(p_before_created_at is null or(s.created_at,s.order_id)<(p_before_created_at,p_before_order))
 order by s.created_at desc,s.order_id desc limit p_limit+1)q;
 v_more:=jsonb_array_length(v_items)>p_limit;
 if v_more then v_items:=v_items-(jsonb_array_length(v_items)-1);end if;
 v_last:=v_items->(jsonb_array_length(v_items)-1);
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','available','items',v_items,'next_cursor',case when v_more then jsonb_build_object('created_at',v_last->'created_at','order_id',v_last->'order_id')else null end,'capabilities',private.offline_history_capabilities(true));
end$$;

create function private.get_my_offline_invoice_document(p_invoice text)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_link private.offline_customer_trusted_links;v_invoice public.business_invoices;v_subject private.offline_walk_in_subjects;v_order public.business_orders;v_snapshot jsonb;v_lines jsonb;v_payment text;
begin
 v_link:=private.resolve_my_offline_history_link();
 if not coalesce((select enabled from private.offline_history_runtime where id),false)or not exists(select 1 from private.offline_history_scope_consents c where c.link_id=v_link.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_subject from private.offline_walk_in_subjects s where s.invoice_id=p_invoice and s.profile_id=v_link.profile_id;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_invoice from public.business_invoices i where i.invoice_id=v_subject.invoice_id and i.order_id=v_subject.order_id and i.branch_id=v_subject.branch_id and i.commission_model='walk_in_frozen_workers'and i.document_link_enabled;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select * into v_order from public.business_orders o where o.order_id=v_subject.order_id and o.branch_id=v_subject.branch_id and o.customer_id is null and o.booking_id is null;
 if not found then raise exception 'History unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',x.value->'name','quantity',x.value->'quantity','unit_price',x.value->'unit_price','subtotal',x.value->'subtotal')order by x.ordinality),'[]'::jsonb)
 into v_lines from jsonb_array_elements(v_invoice.document_snapshot->'lines')with ordinality x(value,ordinality);
 v_snapshot:=jsonb_build_object('branch',jsonb_build_object('name_ar',v_invoice.document_snapshot#>'{branch,name_ar}','name_en',v_invoice.document_snapshot#>'{branch,name_en}','address_ar',v_invoice.document_snapshot#>'{branch,address_ar}','address_en',v_invoice.document_snapshot#>'{branch,address_en}'),
 'lines',v_lines,'currency','EGP','discount',v_invoice.document_snapshot->'discount','total',v_invoice.document_snapshot->'total','tax_amount',v_invoice.document_snapshot->'tax_amount','tax_configuration',v_invoice.document_snapshot->'tax_configuration','delivery_fee',v_invoice.document_snapshot->'delivery_fee');
 v_payment:=private.offline_history_payment_status(v_invoice.invoice_id);
 if private.offline_claim_contact_hash(v_link.profile_id)is distinct from v_link.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('schema_version','offline-customer-invoice-v1','source_kind','offline_walk_in','invoice_id',v_invoice.invoice_id,'order_id',v_subject.order_id,'invoice_number',v_invoice.display_number,'issued_at',v_invoice.issued_at,
 'issued_at_cairo',to_char(v_invoice.issued_at at time zone 'Africa/Cairo','YYYY-MM-DD"T"HH24:MI:SS'),'snapshot',v_snapshot,
 'invoice_total',v_invoice.total,'invoice_discount',v_invoice.discount,'payment_status',v_payment,'payment_method',v_invoice.payment_method,'service_status',v_order.status,
 'document_token',v_invoice.document_token,'portal_origin',v_invoice.document_origin,'qr_reader_bridge',false,'capabilities',private.offline_history_capabilities(true));
end$$;

revoke all on function private.offline_history_notice(text),private.offline_history_capabilities(boolean),private.resolve_my_offline_history_link(),private.offline_history_payment_status(text)from public,anon,authenticated,service_role;
create function public.accept_my_offline_history_scope(p_request uuid,p_consent jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.accept_my_offline_history_scope(p_request,p_consent)$$;
create function public.get_my_offline_history_context()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_history_context()$$;
create function public.get_my_offline_visit_history(p_before_created_at timestamptz default null,p_before_order uuid default null,p_limit integer default 25)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_visit_history(p_before_created_at,p_before_order,p_limit)$$;
create function public.get_my_offline_invoice_document(p_invoice text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_invoice_document(p_invoice)$$;
revoke all on function private.accept_my_offline_history_scope(uuid,jsonb),private.get_my_offline_history_context(),private.get_my_offline_visit_history(timestamptz,uuid,integer),private.get_my_offline_invoice_document(text),public.accept_my_offline_history_scope(uuid,jsonb),public.get_my_offline_history_context(),public.get_my_offline_visit_history(timestamptz,uuid,integer),public.get_my_offline_invoice_document(text)from public,anon,authenticated,service_role;
grant execute on function private.accept_my_offline_history_scope(uuid,jsonb),private.get_my_offline_history_context(),private.get_my_offline_visit_history(timestamptz,uuid,integer),private.get_my_offline_invoice_document(text),public.accept_my_offline_history_scope(uuid,jsonb),public.get_my_offline_history_context(),public.get_my_offline_visit_history(timestamptz,uuid,integer),public.get_my_offline_invoice_document(text)to authenticated;
commit;
