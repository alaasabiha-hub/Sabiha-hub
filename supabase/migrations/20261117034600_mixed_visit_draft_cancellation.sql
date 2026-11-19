begin;
-- Frozen economic intent must be released before the cashier edits its subject
-- or quantities. Catalogue changes remain allowed and still invalidate the seal.
create function private.guard_mixed_visit_group_draft_state()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare draft uuid;begin
 select draft_id into draft from private.cashier_loyalty_draft_intents where request_id=new.intent_id;
 perform 1 from private.cashier_reviewed_drafts where draft_id=draft for update;
 if exists(select 1 from private.cashier_draft_cancellations where draft_id=draft)or exists(select 1 from private.cashier_invoice_postings where draft_id=draft)then raise exception 'Uncancelled unissued draft required for visit reservation'using errcode='40001';end if;
 if exists(select 1 from private.mixed_points_reservations where intent_id=new.intent_id and private.mixed_points_hold_live(request_id))then raise exception 'Recover or release current point reservation before selecting visits'using errcode='40001';end if;return new;end$$;
create trigger a_mixed_visit_group_economic_state before insert on private.mixed_visit_groups for each row execute function private.guard_mixed_visit_group_draft_state();
create function private.guard_visit_held_draft_changes()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.mixed_visit_groups g join private.cashier_loyalty_draft_intents i on i.request_id=g.intent_id where i.draft_id=old.draft_id and private.mixed_visit_group_holds(g.request_id))then raise exception 'Release current visit reservation before changing the reviewed draft or customer'using errcode='40001';end if;
 if tg_op='DELETE'then return old;end if;return new;end$$;
create trigger guard_visit_held_draft before update or delete on private.cashier_reviewed_drafts for each row execute function private.guard_visit_held_draft_changes();
create trigger guard_visit_held_subject before update or delete on private.cashier_draft_subjects for each row execute function private.guard_visit_held_draft_changes();
create function private.release_visits_for_cancelled_draft()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare g record;release_id uuid;begin
 for g in select v.request_id,v.actor_id from private.mixed_visit_groups v join private.cashier_loyalty_draft_intents i on i.request_id=v.intent_id where i.draft_id=new.draft_id and not exists(select 1 from private.mixed_visit_group_releases c where c.group_id=v.request_id)order by v.profile_id,v.request_id loop
 if g.actor_id<>new.actor_id then raise exception 'Draft cancellation and group actor mismatch'using errcode='55000';end if;
 -- Internal idempotency key only; never an Auth identity or a bearer credential.
 release_id:=md5('mixed-visit-draft-cancel:'||new.request_id::text||':'||g.request_id::text)::uuid;
 perform private.release_mixed_visit_components(release_id,g.request_id,'Draft cancellation: '||left(new.reason,350)||' ['||new.request_id::text||']');
 end loop;return new;end$$;
create trigger release_visits_after_draft_cancel after insert on private.cashier_draft_cancellations for each row execute function private.release_visits_for_cancelled_draft();
revoke all on function private.guard_mixed_visit_group_draft_state(),private.guard_visit_held_draft_changes(),private.release_visits_for_cancelled_draft()from public,anon,authenticated,service_role;
commit;
