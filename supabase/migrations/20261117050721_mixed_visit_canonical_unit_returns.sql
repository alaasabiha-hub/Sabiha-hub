begin;
create table private.mixed_visit_returned_units(group_id uuid not null,unit_number integer not null,source_id uuid not null,source_kind text not null check(source_kind in('credit','refund','full')),restore boolean not null,frozen_rule text not null check(frozen_rule in('restore_visits','forfeit_visits')),actor_id uuid not null references public.staff_profiles(user_id),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),primary key(group_id,unit_number),foreign key(group_id,unit_number)references private.mixed_visit_components(group_id,unit_number));
alter table private.mixed_visit_returned_units enable row level security;
revoke all on private.mixed_visit_returned_units from public,anon,authenticated,service_role;
create trigger immutable_visit_returns before update or delete on private.mixed_visit_returned_units for each row execute function private.immutable_loyalty_policy();
create or replace function private.mixed_visit_component_pinned(p_reservation uuid)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select exists(select 1 from private.mixed_visit_components c join private.mixed_visit_invoice_bindings b using(group_id)where c.reservation_id=p_reservation and not exists(select 1 from private.mixed_visit_returned_units u where u.group_id=c.group_id and u.unit_number=c.unit_number and u.restore))$$;
create function private.restore_mixed_visit_units(p_invoice text,p_source uuid,p_kind text)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare g private.mixed_visit_groups;part record;rule text;returned integer;begin
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 if p_kind='credit'then
 if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid cancellation required'using errcode='55000';end if;
 elsif p_kind='refund'then
 if not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.invoice_id=p_invoice and e.refund_part_id=f.request_id and e.event_type='refund'and e.amount=f.amount)))then raise exception 'Actual settled canonical partial refund required'using errcode='55000';end if;
 elsif p_kind='full'then
 if not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)or not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and payment_id=p_source and event_type='refund'and refund_part_id is null)then raise exception 'Actual canonical full refund required'using errcode='55000';end if;
 else raise exception 'Canonical return source required'using errcode='22023';end if;
 -- Frozen original policy per allocated component, never the latest owner terms.
 for part in select c.*,q.terms_snapshot from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.group_id=g.request_id and(p_kind='full'or p_kind='credit'and exists(select 1 from private.cashier_unpaid_service_credits k where k.request_id=p_source and k.invoice_id=p_invoice and k.line_id=g.line_id and k.unit_number=c.unit_number)or p_kind='refund'and exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=p_source and f.invoice_id=p_invoice and f.line_id=g.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[c.unit_number])else c.unit_number>(f.snapshot->>'previous_quantity')::integer and c.unit_number<=(f.snapshot->>'cumulative_quantity')::integer end)))order by c.unit_number loop
 rule:=part.terms_snapshot#>>'{rules,cancellation}';
 if rule is null or rule not in('restore_visits','forfeit_visits')then raise exception 'Explicit original cancellation policy required'using errcode='55000';end if;
 insert into private.mixed_visit_returned_units(group_id,unit_number,source_id,source_kind,restore,frozen_rule,actor_id,creator_xid)values(g.request_id,part.unit_number,p_source,p_kind,rule='restore_visits',rule,auth.uid(),txid_current())on conflict(group_id,unit_number)do nothing;
 get diagnostics returned=row_count;
 if returned=1 then
 if rule='restore_visits'then perform private.release_offline_reward_reservation(part.reservation_id,'Canonical mixed visit unit return: '||p_kind||':'||p_source);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'mixed_visit_unit_returned','business_invoices',p_invoice,g.branch_id,jsonb_build_object('group_id',g.request_id,'unit_number',part.unit_number,'source_id',p_source,'source_kind',p_kind,'frozen_rule',rule,'original_expiry_preserved',true));
 end if;
 end loop;
end$$;
create function private.mixed_visit_canonical_return_received()returns trigger language plpgsql volatile security definer set search_path=pg_catalog as $$declare event_row jsonb:=to_jsonb(new);begin
 if tg_table_name='cashier_unpaid_service_credits'then perform private.restore_mixed_visit_units(event_row->>'invoice_id',(event_row->>'request_id')::uuid,'credit');
 elsif tg_table_name='cashier_partial_refund_lines'then
 if exists(select 1 from private.cashier_partial_refunds f where f.request_id=(event_row->>'request_id')::uuid and f.amount=0)then perform private.restore_mixed_visit_units(event_row->>'invoice_id',(event_row->>'request_id')::uuid,'refund');end if;
 elsif event_row->>'event_type'='refund'then perform private.restore_mixed_visit_units(event_row->>'invoice_id',coalesce((event_row->>'refund_part_id')::uuid,(event_row->>'payment_id')::uuid),case when event_row->>'refund_part_id'is null then'full'else'refund'end);end if;return new;end$$;
