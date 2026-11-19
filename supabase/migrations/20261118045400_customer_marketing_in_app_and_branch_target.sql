begin;

-- Campaign history is independently visible in-app when the customer opted in,
-- even when push permission is disabled. This flag never implies FCM delivery.
alter table public.marketing_campaign_recipients
  add column if not exists in_app_visible boolean not null default false;
alter table public.marketing_campaign_recipients
  drop constraint if exists marketing_campaign_recipients_status_check;
alter table public.marketing_campaign_recipients
  add constraint marketing_campaign_recipients_status_check
  check(status in ('queued','sending','accepted','opened','failed','suppressed','in_app_only'));
alter table public.marketing_campaign_runs
  add column if not exists in_app_count integer not null default 0
  check(in_app_count >= 0);

create or replace function private.list_my_marketing_notifications()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor(); items jsonb; unread bigint;
begin
 if not exists(select 1 from public.customer_marketing_preferences p where p.customer_id=actor and p.marketing_in_app_enabled) then
   return jsonb_build_object('items','[]'::jsonb,'unread_count',0);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'recipient_id',r.recipient_id,'campaign_id',r.campaign_id,
   'title_ar',c.title,'body_ar',c.body,'title_en',coalesce(c.title_en,c.title),'body_en',coalesce(c.body_en,c.body),
   'image_url',c.image_url,'deep_link',c.deep_link,'created_at',r.created_at,
   'read',r.opened_at is not null,'opened_at',r.opened_at
 ) order by r.created_at desc,r.recipient_id desc),'[]'::jsonb),
 count(*) filter(where r.opened_at is null)
 into items,unread
 from public.marketing_campaign_recipients r
 join public.marketing_campaigns c using(campaign_id)
 where r.customer_id=actor and r.in_app_visible;
 return jsonb_build_object('items',items,'unread_count',coalesce(unread,0));
end$$;

create or replace function private.mark_my_marketing_notification_read(p_recipient uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor(); r public.marketing_campaign_recipients%rowtype; changed boolean;
begin
 if p_recipient is null then raise exception 'Notification required' using errcode='22023'; end if;
 perform private.app_inbox_actor();
 if not exists(select 1 from public.customer_marketing_preferences p where p.customer_id=actor and p.marketing_in_app_enabled) then
   raise exception 'Marketing inbox unavailable' using errcode='42501';
 end if;
 select * into r from public.marketing_campaign_recipients where recipient_id=p_recipient and customer_id=actor and in_app_visible for update;
 if not found then raise exception 'Notification unavailable' using errcode='42501'; end if;
 changed:=r.opened_at is null;
 if changed then
   update public.marketing_campaign_recipients set status='opened',opened_at=clock_timestamp() where recipient_id=p_recipient returning * into r;
   insert into public.marketing_campaign_events(campaign_id,run_id,recipient_id,customer_id,event_type)
   values(r.campaign_id,r.run_id,r.recipient_id,actor,'opened');
 end if;
 return jsonb_build_object('recipient_id',r.recipient_id,'read',true,'opened_at',r.opened_at,'changed',changed);
end$$;

-- A push tap can be recorded even when the customer opted out of the in-app
-- marketing list. Serialize opens and write one analytics event at most once.
create or replace function public.record_marketing_open(p_recipient_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); r public.marketing_campaign_recipients%rowtype;
begin
 if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select * into r from public.marketing_campaign_recipients
 where recipient_id=p_recipient_id and customer_id=actor for update;
 if not found or r.status not in ('accepted','opened') then
   raise exception 'Notification recipient not found' using errcode='42501';
 end if;
 if r.opened_at is null then
   update public.marketing_campaign_recipients set status='opened',opened_at=clock_timestamp()
    where recipient_id=p_recipient_id;
   insert into public.marketing_campaign_events(campaign_id,run_id,recipient_id,customer_id,event_type)
    values(r.campaign_id,r.run_id,r.recipient_id,actor,'opened');
   return true;
 end if;
 return false;
end$$;

-- Keep push acceptance separate from in-app inbox delivery in owner reports.
create or replace function public.finish_marketing_campaign_run_with_in_app(
 p_run_id uuid,p_status text,p_recipient_count integer,p_accepted_count integer,
 p_failed_count integer,p_in_app_count integer,p_error_message text default null
) returns void language plpgsql security definer set search_path=pg_catalog as $$
begin
 perform public.finish_marketing_campaign_run(
   p_run_id,p_status,p_recipient_count,p_accepted_count,p_failed_count,p_error_message
 );
 update public.marketing_campaign_runs
   set in_app_count=greatest(p_in_app_count,0)
   where run_id=p_run_id;
end$$;
revoke all on function public.finish_marketing_campaign_run_with_in_app(uuid,text,integer,integer,integer,integer,text) from public,anon,authenticated;
grant execute on function public.finish_marketing_campaign_run_with_in_app(uuid,text,integer,integer,integer,integer,text) to service_role;

revoke all on function private.list_my_marketing_notifications(),private.mark_my_marketing_notification_read(uuid) from public,anon,service_role;
grant execute on function private.list_my_marketing_notifications(),private.mark_my_marketing_notification_read(uuid) to authenticated;
create or replace function public.list_my_marketing_notifications()
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_my_marketing_notifications()$$;
create or replace function public.mark_my_marketing_notification_read(p_recipient uuid)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.mark_my_marketing_notification_read(p_recipient)$$;
revoke all on function public.list_my_marketing_notifications(),public.mark_my_marketing_notification_read(uuid) from public,anon,service_role;
grant execute on function public.list_my_marketing_notifications(),public.mark_my_marketing_notification_read(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
