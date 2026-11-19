begin;
-- Private reviewed identity evidence only. No reader, wallet, financial or UUID bridge.
create table private.offline_claim_requests(
 request_id uuid primary key, actor_id uuid not null references auth.users(id), receipt_key uuid not null,
 profile_id uuid references private.offline_customer_profiles(profile_id), mode text not null check(mode in('original_receipt','lost_secret_review')),
 payload_hash bytea not null check(octet_length(payload_hash)=32), consent jsonb not null,
 email_hash bytea, email_confirmed_at timestamptz, contact_hash bytea,
 secret_proved boolean not null, outcome text not null check(outcome in('pending_owner_review','verification_failed')),
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null);
create index offline_claim_actor_rate on private.offline_claim_requests(actor_id,created_at);
create index offline_claim_receipt_rate on private.offline_claim_requests(receipt_key,created_at);
create table private.offline_claim_decisions(
 request_id uuid primary key,claim_id uuid not null references private.offline_claim_requests(request_id),
 owner_id uuid not null references auth.users(id),decision text not null check(decision in('approve_with_secret','approve_exception','reject','hold')),
 evidence_type text,reason text not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
create unique index offline_claim_final_decision on private.offline_claim_decisions(claim_id)where decision<>'hold';
create table private.offline_customer_trusted_links(
 link_id uuid primary key,profile_id uuid not null references private.offline_customer_profiles(profile_id),
 auth_user_id uuid not null references auth.users(id),claim_id uuid not null unique references private.offline_claim_requests(request_id),
 receipt_id uuid not null unique references private.offline_customer_enrollment_receipts(receipt_id),
 email_hash bytea not null,email_confirmed_at timestamptz not null,contact_hash bytea not null,
 approved_by uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),revoked_at timestamptz);
