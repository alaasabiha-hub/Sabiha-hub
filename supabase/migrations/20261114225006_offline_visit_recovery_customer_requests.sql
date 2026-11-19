begin;
-- Request envelope only. No candidate lookup, canonical claim/link or approval path.
create function private.visit_recovery_request_notice(p_language text)returns text
language sql immutable set search_path=pg_catalog as $$select case p_language
 when 'ar'then 'أطلب مراجعة زياراتي السابقة باستخدام بيانات حسابي المسجلة الحالية. هذا الطلب لا يربط أي سجلات تلقائياً ولا يمنح مكافآت أو صلاحيات عرض.'
 when 'en'then 'I request review of my previous visits using my current registered account details. This request does not automatically link records or grant rewards or record access.'end$$;
revoke all on function private.visit_recovery_request_notice(text)from public,anon,authenticated,service_role;

create table private.visit_recovery_customer_requests(
 case_id uuid primary key default gen_random_uuid(),requester_id uuid not null references public.customers(id),
 status text not null default 'awaiting_matching'check(status='awaiting_matching'),
 email_hash bytea not null check(octet_length(email_hash)=32),email_confirmed_at timestamptz not null,
 phone_hash bytea not null check(octet_length(phone_hash)=32),consent jsonb not null,
 submission_event_id uuid not null unique default gen_random_uuid(),created_at timestamptz not null default clock_timestamp());
create unique index one_open_visit_recovery_request on private.visit_recovery_customer_requests(requester_id)where status='awaiting_matching';
create table private.visit_recovery_submission_requests(
 request_id uuid primary key,actor_id uuid not null references public.customers(id),payload jsonb not null,
 case_id uuid not null references private.visit_recovery_customer_requests(case_id),created_at timestamptz not null default clock_timestamp());
alter table private.visit_recovery_customer_requests enable row level security;
alter table private.visit_recovery_submission_requests enable row level security;
revoke all on private.visit_recovery_customer_requests,private.visit_recovery_submission_requests from public,anon,authenticated,service_role;
create function private.immutable_visit_recovery_submission()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 raise exception 'Recovery submission identity and receipts are retained'using errcode='55000';end$$;
revoke all on function private.immutable_visit_recovery_submission()from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_request before update or delete on private.visit_recovery_customer_requests for each row execute function private.immutable_visit_recovery_submission();
create trigger immutable_visit_recovery_submission before update or delete on private.visit_recovery_submission_requests for each row execute function private.immutable_visit_recovery_submission();

create function private.visit_recovery_request_identity()
returns table(actor_id uuid,email_hash bytea,email_confirmed_at timestamptz,phone_hash bytea)
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare address text;confirmed timestamptz;registered_phone text;begin
 -- Reuses the applied inbox actual-session/Auth/staff-role locks; never JWT metadata.
 actor_id:=private.app_inbox_actor();
 select u.email,u.email_confirmed_at,private.offline_phone_key(c.phone,'EG')into address,confirmed,registered_phone
 from auth.users u join public.customers c on c.id=u.id where u.id=actor_id for share of c;
 if not found or confirmed is null or nullif(trim(address),'')is null or registered_phone is null then
 raise exception 'Confirmed current registered customer details required'using errcode='42501';end if;
 email_hash:=extensions.digest(lower(trim(address)),'sha256');email_confirmed_at:=confirmed;
 phone_hash:=extensions.digest('registered-customer-phone-v1:'||registered_phone,'sha256');return next;
end$$;
revoke all on function private.visit_recovery_request_identity()from public,anon,authenticated,service_role;

create function private.visit_recovery_customer_snapshot(p_case private.visit_recovery_customer_requests,p_identity_current boolean)
returns jsonb language plpgsql stable set search_path=pg_catalog as $$
declare t jsonb:=private.app_inbox_template('recovery_received');begin
 return jsonb_build_object('state','available','case',jsonb_build_object('case_id',p_case.case_id,'status',p_case.status,'created_at',p_case.created_at,'identity_current',p_identity_current),
 'pending_title_ar',t->>'title_ar','pending_title_en',t->>'title_en','pending_text_ar',t->>'body_ar','pending_text_en',t->>'body_en',
 'receipt_message_ar','تم استلام طلبك بنجاح. طلبك قيد المراجعة، وفي انتظار مطابقة معلوماتك مع سجلات زياراتك السابقة',
 'receipt_message_en','Your request has been received successfully. It is under review and waiting for your information to be matched with previous visit records.',
 'notification_notice_ar','سيصلك إشعار داخل التطبيق عند الانتهاء من مراجعة طلبك',
 'notification_notice_en','You will receive an in-app notification when your request review is complete.',
 'status_label_ar','بانتظار مطابقة المعلومات','status_label_en','Waiting for information matching',
 'canonical_claim_created',false,'link_created',false,'approval_available',false);
end$$;
revoke all on function private.visit_recovery_customer_snapshot(private.visit_recovery_customer_requests,boolean)from public,anon,authenticated,service_role;

