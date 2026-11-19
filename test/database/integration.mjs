import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const here=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(here,'../..');
const db=new PGlite({extensions:{pgcrypto}});
await db.exec('create schema extensions; create extension pgcrypto with schema extensions;');
await db.exec(fs.readFileSync(path.join(here,'bootstrap.sql'),'utf8'));
await db.exec(fs.readFileSync(path.join(here,'streamlit_business_schema.sql'),'utf8'));
// Supabase Cloud gives postgres-owned public objects schema-specific API
// defaults. Mirror those defaults so the privilege-hardening migration is
// tested against the same anonymous/authenticated grants as hosted QA.
await db.exec(`alter default privileges for role postgres in schema public revoke execute on functions from public;
alter default privileges for role postgres in schema public grant all on tables to anon,authenticated,service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon,authenticated,service_role;
alter default privileges for role postgres in schema public grant execute on functions to anon,authenticated,service_role;`);
// PGlite does not load Supabase's pg_cron extension. This local-only catalog
// stub lets migrations validate their scheduler registration gates; it never
// executes scheduled jobs and is not evidence of a real cron run.
await db.exec(`create schema cron;
create table cron.job(
 jobid bigint generated always as identity primary key,
 schedule text not null, command text not null, nodename text not null default 'localhost',
 nodeport integer not null default 5432, database text not null, username text not null,
 active boolean not null default true, jobname text unique
);
create table cron.job_run_details(
 jobid bigint not null, runid bigint generated always as identity primary key,
 command text, database text, username text, status text,
 start_time timestamptz, end_time timestamptz
);
create function cron.schedule(text,text,text) returns bigint
language plpgsql as $$declare id bigint; begin
 insert into cron.job(schedule,command,database,username,jobname)
 values($2,$3,current_database(),current_user,$1) returning jobid into id;
 return id;
end$$;
select set_config('cron.log_run','on',false);`);
// Supabase-managed Realtime is also absent from PGlite. Keep only the catalog
// surface required by migration guards; this stub does not deliver messages.
await db.exec(`create schema realtime;
create table realtime.messages(extension text not null,topic text not null);
alter table realtime.messages enable row level security;
create function realtime.topic() returns text language sql stable
 as $$select current_setting('realtime.topic',true)$$;
create function realtime.send(jsonb,text,text,boolean) returns void
 language plpgsql as $$begin return; end$$;
grant select,insert on realtime.messages to anon,authenticated;
grant execute on function realtime.topic() to anon,authenticated;
grant execute on function realtime.send(jsonb,text,text,boolean) to service_role;`);
for(const file of fs.readdirSync(`${root}/supabase/migrations`).sort()) {
 const sql=fs.readFileSync(`${root}/supabase/migrations/${file}`,'utf8');
 try {await db.exec(sql); console.log('PASS migration',file);} catch(e) {console.error('FAIL migration',file,e.message); process.exit(1);}
}

