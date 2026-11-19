begin;
-- Bridge existing canonical proof only. No claim/profile/receipt/link creator.
create table private.visit_recovery_attachment_requests(
 request_id uuid primary key,actor_id uuid not null references public.customers(id),case_id uuid not null references private.visit_recovery_customer_requests(case_id),
 claim_id uuid not null references private.offline_claim_requests(request_id),created_at timestamptz not null default clock_timestamp());
create table private.visit_recovery_canonical_events(
 event_id uuid primary key default gen_random_uuid(),case_id uuid not null references private.visit_recovery_customer_requests(case_id),
 claim_id uuid not null references private.offline_claim_requests(request_id),source_kind text not null check(source_kind in('decision','revocation','attach_existing')),
 source_request_id uuid not null,decision_request_id uuid references private.offline_claim_decisions(request_id),revocation_request_id uuid references private.offline_claim_revocations(request_id),
 link_id uuid references private.offline_customer_trusted_links(link_id),actor_id uuid not null references auth.users(id),
 old_status text not null,new_status text not null check(new_status in('more_info','rejected','linked','revoked')),
 actual_decision_at timestamptz,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(case_id,source_kind,source_request_id));
alter table private.visit_recovery_attachment_requests enable row level security;
alter table private.visit_recovery_canonical_events enable row level security;
revoke all on private.visit_recovery_attachment_requests,private.visit_recovery_canonical_events from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_attachment before update or delete on private.visit_recovery_attachment_requests for each row execute function private.immutable_visit_recovery_submission();
create trigger immutable_visit_recovery_canonical_event before update or delete on private.visit_recovery_canonical_events for each row execute function private.immutable_visit_recovery_submission();

-- Private classification is NEVER returned to the customer before true approval.
-- No Auth registered-phone = legacy contact-phone ownership test exists here.
create function private.visit_recovery_existing_claim_proof(p_claim uuid,p_actor uuid)returns text
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare r private.offline_claim_requests;d private.offline_claim_decisions;l private.offline_customer_trusted_links;begin
 select * into r from private.offline_claim_requests where request_id=p_claim and actor_id=p_actor;
 if not found then raise exception 'Own canonical claim unavailable'using errcode='42501';end if;
 if r.outcome<>'pending_owner_review'or r.profile_id is null then return'pending_shell';end if;
 if not exists(select 1 from private.offline_customer_enrollment_receipts e where e.receipt_id=r.receipt_key and e.profile_id=r.profile_id)
 or not exists(select 1 from auth.users u join public.customers c on c.id=u.id where u.id=p_actor and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())
 and u.email_confirmed_at is not null and u.email_confirmed_at=r.email_confirmed_at and extensions.digest(lower(trim(u.email)),'sha256')=r.email_hash)
 or private.offline_claim_contact_hash(r.profile_id)is distinct from r.contact_hash then return'stale';end if;
 if(r.mode='original_receipt'and not r.secret_proved)or r.mode not in('original_receipt','lost_secret_review')then return'pending_shell';end if;
 select * into d from private.offline_claim_decisions where claim_id=r.request_id and decision<>'hold';
 if found then
 if d.decision='reject'then return'rejected';end if;
 select * into l from private.offline_customer_trusted_links where claim_id=r.request_id;
 if l.link_id is null or l.revoked_at is not null or l.auth_user_id<>p_actor or l.profile_id<>r.profile_id or l.receipt_id<>r.receipt_key or l.approved_by<>d.owner_id
 or l.email_hash is distinct from r.email_hash or l.email_confirmed_at is distinct from r.email_confirmed_at or l.contact_hash is distinct from r.contact_hash
 or d.result->>'link_id'is distinct from l.link_id::text
 or not((d.decision='approve_with_secret'and r.secret_proved)or(d.decision='approve_exception'and r.mode='lost_secret_review'and d.evidence_type in('in_person_original_service_documents','in_person_independent_continuity_witness')))then return'stale';end if;
 return'approved';end if;
 if r.expires_at<=clock_timestamp()then return'stale';end if;
 return'pending';
end$$;
revoke all on function private.visit_recovery_existing_claim_proof(uuid,uuid)from public,anon,authenticated,service_role;

