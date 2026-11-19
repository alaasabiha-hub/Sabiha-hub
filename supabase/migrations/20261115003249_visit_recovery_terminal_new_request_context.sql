begin;
-- Fresh review consent for a NEW request after a rejected/revoked case. Existing
-- cases, immutable submissions and their original consent are never rewritten.
create or replace function private.get_my_visit_recovery_request(p_case uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare ident record;c private.visit_recovery_customer_requests;view jsonb;begin
 select * into strict ident from private.visit_recovery_request_identity();
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and(p_case is null or case_id=p_case)order by created_at desc,case_id desc limit 1;
 if not found then return jsonb_build_object('state','unavailable','case',null,'consent',jsonb_build_object('version','visit-recovery-v1','notice_ar',private.visit_recovery_request_notice('ar'),'notice_en',private.visit_recovery_request_notice('en')));end if;
 view:=private.visit_recovery_customer_status_snapshot(c,c.email_hash=ident.email_hash and c.email_confirmed_at=ident.email_confirmed_at and c.phone_hash=ident.phone_hash);
 if c.status in('rejected','revoked')then
 -- Current Auth/session/contact validated above. Old fingerprint drift does not
 -- authorize old records; a fresh request takes NEW snapshots and review.
 view:=view||jsonb_build_object('new_request_allowed',true,'consent',jsonb_build_object('version','visit-recovery-v1','notice_ar',private.visit_recovery_request_notice('ar'),'notice_en',private.visit_recovery_request_notice('en')));
 end if;
 return view;
end$$;
notify pgrst,'reload schema';
commit;