let passed=0;
async function test(name,run){ try { await run(); passed++; console.log('PASS',name); } catch(e) { console.error('FAIL',name,e.message); await db.close(); process.exit(1); } }
async function rows(sql,args=[]){return (await db.query(sql,args)).rows;}
async function scalar(sql,args=[]){return Object.values((await rows(sql,args))[0])[0];}
await test('anonymous role has no direct writes to public tables or internal money RPCs',async()=>{
 assert.equal(Number(await scalar("select count(*) from information_schema.table_privileges where table_schema='public' and grantee='anon' and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')")),0);
 assert.equal(Number(await scalar("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='S' and (has_sequence_privilege('anon',c.oid,'USAGE') or has_sequence_privilege('anon',c.oid,'SELECT') or has_sequence_privilege('anon',c.oid,'UPDATE'))")),0,'anon must not receive sequence access');
 for(const fn of ['finalize_service_loyalty(uuid,uuid,text)','reverse_service_loyalty(uuid,uuid,text)','restore_cancelled_product_order_stock()']){
  const allowed=await scalar('select has_function_privilege(\'anon\',$1,\'execute\')',[`public.${fn}`]);
  assert.equal(allowed,false,`${fn} must not be callable by anon`);
 }
 assert.equal(await scalar("select has_function_privilege('authenticated','public.place_customer_product_order(jsonb,uuid,text)','execute')"),true);
});
await test('future public objects default closed to anon and public execution',async()=>{
 await db.exec('create table public._qa_future_acl_probe(id integer); create function public._qa_future_acl_probe() returns integer language sql as $$select 1$$');
 assert.equal(await scalar("select has_table_privilege('anon','public._qa_future_acl_probe','insert')"),false,'future table insert must not be granted to anon');
 assert.equal(await scalar("select has_function_privilege('anon','public._qa_future_acl_probe()','execute')"),false,'future RPC execute must not be granted to anon');
 assert.equal(await scalar("select not exists(select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a where p.oid='public._qa_future_acl_probe()'::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE')"),true,'future RPC execute must not be granted to PUBLIC');
 await db.exec('drop function public._qa_future_acl_probe(); drop table public._qa_future_acl_probe');
 await db.exec('create sequence public._qa_future_acl_sequence');
 assert.equal(await scalar("select has_sequence_privilege('anon','public._qa_future_acl_sequence','USAGE')"),false,'future sequence usage must not be granted to anon');
 await db.exec('drop sequence public._qa_future_acl_sequence');
});
async function identity(id='',role='postgres') {
  await db.exec('reset role');
  const session=sessionFor.get(id);
  if(role!=='postgres'&&id&&session) await db.query('insert into auth.sessions(id,user_id) values($1,$2) on conflict(id) do update set not_after=null',[session,id]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
  await db.query("select set_config('request.jwt.claim.role',$1,false)",[role]);
  await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:id,role,...(session?{session_id:session}:{})})]);
  if(role!=='postgres') await db.exec(`set role ${role}`);
}
const alice='00000000-0000-4000-8000-000000000001';
const bob='00000000-0000-4000-8000-000000000002';
const owner='00000000-0000-4000-8000-000000000003';
const employee='00000000-0000-4000-8000-000000000004';
const product='00000000-0000-4000-8000-000000000010';
const service='00000000-0000-4000-8000-000000000011';
const vehicle='00000000-0000-4000-8000-000000000020';
const request='00000000-0000-4000-8000-000000000030';
const bookingRequest='00000000-0000-4000-8000-000000000031';
const sessionFor=new Map([
 [alice,'00000000-0000-4000-8000-000000000101'],
 [bob,'00000000-0000-4000-8000-000000000102'],
 [owner,'00000000-0000-4000-8000-000000000103'],
 [employee,'00000000-0000-4000-8000-000000000104'],
]);
await db.exec(`insert into auth.users values ('${alice}'),('${bob}'),('${owner}'),('${employee}');
update auth.users set email_confirmed_at=clock_timestamp();
insert into public.customers(id,full_name,phone,email) values('${alice}','Alice','LOCAL-ALICE','alice@example.test'),('${bob}','Bob','LOCAL-BOB','bob@example.test');
insert into public.staff_profiles(user_id,full_name,role) values('${owner}','Owner','owner'),('${employee}','Technician','employee');
insert into public.vehicles(id,customer_id,brand,model,plate_number) values('${vehicle}','${alice}','Test','Car','LOCAL-1');
insert into public.business_catalog_items(item_id,item_type,name,price,stock_quantity) values('${product}','product','Test product',100,10),('${service}','service','Test wash',150,null);
insert into public.business_coupons(code,title,discount_type,discount_value) values('LOCAL10','Local coupon','percentage',10);`);
await db.exec('insert into staff_branch_access(user_id,branch_id) select user_id,default_branch_id() from staff_profiles');
const cart=[{item_id:product,quantity:2}];
await identity(alice,'authenticated');
await test('customer only sees own profile',async()=>assert.equal(await scalar('select count(*) from customers'),1));
let customerBooking;
await test('catalog booking snapshots server price',async()=> {
 const [result]=await rows('select public.place_customer_service_booking($1,$2,default_branch_id(),$3,current_date+1,\'10:00\'::time,$4,null) as result',[bookingRequest,service,vehicle,150]);
 customerBooking=result.result;
 assert.equal(Number(customerBooking.quoted_price),150);
 assert.equal(Number(await scalar('select quoted_price from bookings where id=$1',[customerBooking.booking_id])),150);
});
await test('cannot book another customer vehicle',async()=>{
 await identity(bob,'authenticated');
 await assert.rejects(()=>db.query('select public.place_customer_service_booking($1,$2,default_branch_id(),$3,current_date+2,\'10:00\'::time,$4,null)',[bookingRequest,service,vehicle,150]),/Vehicle ownership required/);
 await identity(alice,'authenticated');
});
await test('coupon preview calculates server total',async()=>{
 const value=await scalar('select preview_customer_coupon($1,$2::jsonb)',['LOCAL10',JSON.stringify(cart)]);
 assert.equal(value.total_after_discount,180);
});
let placed;
await test('checkout atomically reserves stock and coupon',async()=>{
 [placed]=await rows('select * from place_customer_product_order($1::jsonb,$2,null,$3)',[JSON.stringify(cart),request,'LOCAL10']);
 assert.equal(Number(placed.total),180);
});
await test('checkout retry returns same order',async()=>{
 const [retry]=await rows('select * from place_customer_product_order($1::jsonb,$2,null,$3)',[JSON.stringify(cart),request,'LOCAL10']);
 assert.equal(retry.order_id,placed.order_id);
 assert.equal(Number(retry.total),180);
});
await test('another customer cannot read order or invoice',async()=>{
 await identity(bob,'authenticated');
 assert.equal(await scalar('select count(*) from business_orders'),0);
 assert.equal(await scalar('select count(*) from business_order_items'),0);
 assert.equal(await scalar('select count(*) from business_invoices'),0);
});
await test('customers cannot change work status',async()=> {
 assert.equal((await rows("update business_orders set status='delivered' where order_id=$1 returning order_id",[placed.order_id])).length,0);
});
await identity('', 'postgres');
await test('stock changed exactly once',async()=>assert.equal(await scalar('select stock_quantity from business_catalog_items where item_id=$1',[product]),8));
await test('cancellation restores stock once',async()=>{
 await db.query("update business_orders set status='cancelled' where order_id=$1",[placed.order_id]);
 await db.query("update business_orders set status='cancelled' where order_id=$1",[placed.order_id]);
 assert.equal(await scalar('select stock_quantity from business_catalog_items where item_id=$1',[product]),10);
});
await test('private documents not readable by customer',async()=>{
 await db.exec("insert into business_documents(category,title,original_filename,mime_type,storage_path) values('Tax / VAT','Local tax','local.pdf','application/pdf','local/local.pdf')");
 await identity(alice,'authenticated');
 assert.equal(await scalar('select count(*) from business_documents'),0);
});
await test('private documents readable by owner',async()=>{
 await identity(owner,'authenticated');
 assert.equal(await scalar('select count(*) from business_documents'),1);
});
await test('customer cannot invoke service loyalty',async()=>{
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query('select * from finalize_service_loyalty($1,$2,$3)',[alice,placed.order_id,'x']),/permission denied/);
});
await identity('','postgres');
await test('no legacy reward is seeded; visit earning and refund remain idempotent',async()=>{
 let fourth;
 for(let i=1;i<=4;i++){
  const id=await scalar("insert into business_orders(order_number,customer_id,service_name,status) values($1,$2,'Wash','completed') returning order_id",['WASH-'+i,alice]);
  await db.query("insert into business_invoices(invoice_id,order_id,service_name,total) values($1,$2,'Wash',150)",['INV-'+i,id]);
  const [result]=await rows('select * from finalize_service_loyalty($1,$2,$3)',[alice,id,'INV-'+i]);
  assert.equal(result.reward_applied,false);
  assert.equal(Number(result.points_balance),0);
  const [retry]=await rows('select * from finalize_service_loyalty($1,$2,$3)',[alice,id,'INV-'+i]);
  assert.equal(retry.reward_applied,false);
  if(i===4) fourth=id;
 }
 assert.equal(Number(await scalar("select total from business_invoices where invoice_id='INV-4'")),150);
 assert.equal(Number(await scalar('select coalesce(sum(points),0) from business_loyalty_transactions where customer_id=$1',[alice])),0);
 await db.exec("update business_invoices set status='refunded' where invoice_id='INV-4'");
 await rows('select * from reverse_service_loyalty($1,$2,$3)',[alice,fourth,'INV-4']);
 await rows('select * from reverse_service_loyalty($1,$2,$3)',[alice,fourth,'INV-4']);
 assert.equal(Number(await scalar('select coalesce(sum(points),0) from business_loyalty_transactions where customer_id=$1',[alice])),0);
});
await test('cancelled orders cannot be reopened or stock reserved twice',async()=>{
 await assert.rejects(()=>db.query("update business_orders set status='received' where order_id=$1",[placed.order_id]),/Invalid order status transition/);
});
await test('retry with a different cart is rejected',async()=>{
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query('select * from place_customer_product_order($1::jsonb,$2,null,$3)',[JSON.stringify([{item_id:product,quantity:1}]),request,'LOCAL10']),/different cart/);
 await identity('','postgres');
});
await test('assigned employee cannot skip work stages or start before appointment day',async()=>{
 await db.exec("update bookings set assigned_workers='[\"Technician\"]'::jsonb, status='confirmed'");
 await identity(employee,'authenticated');
 assert.equal(await scalar('select count(*) from bookings'),1);
 await assert.rejects(()=>db.exec("update bookings set status='completed'"),/Invalid booking status transition/);
 await assert.rejects(()=>db.exec("update bookings set status='in_progress'"),/service day|appointment|management review/i);
 await identity('','postgres');
});
await test('ad consent required and frequency enforced',async()=>{
 await db.query("insert into business_product_ads(item_id,title,description,starts_at,frequency_days) values($1,'Local ad','Test description',now()-interval '1 day',7)",[product]);
 await identity(alice,'authenticated');
 assert.equal((await rows('select * from claim_customer_product_ad()')).length,0);
 await db.query('insert into customer_marketing_preferences(customer_id,marketing_in_app_enabled) values($1,true)',[alice]);
 assert.equal((await rows('select * from claim_customer_product_ad()')).length,1);
 assert.equal((await rows('select * from claim_customer_product_ad()')).length,0);
});
await identity('','postgres');
await test('expiry alert claim is not repeated while sending',async()=>{
 await db.exec('update business_documents set expires_at=current_date+7');
 const alerts=await rows('select * from claim_due_business_document_alerts()');
 assert.ok(alerts.length>0);
 assert.equal((await rows('select * from claim_due_business_document_alerts()')).length,0);
 for(const alert of alerts) await db.query('select finish_business_document_alert($1,true)',[alert.alert_id]);
 assert.equal((await rows('select * from claim_due_business_document_alerts()')).length,0);
});
await test('marketing claim runs only once and finishes without sending a push',async()=>{
 await db.exec("insert into marketing_campaigns(title,body,scheduled_at,next_scheduled_at,status) values('Local campaign','Local test only',now()-interval '1 minute',now()-interval '1 minute','scheduled')");
 const runs=await rows('select * from claim_due_marketing_campaigns()');
 assert.equal(runs.length,1);
 assert.equal((await rows('select * from claim_due_marketing_campaigns()')).length,0);
 await db.query("select finish_marketing_campaign_run($1,'sent',0,0,0,null)",[runs[0].run_id]);
 assert.equal(await scalar('select status from marketing_campaigns'),'sent');
});
await test('duplicate document bytes cannot create a second record',async()=>{
 const digest='a'.repeat(64);
 await db.query("update business_documents set content_sha256=$1",[digest]);
 await assert.rejects(()=>db.query("insert into business_documents(category,title,original_filename,mime_type,storage_path,content_sha256) values('Other','Duplicate','duplicate.pdf','application/pdf','local/duplicate.pdf',$1)",[digest]),/unique constraint/);
});
await test('owner report rejects customer and employee identities',async()=>{
 for(const user of [alice,employee]) {
  await identity(user,'authenticated');
  await assert.rejects(()=>db.query("select get_owner_report(current_date,current_date)"),/owner access required/i);
 }
 await identity('','postgres');
});
await test('owner report aggregates active invoices and expenses without double-counting refunds',async()=>{
 await db.exec("insert into business_expenses(category,amount) values('local-test',25)");
 const [expected]=await rows(`select
  coalesce(sum(total) filter(where status='active'),0) sales,
  coalesce(sum(total) filter(where status='refunded'),0) refunded,
  coalesce(sum(commission_total) filter(where status='active'),0) commissions
  from business_invoices
  where issued_at>=current_date::timestamp at time zone 'Africa/Cairo'
    and issued_at<(current_date+1)::timestamp at time zone 'Africa/Cairo'`);
 await identity(owner,'authenticated');
 const report=await scalar('select get_owner_report(current_date,current_date)');
 assert.equal(Number(report.sales),Number(expected.sales));
 assert.equal(Number(report.refunded_total),Number(expected.refunded));
 assert.equal(Number(report.expenses),25);
 assert.equal(Number(report.net_before_tax),Number(expected.sales)-Number(expected.commissions)-25);
 await identity('','postgres');
});
await test('same-name employees cannot inherit another account assignment',async()=>{
 const other='00000000-0000-4000-8000-000000000088';
 await db.query('insert into auth.users values($1)',[other]);
 await db.query('update auth.users set email_confirmed_at=clock_timestamp() where id=$1',[other]);
 await db.query("insert into staff_profiles(user_id,full_name,role) values($1,'Technician','employee')",[other]);
 sessionFor.set(other,'00000000-0000-4000-8000-000000000108');
 await identity(other,'authenticated');
 assert.equal(await scalar('select count(*) from bookings'),0);
 await identity('','postgres');
});
await test('employee cannot reassign tasks or promote own account',async()=>{
 await identity(employee,'authenticated');
 await assert.rejects(()=>db.query("update staff_profiles set role='owner' where user_id=$1",[employee]),/permission denied/);
 assert.equal(await scalar('select role from staff_profiles where user_id=$1',[employee]),'employee');
 // RLS rejects employee attempts to reassign a booking, including terminal rows.
 await assert.rejects(()=>db.query('update bookings set assigned_staff_ids=$1 returning id',[[employee]]),/row-level security|new row violates/i);
 await identity('','postgres');
});
const zone='00000000-0000-4000-8000-000000000090';
let delivery,pickup;
const deliveryCart=JSON.stringify([{item_id:product,quantity:1}]);
await test('delivery settings enforce owner role and international support phone',async()=>{
 await identity(alice,'authenticated');
 assert.equal((await rows('update business_contact_delivery_settings set delivery_enabled=true returning id')).length,0);
 await assert.rejects(()=>db.query("insert into business_delivery_zones(name,fee) values('Forbidden',1)"),/row-level security/);
 await identity(owner,'authenticated');
 await assert.rejects(()=>db.exec("update business_contact_delivery_settings set whatsapp_enabled=true,whatsapp_phone='01234'"),/check constraint/);
 await db.exec("update business_contact_delivery_settings set delivery_enabled=false,minimum_subtotal=50");
 await db.query('insert into business_delivery_zones(zone_id,name,fee) values($1,\'Local test zone\',25)',[zone]);
});
await test('disabled delivery and unsupported areas are blocked on server',async()=>{
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query("select quote_product_fulfillment($1,'delivery',$2,null)",[deliveryCart,zone]),/disabled/);
 await identity(owner,'authenticated');await db.exec('update business_contact_delivery_settings set delivery_enabled=true');
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query("select quote_product_fulfillment($1,'delivery',null,null)",[deliveryCart]),/outside/);
});
await test('server calculates delivery fee and coupon separately',async()=>{
 await identity('','postgres');await db.exec('update business_catalog_items set stock_quantity=20');
 await identity(alice,'authenticated');
 const q=await scalar("select quote_product_fulfillment($1,'delivery',$2,'LOCAL10')",[deliveryCart,zone]);
 assert.equal(q.total,115);assert.equal(q.subtotal,100);assert.equal(q.discount,10);assert.equal(q.delivery_fee,25);
 await assert.rejects(()=>db.query("select place_product_fulfillment($1,gen_random_uuid(),'delivery',$2,'Local address building 1','+201000000001',null,'LOCAL10',1)",[deliveryCart,zone]),/Price changed/);
 delivery=await scalar("select place_product_fulfillment($1,gen_random_uuid(),'delivery',$2,'Local address building 1','+201000000001',null,'LOCAL10',115)",[deliveryCart,zone]);
 assert.equal(Number(delivery.total),115);
});
await test('fulfillment isolates address and notifications and prevents client writes',async()=>{
 await identity(bob,'authenticated');assert.equal(await scalar('select count(*) from business_order_fulfillments'),0);assert.equal(await scalar('select count(*) from customer_order_notifications'),0);
 await assert.rejects(()=>db.query("select update_product_fulfillment($1,'new','cancelled',null)",[delivery.order_id]),/access denied/);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("update business_order_fulfillments set delivery_fee=0 where order_id=$1",[delivery.order_id]),/permission denied/);
});
await test('courier assignment and transitions synchronize order and invoice once',async()=>{
 await identity(owner,'authenticated');
 await db.query("select update_product_fulfillment($1,'new','confirmed',$2)",[delivery.order_id,employee]);
 await assert.rejects(()=>db.query("select update_product_fulfillment($1,'confirmed','delivered',$2)",[delivery.order_id,employee]),/Invalid fulfillment transition/);
 await db.query("select update_product_fulfillment($1,'confirmed','preparing',$2)",[delivery.order_id,employee]);
 await identity(employee,'authenticated');
 await db.query("select update_product_fulfillment($1,'preparing','out_for_delivery',$2)",[delivery.order_id,employee]);
 await db.query("select update_product_fulfillment($1,'out_for_delivery','delivered',$2)",[delivery.order_id,employee]);
 await identity(owner,'authenticated');
 await db.query("select update_product_fulfillment($1,'delivered','delivered',$2)",[delivery.order_id,employee]);
 assert.equal(Number(await scalar('select total from business_invoices where order_id=$1',[delivery.order_id])),115);
 assert.equal(await scalar('select count(*) from business_invoices where order_id=$1',[delivery.order_id]),1);
 await assert.rejects(()=>db.query("select update_product_fulfillment($1,'delivered','cancelled',$2)",[delivery.order_id,employee]),/Invalid fulfillment transition/);
 await identity('','postgres');assert.equal(await scalar('select count(*) from customer_order_notifications where order_id=$1',[delivery.order_id]),5);
});
await test('pickup is free and cancellation restores stock once with stable retries',async()=>{
 await identity(alice,'authenticated');
 const id='00000000-0000-4000-8000-000000000091';
 pickup=await scalar("select place_product_fulfillment($1,$2,'pickup',null,null,null,'Local pickup',null,100)",[deliveryCart,id]);
 const retry=await scalar("select place_product_fulfillment($1,$2,'pickup',null,null,null,'Local pickup',null,100)",[deliveryCart,id]);assert.equal(retry.order_id,pickup.order_id);
 await assert.rejects(()=>db.query("select place_product_fulfillment($1,$2,'pickup',null,null,null,'Changed',null,100)",[deliveryCart,id]),/different delivery details/);
 await db.query("select update_product_fulfillment($1,'new','cancelled',null)",[pickup.order_id]);
 await identity(owner,'authenticated');await db.query("select update_product_fulfillment($1,'cancelled','cancelled',null)",[pickup.order_id]);
 await identity('','postgres');assert.equal(await scalar('select stock_quantity from business_catalog_items where item_id=$1',[product]),19);
});
await test('delivery minimum and inactive zones cannot be bypassed',async()=>{
 await identity(owner,'authenticated');await db.exec('update business_contact_delivery_settings set minimum_subtotal=500');
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select quote_product_fulfillment($1,'delivery',$2,null)",[deliveryCart,zone]),/minimum/);
 await identity(owner,'authenticated');await db.query('update business_delivery_zones set is_active=false where zone_id=$1',[zone]);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select quote_product_fulfillment($1,'delivery',$2,null)",[deliveryCart,zone]),/outside/);
 await identity('','postgres');
});