create trigger visit_return_after_verified_refund after insert on public.business_payment_events for each row execute function private.mixed_visit_canonical_return_received();
create trigger visit_return_after_unpaid_credit after insert on private.cashier_unpaid_service_credits for each row execute function private.mixed_visit_canonical_return_received();
create constraint trigger visit_return_after_zero_refund after insert on private.cashier_partial_refund_lines deferrable initially deferred for each row execute function private.mixed_visit_canonical_return_received();
revoke all on function private.mixed_visit_component_pinned(uuid),private.restore_mixed_visit_units(text,uuid,text),private.mixed_visit_canonical_return_received()from public,anon,authenticated,service_role;
create or replace function private.check_mixed_visit_group_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g private.mixed_visit_groups;components bigint;held bigint;closed boolean;begin
 select *into g from private.mixed_visit_groups where request_id=new.request_id;
 select count(*)into components from private.mixed_visit_components where group_id=g.request_id;
 if components<>g.covered_units or g.creator_xid<>txid_current()then raise exception 'Atomic complete visit group required'using errcode='55000';end if;
 if exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id join private.service_reward_quotes q on q.quote_id=x.quote_id where x.group_id=g.request_id and(c.creator_xid<>g.creator_xid or c.quote_id<>x.quote_id or c.offline_profile_id<>g.profile_id or c.requested_by<>g.actor_id or q.offline_car_ref_id<>g.car_id or q.branch_id<>g.branch_id or q.rules_version_id<>g.rules_version_id or q.offline_channel_version_id<>g.channel_id))then raise exception 'Original typed component facts mismatch'using errcode='55000';end if;
 if g.quote#>>'{visit_reward,unit}'is distinct from'service_visits'or g.quote#>>'{visit_reward,covered_line}'is distinct from g.line_id or(g.quote#>>'{visit_reward,covered_units}')::numeric<>g.covered_units or(g.quote#>>'{visit_reward,required_visits}')::numeric<>g.required_visits
 or g.expires_at>(select min(q.expires_at)from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.group_id=g.request_id)
 or not exists(select 1 from private.cashier_loyalty_draft_intents i where i.request_id=g.intent_id and i.actor_id=g.actor_id and i.branch_id=g.branch_id and i.witness->>'subject_kind'='offline_profile'and(i.witness->>'subject')::uuid=g.profile_id and(i.witness->>'car')::uuid=g.car_id and i.expires_at>=g.expires_at)
 then raise exception 'Exact sealed coverage interval and expiry required'using errcode='55000';end if;
 select count(*)into held from private.reward_credit_claims h join private.mixed_visit_components c on c.reservation_id=h.reserve_request_id where c.group_id=g.request_id and h.released_at is null;
 closed:=exists(select 1 from private.mixed_visit_group_releases where group_id=g.request_id);
 if closed then
 if held<>0 or exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=g.request_id and c.state not in('released','expired','refunded'))then raise exception 'Closed group requires fully released canonical holds'using errcode='55000';end if;
 elsif exists(select 1 from private.mixed_visit_invoice_bindings where group_id=g.request_id)then
 if held<>g.required_visits-coalesce((select sum(q.threshold_visits)from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id join private.mixed_visit_returned_units u using(group_id,unit_number)where c.group_id=g.request_id and u.restore),0)
 or exists(select 1 from private.mixed_visit_components c join private.offline_reward_reservation_commands d on d.request_id=c.reservation_id where c.group_id=g.request_id and not exists(select 1 from private.mixed_visit_returned_units u where u.group_id=c.group_id and u.unit_number=c.unit_number and u.restore)and d.state<>'active')then raise exception 'Issued coverage requires pinned or canonically returned original components'using errcode='55000';end if;
 else
 if held<>g.required_visits or g.expires_at<=clock_timestamp()or exists(select 1 from private.mixed_visit_components x join private.offline_reward_reservation_commands c on c.request_id=x.reservation_id where x.group_id=g.request_id and c.state<>'active')then raise exception 'Exactly funded active visit group required'using errcode='55000';end if;
 end if;return null;end$$;
create or replace function private.lock_mixed_visit_backing(p_group uuid)returns void language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare g private.mixed_visit_groups;begin
 select *into strict g from private.mixed_visit_groups where request_id=p_group and actor_id=auth.uid();
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 -- Same lock order as canonical sync: profile, then actual source invoices.
 perform 1 from public.business_invoices i where exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id where c.group_id=p_group and h.released_at is null and e.invoice_id=i.invoice_id)order by i.invoice_id for update of i;
 if exists(select 1 from private.mixed_visit_components c join private.offline_reward_reservation_commands d on d.request_id=c.reservation_id where c.group_id=p_group and not exists(select 1 from private.mixed_visit_returned_units u where u.group_id=c.group_id and u.unit_number=c.unit_number and u.restore)and(d.state<>'active'or(select count(*)from private.reward_credit_claims h where h.reserve_request_id=c.reservation_id and h.released_at is null)<>(select threshold_visits from private.service_reward_quotes where quote_id=c.quote_id)))or exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id where c.group_id=p_group and h.released_at is null and(e.offline_profile_id is distinct from g.profile_id or private.reward_credit_refund(e.id)is not null or exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund')))then raise exception 'Original visit backing changed; canonical review/cancellation required'using errcode='55000';end if;
 if exists(select 1 from private.reward_refund_reviews v where v.offline_profile_id=g.profile_id and v.closed_at is null and not exists(select 1 from private.reward_credit_claims h where h.debt_id=v.review_id and h.released_at is null and private.reward_credit_refund(h.earning_id)is null))then raise exception 'Outstanding canonical source refund review required'using errcode='55000';end if;
end$$;
commit;
