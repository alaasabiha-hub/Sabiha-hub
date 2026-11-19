"""LOCAL QA fixture; default PLAN. Explicit prepare/resume/cleanup only after root review.
Uses literal setup AST from accepted offline_loyalty_kernel_concurrency.py, never
executes/imports that main. One real walk-in/work/cash/earning; no fake credits,
Auth creation, old HR edits or production enable. No secrets in journal/proof.
"""
import argparse,ast,json,uuid
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit

def uid():return str(uuid.uuid4())
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n');p.chmod(0o600)
def template():
 tree=ast.parse(Path(__file__).with_name('offline_loyalty_kernel_concurrency.py').read_text())
 candidates=[n.value.left.value for n in ast.walk(tree)if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='setup'for t in n.targets)and isinstance(n.value,ast.BinOp)and isinstance(n.value.left,ast.Constant)]
 assert len(candidates)==1
 return candidates[0]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--action',choices=['plan','prepare','resume','cleanup'],default='plan');p.add_argument('--journal',type=Path);a=p.parse_args()
 if a.action=='plan':print('PLAN: one tagged actual QA walk-in, work, cash and earn; disabled gate restored before commit; separate hold proof then full refund/reversal and retained audit cleanup.');return
 r=a.runtime.resolve();state=a.journal or r/'offline-reservation-fixture.json';state.resolve().relative_to(r)
 q=WorkQA(SimpleNamespace(runtime=r,state=state,proof=r/'unused'));d=None
 def sql(s):return q.sql(s)
 def owner():return "select set_config('request.jwt.claim.sub',"+lit(d['owner'])+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':d['owner'],'session_id':d['owner_session_id']}))+",true);set local role authenticated;"
 def recover():
  # The sole producer transaction either committed atomically or did not. Never retry it.
  found=json.loads(sql("begin;select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));"+'select coalesce(jsonb_agg(jsonb_build_object(\'order_id\',s.order_id,\'invoice_id\',i.invoice_id,\'offline_profile_id\',s.profile_id,\'car_ref_id\',s.car_ref_id)),\'[]\')from private.offline_walk_in_subjects s join public.business_invoices i on i.order_id=s.order_id join public.business_branches b on b.branch_id=s.branch_id where s.branch_id='+lit(d['branch'])+' and b.name_en='+lit(d['tag'])+' and s.service_id='+lit(d['service'])+' and s.command_id='+lit(d['walkin'])+' and s.registration_request_id='+lit(d['registration'])+' and s.gross=120;commit;'))
  if len(found)>1:raise RuntimeError('Unexpected QA cardinality; manual review')
  if found:
   d.update(found[0]);d['orders']=[{'order_id':d['order_id'],'invoice_id':d['invoice_id']}];d['earning_ids']=json.loads(sql('select coalesce(jsonb_agg(id),\'[]\')from private.canonical_loyalty_visits where order_id='+lit(d['order_id'])+" and kind='earn';"));assert len(d['earning_ids'])==1
  d['commit_discovered']=bool(found);save(state,d)
 def drain():
  # One event per transaction; never broad loops or silently consume foreign work.
  for _ in range(64):
   n=int(sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;'))
   if n==0:return
   assert d.get('order_id')and sql('select bool_and(order_id='+lit(d['order_id'])+')from private.loyalty_visit_outbox where processed_at is null;')=='t'
   answer=json.loads(sql('select private.drain_loyalty_visit_event();'));assert answer.get('processed')is True,'Natural retry deadline: retain journal and resume later'
  raise RuntimeError('Bounded QA drain incomplete')
 try:
  if a.action=='prepare':
   assert not state.exists(),'Existing journal: resume/cleanup, never create again'
   d={k:uid()for k in ['branch','service','offer','policy','rules','overlay','activation','shift','registration','walkin','sale','refund']}
   d.update({'local_only':True,'allocator_fixture':True,'tag':'QA-reserve-'+uuid.uuid4().hex[:10],'owner':q.actors['owner'],'worker':json.loads((r/'loyalty-component-staff-provision-proof.json').read_text())['staff_id'],'work':{s:uid()for s in ['in_progress','quality_check','completed','delivered']},'orders':[],'phone':'+201'+str(uuid.uuid4().int%1000000000).zfill(9)})
   d['owner_session_id']=sql('select id from auth.sessions where user_id='+lit(d['owner'])+' and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;');uuid.UUID(d['owner_session_id'])
   assert sql("select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;")=='t'
   assert sql("select not earning_enabled from private.offline_service_visit_runtime where singleton;")=='t'
   assert sql('select exists(select 1 from private.hr_employment where staff_id='+lit(d['worker'])+" and starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and(ends_on is null or ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date));")=='t'
   d['before_rows']=dict(q.rows());d['before_counters']=json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));d['before_auth']=sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
   d['dispatch_started']=True;save(state,d) # BEFORE producer dispatch, including uncertain-response recovery.
   gate_on="alter table private.offline_service_visit_runtime drop constraint offline_service_visit_runtime_earning_enabled_check;update private.offline_service_visit_runtime set earning_enabled=true where singleton;"
   gate_off="update private.offline_service_visit_runtime set earning_enabled=false where singleton;alter table private.offline_service_visit_runtime add constraint offline_service_visit_runtime_earning_enabled_check check(not earning_enabled);"
   source=template().replace('begin;create temp table','begin;select pg_advisory_xact_lock(hashtextextended(\'canonical-loyalty-cron\',0));create temp table')
   source=source.replace("(select id from auth.sessions where user_id=%(owner)s and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1)",'%(owner_session_id)s::uuid')
   source=source.replace("'+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%%1000000000)::text,9,'0')",'%(phone)s')
   source=source.replace("'visit_reward',3,","'visit_reward',1,").replace("array['duplicate','earn_first','refund_first']","array['reservation']")
   source=source.replace('nonce:=gen_random_uuid();perform public.prepare_offline_walk_in','nonce:=%(walkin)s;perform public.prepare_offline_walk_in')
   source=source.replace('nonce:=gen_random_uuid();perform public.prepare_service_work',"nonce:=(%(work)s::jsonb->>stage)::uuid;perform public.prepare_service_work")
   source=source.replace('public.record_shift_payment(gen_random_uuid(),','public.record_shift_payment(%(sale)s,')
   source=source.replace("  execute 'reset role';%(gate_off)s","  execute 'reset role';perform private.reconcile_loyalty_visit(oid);%(gate_off)s")
   source=source%{**{k:lit(v)for k,v in d.items()if isinstance(v,str)},'work':lit(json.dumps(d['work'])),'gate_on':gate_on,'gate_off':gate_off}
   sql(source) # Output excludes secret; deliberately not persisted or printed.
   recover()
  else:
   d=json.loads(state.read_text());assert d['local_only']and d['allocator_fixture'];recover()
  if not d.get('commit_discovered'):
   assert sql('select count(*)from public.business_branches where branch_id='+lit(d['branch'])+';')=='0'
   d['producer_not_committed']=True;save(state,d);return
  if a.action in ['prepare','resume']:
   drain();assert sql("select not earning_enabled and exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and conname='offline_service_visit_runtime_earning_enabled_check')from private.offline_service_visit_runtime where singleton;")=='t'
   d.update({'owner_id':d['owner'],'profile_id':d['offline_profile_id'],'channel_version_id':d['overlay'],'branch_id':d['branch'],'branch_name':d['tag'],'profile_name':d['tag'],'gross_amount':'120','rules_version_id':d['rules'],'ready_for_private_hold_tool':True});save(state,d)
  else:
   assert sql('select not exists(select 1 from private.reward_credit_claims where offline_profile_id='+lit(d['offline_profile_id'])+' and released_at is null);')=='t','Release holds first'
   if sql('select count(*)from public.business_payment_events where invoice_id='+lit(d['invoice_id'])+" and event_type='refund';")=='0':sql('begin;'+owner()+'select public.record_shift_payment('+lit(d['refund'])+','+lit(d['shift'])+','+lit(d['invoice_id'])+",'refund','cash');commit;")
   sql('select private.reconcile_loyalty_visit('+lit(d['order_id'])+');');drain()
   sql('begin;'+owner()+"do $$begin if exists(select 1 from public.business_cashier_shifts where shift_id="+lit(d['shift'])+" and status='open')then perform public.close_cashier_shift("+lit(d['shift'])+",0,'QA full refund no physical cash');end if;end$$;select public.approve_cashier_shift("+lit(d['shift'])+');reset role;update public.business_offers set is_active=false,is_public=false where offer_id='+lit(d['offer'])+';update public.business_catalog_items set is_active=false,is_public=false where item_id='+lit(d['service'])+';update public.business_branches set is_active=false where branch_id='+lit(d['branch'])+';commit;')
   before=Counter(d['before_rows']);after=q.rows();c=json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
   proof={'all_old_rows_unchanged':not bool(before-after),'auth_users_unchanged':d['before_auth']==sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;"),'exact_document_delta':c['INV']==d['before_counters']['INV']+1 and c['BKG']==d['before_counters']['BKG'],'qa_net_zero':sql('select coalesce(sum(visits),0)=0 from private.canonical_loyalty_visits where branch_id='+lit(d['branch'])+';')=='t','no_open_resource':sql('select not exists(select 1 from private.service_resource_spans where walk_in_order_id='+lit(d['order_id'])+' and ended_at is null);')=='t','runtime_disabled':sql("select not earning_enabled from private.offline_service_visit_runtime where singleton;")=='t','outbox_zero':sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'}
   d['cleanup_proof']=proof;save(state,d);assert all(proof.values())
 except Exception as error:
  if d is not None:d['last_error_type']=type(error).__name__;save(state,d)
  raise SystemExit('QA stage incomplete; sanitized journal retained; use resume/cleanup, never blind prepare retry')from None
 print('PASS local QA fixture '+a.action+'; no secrets persisted')
if __name__=='__main__':main()