create function private.visit_recovery_case_identity_current(p_case private.visit_recovery_customer_requests)returns boolean
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare address text;confirmed timestamptz;phone text;begin
 select u.email,u.email_confirmed_at,private.offline_phone_key(c.phone,'EG')into address,confirmed,phone
 from auth.users u join public.customers c on c.id=u.id where u.id=p_case.requester_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())for share of u,c;
 return coalesce(found and confirmed is not null and confirmed=p_case.email_confirmed_at and extensions.digest(lower(trim(address)),'sha256')=p_case.email_hash
 and phone is not null and extensions.digest('registered-customer-phone-v1:'||phone,'sha256')=p_case.phone_hash,false);
end$$;
revoke all on function private.visit_recovery_case_identity_current(private.visit_recovery_customer_requests)from public,anon,authenticated,service_role;

create function private.validate_visit_recovery_canonical_event()returns trigger language plpgsql set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;r private.offline_claim_requests;d private.offline_claim_decisions;rev private.offline_claim_revocations;l private.offline_customer_trusted_links;begin
 if new.creator_xid<>txid_current()or new.actor_id is distinct from auth.uid()then raise exception 'Actual current canonical event required'using errcode='55000';end if;
 select * into c from private.visit_recovery_customer_requests where case_id=new.case_id;
 select * into r from private.offline_claim_requests where request_id=new.claim_id and actor_id=c.requester_id;
 if r.request_id is null or not exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id and m.claim_id=r.request_id)or c.status<>new.old_status then raise exception 'Exact mapped case event required'using errcode='55000';end if;
 if new.source_kind in('decision','attach_existing')then
 select * into d from private.offline_claim_decisions where request_id=new.decision_request_id and claim_id=r.request_id;
 if d.request_id is null or new.revocation_request_id is not null or new.actual_decision_at is distinct from d.created_at then raise exception 'Actual decision receipt required'using errcode='55000';end if;
 if new.source_kind='decision'and(new.source_request_id<>d.request_id or d.owner_id<>auth.uid()or private.active_staff_role()is distinct from'owner')then raise exception 'Actual owner decision required'using errcode='42501';end if;
 if new.source_kind='attach_existing'and(new.actor_id<>c.requester_id or not exists(select 1 from private.visit_recovery_attachment_requests a where a.request_id=new.source_request_id and a.actor_id=c.requester_id and a.case_id=c.case_id and a.claim_id=r.request_id))then raise exception 'Explicit own attachment receipt required'using errcode='42501';end if;
 if new.new_status='linked'then
 if d.decision not in('approve_with_secret','approve_exception')then raise exception 'Actual approving decision required'using errcode='55000';end if;
 if c.status not in('awaiting_matching','more_info')or private.visit_recovery_existing_claim_proof(r.request_id,c.requester_id)<>'approved'or not private.visit_recovery_case_identity_current(c)then raise exception 'Current canonical approved link and immutable case identity required'using errcode='55000';end if;
 select * into l from private.offline_customer_trusted_links where claim_id=r.request_id and revoked_at is null;
 if new.link_id is distinct from l.link_id then raise exception 'Exact actual link required'using errcode='55000';end if;
 elsif new.source_kind<>'decision'or c.status not in('awaiting_matching','more_info')or new.link_id is not null
 or not((d.decision='hold'and new.new_status='more_info')or(d.decision='reject'and new.new_status='rejected'))then raise exception 'Canonical nonapproval outcome mismatch'using errcode='55000';end if;
 elsif new.source_kind='revocation'then
 select * into rev from private.offline_claim_revocations where request_id=new.revocation_request_id;
 select * into l from private.offline_customer_trusted_links where link_id=rev.link_id and claim_id=r.request_id;
 if rev.request_id is null or new.decision_request_id is not null or new.source_request_id<>rev.request_id or rev.owner_id<>auth.uid()or private.active_staff_role()is distinct from'owner'
 or l.link_id is null or l.auth_user_id<>c.requester_id or l.profile_id<>r.profile_id or l.receipt_id<>r.receipt_key or l.revoked_at is null
 or new.link_id is distinct from l.link_id or c.status<>'linked'or new.new_status<>'revoked'or new.actual_decision_at is distinct from rev.created_at then raise exception 'Actual linked-case revocation receipt required'using errcode='55000';end if;
 end if;
 return new;