create function private.get_my_visit_recovery_request(p_case uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare ident record;c private.visit_recovery_customer_requests;begin
 select * into strict ident from private.visit_recovery_request_identity();
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and(p_case is null or case_id=p_case)order by created_at desc,case_id desc limit 1;
 if not found then return jsonb_build_object('state','unavailable','case',null,'consent',jsonb_build_object('version','visit-recovery-v1','notice_ar',private.visit_recovery_request_notice('ar'),'notice_en',private.visit_recovery_request_notice('en')));end if;
 return private.visit_recovery_customer_snapshot(c,c.email_hash=ident.email_hash and c.email_confirmed_at=ident.email_confirmed_at and c.phone_hash=ident.phone_hash);
end$$;

create function private.submit_visit_recovery_request(p_request uuid,p_consent jsonb)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare ident record;prior private.visit_recovery_submission_requests;c private.visit_recovery_customer_requests;
 normalized jsonb;language_code text;created boolean:=false;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Recovery submissions require READ COMMITTED'using errcode='25001';end if;
 if p_request is null or p_consent is null or jsonb_typeof(p_consent)<>'object'
 or not(p_consent?&array['accepted','version','language','text'])or p_consent-array['accepted','version','language','text']<>'{}'::jsonb
 or not(p_consent @> '{"accepted":true,"version":"visit-recovery-v1"}'::jsonb)then
 raise exception 'Explicit recovery request consent required'using errcode='22023';end if;
 language_code:=p_consent->>'language';
 if language_code is null or language_code not in('ar','en')or p_consent->>'text'is distinct from private.visit_recovery_request_notice(language_code)then
 raise exception 'Actual recovery request notice required'using errcode='22023';end if;
 normalized:=jsonb_build_object('consent',p_consent);
 -- One global request identity, then actual identity locks, then one actor envelope.
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-submit:'||p_request::text,0));
 select * into strict ident from private.visit_recovery_request_identity();
 select * into prior from private.visit_recovery_submission_requests where request_id=p_request;
 if found then
 if prior.actor_id<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 if prior.payload<>normalized then raise exception 'Recovery request identity reused with changed consent'using errcode='22023';end if;
 return private.get_my_visit_recovery_request(prior.case_id);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||ident.actor_id::text,0));
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and status='awaiting_matching';
 if not found then
 insert into private.visit_recovery_customer_requests(requester_id,email_hash,email_confirmed_at,phone_hash,consent)
 values(ident.actor_id,ident.email_hash,ident.email_confirmed_at,ident.phone_hash,p_consent)returning * into c;created:=true;
 end if;
 insert into private.visit_recovery_submission_requests(request_id,actor_id,payload,case_id)values(p_request,ident.actor_id,normalized,c.case_id);
 if created then
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'customer',ident.actor_id,'recovery_received');
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'active_owner_pool',null,'recovery_submitted');
 end if;
 -- Existing open case is returned, never silently replaced or re-fingerprinted.
 return private.get_my_visit_recovery_request(c.case_id);
end$$;

create function private.get_visit_recovery_request_for_review(p_case uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;current_identity boolean;begin
 perform private.app_inbox_actor();
 if private.active_staff_role()is distinct from'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 select * into c from private.visit_recovery_customer_requests where case_id=p_case;
 if not found then return jsonb_build_object('state','unavailable','case',null);end if;
 select exists(select 1 from auth.users u join public.customers own on own.id=u.id where u.id=c.requester_id and u.deleted_at is null
 and(u.banned_until is null or u.banned_until<=clock_timestamp())and u.email_confirmed_at=c.email_confirmed_at
 and extensions.digest(lower(trim(u.email)),'sha256')=c.email_hash
 and extensions.digest('registered-customer-phone-v1:'||private.offline_phone_key(own.phone,'EG'),'sha256')=c.phone_hash)into current_identity;
 return jsonb_build_object('state','available','case',jsonb_build_object('case_id',c.case_id,'status',c.status,'created_at',c.created_at,'identity_current',current_identity),
 'approval_available',false,'canonical_claim_created',false,'link_created',false);
end$$;

revoke all on function private.submit_visit_recovery_request(uuid,jsonb),private.get_my_visit_recovery_request(uuid),private.get_visit_recovery_request_for_review(uuid)from public,anon,service_role;
grant execute on function private.submit_visit_recovery_request(uuid,jsonb),private.get_my_visit_recovery_request(uuid),private.get_visit_recovery_request_for_review(uuid)to authenticated;
create function public.submit_visit_recovery_request(p_request uuid,p_consent jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.submit_visit_recovery_request(p_request,p_consent)$$;
create function public.get_my_visit_recovery_request(p_case uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_visit_recovery_request(p_case)$$;
create function public.get_visit_recovery_request_for_review(p_case uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_visit_recovery_request_for_review(p_case)$$;
revoke all on function public.submit_visit_recovery_request(uuid,jsonb),public.get_my_visit_recovery_request(uuid),public.get_visit_recovery_request_for_review(uuid)from public,anon,service_role;
grant execute on function public.submit_visit_recovery_request(uuid,jsonb),public.get_my_visit_recovery_request(uuid),public.get_visit_recovery_request_for_review(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