create unique index offline_claim_active_profile on private.offline_customer_trusted_links(profile_id)where revoked_at is null;
create unique index offline_claim_active_auth on private.offline_customer_trusted_links(auth_user_id)where revoked_at is null;
create table private.offline_claim_revocations(request_id uuid primary key,link_id uuid not null references private.offline_customer_trusted_links(link_id),owner_id uuid not null references auth.users(id),reason text not null,created_at timestamptz not null default clock_timestamp());
do $$declare v_t text;begin foreach v_t in array array['offline_claim_requests','offline_claim_decisions','offline_customer_trusted_links','offline_claim_revocations']loop
 execute format('alter table private.%I enable row level security',v_t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',v_t);
 if v_t<>'offline_customer_trusted_links'then execute format('create trigger immutable_offline_claim before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',v_t);end if;end loop;end$$;
create function private.guard_offline_customer_link()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Reviewed links are retained'using errcode='55000';end if;
 if (to_jsonb(new)-'revoked_at')is distinct from(to_jsonb(old)-'revoked_at')or old.revoked_at is not null or new.revoked_at is null then raise exception 'Only first revocation is permitted; link evidence is immutable'using errcode='55000';end if;
 new.revoked_at:=clock_timestamp();return new;
end$$;
revoke all on function private.guard_offline_customer_link()from public,anon,authenticated,service_role;
create trigger guard_offline_customer_link before update or delete on private.offline_customer_trusted_links for each row execute function private.guard_offline_customer_link();
create function private.offline_claim_notice(p_language text)returns text language sql immutable set search_path=pg_catalog as $$select case p_language
 when 'en'then 'I request owner review to link this reception receipt to my confirmed app account. I consent to this identity review. Phone matching alone is not proof. History and rewards remain unavailable until secure access is implemented.'
 when 'ar'then 'أطلب مراجعة المالك لربط إيصال الاستقبال بحسابي المؤكد في التطبيق وأوافق على مراجعة الهوية. تطابق الهاتف وحده ليس إثباتاً. تبقى السجلات والمكافآت غير متاحة حتى تنفيذ الوصول الآمن.'end$$;
create function private.offline_claim_contact_hash(p_profile uuid)returns bytea language sql stable set search_path=pg_catalog as $$select extensions.digest(coalesce(jsonb_agg(jsonb_build_object('contact_id',c.contact_id,'phone',c.phone_e164,'verification',c.verification,'created_at',c.created_at)order by c.contact_id)::text,'[]'),'sha256')from private.offline_customer_contacts c where c.profile_id=p_profile$$;
-- Exactly 32 XOR/OR iterations; both digests must have fixed size. No early byte exit.
create function private.offline_claim_digest_matches(p_a bytea,p_b bytea)returns boolean language plpgsql immutable set search_path=pg_catalog as $$declare v_diff integer:=0;v_i integer;begin
 if octet_length(p_a)is distinct from 32 or octet_length(p_b)is distinct from 32 then return false;end if;
 for v_i in 0..31 loop v_diff:=v_diff | (get_byte(p_a,v_i)#get_byte(p_b,v_i));end loop;return v_diff=0;end$$;
create function private.offline_claim_flags()returns jsonb language sql immutable set search_path=pg_catalog as $$select '{"history_visible":false,"wallet_access":false,"guest_redemption":false,"reader_bridge_implemented":false}'::jsonb$$;
create function private.get_my_offline_customer_claim(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_r private.offline_claim_requests;v_status text;v_live boolean;begin
 if auth.uid()is null then raise exception 'Authenticated customer required'using errcode='42501';end if;
 select * into v_r from private.offline_claim_requests where request_id=p_request and actor_id=auth.uid();
 if not found then return jsonb_build_object('request_id',p_request,'status','unavailable','capabilities',private.offline_claim_flags());end if;
 v_status:=v_r.outcome;
 -- Recheck real Auth state and the entire contact set on every status read too.
 select exists(select 1 from auth.users u join public.customers c on c.id=u.id where u.id=v_r.actor_id and u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null and (u.banned_until is null or u.banned_until<clock_timestamp())and extensions.digest(lower(trim(u.email)),'sha256')=v_r.email_hash and u.email_confirmed_at=v_r.email_confirmed_at)into v_live;
 if v_status='pending_owner_review'then
  if not v_live or(v_r.profile_id is not null and private.offline_claim_contact_hash(v_r.profile_id)is distinct from v_r.contact_hash)then v_status:='stale_identity_review_required';
  elsif exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=v_r.request_id and l.revoked_at is not null)then v_status:='revoked';
  elsif exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=v_r.request_id and l.revoked_at is null)then v_status:='approved_pending_reader_bridge';
  elsif exists(select 1 from private.offline_claim_decisions d where d.claim_id=v_r.request_id and d.decision='reject')then v_status:='rejected';
  elsif v_r.expires_at<=clock_timestamp()then v_status:='expired';end if;
 end if;
 return jsonb_build_object('request_id',p_request,'status',v_status,'expires_at',v_r.expires_at,'capabilities',private.offline_claim_flags());
end$$;
create function private.request_offline_customer_claim(p_request uuid,p_receipt uuid,p_secret text,p_mode text,p_consent jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid();v_prior private.offline_claim_requests;v_receipt private.offline_customer_enrollment_receipts;v_auth auth.users;v_hash bytea;v_payload_hash bytea;v_proof boolean;v_allowed boolean;v_pid uuid;v_email_hash bytea;v_contact_hash bytea;v_outcome text:='verification_failed';v_now timestamptz:=clock_timestamp();begin
 if v_actor is null then raise exception 'Authenticated customer required'using errcode='42501';end if;
 if p_request is null or p_receipt is null or p_mode is null or p_mode not in('original_receipt','lost_secret_review')or length(coalesce(p_secret,''))>128 then raise exception 'Stable request, receipt and supported proof mode required'using errcode='22023';end if;
 if p_consent is null or jsonb_typeof(p_consent)<>'object'or not p_consent?&array['accepted','version','text','language']or p_consent-array['accepted','version','text','language']<>'{}'::jsonb or p_consent->'accepted'is distinct from 'true'::jsonb or p_consent->>'version'is distinct from 'offline-claim-v1'or not coalesce(p_consent->>'language'in('en','ar'),false)or p_consent->>'text'is distinct from private.offline_claim_notice(p_consent->>'language')then raise exception 'Display and accept current identity-review consent'using errcode='22023';end if;
 if p_mode='lost_secret_review'and coalesce(p_secret,'')<>''then raise exception 'Lost-secret review cannot submit a secret'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Claim requires READ COMMITTED'using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-request:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||v_actor::text,0));
 v_hash:=extensions.digest(coalesce(p_secret,''),'sha256');
 v_payload_hash:=extensions.digest(jsonb_build_object('receipt',p_receipt,'mode',p_mode,'proof_hash',encode(v_hash,'hex'),'consent',p_consent)::text,'sha256');
 select * into v_prior from private.offline_claim_requests where request_id=p_request;
 if found then
  if v_prior.actor_id<>v_actor then raise exception 'Claim request unavailable'using errcode='42501';end if;
  if v_prior.payload_hash<>v_payload_hash then raise exception 'Claim request changed'using errcode='22023';end if;
  return private.get_my_offline_customer_claim(p_request);
 end if;
 -- Shared receipt mutex bounds attempts across multiple Auth accounts, without discovery.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-receipt:'||p_receipt::text,0));
 select(count(*)filter(where created_at>v_now-interval '1 hour')<5 and count(*)<20)into v_allowed from private.offline_claim_requests where actor_id=v_actor and created_at>v_now-interval '1 day';
 v_allowed:=v_allowed and (select count(*)filter(where created_at>v_now-interval '1 hour')<5 and count(*)<20 from private.offline_claim_requests where receipt_key=p_receipt and created_at>v_now-interval '1 day');
 select * into v_receipt from private.offline_customer_enrollment_receipts where receipt_id=p_receipt;
 v_proof:=private.offline_claim_digest_matches(v_hash,coalesce(v_receipt.secret_hash,extensions.digest('offline-claim-dummy-unavailable','sha256')));
 select * into v_auth from auth.users where id=v_actor for share;
 if v_allowed and v_receipt.receipt_id is not null and (p_mode='lost_secret_review'or(v_proof and p_secret ~ '^[0-9a-f]{64}$'))and v_auth.email is not null and v_auth.email_confirmed_at is not null and v_auth.deleted_at is null and(v_auth.banned_until is null or v_auth.banned_until<v_now)and exists(select 1 from public.customers where id=v_actor)then
  perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||v_receipt.profile_id::text,0));
  if not exists(select 1 from private.offline_customer_trusted_links where receipt_id=p_receipt or(auth_user_id=v_actor and revoked_at is null)or(profile_id=v_receipt.profile_id and revoked_at is null))then
   v_pid:=v_receipt.profile_id;v_email_hash:=extensions.digest(lower(trim(v_auth.email)),'sha256');v_contact_hash:=private.offline_claim_contact_hash(v_pid);v_outcome:='pending_owner_review';
  end if;
 end if;
 -- Lost-secret mode must not disclose whether a random receipt UUID exists.
 -- An unknown receipt gets the same pending shell but has no approvable profile.
 if v_allowed and p_mode='lost_secret_review'and v_auth.email is not null and v_auth.email_confirmed_at is not null and v_auth.deleted_at is null and(v_auth.banned_until is null or v_auth.banned_until<v_now)and exists(select 1 from public.customers where id=v_actor)then
  v_outcome:='pending_owner_review';v_email_hash:=extensions.digest(lower(trim(v_auth.email)),'sha256');
 end if;
 insert into private.offline_claim_requests(request_id,actor_id,receipt_key,profile_id,mode,payload_hash,consent,email_hash,email_confirmed_at,contact_hash,secret_proved,outcome,created_at,expires_at)
 values(p_request,v_actor,p_receipt,v_pid,p_mode,v_payload_hash,p_consent,v_email_hash,case when v_outcome='pending_owner_review'then v_auth.email_confirmed_at end,v_contact_hash,v_pid is not null and p_mode='original_receipt'and v_proof,v_outcome,v_now,v_now+interval '24 hours');
 -- Do not RAISE after recording bad proofs: counters must commit in a normal RPC TX.
 return private.get_my_offline_customer_claim(p_request);
