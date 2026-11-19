begin;

alter table private.admin_notification_events
 drop constraint admin_notification_events_template_code_check;
alter table private.admin_notification_events
 add constraint admin_notification_events_template_code_check check(template_code in
  ('booking_created','booking_changed','cashier_payment_review','cashier_order_review','inventory_zero',
   'expense_recorded','document_expiry','complaint_new','complaint_changed','review_new','recruitment_new',
   'payroll_approved','payroll_adjustment'));

create or replace function private.admin_notification_template(p_code text) returns jsonb
language plpgsql immutable set search_path=pg_catalog as $$
begin
 return case p_code
  when 'booking_created' then jsonb_build_object('title_ar','حجز جديد','title_en','New booking','body_ar','يوجد حجز جديد يحتاج مراجعة.','body_en','A new booking needs review.')
  when 'booking_changed' then jsonb_build_object('title_ar','تحديث حجز','title_en','Booking updated','body_ar','تغيرت حالة حجز وتحتاج المراجعة.','body_en','A booking status changed and needs review.')
  when 'cashier_payment_review' then jsonb_build_object('title_ar','فاتورة بانتظار التحصيل','title_en','Invoice awaiting collection','body_ar','توجد فاتورة تحتاج مراجعة أو تأكيد تحصيل من الكاشير.','body_en','An invoice needs cashier review or collection confirmation.')
  when 'cashier_order_review' then jsonb_build_object('title_ar','طلب يحتاج مراجعة الكاشير','title_en','Order needs cashier review','body_ar','يوجد طلب جديد أو تحديث يحتاج مراجعة الكاشير.','body_en','A new or updated order needs cashier review.')
  when 'inventory_zero' then jsonb_build_object('title_ar','نفاد مخزون','title_en','Stock depleted','body_ar','وصل مخزون أحد الأصناف إلى الصفر.','body_en','An item’s stock reached zero.')
  when 'expense_recorded' then jsonb_build_object('title_ar','مصروف جديد','title_en','Expense recorded','body_ar','تم تسجيل مصروف يحتاج مراجعة مالية.','body_en','An expense was recorded for financial review.')
  when 'document_expiry' then jsonb_build_object('title_ar','تنبيه مستند','title_en','Document alert','body_ar','يوجد مستند يحتاج متابعة بخصوص تاريخ الصلاحية.','body_en','A document expiry alert needs follow-up.')
  when 'complaint_new' then jsonb_build_object('title_ar','شكوى جديدة','title_en','New complaint','body_ar','وصلت شكوى جديدة تحتاج متابعة.','body_en','A new complaint needs follow-up.')
  when 'complaint_changed' then jsonb_build_object('title_ar','تحديث شكوى','title_en','Complaint updated','body_ar','تغيرت حالة شكوى تحتاج متابعة.','body_en','A complaint status changed and needs follow-up.')
  when 'review_new' then jsonb_build_object('title_ar','تقييم جديد','title_en','New review','body_ar','وصل تقييم جديد للخدمة.','body_en','A new service review was submitted.')
  when 'recruitment_new' then jsonb_build_object('title_ar','طلب توظيف جديد','title_en','New job application','body_ar','وصل طلب توظيف جديد يحتاج مراجعة.','body_en','A new job application needs review.')
  when 'payroll_approved' then jsonb_build_object('title_ar','تحديث رواتب','title_en','Payroll update','body_ar','تم اعتماد سجل رواتب جديد.','body_en','A payroll record was approved.')
  when 'payroll_adjustment' then jsonb_build_object('title_ar','تحديث مستحقات موظف','title_en','Employee compensation update','body_ar','تم تسجيل تعديل مستحقات يحتاج مراجعة المالك.','body_en','A compensation adjustment was recorded for owner review.')
  else null end;
end$$;

