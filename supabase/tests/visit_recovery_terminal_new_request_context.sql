begin;
create function pg_temp.terminal_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
do $$declare customer uuid;own uuid;nonce uuid:=gen_random_uuid();second_nonce uuid:=gen_random_uuid();review uuid:=gen_random_uuid();value jsonb;payload jsonb;old_case uuid;new_case uuid;before_count bigint;begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.email_confirmed_at is not null and u.deleted_at is null
 and private.offline_phone_key(c.phone,'EG')is not null and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and exists(select 1 from auth.sessions s where s.user_id=c.id and(s.not_after is null or s.not_after>clock_timestamp()))
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id and r.status in('awaiting_matching','more_info'))order by c.id limit 1;
 select user_id into strict own from public.staff_profiles s where role='owner'and is_active and exists(select 1 from auth.sessions x where x.user_id=s.user_id and(x.not_after is null or x.not_after>clock_timestamp()))limit 1;
 perform pg_temp.terminal_actor(customer);
 value:=public.submit_visit_recovery_request(nonce,jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',private.visit_recovery_request_notice('en')));
 old_case:=(value#>>'{case,case_id}')::uuid;
 assert not coalesce((value->>'new_request_allowed')::boolean,false);
 select p.payload into strict payload from private.visit_recovery_submission_requests p where request_id=nonce;
 perform pg_temp.terminal_actor(own);
 perform public.prepare_visit_recovery_review(review,old_case,'awaiting_matching','reject','Isolated terminal request fresh consent review');perform public.apply_visit_recovery_review(review);
 perform pg_temp.terminal_actor(customer);
 value:=public.get_my_visit_recovery_request(old_case);
 assert value#>>'{case,status}'='rejected'and(value->>'new_request_allowed')::boolean;
 assert value#>>'{consent,notice_ar}'=private.visit_recovery_request_notice('ar');
 assert public.get_my_visit_recovery_submission(nonce)->'payload'=payload;
 select count(*)into before_count from private.visit_recovery_customer_requests where requester_id=customer;
 value:=public.submit_visit_recovery_request(second_nonce,jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','ar','text',private.visit_recovery_request_notice('ar')));
 new_case:=(value#>>'{case,case_id}')::uuid;assert new_case<>old_case;
 assert value#>>'{case,status}'='awaiting_matching'and not coalesce((value->>'new_request_allowed')::boolean,false);
 assert(select count(*)from private.visit_recovery_customer_requests where requester_id=customer)=before_count+1;
 assert(select status from private.visit_recovery_customer_requests where case_id=old_case)='rejected';
 assert(select p.payload from private.visit_recovery_submission_requests p where request_id=nonce)=payload;
 assert(select count(*)from private.app_inbox_events e join private.visit_recovery_customer_requests c on c.submission_event_id=e.source_event_id where c.case_id=new_case)=2;
end$$;
rollback;