let branch2,branchService,branchProduct;
const branchManager='00000000-0000-4000-8000-000000000092';
await test('owner creates a branch with independent hours and zero-stock price copies',async()=>{
 await identity(owner,'authenticated');[branch2]=await rows("insert into business_branches(name_ar,name_en,delivery_enabled) values('فرع تجريبي','Test branch',true) returning *");
 assert.equal(await scalar('select count(*) from business_branch_hours where branch_id=$1',[branch2.branch_id]),7);
 await db.query('select copy_branch_prices(default_branch_id(),$1)',[branch2.branch_id]);
 branchProduct=(await rows('select item_id,price,stock_quantity from business_catalog_items where branch_id=$1 and catalog_key=$2',[branch2.branch_id,await scalar('select catalog_key from business_catalog_items where item_id=$1',[product])]))[0];
 branchService=(await rows('select item_id,price,stock_quantity from business_catalog_items where branch_id=$1 and catalog_key=$2',[branch2.branch_id,await scalar('select catalog_key from business_catalog_items where item_id=$1',[service])]))[0];
 assert.equal(branchProduct.stock_quantity,0);
 await db.query('update business_catalog_items set price=225 where item_id=$1',[branchService.item_id]);
 assert.equal(Number(await scalar('select price from business_catalog_items where item_id=$1',[service])),150);
});
await test('branch manager price permission is explicit and branch-scoped',async()=>{
 await identity('','postgres');await db.query('insert into auth.users values($1)',[branchManager]);await db.query('update auth.users set email_confirmed_at=clock_timestamp() where id=$1',[branchManager]);sessionFor.set(branchManager,'00000000-0000-4000-8000-000000000109');await db.query("insert into staff_profiles(user_id,full_name,role) values($1,'Branch manager','manager')",[branchManager]);
 await identity(owner,'authenticated');await db.query('insert into staff_branch_access(user_id,branch_id) values($1,$2)',[branchManager,branch2.branch_id]);
 await identity(branchManager,'authenticated');assert.equal((await rows('update business_catalog_items set price=230 where item_id=$1 returning item_id',[branchService.item_id])).length,0);
 await identity(owner,'authenticated');assert.equal(await scalar('select private.has_live_invoice_session()'),true);assert.equal(await scalar('select private.active_staff_role()'),'owner');await db.query('update staff_branch_access set can_edit_prices=true where user_id=$1',[branchManager]);
 await identity(branchManager,'authenticated');await db.query('update business_catalog_items set price=230 where item_id=$1',[branchService.item_id]);
 await assert.rejects(()=>db.query("insert into business_catalog_items(branch_id,name,item_type,price,stock_quantity) values($1,'Unauthorized stock','product',1,999)",[branch2.branch_id]),/row-level security|owner session required/i);
 assert.equal((await rows('update business_catalog_items set price=1 where item_id=$1 returning item_id',[service])).length,0);
});
await test('branch stock transfer is atomic idempotent and does not copy stock with prices',async()=>{
 await identity(owner,'authenticated');const id='00000000-0000-4000-8000-000000000093';
 await db.query('select transfer_branch_stock($1,$2,$3,2,\'Local stock move\')',[id,product,branchProduct.item_id]);
 await db.query('select transfer_branch_stock($1,$2,$3,2,\'Local stock move\')',[id,product,branchProduct.item_id]);
 assert.equal(await scalar('select stock_quantity from business_catalog_items where item_id=$1',[branchProduct.item_id]),2);
 await assert.rejects(()=>db.query('select transfer_branch_stock($1,$2,$3,3,\'Local stock move\')',[id,product,branchProduct.item_id]),/already used/);
 await db.query('select copy_branch_prices(default_branch_id(),$1)',[branch2.branch_id]);assert.equal(await scalar('select stock_quantity from business_catalog_items where item_id=$1',[branchProduct.item_id]),2);
});
let branchBooking;
await test('branch booking snapshots its price and manager cannot read another branch',async()=>{
 await identity(alice,'authenticated');branchBooking=await scalar("select public.place_customer_service_booking(gen_random_uuid(),$1,$2,$3,current_date+10,'10:00'::time,$4,null)",[branchService.item_id,branch2.branch_id,vehicle,150]);
 assert.equal(Number(branchBooking.quoted_price),150); // price copy restored the source's current 150, not old invoices
 await identity(branchManager,'authenticated');assert.equal(await scalar('select count(*) from bookings where branch_id<>$1',[branch2.branch_id]),0);
 await identity(owner,'authenticated');await db.query('update business_catalog_items set price=300 where item_id=$1',[branchService.item_id]);
 await identity(alice,'authenticated');assert.equal(Number(await scalar('select quoted_price from bookings where id=$1',[branchBooking.booking_id])),150);
});
await test('database blocks closing hours holidays temporary closure and foreign branch service',async()=>{
 await identity(alice,'authenticated');
 const insert=(time='08:00')=>db.query("select public.place_customer_service_booking(gen_random_uuid(),$1,$2,$3,current_date+11,$4::time,300,null)",[branchService.item_id,branch2.branch_id,vehicle,time]);
 await assert.rejects(()=>insert(),/outside opening/);
 await identity(owner,'authenticated');await db.query("insert into business_branch_exceptions(branch_id,exception_date,reason) values($1,current_date+11,'Local closure')",[branch2.branch_id]);
 await identity(alice,'authenticated');await assert.rejects(()=>insert('10:00'),/closed on this date/);
 await identity(owner,'authenticated');await db.query('delete from business_branch_exceptions where branch_id=$1',[branch2.branch_id]);await db.query('update business_branches set temporarily_closed=true where branch_id=$1',[branch2.branch_id]);
 await identity(alice,'authenticated');await assert.rejects(()=>insert('10:00'),/Branch is closed/);
 await identity(owner,'authenticated');await db.query('update business_branches set temporarily_closed=false where branch_id=$1',[branch2.branch_id]);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select public.place_customer_service_booking(gen_random_uuid(),$1,default_branch_id(),$2,current_date+11,'10:00'::time,300,null)",[branchService.item_id,vehicle]),/Published branch service required/);
});
await test('capacity is enforced in database and cancellation releases its resource',async()=>{
 await identity(owner,'authenticated');await db.query("update business_branch_resources set capacity=1 where branch_id=$1 and resource_key='wash'",[branch2.branch_id]);
 await identity(alice,'authenticated');
 const insert=()=>db.query("select public.place_customer_service_booking(gen_random_uuid(),$1,$2,$3,current_date+12,'12:00'::time,300,null)",[branchService.item_id,branch2.branch_id,vehicle]);
 const first=(await insert()).rows[0].place_customer_service_booking;await assert.rejects(insert,/capacity reached/);
 await identity(owner,'authenticated');await db.query("update bookings set status='cancelled' where id=$1",[first.booking_id]);
 await identity(alice,'authenticated');await insert();
 await identity('','postgres');
});
await test('audit log is owner-readable and cannot be forged by authenticated users',async()=>{
 await identity(owner,'authenticated');assert.ok(await scalar('select count(*) from business_audit_log')>0);
 await assert.rejects(()=>db.exec("insert into business_audit_log(actor,action,entity) values('fake','fake','fake')"),/permission denied/);
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from business_audit_log'),0);
 await identity('','postgres');
});