end$$;
create function private.list_offline_customer_claim_reviews(p_branch uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 return coalesce((select jsonb_agg(v.item order by v.created_at desc)from(select r.created_at,jsonb_build_object('claim_id',r.request_id,'claimant_id',r.actor_id,'branch_id',p.created_branch_id,'profile_reference',p.profile_id,'name',p.full_name,'mode',r.mode,'secret_proved',r.secret_proved,'created_at',r.created_at,'expires_at',r.expires_at,'status',case when exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=r.request_id and l.revoked_at is not null)then 'revoked' when exists(select 1 from private.offline_customer_trusted_links l where l.claim_id=r.request_id)then 'approved_pending_reader_bridge' when exists(select 1 from private.offline_claim_decisions d where d.claim_id=r.request_id and d.decision='reject')then 'rejected' when r.expires_at<=clock_timestamp()then 'expired'else 'pending_owner_review'end,'confirmed_account_current',exists(select 1 from auth.users u where u.id=r.actor_id and u.email_confirmed_at=r.email_confirmed_at and u.email_confirmed_at is not null and extensions.digest(lower(trim(u.email)),'sha256')=r.email_hash and u.deleted_at is null and(u.banned_until is null or u.banned_until<clock_timestamp())),'contact_current',private.offline_claim_contact_hash(p.profile_id)=r.contact_hash,'capabilities',private.offline_claim_flags())item
 from private.offline_claim_requests r join private.offline_customer_profiles p on p.profile_id=r.profile_id where r.outcome='pending_owner_review'and(p_branch is null or p.created_branch_id=p_branch)order by r.created_at desc limit 100)v),'[]'::jsonb);
