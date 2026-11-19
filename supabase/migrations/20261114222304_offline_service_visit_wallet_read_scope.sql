begin;
-- READ-ONLY component, shipped disabled. No spender, allocator, debt or issuer enablement.
create table private.offline_visit_wallet_runtime(singleton boolean primary key default true check(singleton),read_enabled boolean not null default false check(not read_enabled));
insert into private.offline_visit_wallet_runtime(singleton,read_enabled)values(true,false);
create table private.offline_visit_wallet_read_consents(
 request_id uuid primary key,link_id uuid not null references private.offline_customer_trusted_links(link_id),actor_id uuid not null references auth.users(id),
 consent jsonb not null,version text not null check(version='offline-wallet-read-v1'),created_at timestamptz not null default clock_timestamp());
alter table private.offline_visit_wallet_runtime enable row level security;
alter table private.offline_visit_wallet_read_consents enable row level security;
revoke all on private.offline_visit_wallet_runtime,private.offline_visit_wallet_read_consents from public,anon,authenticated,service_role;
create trigger immutable_offline_wallet_consent before update or delete on private.offline_visit_wallet_read_consents for each row execute function private.immutable_canonical_visit();
create function private.offline_visit_wallet_read_notice(p_language text)returns text language sql immutable set search_path=pg_catalog as $$select case p_language
when 'en'then 'I agree to view the service-visit records owned by the reception profile linked to my owner-reviewed receipt. This does not transfer credits, combine app and reception balances, or authorize reward redemption.'
when 'ar'then 'أوافق على عرض سجلات زيارات الخدمة المملوكة لملف الاستقبال المرتبط بإيصالي الذي راجعه المالك. لا تنقل هذه الموافقة الأرصدة ولا تدمج رصيد التطبيق والاستقبال ولا تسمح باستبدال المكافآت.'end$$;

-- One-statement snapshot of actual owned records, not an allocator/spendable balance.
create function private.offline_visit_wallet_projection(p_profile uuid)returns jsonb language sql stable security definer set search_path=pg_catalog as $$
with credits as materialized(
 select e.id,e.policy_version_id,s.channel_version_id,s.offline_activation_id,v.version_no channel_version_no,et.rules_version_id,r.rules,r.terms_snapshot,
 case when et.rules_version_id is null then jsonb_build_object('valid',false,'reason','original_rules_missing')else private.reward_credit_terms(e.id,et.rules_version_id)end credit_terms,
 private.reward_credit_refund(e.id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund')effective_refunded,
 exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund')ledger_reversed,
 exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null)claimed
 from private.canonical_loyalty_visits e join private.offline_service_visit_order_snapshots s on s.order_id=e.offline_order_snapshot_id and s.offline_profile_id=e.offline_profile_id
 join private.offline_visit_channel_versions v on v.version_id=s.channel_version_id left join private.reward_earning_terms et on et.earning_id=e.id left join private.loyalty_redemption_rule_versions r on r.rules_version_id=et.rules_version_id
 where e.source_channel='offline_walk_in'and e.customer_id is null and e.offline_profile_id=p_profile and e.kind='earn'),
 cohorts as(
 select policy_version_id,channel_version_id,offline_activation_id,channel_version_no,rules_version_id,max(terms_snapshot#>>'{offer,name}')offer_name,max(rules->>'pooling')pooling,
 count(*)recorded_earned_visits,count(*)filter(where effective_refunded)effectively_refunded_visits,
 count(*)filter(where not effective_refunded and not claimed and coalesce((credit_terms->>'valid')::boolean,false))recorded_unclaimed_valid_visits,
 count(*)filter(where rules_version_id is null)unbound_terms_visits,
 count(*)filter(where not effective_refunded and credit_terms->>'expires_at'is not null and(credit_terms->>'expires_at')::timestamptz<=statement_timestamp())expired_visits
 from credits group by policy_version_id,channel_version_id,offline_activation_id,channel_version_no,rules_version_id),
 shown as(select *from cohorts order by channel_version_no,offline_activation_id,rules_version_id nulls last limit 100)
 select jsonb_build_object('state','available_read_only','unit','service_visits','owner_kind','offline_profile','as_of',statement_timestamp(),
 'recorded_earned_visits',(select count(*)from credits),'ledger_reversed_visits',(select count(*)from credits where ledger_reversed),
 'effective_refunded_visits',(select count(*)from credits where effective_refunded),
 'actual_refunds_awaiting_reversal',(select count(*)from credits where effective_refunded and not ledger_reversed),
 'observed_active_claim_visits',(select count(*)from credits where claimed),
 'cohorts',coalesce((select jsonb_agg(jsonb_build_object('policy_version_id',policy_version_id,'channel_version_id',channel_version_id,'offline_activation_id',offline_activation_id,'channel_version_no',channel_version_no,'rules_version_id',rules_version_id,'offer_name',offer_name,'pooling',pooling,'recorded_earned_visits',recorded_earned_visits,'effectively_refunded_visits',effectively_refunded_visits,'recorded_unclaimed_valid_visits',recorded_unclaimed_valid_visits,'expired_visits',expired_visits,'unbound_terms_visits',unbound_terms_visits)order by channel_version_no,offline_activation_id,rules_version_id)from shown),'[]'::jsonb),
 'cohorts_truncated',(select count(*)>100 from cohorts),'pools_overlap',true,'global_spendable_balance',null,'debt_adjusted_spendable_visits',null,
 'redemption_enabled',false,'offline_allocation_supported',false,'refund_debt_resolution_supported',false,'points_conversion_supported',false,'ownership_transferred',false)$$;

create function private.accept_my_offline_wallet_read_scope(p_request uuid,p_consent jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare link private.offline_customer_trusted_links;prior private.offline_visit_wallet_read_consents;language text;
begin
 link:=private.resolve_my_offline_history_link(); -- live session + actual owner-reviewed proof, NOT history consent
 if p_request is null or jsonb_typeof(p_consent)<>'object'or not p_consent?&array['accepted','version','language','text']
 or p_consent-array['accepted','version','language','text']<>'{}'::jsonb or p_consent->'accepted'is distinct from'true'::jsonb
 or p_consent->>'version'is distinct from'offline-wallet-read-v1' then raise exception 'Explicit wallet read scope required'using errcode='22023';end if;
 language:=p_consent->>'language';
 if language is null or language not in('ar','en')or p_consent->>'text'is distinct from private.offline_visit_wallet_read_notice(language)then raise exception 'Actual fixed wallet notice required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-wallet-consent:'||p_request::text,0));
 select *into prior from private.offline_visit_wallet_read_consents where request_id=p_request;
 if found then
 if prior.actor_id<>auth.uid()then raise exception 'Wallet unavailable'using errcode='42501';end if;
 if prior.link_id<>link.link_id or prior.consent<>p_consent then raise exception 'Wallet consent request changed'using errcode='22023';end if;
 else insert into private.offline_visit_wallet_read_consents(request_id,link_id,actor_id,consent,version)values(p_request,link.link_id,auth.uid(),p_consent,'offline-wallet-read-v1');end if;
 if private.offline_claim_contact_hash(link.profile_id)is distinct from link.contact_hash then raise exception 'Wallet unavailable'using errcode='42501';end if;
 return jsonb_build_object('state','read_consent_recorded','request_id',p_request,'read_enabled',coalesce((select read_enabled from private.offline_visit_wallet_runtime where singleton),false),'redemption_enabled',false);