let review,complaint;
// A narrowly scoped local fixture supplies a pre-existing completed visit for
// review/inspection read tests; it is never used to prove earning or payment.
await identity('','postgres');
const completedBooking=await scalar("insert into bookings(customer_id,vehicle_id,catalog_item_id,branch_id,service_name,booking_date,booking_time,status,assigned_staff_ids,quoted_price) values($1,$2,$3,default_branch_id(),'Local completed fixture',current_date+30,'10:00','completed',array[$4::uuid],150) returning id",[alice,vehicle,service,employee]);
await test('reviews require own completed service and an assigned employee',async()=>{
 await identity(bob,'authenticated');await assert.rejects(()=>db.query('select save_service_review($1,$2,5,\'Fake\')',[completedBooking,employee]),/Only rate staff/);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query('select save_service_review($1,$2,5,\'Too early\')',[branchBooking.id,employee]),/Only rate staff/);
 await assert.rejects(()=>db.query('select save_service_review($1,$2,5,\'Wrong employee\')',[completedBooking,owner]),/Only rate staff/);
 review=await scalar('select save_service_review($1,$2,4,\'Good service\')',[completedBooking,employee]);
 const retry=await scalar('select save_service_review($1,$2,5,\'Edited review\')',[completedBooking,employee]);assert.equal(review,retry);
 assert.equal(await scalar('select count(*) from employee_service_reviews'),1);
});
await test('public rating averages are real and moderation never changes stars',async()=>{
 await identity(owner,'authenticated');await db.query("select manage_employee_profile($1,'Local employee','Technician',default_branch_id(),true,null,false)",[employee]);
 let directory=await scalar('select employee_directory(null)');assert.equal(directory[0].average_stars,5);assert.equal(directory[0].review_count,1);assert.equal(directory[0].comments.length,0);assert.equal(directory[0].photo_path,null);
 await db.query("select moderate_service_review($1,true,'Reviewed for publication')",[review]);directory=await scalar('select employee_directory(null)');assert.equal(directory[0].comments.length,1);
 await db.query("select moderate_service_review($1,false,'Hidden after moderation')",[review]);directory=await scalar('select employee_directory(null)');assert.equal(directory[0].comments.length,0);assert.equal(directory[0].average_stars,5);
 assert.ok(!JSON.stringify(directory).includes('customer_id'));assert.ok(!JSON.stringify(directory).includes('phone'));
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select moderate_service_review($1,true,'Unauthorized')",[review]),/Owner/);
});
await test('complaints are idempotent and bound to the customer visit',async()=>{
 await identity(bob,'authenticated');await assert.rejects(()=>db.query("select create_customer_complaint(gen_random_uuid(),$1,null,'Not my visit complaint')",[completedBooking]),/not yours/);
 await identity(alice,'authenticated');const request='00000000-0000-4000-8000-000000000099';
 complaint=await scalar("select create_customer_complaint($1,$2,null,'Local test complaint details')",[request,completedBooking]);
 const retry=await scalar("select create_customer_complaint($1,$2,null,'Local test complaint details')",[request,completedBooking]);assert.equal(complaint.complaint_id,retry.complaint_id);
 await identity(bob,'authenticated');assert.equal(await scalar('select count(*) from customer_complaints'),0);assert.equal(await scalar('select count(*) from customer_complaint_events'),0);
 await identity(branchManager,'authenticated');await assert.rejects(()=>db.query("select update_customer_complaint($1,'new','under_review',null,'Cross branch note',false)",[complaint.complaint_id]),/denied/);
});
await test('complaint status events keep internal notes private',async()=>{
 await identity(owner,'authenticated');await db.query("select update_customer_complaint($1,'new','under_review',$2,'Internal management note',true)",[complaint.complaint_id,employee]);
 await db.query("select update_customer_complaint($1,'under_review','in_progress',$2,'Working on the complaint',false)",[complaint.complaint_id,employee]);
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from customer_complaint_events'),2);
 assert.equal(await scalar("select count(*) from customer_complaint_events where note='Internal management note'"),0);
 await assert.rejects(()=>db.query("update customer_complaints set status='closed' where complaint_id=$1",[complaint.complaint_id]),/permission denied/);
 await identity(owner,'authenticated');assert.equal(await scalar('select count(*) from customer_complaint_events'),3);
});
await test('private attachment and approved employee photo policies isolate originals',async()=>{
 const path=alice+'/'+complaint.complaint_id+'/local.png';
 await identity(alice,'authenticated');await db.query("insert into storage.objects(bucket_id,name) values('complaint-files',$1)",[path]);
 await identity(bob,'authenticated');assert.equal(await scalar("select count(*) from storage.objects where bucket_id='complaint-files'"),0);
 await identity(owner,'authenticated');assert.equal(await scalar("select count(*) from storage.objects where bucket_id='complaint-files'"),1);
 const photo=employee+'/local.png';await db.query("insert into storage.objects(bucket_id,name) values('staff-photos',$1)",[photo]);
 await db.query("select manage_employee_profile($1,'Local employee','Technician',default_branch_id(),true,$2,true)",[employee,photo]);
 await identity(alice,'authenticated');assert.equal(await scalar("select count(*) from storage.objects where bucket_id='staff-photos'"),1);
 await identity('','postgres');
});