create or replace function private.list_admin_notifications(p_category text default null,p_unread_only boolean default false,p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.admin_notification_actor(); v_items jsonb; v_unread bigint; v_role text; v_permissions jsonb;
begin
 if p_limit is null or p_unread_only is null or p_limit not between 1 and 100 or (p_category is not null and p_category not in
  ('bookings','cashier','inventory','expenses','documents','complaints','reviews','recruitment','payroll')) then
   raise exception 'Valid notification filter required' using errcode='22023'; end if;
 select role,permissions into strict v_role,v_permissions from public.staff_profiles where user_id=v_actor and is_active;
 with visible as (
  select e.*, t->>'title_ar' title_ar,t->>'title_en' title_en,t->>'body_ar' body_ar,t->>'body_en' body_en,
   (r.event_id is not null) is_read,r.read_at
  from private.admin_notification_events e
  join private.admin_notification_settings s using(category)
  cross join lateral (select private.admin_notification_template(e.template_code) t) x
  left join private.admin_notification_reads r on r.event_id=e.event_id and r.actor_id=v_actor
  where s.enabled and (p_category is null or e.category=p_category)
   and ((v_role='owner' and s.recipient_roles @> array['owner']::text[])
     or (v_role='manager' and s.recipient_roles @> array['manager']::text[] and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
     or (v_role='employee' and s.recipient_roles @> array['employee']::text[] and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
     or (v_role in ('manager','employee') and coalesce(v_permissions->>'cashier','false')='true' and s.recipient_roles @> array['cashier']::text[] and e.category='cashier' and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id)))
   and (not p_unread_only or r.event_id is null)
 ), page as (select * from visible order by created_at desc,event_id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('event_id',event_id,'category',category,'template_code',template_code,'title_ar',title_ar,'title_en',title_en,'body_ar',body_ar,'body_en',body_en,'created_at',created_at,'branch_id',branch_id,'read',is_read,'read_at',read_at) order by created_at desc,event_id desc),'[]'::jsonb) into v_items from page;
 with allowed as (
  select e.event_id from private.admin_notification_events e join private.admin_notification_settings s using(category) where s.enabled and
   ((v_role='owner' and s.recipient_roles @> array['owner']::text[])
    or (v_role in ('manager','employee') and s.recipient_roles @> array[v_role]::text[] and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id))
    or (v_role in ('manager','employee') and coalesce(v_permissions->>'cashier','false')='true' and s.recipient_roles @> array['cashier']::text[] and e.category='cashier' and e.branch_id is not null and exists(select 1 from public.staff_branch_access a where a.user_id=v_actor and a.branch_id=e.branch_id)))
 ) select count(*) into v_unread from allowed a where not exists(select 1 from private.admin_notification_reads r where r.event_id=a.event_id and r.actor_id=v_actor);
 return jsonb_build_object('items',v_items,'unread_count',v_unread,'push_enabled',false);
end$$;

create or replace function private.admin_notification_source_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare v_id uuid; v_branch uuid; v_revision text; v_category text; v_template text;
begin
 if tg_table_name='bookings' then
  v_id:=new.id;v_branch:=new.branch_id;
  if tg_op='INSERT' then v_category:='bookings';v_template:='booking_created';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_category:='bookings';v_template:='booking_changed';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new;end if;
 elsif tg_table_name='business_orders' then
  v_id:=new.order_id;v_branch:=new.branch_id;v_category:='cashier';
  if tg_op='INSERT' then v_template:='cashier_order_review';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_template:='cashier_order_review';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new;end if;
 elsif tg_table_name='cashier_invoice_postings' then
  v_id:=new.request_id;v_branch:=new.branch_id;v_category:='cashier';v_template:='cashier_payment_review';v_revision:='issued:'||new.created_at::text;
 elsif tg_table_name='business_inventory_movements' then
  if new.after_quantity>0 then return new;end if;v_id:=new.movement_id;v_branch:=new.branch_id;v_category:='inventory';v_template:='inventory_zero';v_revision:='zero:'||new.after_quantity::text;
 elsif tg_table_name='business_expenses' then
  v_id:=new.expense_id;v_branch:=new.branch_id;v_category:='expenses';v_template:='expense_recorded';v_revision:='created:'||new.created_at::text;
 elsif tg_table_name='business_document_alerts' then
  v_id:=new.alert_id;v_category:='documents';v_template:='document_expiry';v_revision:='alert:'||new.alert_date::text||':'||new.days_before_expiry::text;
 elsif tg_table_name='customer_complaints' then
  v_id:=new.complaint_id;v_branch:=new.branch_id;v_category:='complaints';
  if tg_op='INSERT' then v_template:='complaint_new';v_revision:='created:'||new.created_at::text;
  elsif new.status is distinct from old.status then v_template:='complaint_changed';v_revision:='status:'||old.status||'>'||new.status||':'||txid_current()::text;
  else return new;end if;
 elsif tg_table_name='employee_service_reviews' then
  v_id:=new.review_id;v_branch:=new.branch_id;v_category:='reviews';v_template:='review_new';v_revision:='created:'||new.created_at::text;
 elsif tg_table_name='recruitment_applications' then
  v_id:=new.id;v_category:='recruitment';v_template:='recruitment_new';v_revision:='submitted:'||new.submitted_at::text;
  select branch_id into v_branch from private.recruitment_jobs where id=new.job_id;
 elsif tg_table_name='hr_payroll' then
  v_id:=new.id;v_category:='payroll';v_template:='payroll_approved';v_revision:='approved:'||new.approved_at::text;
 elsif tg_table_name='hr_adjustment' then
  v_id:=new.id;v_category:='payroll';v_template:='payroll_adjustment';v_revision:='adjustment:'||new.created_by::text||':'||new.on_date::text;
 else raise exception 'Unsupported notification source' using errcode='22023';end if;
 perform private.emit_admin_notification(v_category,v_template,tg_table_name,v_id,v_revision,v_branch);
 return new;
end$$;

commit;