end$$;
revoke all on function private.validate_visit_recovery_canonical_event()from public,anon,authenticated,service_role;
create trigger validate_visit_recovery_canonical_event before insert on private.visit_recovery_canonical_events for each row execute function private.validate_visit_recovery_canonical_event();

create or replace function private.guard_visit_recovery_case_status()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'or(to_jsonb(new)-'status')is distinct from(to_jsonb(old)-'status')or old.status=new.status then raise exception 'Recovery case identity is immutable'using errcode='55000';end if;
 if exists(select 1 from private.visit_recovery_canonical_events e where e.case_id=old.case_id and e.old_status=old.status and e.new_status=new.status and e.actor_id=auth.uid()and e.creator_xid=txid_current())then return new;end if;
 if old.status not in('awaiting_matching','more_info')or new.status not in('more_info','rejected')or exists(select 1 from private.visit_recovery_case_claims m where m.case_id=old.case_id)
 or not exists(select 1 from private.visit_recovery_owner_decisions d where d.case_id=old.case_id and d.owner_id=auth.uid()and d.expected_status=old.status and d.status_after=new.status and d.creator_xid=txid_current())then raise exception 'Actual unmapped or validated canonical witness required'using errcode='55000';end if;
 return new;
end$$;

create function private.emit_visit_recovery_canonical_event(p_case uuid,p_claim uuid,p_kind text,p_source uuid,p_decision uuid,p_revocation uuid,p_link uuid,p_new_status text,p_actual_time timestamptz)
returns void language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;code text;begin
 select * into strict c from private.visit_recovery_customer_requests where case_id=p_case;
 insert into private.visit_recovery_canonical_events(case_id,claim_id,source_kind,source_request_id,decision_request_id,revocation_request_id,link_id,actor_id,old_status,new_status,actual_decision_at,creator_xid)
 values(p_case,p_claim,p_kind,p_source,p_decision,p_revocation,p_link,auth.uid(),c.status,p_new_status,p_actual_time,txid_current());
 if c.status<>p_new_status then update private.visit_recovery_customer_requests set status=p_new_status where case_id=c.case_id;end if;
 code:=case p_new_status when'linked'then'recovery_approved'when'revoked'then'recovery_access_ended'when'more_info'then'recovery_more_info'else'recovery_rejected'end;
 perform private.append_visit_recovery_inbox(p_source,c.case_id,'customer',c.requester_id,code);
end$$;
revoke all on function private.emit_visit_recovery_canonical_event(uuid,uuid,text,uuid,uuid,uuid,uuid,text,timestamptz)from public,anon,authenticated,service_role;

