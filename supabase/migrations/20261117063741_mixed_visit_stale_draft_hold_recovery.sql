begin;
-- Recover an older unissued held selection without disclosing its old customer.
CREATE OR REPLACE FUNCTION private.get_cashier_mixed_visits_context(p_branch uuid, p_draft uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;choice record;balance bigint;maximum bigint;options jsonb:='[]'::jsonb;docs jsonb:='[]'::jsonb;g private.mixed_visit_groups;hold jsonb;approval jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if private.active_staff_role()is distinct from'owner'then return jsonb_build_object('enabled',false,'scope','owner_pilot_only','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and actor_id=actor and branch_id=p_branch;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor;
 if d.draft_id is null then return jsonb_build_object('enabled',false,'state','absent','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 select x.*into g from private.mixed_visit_groups x join private.cashier_loyalty_draft_intents i on i.request_id=x.intent_id where i.draft_id=p_draft and x.actor_id=actor and x.branch_id=p_branch and not exists(select 1 from private.cashier_invoice_postings p where p.draft_id=p_draft)and not exists(select 1 from private.mixed_visit_group_releases z where z.group_id=x.request_id)and exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id where c.group_id=x.request_id and h.released_at is null)order by x.created_at desc limit 1;
 if g.request_id is not null and not exists(select 1 from private.cashier_loyalty_draft_intents i where i.request_id=g.intent_id and i.draft_version=d.version and i.binding_version=b.version and b.draft_version=d.version and b.subject_kind='offline_profile'and g.profile_id=b.subject_id and g.car_id=b.car_id)then
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Current visit allocator requires owner authority'using errcode='42501';end if;
 return jsonb_build_object('enabled',true,'redemption_enabled',false,'scope','owner_pilot_only','state','stale_hold_requires_release','draft_version',d.version,'binding_version',b.version,'hold',jsonb_build_object('group_id',g.request_id,'recovery_only',true,'reservation_live',false,'balance_reserved',true,'payment_confirmed',false),'approval',null,'options','[]'::jsonb,'documents','[]'::jsonb);
 end if;
 if d.draft_id is null or b.draft_id is null or b.draft_version<>d.version or b.subject_kind<>'offline_profile'then return jsonb_build_object('enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'state','offline_subject_required','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 if exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then return jsonb_build_object('enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'state','issued','options','[]'::jsonb,'documents','[]'::jsonb);end if;
 
 if g.request_id is not null then
 hold:=private.mixed_visit_group_snapshot(g.request_id)||jsonb_build_object('balance_reserved',true,'payment_confirmed',false,'verbal_notice_ar',private.mixed_visit_verbal_notice('ar',g.quote),'verbal_notice_en',private.mixed_visit_verbal_notice('en',g.quote));
 select jsonb_build_object('group_id',g.request_id,'consent_id',c.request_id)into approval from private.mixed_visit_verbal_consents c where c.group_id=g.request_id and coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false)and private.mixed_visit_verbal_current(c.request_id);
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',invoice_id,'number',display_number)order by invoice_id),'[]')into docs from(select distinct i.invoice_id,i.display_number from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id join private.canonical_loyalty_visits e on e.id=h.earning_id join public.business_invoices i on i.invoice_id=e.invoice_id where c.group_id=g.request_id and h.released_at is null)s;
 end if;
 for choice in select distinct on(r.rules_version_id,j->>'line_id')r.rules_version_id,c.version_id channel_id,p.version_id policy_id,j->>'line_id'line_id,(j->>'quantity')::bigint quantity,j->>'name'name,j->>'name_en'name_en,(r.terms_snapshot->>'threshold_visits')::bigint required_visits,(v.terms->>'maximum_covered_units')::bigint maximum_units
 from private.owner_mixed_visit_policy_current p join private.owner_mixed_visit_policy_versions v using(version_id)join private.loyalty_redemption_rule_versions r on r.rules_version_id=p.rules_version_id join private.offline_visit_channel_versions c on c.rules_version_id=r.rules_version_id and c.branch_id=p.branch_id and c.enabled join private.offline_visit_channel_activations a on a.channel_version_id=c.version_id cross join lateral jsonb_array_elements(d.quote->'lines')j
 where coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false)and p.branch_id=p_branch and v.terms->>'allow_walk_in'='true'and j->>'item_type'='service'and j->>'item_id'=r.terms_snapshot#>>'{reward_service,id}'
 order by r.rules_version_id,j->>'line_id',c.version_no desc loop
 if choice.required_visits<1 then continue;end if;
 if not private.offline_reward_debt_clear(b.subject_id,choice.rules_version_id)then continue;end if;
 select count(*)into balance from private.reward_owner_candidate_lots('offline_profile',b.subject_id,choice.rules_version_id,choice.channel_id);
 maximum:=least(div(balance,choice.required_visits)::bigint,choice.quantity,choice.maximum_units);
 if maximum>0 then options:=options||jsonb_build_array(jsonb_build_object('rules_id',choice.rules_version_id,'channel_id',choice.channel_id,'policy_id',choice.policy_id,'line_id',choice.line_id,'name',choice.name,'name_en',choice.name_en,'available_visits',balance,'threshold_visits',choice.required_visits,'maximum_units',maximum));end if;
 end loop;
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Current visit allocator requires owner authority'using errcode='42501';end if;
 return jsonb_build_object('enabled',hold is not null or coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'redemption_enabled',coalesce((select enabled from private.mixed_visit_pos_runtime where singleton),false),'scope','owner_pilot_only','state','ready','draft_version',d.version,'binding_version',b.version,'options',options,'documents',docs,'hold',hold,'approval',approval,'phone_is_not_identity_proof',true,'approval_method','cashier_attested_verbal');
end$function$;
CREATE OR REPLACE FUNCTION private.bind_mixed_visit_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;begin
 select *into a from private.mixed_visit_issue_authorizations where request_id=new.request_id;
 if not found then
 if new.quote?'visit_reward'or exists(select 1 from private.mixed_visit_groups existing_group join private.cashier_loyalty_draft_intents i on i.request_id=existing_group.intent_id where i.draft_id=new.draft_id and existing_group.actor_id=new.actor_id and existing_group.expires_at>clock_timestamp() and not exists(select 1 from private.mixed_visit_group_releases r where r.group_id=existing_group.request_id)and exists(select 1 from private.mixed_visit_components c join private.reward_credit_claims h on h.reserve_request_id=c.reservation_id where c.group_id=existing_group.request_id and h.released_at is null))then raise exception 'Visit quote requires atomic issuer authorization'using errcode='42501';end if;return new;end if;
 select *into strict g from private.mixed_visit_groups where request_id=a.group_id;
 if a.actor_id<>new.actor_id or a.creator_xid<>txid_current()or new.creator_xid<>txid_current()or new.branch_id<>g.branch_id or new.draft_id<>(select draft_id from private.cashier_loyalty_draft_intents where request_id=g.intent_id)or new.quote is distinct from(g.quote||jsonb_build_object('quote_only',false,'can_issue',true,'balance_reserved',true,'consent_authorized',true,'visit_reward_group_id',g.request_id,'visit_reward_consent_id',a.consent_id))then raise exception 'Exact atomic visit invoice binding required'using errcode='55000';end if;
 insert into private.mixed_visit_invoice_bindings(invoice_id,group_id,creator_xid)values(new.invoice_id,g.request_id,txid_current());return new;
end$function$;
commit;