end$$;
create function private.get_my_offline_service_visit_wallet()returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare link private.offline_customer_trusted_links;consented boolean;enabled boolean;result jsonb;
begin
 begin link:=private.resolve_my_offline_history_link();exception when insufficient_privilege then return jsonb_build_object('state','review_required','unit','service_visits','redemption_enabled',false,'global_spendable_balance',null);end;
 select exists(select 1 from private.offline_visit_wallet_read_consents c where c.link_id=link.link_id and c.actor_id=auth.uid()and c.version='offline-wallet-read-v1')into consented;
 select read_enabled into enabled from private.offline_visit_wallet_runtime where singleton;
 if not consented or not coalesce(enabled,false)then
 return jsonb_build_object('state',case when not consented then'consent_required'else'acceptance_pending'end,'unit','service_visits','redemption_enabled',false,'global_spendable_balance',null,
 'consent',jsonb_build_object('version','offline-wallet-read-v1','notice_ar',private.offline_visit_wallet_read_notice('ar'),'notice_en',private.offline_visit_wallet_read_notice('en')));end if;
 result:=private.offline_visit_wallet_projection(link.profile_id);
 if private.offline_claim_contact_hash(link.profile_id)is distinct from link.contact_hash then raise exception 'Wallet unavailable'using errcode='42501';end if;
 return result;
end$$;
revoke all on function private.offline_visit_wallet_read_notice(text),private.offline_visit_wallet_projection(uuid),private.accept_my_offline_wallet_read_scope(uuid,jsonb),private.get_my_offline_service_visit_wallet()from public,anon,authenticated,service_role;
create function public.accept_my_offline_wallet_read_scope(p_request uuid,p_consent jsonb)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.accept_my_offline_wallet_read_scope(p_request,p_consent)$$;
create function public.get_my_offline_service_visit_wallet()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_offline_service_visit_wallet()$$;
revoke all on function public.accept_my_offline_wallet_read_scope(uuid,jsonb),public.get_my_offline_service_visit_wallet()from public,anon,authenticated,service_role;
grant execute on function private.accept_my_offline_wallet_read_scope(uuid,jsonb),private.get_my_offline_service_visit_wallet(),public.accept_my_offline_wallet_read_scope(uuid,jsonb),public.get_my_offline_service_visit_wallet()to authenticated;
notify pgrst,'reload schema';
commit;
