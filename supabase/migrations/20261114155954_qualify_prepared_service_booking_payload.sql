begin;
-- Distinguish normalized local fields from table payload columns without changing the public contract.
create or replace function private.prepare_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a private.service_booking_attempts;v_payload jsonb;view jsonb;q private.service_reward_quotes;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null or p_mode is null or p_mode not in('normal','reward') or p_payload is null or jsonb_typeof(p_payload)<>'object' or pg_column_size(p_payload)>16000 then raise exception 'Explicit mode and complete booking payload required' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':service-booking:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||auth.uid()::text,0));
 if p_mode='normal' then
 if not p_payload ?& array['p_service','p_branch','p_vehicle','p_date','p_time','p_expected_price','p_notes'] or p_payload-array['p_service','p_branch','p_vehicle','p_date','p_time','p_expected_price','p_notes']<>'{}'::jsonb then raise exception 'Exact normal booking fields required' using errcode='22023';end if;
 v_payload:=jsonb_build_object('p_service',(p_payload->>'p_service')::uuid,'p_branch',(p_payload->>'p_branch')::uuid,'p_vehicle',(p_payload->>'p_vehicle')::uuid,'p_date',(p_payload->>'p_date')::date,'p_time',(p_payload->>'p_time')::time,'p_expected_price',(p_payload->>'p_expected_price')::numeric,'p_notes',nullif(trim(p_payload->>'p_notes'),''));
 if v_payload->>'p_service' is null or v_payload->>'p_branch' is null or v_payload->>'p_vehicle' is null or v_payload->>'p_date' is null or v_payload->>'p_time' is null or v_payload->>'p_expected_price' is null or length(coalesce(v_payload->>'p_notes',''))>2000 then raise exception 'Complete normal booking fields required' using errcode='22023';end if;
 else
 if not p_payload ?& array['p_quote','p_fingerprint','p_accept_terms','p_adopt_existing_visits'] or p_payload-array['p_quote','p_fingerprint','p_accept_terms','p_adopt_existing_visits']<>'{}'::jsonb then raise exception 'Exact reward booking fields required' using errcode='22023';end if;
 v_payload:=jsonb_build_object('p_quote',(p_payload->>'p_quote')::uuid,'p_fingerprint',p_payload->>'p_fingerprint','p_accept_terms',(p_payload->>'p_accept_terms')::boolean,'p_adopt_existing_visits',(p_payload->>'p_adopt_existing_visits')::boolean);
 select * into q from private.service_reward_quotes where quote_id=(v_payload->>'p_quote')::uuid and customer_id=auth.uid();
 if q.quote_id is null or v_payload->>'p_fingerprint' is distinct from q.fingerprint or(v_payload->>'p_accept_terms')::boolean is distinct from true or(v_payload->>'p_adopt_existing_visits')is null or(cardinality(q.adoption_ids)>0 and(v_payload->>'p_adopt_existing_visits')::boolean is not true) then raise exception 'Own quote and explicit complete consent required' using errcode='22023';end if;
 end if;
 select * into a from private.service_booking_attempts where customer_id=auth.uid() and request_id=p_request;
 if a.request_id is not null then
 if a.state='closed' then return private.service_booking_attempt_view(p_request);end if;
 if a.mode<>p_mode or a.payload<>v_payload then raise exception 'Prepared mode/payload is immutable' using errcode='22023';end if;return private.service_booking_attempt_view(p_request);end if;
 view:=private.service_booking_attempt_view(p_request);if view->>'state'<>'absent' then if view->>'mode' is distinct from p_mode then raise exception 'Request belongs to another booking mode' using errcode='22023';end if;return view;end if;
 if exists(select 1 from private.service_booking_attempts where customer_id=auth.uid() and(state='open' or(state='succeeded' and acknowledged_at is null))) then raise exception 'Resolve and acknowledge the previous booking attempt first' using errcode='55000';end if;
 insert into private.service_booking_attempts(request_id,customer_id,mode,payload,state) values(p_request,auth.uid(),p_mode,v_payload,'open');return private.service_booking_attempt_view(p_request);
end $$;
notify pgrst,'reload schema';
commit;
