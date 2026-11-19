"""PLAN by default. Tagged LOCAL cash-ledger/component races, no gateway/real money.
Uses test-owned transactional DDL to relax/restore the disabled gate ONLY inside
setup/earning transactions. No disabled-check removal or enabled runtime commits.
QA invoices/work/cash/refunds are retained; no deletes or old HR/Auth changes.
"""
import argparse,json,time,uuid,hashlib
from pathlib import Path
from collections import Counter
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def uid():return str(uuid.uuid4())

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--execute',action='store_true');p.add_argument('--dry-run',action='store_true');a=p.parse_args()
 if not(a.execute or a.dry_run):print(json.dumps({'plan_only':True,'cases':['duplicate eligible workers','earn commit before waiting refund','refund commit before waiting earning'],'retained_qa_invoices':3,'production':False}));return
 r=a.runtime.resolve();q=WorkQA(SimpleNamespace(runtime=r,state=r/'offline-loyalty-concurrency-state.json',proof=r/'unused'))
 d={key:uid()for key in ['branch','service','offer','policy','rules','overlay','activation','shift','registration']};d['tag']='offline-race-'+uuid.uuid4().hex[:10];d['owner']=q.actors['owner'];d['worker']=json.loads((r/'loyalty-component-staff-provision-proof.json').read_text())['staff_id'];d['orders']=[]
 state=r/'offline-loyalty-concurrency-state.json';assert not state.exists()or not json.loads(state.read_text()).get('orders'),'Existing QA state retained: use cleanup/resume, do not repeat accepted races';proof={'local_only':True,'production_touched':False,'physical_service_performed':False,'real_money_or_gateway':False,'all_passed':False,'checks':[]};sessions=[];seeded=False
 def save():state.write_text(json.dumps(d,indent=2)+'\n');state.chmod(0o600)
 def sess(name):
  x=PsqlSession(q.command,q.env,d['tag']+'-'+name);sessions.append(x);return x
 def owner_sql():return "select set_config('request.jwt.claim.sub',"+lit(d['owner'])+",true);set local role authenticated;"
 # Only owner DDL within a live test transaction; restore exact original name/check.
 gate_on="alter table private.offline_service_visit_runtime drop constraint offline_service_visit_runtime_earning_enabled_check;update private.offline_service_visit_runtime set earning_enabled=true where singleton;"
 gate_off="update private.offline_service_visit_runtime set earning_enabled=false where singleton;alter table private.offline_service_visit_runtime add constraint offline_service_visit_runtime_earning_enabled_check check(not earning_enabled);"
 def wait_lock(s):
  end=time.monotonic()+8
  while q.sql('select count(*)from pg_stat_activity where pid='+str(s.pid)+" and wait_event_type='Lock';")!='1':
   if s.proc.poll()is not None:raise RuntimeError('Concurrent SQL exited before lock observation')
   assert time.monotonic()<end,'Expected actual lock wait not observed';time.sleep(.05)
 def reconcile(o):return 'select private.reconcile_loyalty_visit('+lit(o)+');'
 def launch(s,sql):
  marker='OFFLINE_DONE_'+uuid.uuid4().hex;s.send(sql+'\n\\echo '+marker);return marker
 def finish_gate(s):return s.run(gate_off+'commit;')
 def refund_sql(item):return owner_sql()+"select public.record_shift_payment('"+uid()+"',"+lit(d['shift'])+','+lit(item['invoice_id'])+",'refund','cash');reset role;"
 try:
  assert q.sql("select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;")=='t'
  assert q.sql("select not earning_enabled from private.offline_service_visit_runtime where singleton;")=='t'
  assert q.sql("select count(*)=1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and conname='offline_service_visit_runtime_earning_enabled_check';")=='t'
  assert q.sql('select exists(select 1 from private.hr_employment where staff_id='+lit(d['worker'])+" and starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and(ends_on is null or ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date));")=='t'
  before=q.rows();counters=json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));auth=q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
  d['before_rows']=dict(before);d['before_counters']=counters;d['before_auth']=auth;save()
  guard=sess('cron-guard');guard.run("begin;select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));")
  save()
  setup="""begin;create temp table qa_seed(doc jsonb);do $$declare intake jsonb;reg jsonb;result jsonb;output jsonb:='[]';nonce uuid;stage text;kind text;oid uuid;begin
  insert into public.business_branches(branch_id,name_ar,name_en)values(%(branch)s,%(tag)s,%(tag)s);
  update public.business_branch_hours set is_open=true,opens_at='00:00',closes_at='23:59'where branch_id=%(branch)s;
  insert into public.staff_branch_access(user_id,branch_id)values(%(worker)s,%(branch)s);
  insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(%(service)s,%(branch)s,'service',%(tag)s,'sedan',120,5,'wash',true,true);
  insert into public.business_offers(offer_id,branch_id,name,offer_type,visits_required,reward_item_id,is_active,is_public)values(%(offer)s,%(branch)s,%(tag)s,'visit_reward',3,%(service)s,true,true);
  perform set_config('request.jwt.claim.sub',%(owner)s,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',%(owner)s,'session_id',(select id from auth.sessions where user_id=%(owner)s and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1))::text,true);
  reg:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
  execute 'set local role authenticated';
  perform public.save_loyalty_policy(%(policy)s,%(branch)s,%(offer)s,array[%(service)s::uuid],true);
  perform public.save_loyalty_redemption_rules(%(rules)s,%(policy)s,null,'{"pooling":"policy_version","expiry":"no_expiry","cancellation":"restore_visits","refunded_contribution":"offset_future_visits"}');
  intake:=public.register_offline_customer(%(registration)s,%(branch)s,%(tag)s,'+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%%1000000000)::text,9,'0'),'EG','{"plate_number":"QA RACE"}',reg);
  perform public.save_offline_visit_channel(%(overlay)s,%(branch)s,%(policy)s,%(rules)s,array[%(service)s::uuid],array[(intake->>'offline_profile_id')::uuid],true);
  execute 'reset role';
  %(gate_on)s
  insert into private.offline_visit_channel_activations(activation_id,channel_version_id,activated_by)values(%(activation)s,%(overlay)s,%(owner)s);
  execute 'set local role authenticated';perform public.open_cashier_shift(%(shift)s,%(branch)s,0);
  foreach kind in array array['duplicate','earn_first','refund_first']loop
   nonce:=gen_random_uuid();perform public.prepare_offline_walk_in(nonce,(intake->>'request_id')::uuid,%(service)s,120,%(owner)s,array[%(worker)s::uuid]);result:=public.place_offline_walk_in(nonce);perform public.ack_offline_walk_in_command(nonce);oid:=(result#>>'{result,order_id}')::uuid;
   foreach stage in array array['in_progress','quality_check','completed','delivered']loop
    nonce:=gen_random_uuid();perform public.prepare_service_work(nonce,oid,case stage when'in_progress'then'received'when'quality_check'then'in_progress'when'completed'then'quality_check'else'completed'end,stage,'QA isolated loyalty race');perform public.place_service_work(nonce);perform public.ack_service_work_command(nonce);
   end loop;
   perform public.record_shift_payment(gen_random_uuid(),%(shift)s,result#>>'{result,invoice_id}','sale','cash');
   output:=output||jsonb_build_array(jsonb_build_object('case',kind,'order_id',oid,'invoice_id',result#>>'{result,invoice_id}'));
  end loop;
  execute 'reset role';%(gate_off)s
  insert into qa_seed values(jsonb_build_object('orders',output,'offline_profile_id',intake->>'offline_profile_id'));
  end$$;select doc from qa_seed;commit;"""%{**{k:lit(v)for k,v in d.items()if k!='orders'},'gate_on':gate_on,'gate_off':gate_off}
  if a.dry_run:
   q.sql(setup.rsplit('commit;',1)[0]+'rollback;')
   assert q.rows()==before
   assert json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))==counters
   proof.update({'all_passed':True,'dry_run_only':True,'atomic_setup_rolled_back_rows_and_counters_unchanged':True});return
  out=json.loads(q.sql(setup));d.update(out);seeded=True;save()
  assert len(d['orders'])==3
  worker1=sess('worker-a');worker2=sess('worker-b')
  item=d['orders'][0];worker1.run('begin;'+gate_on+reconcile(item['order_id']))
  marker=launch(worker2,'begin;'+reconcile(item['order_id'])+'commit;');wait_lock(worker2);finish_gate(worker1);answer=worker2.wait(marker);assert 'already_earned'in answer
  assert q.sql('select count(*)from private.canonical_loyalty_visits where order_id='+lit(item['order_id'])+"and kind='earn';")=='1';proof['checks'].append('duplicate_workers_real_wait_one_earn')
  item=d['orders'][1];worker1.run('begin;'+gate_on+reconcile(item['order_id']));marker=launch(worker2,'begin;'+refund_sql(item)+'commit;');wait_lock(worker2);finish_gate(worker1);worker2.wait(marker)
  assert q.sql(reconcile(item['order_id']))=='refunded';proof['checks'].append('earn_commit_before_waiting_cash_refund_one_reversal')
  item=d['orders'][2];worker2.run('begin;'+refund_sql(item));marker=launch(worker1,'begin;'+gate_on+reconcile(item['order_id'])+gate_off+'commit;');wait_lock(worker1);worker2.run('commit;');answer=worker1.wait(marker);assert 'fully_refunded_before_earning'in answer,answer
  assert q.sql('select count(*)from private.canonical_loyalty_visits where order_id='+lit(item['order_id'])+';')=='0';proof['checks'].append('refund_commit_before_waiting_earn_no_phantom_credit')
  proof['all_passed']=True
 finally:
  # Roll back any interrupted work/DDL before retaining/settling ONLY this new QA.
  for x in sessions[1:]:x.rollback_close()
  try:
   if seeded:
    for item in d['orders']:
     if q.sql('select count(*)from public.business_payment_events where invoice_id='+lit(item['invoice_id'])+"and event_type='refund';")=='0':q.sql('begin;'+refund_sql(item)+'commit;')
     q.sql(reconcile(item['order_id']))
    q.sql('begin;'+owner_sql()+'select public.close_cashier_shift('+lit(d['shift'])+",0,'QA full refunds, no physical cash');select public.approve_cashier_shift("+lit(d['shift'])+');reset role;update public.business_offers set is_active=false,is_public=false where offer_id='+lit(d['offer'])+';update public.business_catalog_items set is_active=false,is_public=false where item_id='+lit(d['service'])+';update public.business_branches set is_active=false where branch_id='+lit(d['branch'])+';commit;')
    for _ in range(100):
     if q.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0':break
     result=json.loads(q.sql('select private.drain_loyalty_visit_event();'))
     assert result.get('processed')is True,'Retain natural retry deadline and resume cleanup later'
    else:raise RuntimeError('Unexpected unbounded pending events')
    after=q.rows();after_counters=json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
    proof['old_rows_unchanged']=not bool(before-after);proof['auth_users_unchanged']=auth==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;");proof['exact_invoice_numbers']=after_counters['INV']==counters['INV']+3 and after_counters['BKG']==counters['BKG']
    proof['runtime_disabled_with_check']=q.sql("select not earning_enabled and exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and conname='offline_service_visit_runtime_earning_enabled_check')from private.offline_service_visit_runtime where singleton;")=='t'
    proof['qa_net_visits_zero']=q.sql('select coalesce(sum(visits),0)from private.canonical_loyalty_visits where branch_id='+lit(d['branch'])+';')=='0';proof['pending_outbox_zero']=q.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0'
    proof['cleanup_complete']=all(proof[k]for k in ['old_rows_unchanged','auth_users_unchanged','exact_invoice_numbers','runtime_disabled_with_check','qa_net_visits_zero','pending_outbox_zero'])
   else:proof['cleanup_complete']=q.sql('select count(*)from public.business_branches where branch_id='+lit(d['branch'])+';')=='0'
  except Exception as e:proof['cleanup_complete']=False;proof['cleanup_error_type']=type(e).__name__
  finally:
   for x in sessions:x.rollback_close()
   save();(r/('offline-loyalty-kernel-concurrency-dryrun-proof.json'if a.dry_run else'offline-loyalty-kernel-concurrency-proof.json')).write_text(json.dumps(proof,indent=2)+'\n')
 assert proof['all_passed']and proof['cleanup_complete'],proof
 print(json.dumps(proof))
if __name__=='__main__':main()