create function private.attach_my_visit_recovery_claim(p_request uuid,p_case uuid,p_claim uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid:=auth.uid();r private.offline_claim_requests;c private.visit_recovery_customer_requests;ident record;prior private.visit_recovery_attachment_requests;
 existing private.visit_recovery_case_claims;proof text;d private.offline_claim_decisions;l private.offline_customer_trusted_links;begin
 if actor is null or p_request is null or p_case is null or p_claim is null then raise exception 'Exact own case and canonical claim required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Attachment requires READ COMMITTED'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-attach:'||p_request::text,0));
 -- Canonical request mutex MUST precede Auth; never call the claim creator here.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-request:'||p_claim::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||actor::text,0));
 select * into r from private.offline_claim_requests where request_id=p_claim and actor_id=actor;
 if not found then raise exception 'Own canonical claim unavailable'using errcode='42501';end if;
 if r.profile_id is not null then
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||r.profile_id::text,0));
 -- Same contact-set freeze/order as canonical approval, before actual Auth row locks.
 lock table private.offline_customer_contacts in share mode;end if;
 select * into strict ident from private.visit_recovery_request_identity();
 select * into c from private.visit_recovery_customer_requests where case_id=p_case and requester_id=actor;
 if not found then raise exception 'Own recovery case unavailable'using errcode='42501';end if;
 select * into prior from private.visit_recovery_attachment_requests where request_id=p_request;
 if found then
 if prior.actor_id<>actor then raise exception 'Own attachment receipt unavailable'using errcode='42501';end if;
 if prior.case_id<>p_case or prior.claim_id<>p_claim then raise exception 'Attachment identity changed'using errcode='22023';end if;
 return private.get_my_visit_recovery_request(c.case_id);end if;
 if c.email_hash is distinct from ident.email_hash or c.email_confirmed_at is distinct from ident.email_confirmed_at or c.phone_hash is distinct from ident.phone_hash then raise exception 'Case identity changed; current independent review required'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||actor::text,0));
 select * into c from private.visit_recovery_customer_requests where case_id=p_case and requester_id=actor for update;
 if c.status not in('awaiting_matching','more_info')then raise exception 'Case no longer accepts attachment'using errcode='55000';end if;
 select * into existing from private.visit_recovery_case_claims where case_id=c.case_id;
 if found and existing.claim_id<>p_claim then raise exception 'Case already bound to a canonical claim'using errcode='55000';end if;
 if exists(select 1 from private.visit_recovery_case_claims m where m.claim_id=p_claim and m.case_id<>c.case_id)then raise exception 'Canonical claim already bound to another case'using errcode='55000';end if;
 proof:=private.visit_recovery_existing_claim_proof(p_claim,actor);
 -- Uniform pending response: unknown receipt shells, stale/rejected/revoked
 -- evidence do not reveal profile existence and never become a real map.
 insert into private.visit_recovery_attachment_requests(request_id,actor_id,case_id,claim_id)values(p_request,actor,c.case_id,p_claim);
 if proof in('pending','approved')then
 insert into private.visit_recovery_case_claims(case_id,claim_id)values(c.case_id,p_claim)on conflict(case_id)do nothing;
 if proof='approved'then
 select * into strict d from private.offline_claim_decisions where claim_id=p_claim and decision in('approve_with_secret','approve_exception');
 select * into strict l from private.offline_customer_trusted_links where claim_id=p_claim and revoked_at is null;
 -- NEW explicit attach event; actual old decision time is retained separately.
 perform private.emit_visit_recovery_canonical_event(c.case_id,p_claim,'attach_existing',p_request,d.request_id,null,l.link_id,'linked',d.created_at);
 end if;end if;
 return private.get_my_visit_recovery_request(c.case_id);
end$$;
revoke all on function private.attach_my_visit_recovery_claim(uuid,uuid,uuid)from public,anon,service_role;
grant execute on function private.attach_my_visit_recovery_claim(uuid,uuid,uuid)to authenticated;
create function public.attach_my_visit_recovery_claim(p_request uuid,p_case uuid,p_claim uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.attach_my_visit_recovery_claim(p_request,p_case,p_claim)$$;
revoke all on function public.attach_my_visit_recovery_claim(uuid,uuid,uuid)from public,anon,service_role;
grant execute on function public.attach_my_visit_recovery_claim(uuid,uuid,uuid)to authenticated;

create function private.visit_recovery_decision_hook()returns trigger language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare c private.visit_recovery_customer_requests;case_ref uuid;status_after text;link_ref uuid;begin
 select case_id into case_ref from private.visit_recovery_case_claims where claim_id=new.claim_id;
 if not found then return new;end if;
 -- Existing direct/prepared canonical writers already hold Auth/profile locks.
 -- Do not acquire a canonical request/owner nonce AFTER those locks.
 perform private.visit_recovery_owner();
 select * into strict c from private.visit_recovery_customer_requests where case_id=case_ref;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||c.requester_id::text,0));
 select * into strict c from private.visit_recovery_customer_requests where case_id=case_ref for update;
 if c.status not in('awaiting_matching','more_info')then raise exception 'Terminal case forbids a later canonical decision'using errcode='55000';end if;
 status_after:=case new.decision when'hold'then'more_info'when'reject'then'rejected'else'linked'end;
 if status_after='linked'then link_ref:=(new.result->>'link_id')::uuid;end if;
 perform private.emit_visit_recovery_canonical_event(c.case_id,new.claim_id,'decision',new.request_id,new.request_id,null,link_ref,status_after,new.created_at);
 return new;