end$$;
create function private.decide_offline_customer_claim(p_request uuid,p_claim uuid,p_decision text,p_reason text,p_evidence_type text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_r private.offline_claim_requests;v_a auth.users;v_prior private.offline_claim_decisions;v_payload jsonb;v_result jsonb;v_link uuid;begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_request is null or p_claim is null or p_decision is null or p_decision not in('approve_with_secret','approve_exception','reject','hold')or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Explicit supported decision and review reason required'using errcode='22023';end if;
 if p_decision='approve_exception'and coalesce(p_evidence_type,'')not in('in_person_original_service_documents','in_person_independent_continuity_witness')then raise exception 'Independent in-person continuity evidence required; phone matching is insufficient'using errcode='22023';end if;
 if p_decision<>'approve_exception'and p_evidence_type is not null then raise exception 'Evidence type is only for explicit continuity exception'using errcode='22023';end if;
 perform set_config('lock_timeout','20s',true);
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Claim review requires READ COMMITTED'using errcode='55000';end if;
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
 return v_result;
end$$;
create function private.revoke_offline_customer_link(p_request uuid,p_link uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_l private.offline_customer_trusted_links;v_prior private.offline_claim_revocations;begin
 if private.active_staff_role()is distinct from 'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_request is null or p_link is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Stable revocation request and explicit reason required'using errcode='22023';end if;
 perform set_config('lock_timeout','20s',true);
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
 return jsonb_build_object('link_id',p_link,'status','revoked','capabilities',private.offline_claim_flags());
end$$;
-- Helpers are private. Only the five audited definer entry points may be called through invoker wrappers.
revoke all on function private.offline_claim_notice(text),private.offline_claim_contact_hash(uuid),private.offline_claim_digest_matches(bytea,bytea),private.offline_claim_flags()from public,anon,authenticated,service_role;
revoke all on function private.request_offline_customer_claim(uuid,uuid,text,text,jsonb),private.get_my_offline_customer_claim(uuid),private.list_offline_customer_claim_reviews(uuid),private.decide_offline_customer_claim(uuid,uuid,text,text,text),private.revoke_offline_customer_link(uuid,uuid,text)from public,anon,service_role;
grant execute on function private.request_offline_customer_claim(uuid,uuid,text,text,jsonb),private.get_my_offline_customer_claim(uuid),private.list_offline_customer_claim_reviews(uuid),private.decide_offline_customer_claim(uuid,uuid,text,text,text),private.revoke_offline_customer_link(uuid,uuid,text)to authenticated;
create function public.request_offline_customer_claim(p_request uuid,p_receipt uuid,p_secret text,p_mode text,p_consent jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.request_offline_customer_claim(p_request,p_receipt,p_secret,p_mode,p_consent)$$;
create function public.get_my_offline_customer_claim(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_customer_claim(p_request)$$;
create function public.list_offline_customer_claim_reviews(p_branch uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_offline_customer_claim_reviews(p_branch)$$;
create function public.decide_offline_customer_claim(p_request uuid,p_claim uuid,p_decision text,p_reason text,p_evidence_type text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.decide_offline_customer_claim(p_request,p_claim,p_decision,p_reason,p_evidence_type)$$;
create function public.revoke_offline_customer_link(p_request uuid,p_link uuid,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.revoke_offline_customer_link(p_request,p_link,p_reason)$$;
revoke all on function public.request_offline_customer_claim(uuid,uuid,text,text,jsonb),public.get_my_offline_customer_claim(uuid),public.list_offline_customer_claim_reviews(uuid),public.decide_offline_customer_claim(uuid,uuid,text,text,text),public.revoke_offline_customer_link(uuid,uuid,text)from public,anon,service_role;
grant execute on function public.request_offline_customer_claim(uuid,uuid,text,text,jsonb),public.get_my_offline_customer_claim(uuid),public.list_offline_customer_claim_reviews(uuid),public.decide_offline_customer_claim(uuid,uuid,text,text,text),public.revoke_offline_customer_link(uuid,uuid,text)to authenticated;
notify pgrst,'reload schema';
commit;