const shiftRequest='00000000-0000-4000-8000-000000000110';
await identity('','postgres');await db.exec("insert into business_invoices(invoice_id,service_name,total) values('SHIFT-CASH','Synthetic',100),('SHIFT-ELECTRONIC','Synthetic',50)");
await test('shift opening requires branch cashier permission and is idempotent',async()=>{
 await identity(alice,'authenticated');await assert.rejects(()=>db.query('select open_cashier_shift($1,default_branch_id(),100)',[shiftRequest]),/permission/);
 await identity(employee,'authenticated');await assert.rejects(()=>db.query('select open_cashier_shift($1,default_branch_id(),100)',[shiftRequest]),/permission/);
 await identity(owner,'authenticated');assert.equal(await scalar('select open_cashier_shift($1,default_branch_id(),100)',[shiftRequest]),shiftRequest);
 assert.equal(await scalar('select open_cashier_shift($1,default_branch_id(),100)',[shiftRequest]),shiftRequest);
});
await test('invoice payments are computed server-side and recorded once',async()=>{
 await identity(owner,'authenticated');const request='00000000-0000-4000-8000-000000000111';
 const first=await scalar("select record_shift_payment($1,$2,'SHIFT-CASH','sale','cash')",[request,shiftRequest]);
 const retry=await scalar("select record_shift_payment(gen_random_uuid(),$1,'SHIFT-CASH','sale','cash')",[shiftRequest]);assert.equal(first,retry);
 await assert.rejects(()=>db.query("select record_shift_payment(gen_random_uuid(),$1,'SHIFT-ELECTRONIC','sale','electronic')",[shiftRequest]),/verified gateway confirmation|manual recording is unavailable/i);
 assert.equal(await scalar('select count(*) from business_payment_events where shift_id=$1',[shiftRequest]),1);
 await identity('','postgres');await assert.rejects(()=>db.exec("update business_invoices set total=200 where invoice_id='SHIFT-CASH'"),/immutable/);
});
await test('shift refunds and expenses preserve expected cash and shared reports',async()=>{
 await identity(owner,'authenticated');await db.query("select record_shift_payment(gen_random_uuid(),$1,'SHIFT-CASH','refund','cash')",[shiftRequest]);
 const request='00000000-0000-4000-8000-000000000112';await db.query("select record_shift_movement($1,$2,'expense',10,'Synthetic expense')",[request,shiftRequest]);await db.query("select record_shift_movement($1,$2,'expense',10,'Synthetic expense')",[request,shiftRequest]);
 await db.query("select record_shift_movement(gen_random_uuid(),$1,'deposit',5,'Synthetic deposit')",[shiftRequest]);
 const t=await scalar('select cashier_shift_totals($1)',[shiftRequest]);assert.equal(t.cash_payments_net,0);assert.equal(t.electronic_payments_net,0);assert.equal(t.expected_cash,95);
 await identity('','postgres');assert.equal(await scalar("select count(*) from business_expenses where category='SHIFT-'||$1::text",[request]),1);
});
await test('shift closing requires difference explanation and seals further mutations',async()=>{
 await identity(owner,'authenticated');await assert.rejects(()=>db.query("select close_cashier_shift($1,90,'')",[shiftRequest]),/explanation/);
 const t=await scalar("select close_cashier_shift($1,90,'Synthetic cash difference')",[shiftRequest]);assert.equal(t.difference,-5);
 await assert.rejects(()=>db.query("select record_shift_movement(gen_random_uuid(),$1,'deposit',5,'Late cash deposit')",[shiftRequest]),/sealed/);
 await assert.rejects(()=>db.query('update business_cashier_shifts set actual_cash=95 where shift_id=$1',[shiftRequest]),/permission denied/);
});
await test('owner approves shifts and customers cannot read cash ledgers',async()=>{
 await identity(employee,'authenticated');await assert.rejects(()=>db.query('select approve_cashier_shift($1)',[shiftRequest]),/Owner approval/);
 await identity(owner,'authenticated');await db.query('select approve_cashier_shift($1)',[shiftRequest]);assert.equal(await scalar('select status from business_cashier_shifts where shift_id=$1',[shiftRequest]),'closed');
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from business_cashier_shifts'),0);assert.equal(await scalar('select count(*) from business_payment_events'),0);
 await identity('','postgres');
});