end$$;
create function private.visit_recovery_revocation_hook()returns trigger language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare l private.offline_customer_trusted_links;c private.visit_recovery_customer_requests;case_ref uuid;begin
 select * into strict l from private.offline_customer_trusted_links where link_id=new.link_id;
 select case_id into case_ref from private.visit_recovery_case_claims where claim_id=l.claim_id;
 if not found then return new;end if;
 perform private.visit_recovery_owner();
 select * into strict c from private.visit_recovery_customer_requests where case_id=case_ref;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||c.requester_id::text,0));
 select * into strict c from private.visit_recovery_customer_requests where case_id=case_ref for update;
 -- Revocation remains possible after customer contact/email drift; it grants nothing.
 perform private.emit_visit_recovery_canonical_event(c.case_id,l.claim_id,'revocation',new.request_id,null,new.request_id,l.link_id,'revoked',new.created_at);
 return new;
end$$;
revoke all on function private.visit_recovery_decision_hook(),private.visit_recovery_revocation_hook()from public,anon,authenticated,service_role;
create trigger visit_recovery_after_canonical_decision after insert on private.offline_claim_decisions for each row execute function private.visit_recovery_decision_hook();
create trigger visit_recovery_after_canonical_revocation after insert on private.offline_claim_revocations for each row execute function private.visit_recovery_revocation_hook();

-- Exact owner item base from final APPLIED225809 SHA256 a0a4b10742e1f6e57f3d036b7f877213bc40e1ba654563ab7f439b56c1a517d3.
create or replace function private.visit_recovery_owner_case_item(p_case uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;customer public.customers;current_identity boolean;mapped boolean;begin
 select * into c from private.visit_recovery_customer_requests where case_id=p_case;
 if not found then return null;end if;
 select * into customer from public.customers where id=c.requester_id;
 select exists(select 1 from auth.users u where u.id=c.requester_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())
 and u.email_confirmed_at=c.email_confirmed_at and extensions.digest(lower(trim(u.email)),'sha256')=c.email_hash
 and extensions.digest('registered-customer-phone-v1:'||private.offline_phone_key(customer.phone,'EG'),'sha256')=c.phone_hash)into current_identity;
 select exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id)into mapped;
 return jsonb_build_object('case_id',c.case_id,'status',c.status,'created_at',c.created_at,'identity_current',current_identity,
 'requester_name',customer.full_name,'registered_phone',customer.phone,'canonical_claim_mapped',mapped,'canonical_claim_reference',(select claim_id from private.visit_recovery_case_claims where case_id=c.case_id),
 'canonical_review_required',mapped,
 'more_info_available',not mapped and c.status='awaiting_matching','reject_available',not mapped and c.status in('awaiting_matching','more_info'),'approval_available',false);
end$$;

create or replace function private.visit_recovery_customer_status_snapshot(p_case private.visit_recovery_customer_requests,p_identity_current boolean)
returns jsonb language plpgsql volatile set search_path=pg_catalog as $$
declare value jsonb:=private.visit_recovery_customer_snapshot(p_case,p_identity_current);t jsonb;claim_ref uuid;live_link boolean:=false;begin
 if p_case.status in('more_info','rejected','linked','revoked')then
 t:=private.app_inbox_template(case p_case.status when'more_info'then'recovery_more_info'when'rejected'then'recovery_rejected'when'linked'then'recovery_approved'else'recovery_access_ended'end);
 value:=value||jsonb_build_object('pending_title_ar',t->>'title_ar','pending_title_en',t->>'title_en','pending_text_ar',t->>'body_ar','pending_text_en',t->>'body_en',
 'receipt_message_ar',t->>'body_ar','receipt_message_en',t->>'body_en','status_label_ar',t->>'title_ar','status_label_en',t->>'title_en');end if;
 if p_case.status in('linked','revoked')then
 select claim_id into claim_ref from private.visit_recovery_case_claims where case_id=p_case.case_id;
 if p_case.status='linked'and p_identity_current and claim_ref is not null then live_link:=private.visit_recovery_existing_claim_proof(claim_ref,p_case.requester_id)='approved';end if;
 -- Existing canonical rows were reused, never created by the attachment RPC.
 value:=(value-'canonical_claim_created'-'link_created')||jsonb_build_object('canonical_claim_attached',true,'link_current',coalesce(live_link,false),'record_access_requires_fresh_history_scope',true);
 end if;
 return value;
end$$;
notify pgrst,'reload schema';
commit;
