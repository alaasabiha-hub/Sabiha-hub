-- SOURCE ONLY isolated post-DDL negative/shape checks. Root controls actual execution.
begin;
do $$declare row_quote private.service_reward_quotes;source_quote jsonb;denied boolean;own uuid;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 assert not has_table_privilege('authenticated','private.offline_reward_reservation_commands','INSERT');
 assert not has_function_privilege('service_role','private.release_offline_reward_reservation(uuid,text)','EXECUTE');
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 for row_quote in select *from private.service_reward_quotes where owner_kind='auth_customer'loop
 source_quote:=private.customer_reward_quote(row_quote);
 assert not(source_quote?'owner_kind')and not(source_quote?'offline_profile_id')and not(source_quote?'offline_channel_version_id')and not(source_quote?'reserve_request_id')and not(source_quote?'requested_by');
 assert row_quote.customer_id is not null and row_quote.vehicle_id is not null and row_quote.booking_date is not null and row_quote.booking_time is not null;
 end loop;
 denied:=false;begin perform private.sync_customer_rewards(null);exception when invalid_parameter_value then denied:=true;end;assert denied,'NULL Auth sync must fail, not claim clean debt';
 denied:=false;begin insert into private.service_reward_redemptions(redemption_id,owner_kind,customer_id)values(gen_random_uuid(),'offline_profile',null);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied,'No offline reward issuance before consent/commission integration';
 denied:=false;begin insert into private.reward_refund_reviews(owner_kind,customer_id)values('offline_profile',null);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied,'No unfounded typed debt records';
 assert not exists(select 1 from private.reward_credit_claims where owner_kind='auth_customer'and(customer_id is null or kind='reserve'));
end$$;
rollback;