let beforeInspection,afterInspection;
await test('only assigned staff can create versioned vehicle inspection drafts',async()=>{
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select begin_vehicle_inspection($1,'before')",[completedBooking]),/permission/);
 await identity(branchManager,'authenticated');await assert.rejects(()=>db.query("select begin_vehicle_inspection($1,'before')",[completedBooking]),/permission/);
 await identity(owner,'authenticated');beforeInspection=await scalar("select begin_vehicle_inspection($1,'before')",[completedBooking]);
 assert.equal(await scalar("select begin_vehicle_inspection($1,'before')",[completedBooking]),beforeInspection);
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from vehicle_inspections'),0);
});
async function inspectionMedia(id){
 for(const kind of ['front','back','left','right','interior']){
  const path=id+'/'+kind+'/synthetic.png';await db.query("insert into storage.objects(bucket_id,name) values('vehicle-inspections',$1)",[path]);await db.query('select register_inspection_media($1,$2,$3,null)',[id,kind,path]);
 }
}
await test('inspection approval requires five views and signature or documented inability',async()=>{
 await identity(owner,'authenticated');let version=await scalar('select version from vehicle_inspections where inspection_id=$1',[beforeInspection]);
 await db.query("select save_vehicle_inspection($1,$2,'Local notes','Synthetic vehicle condition',1000,'[]',false,null)",[beforeInspection,version]);
 version=await scalar('select version from vehicle_inspections where inspection_id=$1',[beforeInspection]);await assert.rejects(()=>db.query('select approve_vehicle_inspection($1,$2)',[beforeInspection,version]),/images required/);
 await inspectionMedia(beforeInspection);version=await scalar('select version from vehicle_inspections where inspection_id=$1',[beforeInspection]);await assert.rejects(()=>db.query('select approve_vehicle_inspection($1,$2)',[beforeInspection,version]),/signature or documented/);
 await db.query("select save_vehicle_inspection($1,$2,'Local notes','Synthetic vehicle condition',1000,'[]',false,'Synthetic signature unavailable')",[beforeInspection,version]);
 version=await scalar('select version from vehicle_inspections where inspection_id=$1',[beforeInspection]);await db.query('select approve_vehicle_inspection($1,$2)',[beforeInspection,version]);
});
await test('customer sees only own approved inspection photos and notes',async()=>{
 await identity(bob,'authenticated');assert.equal(await scalar('select count(*) from vehicle_inspections'),0);assert.equal(await scalar("select count(*) from storage.objects where bucket_id='vehicle-inspections'"),0);
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from vehicle_inspections'),1);assert.equal(await scalar("select count(*) from storage.objects where bucket_id='vehicle-inspections'"),5);
 assert.equal((await rows("delete from storage.objects where bucket_id='vehicle-inspections' returning id")).length,0);
 await identity('','postgres');await assert.rejects(()=>db.query("update vehicle_inspections set notes='Silent edit' where inspection_id=$1",[beforeInspection]),/immutable/);
});
await test('approved inspection amendment preserves original and requires owner reason',async()=>{
 await identity(employee,'authenticated');await assert.rejects(()=>db.query("select begin_vehicle_inspection($1,'before',$2,'Local amendment reason')",[completedBooking,beforeInspection]),/Owner/);
 await identity(owner,'authenticated');const revision=await scalar("select begin_vehicle_inspection($1,'before',$2,'Local amendment reason')",[completedBooking,beforeInspection]);
 assert.equal(await scalar('select revision from vehicle_inspections where inspection_id=$1',[revision]),2);assert.equal(await scalar('select count(*) from vehicle_inspection_media where inspection_id=$1',[revision]),5);
 assert.equal(await scalar('select notes from vehicle_inspections where inspection_id=$1',[beforeInspection]),'Local notes');
 afterInspection=await scalar("select begin_vehicle_inspection($1,'after')",[completedBooking]);await inspectionMedia(afterInspection);
 let version=await scalar('select version from vehicle_inspections where inspection_id=$1',[afterInspection]);
 await db.query("select save_vehicle_inspection($1,$2,'After notes','Synthetic finished condition',1001,'[]',false,'Synthetic signature unavailable')",[afterInspection,version]);version=await scalar('select version from vehicle_inspections where inspection_id=$1',[afterInspection]);await db.query('select approve_vehicle_inspection($1,$2)',[afterInspection,version]);
 await identity(alice,'authenticated');assert.equal(await scalar('select count(*) from vehicle_inspections'),2);
});
await test('branch can require approved before and after reports before service completion',async()=>{
 await identity(alice,'authenticated');const slot=await scalar("select slot_time from public.available_booking_slots($1,$2,current_date) where slot_time>(clock_timestamp() at time zone 'Africa/Cairo')::time order by slot_time limit 1",[branch2.branch_id,branchService.item_id]);assert.ok(slot);
 await db.query("select public.change_customer_booking(gen_random_uuid(),$1,'reschedule',current_date,$2)",[branchBooking.booking_id,slot]);
 await identity(owner,'authenticated');await db.query('update business_branches set inspection_required=true where branch_id=$1',[branch2.branch_id]);
 await db.query("update bookings set status='confirmed' where id=$1",[branchBooking.booking_id]);await db.query("update bookings set status='in_progress' where id=$1",[branchBooking.booking_id]);
 await assert.rejects(()=>db.query("update bookings set status='completed' where id=$1",[branchBooking.booking_id]),/before and after inspections/);
 await identity('','postgres');
});

await test('anonymous homepage exposes published data only, without ledger or staff fields',async()=>{
 await identity('','postgres');await db.query("insert into business_catalog_items(item_type,name,price,is_public) values('product','Private catalog secret',99,false)");
 await identity('','anon');const home=await scalar('select get_public_home()');
 assert(home.branches.length>0);assert(!JSON.stringify(home).includes('Private catalog secret'));
 for(const c of home.catalog){assert(!('stock_quantity' in c));assert(!('commission_value' in c));}
 await assert.rejects(()=>db.query('select * from business_payment_events'),/permission denied/);
 await assert.rejects(()=>db.query('select * from customers'),/permission denied/);
 await identity('','postgres');
});
await test('inspected booking identity cannot be moved to a different customer',async()=>{
 await identity('','postgres');await assert.rejects(()=>db.query('update bookings set customer_id=$1 where id=$2',[bob,completedBooking]),/inspect|vehicle|customer/i);
});


