begin;
create function private.get_my_mixed_points_earnings()returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare linked private.offline_customer_trusted_links;profile uuid;buckets jsonb;
begin
 perform private.require_typed_reward_document_session(null);
 if private.active_staff_role()is not null or not exists(select 1 from public.customers where id=auth.uid())then raise exception 'Actual customer required'using errcode='42501';end if;
 -- Phone matching and email confirmation alone never select an offline wallet.
 begin
 linked:=private.resolve_my_offline_history_link();
 if coalesce((select enabled from private.offline_history_runtime where id),false)
 and exists(select 1 from private.offline_history_scope_consents c where c.link_id=linked.link_id and c.actor_id=auth.uid()and c.version='offline-history-v1')then profile:=linked.profile_id;end if;
 exception when insufficient_privilege then profile:=null;end;
 with owned as(select w.*from private.mixed_points_wallets w where(w.subject_kind='app_customer'and w.subject_id=auth.uid())or(w.subject_kind='offline_profile'and w.subject_id=profile)),
 amounts as(select w.wallet_id,w.branch_id,l.policy_id,sum(l.points)earned,sum(coalesce(o.points,0))offsets,
 bool_or(exists(select 1 from private.mixed_points_refund_reviews review where review.lot_id=l.lot_id))review_required
 from owned w join private.mixed_points_earned_lots l using(wallet_id)left join private.mixed_points_refund_offsets o using(lot_id)group by w.wallet_id,w.branch_id,l.policy_id)
 select coalesce(jsonb_agg(jsonb_build_object('wallet_id',a.wallet_id,'branch_id',a.branch_id,'policy_version_id',a.policy_id,'policy_version',p.version,
 'earned_points',a.earned::text,'refund_offsets',a.offsets::text,'net_earned_points',(a.earned-a.offsets)::text,
 'review_required',a.review_required,'point_value_egp',p.rules->'point_value_egp','point_value_basis',p.rules->'point_value_basis')order by a.branch_id,a.wallet_id,p.version),'[]'::jsonb)into buckets
 from amounts a join private.mixed_points_policy_versions p on p.version_id=a.policy_id;
 if profile is not null and private.offline_claim_contact_hash(profile)is distinct from linked.contact_hash then raise exception 'History unavailable'using errcode='42501';end if;
 return jsonb_build_object('unit','reward_points_v1','has_earnings',jsonb_array_length(buckets)>0,'buckets',buckets,'ledger_only',true,'redemption_available',false,'legacy_converted',false);
end$$;
create function public.get_my_mixed_points_earnings()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_mixed_points_earnings()$$;
revoke all on function private.get_my_mixed_points_earnings(),public.get_my_mixed_points_earnings()from public,anon,authenticated,service_role;
grant execute on function private.get_my_mixed_points_earnings(),public.get_my_mixed_points_earnings()to authenticated;
commit;
