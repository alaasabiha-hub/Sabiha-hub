"""Local isolated two-session nonce close/submit test. Default PLAN; no production."""
import argparse,json,time,uuid
from pathlib import Path
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
 if not a.execute:print('PLAN local QA close-before-submit and submit-before-close; real lock waits; exact notices; owner rejects new isolated request.');return
 r=a.runtime.resolve();f=json.loads((r/'recovery-bridge-fixture.json').read_text());assert f['local_only']and f['canonical_bridge_fixture']
 q=WorkQA(SimpleNamespace(runtime=r,state=r/'unused',proof=r/'unused'));assert q.base=='http://127.0.0.1:54321'
 path=r/'visit-recovery-restart-concurrency-proof.json';assert not path.exists(),'Existing proof: never regenerate nonces or repeat successful races'
 customer=f['cases'][0];uid=customer['customer_id'];sid=customer['session_id'];owner=f['owner_id'];owner_sid=f['owner_session_id']
 notice=q.sql("select private.visit_recovery_request_notice('en');")
 consent=json.dumps({'accepted':True,'version':'visit-recovery-v1','language':'en','text':notice})
 before=q.rows();before_auth=q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
 v={'local_only':True,'all_passed':False,'nonces':{k:str(uuid.uuid4())for k in['close_first','submit_first','review']},'checks':[]};sessions=[]
 def save():path.write_text(json.dumps(v,indent=2)+'\n');path.chmod(0o600)
 def actor(user,session):return "select set_config('request.jwt.claim.sub',"+lit(user)+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':user,'session_id':session,'role':'authenticated'}))+",true);set local role authenticated;"
 def submit(n):return 'select public.submit_visit_recovery_request('+lit(n)+','+lit(consent)+'::jsonb);'
 def close(n):return 'select public.close_my_visit_recovery_submission('+lit(n)+');'
 def wait(second,first):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if q.sql('select '+str(first.pid)+'=any(pg_blocking_pids('+str(second.pid)+'));')=='t':return
   time.sleep(.05)
  raise RuntimeError('Expected lock wait absent')
 def launch(s,body):mark='RESTART_'+uuid.uuid4().hex;s.send('begin;'+body+'commit;\n\\echo '+mark);return mark
 case=None
 save()
 try:
  assert q.sql("select not exists(select 1 from private.visit_recovery_customer_requests where requester_id="+lit(uid)+"and status in('awaiting_matching','more_info'));")=='t'
  first=PsqlSession(q.command,q.env,'qa-recovery-restart-first');second=PsqlSession(q.command,q.env,'qa-recovery-restart-second');sessions=[first,second]
  n=v['nonces']['close_first'];first.run('begin;'+actor(uid,sid)+close(n));mark=launch(second,actor(uid,sid)+submit(n));wait(second,first);first.run('commit;');answer=second.wait(mark)
  assert any('closed'in line for line in answer)
  assert q.sql('select not exists(select 1 from private.visit_recovery_submission_requests where request_id='+lit(n)+');')=='t'
  v['checks'].append('close_first_blocks_late_producer_without_case_or_notice');save()
  n=v['nonces']['submit_first'];first.run('begin;'+actor(uid,sid)+submit(n));mark=launch(second,actor(uid,sid)+close(n));wait(second,first);first.run('commit;');answer=second.wait(mark)
  assert any('accepted'in line for line in answer)
  case=q.sql('select case_id from private.visit_recovery_submission_requests where request_id='+lit(n)+';');uuid.UUID(case)
  assert q.sql('select count(*)from private.app_inbox_events e join private.visit_recovery_customer_requests c on c.submission_event_id=e.source_event_id where c.case_id='+lit(case)+';')=='2'
  assert q.sql('select not exists(select 1 from private.visit_recovery_submission_closures where request_id='+lit(n)+');')=='t'
  v['checks'].append('producer_first_retains_exact_receipt_and_two_original_notices');save()
 except Exception as error:v['error_type']=type(error).__name__
 finally:
  for s in sessions:s.rollback_close()
  try:
   # Fence both exact nonces before discovering a late committed producer.
   for nonce in [v['nonces']['close_first'],v['nonces']['submit_first']]:q.sql('begin;'+actor(uid,sid)+close(nonce)+'commit;')
   case=q.sql('select case_id from private.visit_recovery_submission_requests where request_id='+lit(v['nonces']['submit_first'])+';')
   if case:
    q.sql('begin;'+actor(owner,owner_sid)+'select public.prepare_visit_recovery_review('+','.join(map(lit,[v['nonces']['review'],case,'awaiting_matching','reject','Isolated QA nonce recovery acceptance completed']))+');select public.apply_visit_recovery_review('+lit(v['nonces']['review'])+');commit;')
   from collections import Counter
   v['prior_rows_unchanged']=not bool(before-q.rows());v['auth_users_unchanged']=before_auth==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
   v['no_open_qa_request']=q.sql("select not exists(select 1 from private.visit_recovery_customer_requests where requester_id="+lit(uid)+"and status in('awaiting_matching','more_info'));")=='t'
   v['cleanup_complete']=True
  except Exception as error:v['cleanup_error_type']=type(error).__name__;v['cleanup_complete']=False
  v['all_passed']=len(v['checks'])==2 and all(v.get(k)is True for k in['prior_rows_unchanged','auth_users_unchanged','no_open_qa_request','cleanup_complete']);save()
 print('PASS local recovery restart concurrency'if v['all_passed']else'INCOMPLETE sanitized proof retained')
 if not v['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