let invoiceToken,printJob,printPrinter;
await test('invoice QR identity is stable and resolving requires the customer or branch cashier',async()=>{
 await identity('','postgres');
 const order=(await rows("insert into business_orders(order_number,service_name,customer_id) values('QR-TEST','QR service',$1) returning order_id",[alice]))[0];
 await db.query("insert into business_invoices(invoice_id,order_id,service_name,total) values('QR-INV',$1,'QR service',123)",[order.order_id]);
 invoiceToken=await scalar("select document_token from business_invoices where invoice_id='QR-INV'");
 await identity(bob,'authenticated');await assert.rejects(()=>db.query('select resolve_invoice_document($1)',[invoiceToken]),/unavailable|authorized/);
 await identity('','anon');await assert.rejects(()=>db.query('select resolve_invoice_document($1)',[invoiceToken]),/permission denied/);
 await identity(alice,'authenticated');const doc=await scalar('select resolve_invoice_document($1)',[invoiceToken]);assert.equal(doc.invoice_id,'QR-INV');assert.equal(doc.payment_status,'unpaid');assert.equal(doc.snapshot.total,123);assert(!('customer_phone' in doc));
 await identity(owner,'authenticated');await db.query("select set_invoice_link('QR-INV',false)");
 await identity(alice,'authenticated');await assert.rejects(()=>db.query('select resolve_invoice_document($1)',[invoiceToken]),/unavailable/);
 await identity(owner,'authenticated');await db.query("select set_invoice_link('QR-INV',true)");assert.equal((await scalar('select resolve_invoice_document($1)',[invoiceToken])).document_token,invoiceToken);
});
await test('automatic print outbox is generated once after committed payment and never charges on retry',async()=>{
 await identity(owner,'authenticated');
 printPrinter=(await rows("insert into business_printers(branch_id,name,paper,transport,is_default,auto_print) values(default_branch_id(),'Mock printer','80','system',true,true) returning printer_id"))[0].printer_id;
 const shift=await scalar('select open_cashier_shift(gen_random_uuid(),default_branch_id(),0)');
 const payment=await scalar("select record_shift_payment(gen_random_uuid(),$1,'QR-INV','sale','cash')",[shift]);
 await db.query("select record_shift_payment($1,$2,'QR-INV','sale','cash')",[payment,shift]);
 assert.equal(await scalar("select count(*) from business_print_jobs where invoice_id='QR-INV'"),1);
 printJob=await scalar("select job_id from business_print_jobs where invoice_id='QR-INV'");
 const lease=await scalar('select claim_invoice_print($1)',[printJob]);assert.equal(lease.invoice.payment_status,'paid');assert.equal(lease.is_reprint,false);
 await assert.rejects(()=>db.query('select claim_invoice_print($1)',[printJob]),/leased/);
 await db.query("select finish_invoice_print($1,$2,'failed','printer_offline')",[printJob,lease.lease_token]);
 const retry=await scalar('select claim_invoice_print($1)',[printJob]);assert.equal(retry.is_reprint,true);assert.equal(retry.invoice.document_token,invoiceToken);
 await assert.rejects(()=>db.query("select finish_invoice_print($1,$2,'submitted',null)",[printJob,lease.lease_token]),/lease invalid/);
 await db.query("select finish_invoice_print($1,$2,'submitted',null)",[printJob,retry.lease_token]);
 assert.equal(await scalar("select count(*) from business_payment_events where invoice_id='QR-INV' and event_type='sale'"),1);
 assert.equal(await scalar('select count(*) from business_print_attempts where job_id=$1',[printJob]),2);
 const manual=await scalar("select request_invoice_print(gen_random_uuid(),'QR-INV',$1)",[printPrinter]);assert.equal(await scalar('select is_reprint from business_print_jobs where job_id=$1',[manual]),true);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select request_invoice_print(gen_random_uuid(),'QR-INV',$1)",[printPrinter]),/Cashier/);
 await identity('','postgres');await assert.rejects(()=>db.query("update business_invoices set document_token=gen_random_uuid() where invoice_id='QR-INV'"),/immutable/);
});
await test('an issued QR retains its original origin after the owner changes the website setting',async()=>{
 await identity(owner,'authenticated');await db.query("update business_invoice_portal_settings set public_origin='https://first.example.test' where id");
 const first=await scalar('select resolve_invoice_document($1)',[invoiceToken]);assert.equal(first.portal_origin,'https://first.example.test');
 await db.query("update business_invoice_portal_settings set public_origin='https://second.example.test' where id");
 assert.equal((await scalar('select resolve_invoice_document($1)',[invoiceToken])).portal_origin,first.portal_origin);
});
await test('overall invoice review requires the actual customer and a completed linked booking',async()=>{
 await identity('','postgres');
 const order=(await rows("insert into business_orders(order_number,service_name,customer_id,booking_id) values('SERVICE-REVIEW','Review service',$1,$2) returning order_id",[alice,completedBooking]))[0];
 await db.query("insert into business_invoices(invoice_id,order_id,service_name,total) values('SERVICE-REVIEW',$1,'Review service',150)",[order.order_id]);
 const token=await scalar("select document_token from business_invoices where invoice_id='SERVICE-REVIEW'");
 await identity(bob,'authenticated');await assert.rejects(()=>db.query("select save_invoice_service_review($1,5,'Fake')",[token]),/unavailable|authorized/);
 await identity(alice,'authenticated');const review=await scalar("select save_invoice_service_review($1,4,'Verified service')",[token]);
 assert.equal(await scalar("select save_invoice_service_review($1,5,'Edited once')",[token]),review);assert.equal(await scalar('select count(*) from completed_service_reviews'),1);
 await identity(owner,'authenticated');await db.query("select moderate_invoice_service_review($1,false,'Hide abusive comment only')",[review]);assert.equal(await scalar('select stars from completed_service_reviews where review_id=$1',[review]),5);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select save_invoice_service_review($1,5,'Not completed')",[invoiceToken]),/completed/);
});
await test('sales window separates invoice cohort from cash events and preserves unknown taxes',async()=>{
 await identity('','postgres');
 await db.query("insert into business_invoices(invoice_id,service_name,total,discount,issued_at) values('WINDOW-A','Window test',150,20,'2026-01-10 10:00+02'),('WINDOW-END','Boundary',999,0,'2026-01-10 11:00+02'),('WINDOW-R','Refunded',40,0,'2026-01-10 10:30+02')");
 await db.query("update business_invoices set status='refunded' where invoice_id='WINDOW-R'");
 await identity(owner,'authenticated');
 const r=await scalar("select get_owner_sales_window('2026-01-10 10:00','2026-01-10 11:00')");
 assert.equal(r.net_billed,150);assert.equal(r.discounts,20);assert.equal(r.billed_before_discount,170);
 assert.equal(r.invoice_count,1);assert.equal(r.refunded_invoice_value,40);assert.equal(r.tax_missing_count,1);
 assert.equal(r.taxes,null);assert.equal(r.actual_profit,null);assert.equal(r.gross_sales_ex_tax,null);
 assert.equal(r.uncollected_recorded,150);assert.equal(r.cash_activity.transaction_count,0);
 assert.equal(r.hourly.length,24);assert.equal(r.hourly[10].net_billed,150);
 const empty=await scalar("select get_owner_sales_window('2001-01-01','2001-01-02')");assert.equal(empty.net_billed,0);assert.equal(empty.taxes,0);
 await assert.rejects(()=>db.query("select get_owner_sales_window('2026-01-02','2026-01-01')"),/valid window/);
 await assert.rejects(()=>db.query("select get_owner_sales_window('2026-04-24 00:30','2026-04-24 03:00')"),/Cairo time/);
 await identity(alice,'authenticated');await assert.rejects(()=>db.query("select get_owner_sales_window('2026-01-10','2026-01-11')"),/owner/);
 await identity(employee,'authenticated');await assert.rejects(()=>db.query("select get_owner_sales_window('2026-01-10','2026-01-11')"),/owner/);
});
await test('sales window isolates branches and cash events outside the issued invoice cohort',async()=>{
 await identity('','postgres');
 await db.query("insert into business_invoices(invoice_id,service_name,total,branch_id,issued_at) values('WINDOW-BRANCH','Branch isolated',80,$1,'2026-01-10 10:10+02')",[branch2.branch_id]);
 const shift=await scalar("insert into business_cashier_shifts(shift_id,branch_id,cashier_id,opening_cash,status) values(gen_random_uuid(),default_branch_id(),$1,0,'closed') returning shift_id",[owner]);
 await db.query("insert into business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id,created_at) values(gen_random_uuid(),$1,'WINDOW-END','sale','cash',999,$2,'2026-01-10 10:15+02')",[shift,owner]);
 await identity(owner,'authenticated');
 const all=await scalar("select get_owner_sales_window('2026-01-10 10:00','2026-01-10 11:00')");
 const branch=await scalar("select get_owner_sales_window('2026-01-10 10:00','2026-01-10 11:00',$1)",[branch2.branch_id]);
 assert.equal(all.net_billed,230);assert.equal(all.cash_activity.collections,999);assert.equal(all.cash_activity.transaction_count,1);
 assert.equal(branch.net_billed,80);assert.equal(branch.cash_activity.collections,0);assert.equal(branch.invoice_count,1);
 await assert.rejects(()=>db.query("select get_owner_sales_window('2026-01-10','2026-01-11',gen_random_uuid())"),/Unknown branch/);
});
await test('hourly completed visits use verified service-end time rather than invoice issue time',async()=>{
 await identity(owner,'postgres');
 const booking=(await rows('select id,branch_id,resource_key,duration_minutes from bookings where id=$1',[completedBooking]))[0];
 const start='2026-01-10 12:05:00+02';const finish='2026-01-10 12:45:00+02';
 await db.exec('begin');
 const startEvent=await scalar("insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,action,payload,occurred_at,creator_xid) values(gen_random_uuid(),gen_random_uuid(),$1,'booking',$2,'start','{}', $3,txid_current()) returning event_id",[owner,completedBooking,start]);
 const span=await scalar("insert into private.service_resource_spans(span_id,source_kind,booking_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id) values(gen_random_uuid(),'booking',$1,$2,$3,$4,$5::timestamptz,$5::timestamptz+make_interval(mins=>$4::integer),$6) returning span_id",[completedBooking,booking.branch_id,booking.resource_key,booking.duration_minutes,start,startEvent]);
 const endEvent=await scalar("insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,action,payload,occurred_at,creator_xid) values(gen_random_uuid(),gen_random_uuid(),$1,'booking',$2,'complete','{}',$3,txid_current()) returning event_id",[owner,completedBooking,finish]);
 await db.query('update private.service_resource_spans set ended_at=$2,end_event_id=$3 where span_id=$1',[span,finish,endEvent]);
 await db.exec('commit');
 await identity(owner,'authenticated');
 const response=await scalar("select get_admin_console('2026-01-10 12:00','2026-01-10 13:00')");
 assert.equal(response.report.hourly.length,24);
 assert.equal(response.report.hourly[12].completed_service_visits,1);
 assert.equal(response.report.hourly[11].completed_service_visits,0);
 assert.equal(response.report.hourly[12].net_billed,0,'no invoice is required to count a verified completed wash');
 await identity(employee,'authenticated');
 const assigned=await scalar("select get_admin_console('2026-01-10 12:00','2026-01-10 13:00')");
 assert.equal(assigned.financial,false);
 assert.equal(assigned.report,null,'non-financial employee cannot see the hourly financial report');
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query("select get_admin_console('2026-01-10 10:00','2026-01-10 11:00')"),/Active staff access required/);
});
await test('daily close waits for approved shifts, snapshots accounting, and only permits append-only corrections',async()=>{
 const day=await scalar("select current_date-2");
 await identity(owner,'postgres');
 const shift=await scalar("insert into business_cashier_shifts(shift_id,branch_id,cashier_id,opening_cash,status,opened_at,closed_at,expected_cash,actual_cash,difference,difference_reason,approved_by,approved_at) values(gen_random_uuid(),default_branch_id(),$1,50,'closed',$2::date::timestamp+'08:00',$2::date::timestamp+'17:00',100,98,-2,'Counted till was short',$1,clock_timestamp()) returning shift_id",[owner,day]);
 await db.query("insert into business_invoices(invoice_id,service_name,total,branch_id,issued_at) values('DAY-CLOSE-INV','Daily close fixture',100,default_branch_id(),$1::date::timestamp+'12:00')",[day]);
 await db.query("insert into business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id,created_at) values(gen_random_uuid(),$1,'DAY-CLOSE-INV','sale','cash',100,$2,$3::date::timestamp+'12:30')",[shift,owner,day]);
 await db.query("insert into business_expenses(branch_id,expense_date,category,amount,note,created_by) values(default_branch_id(),$1,'QA-DAY-CLOSE',10,'Local close fixture',$2::text)",[day,owner]);
 const request='00000000-0000-4000-8000-000000000901';
 await identity(owner,'authenticated');
 const pending=await scalar('select prepare_branch_daily_close($1,default_branch_id(),$2)',[request,day]);
 assert.equal(pending.status,'awaiting_approval');assert.equal(pending.snapshot.report.net_billed,100);
 assert.equal(pending.snapshot.payment_activity.cash_collected,100);assert.equal(pending.snapshot.expenses.total,10);
 assert.equal(pending.snapshot.report.actual_profit,null);assert.equal(pending.snapshot.shift_reconciliation.length,1);
 assert.equal(pending.snapshot.shift_reconciliation[0].difference,-2);
 assert.equal((await scalar('select prepare_branch_daily_close($1,default_branch_id(),$2)',[request,day])).close_id,pending.close_id);
 await assert.rejects(()=>db.query('select prepare_branch_daily_close(gen_random_uuid(),default_branch_id(),$1)',[day]),/already has a close record/);
 await identity(branchManager,'authenticated');
 await assert.rejects(()=>db.query('select approve_branch_daily_close(default_branch_id(),$1)',[day]),/Owner approval required/);
 await identity(owner,'authenticated');
 const approved=await scalar('select approve_branch_daily_close(default_branch_id(),$1)',[day]);
 assert.equal(approved.status,'approved');assert.equal(approved.approved_by,owner);
 const correction='00000000-0000-4000-8000-000000000902';
 const correctionId=await scalar("select record_branch_daily_close_correction($1,$2,'Documented bank receipt clarification',$3::jsonb)",[correction,pending.close_id,JSON.stringify({note:'QA-only clarification'})]);
 assert.equal(await scalar("select record_branch_daily_close_correction($1,$2,'Documented bank receipt clarification',$3::jsonb)",[correction,pending.close_id,JSON.stringify({note:'QA-only clarification'})]),correctionId);
 const reread=await scalar('select get_branch_daily_close(default_branch_id(),$1)',[day]);
 assert.equal(reread.snapshot.report.net_billed,100);assert.equal(reread.corrections.length,1);
 await identity(alice,'authenticated');
 await assert.rejects(()=>db.query('select get_branch_daily_close(default_branch_id(),$1)',[day]),/Owner or authorized branch manager required/);
 await identity(owner,'postgres');
 await assert.rejects(()=>db.query("update private.branch_daily_closures set snapshot='{}'::jsonb where close_id=$1",[pending.close_id]),/immutable|approval|correction record/);
 await assert.rejects(()=>db.query('delete from private.branch_daily_closures where close_id=$1',[pending.close_id]),/retained/);
 await assert.rejects(()=>db.query('update private.branch_daily_close_corrections set reason=\'Changed\' where correction_id=$1',[correctionId]),/immutable/);
});
await test('daily close blocks an unapproved shift spanning its date',async()=>{
 const day=await scalar('select current_date-3');await identity(owner,'postgres');
 await db.query("insert into business_cashier_shifts(shift_id,branch_id,cashier_id,opening_cash,status,opened_at,closed_at) values(gen_random_uuid(),$1,$2,0,'awaiting_approval',$3::date::timestamp+'08:00',$3::date::timestamp+'17:00')",[branch2.branch_id,branchManager,day]);
 await identity(owner,'authenticated');
 await assert.rejects(()=>db.query('select prepare_branch_daily_close(gen_random_uuid(),$1,$2)',[branch2.branch_id,day]),/closed and owner-approved/);
});
console.log(`${passed} database integration scenarios passed. Test fixtures only; no network or hosted data used.`);
await db.close();
