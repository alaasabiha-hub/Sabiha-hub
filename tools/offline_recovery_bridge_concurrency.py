"""SOURCE ONLY by default. Two-session canonical recovery bridge acceptance.
Requires TWO committed QA cases/claims produced through real APIs, one legitimate
claim per existing confirmed customer. Never changes phones, Auth or quotas.
No secrets or tokens in journal/output. Root approval required before --execute.
"""
import argparse,json,time,uuid
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
 if not a.execute:print('PLAN: two actual QA claims; attach/approval both commit orders, attachment replay/revoke both commit orders; real lock waits; exact event/inbox count; validated QA revoke cleanup. No identity/quota edits.');return
 r=a.runtime.resolve();a.fixture.resolve().relative_to(r);f=json.loads(a.fixture.read_text());assert f['local_only']and f['canonical_bridge_fixture']
 q=WorkQA(SimpleNamespace(runtime=r,state=a.fixture,proof=a.proof));assert len(f['cases'])==2
 for k in ['owner_id','owner_session_id','branch_id']:f[k]=str(uuid.UUID(f[k]))
 for c in f['cases']:
  for k in ['customer_id','session_id','case_id','claim_id','profile_id']:c[k]=str(uuid.UUID(c[k]))
 assert len({c['customer_id']for c in f['cases']})==2 and 'QA'in f['branch_tag']
 stage={'local_only':True,'all_passed':False,'checks':[],'commands':[{k:str(uuid.uuid4())for k in ['attach','approve','revoke']}for _ in f['cases']]};sessions=[]
 journal=a.proof.with_name(a.proof.stem+'-commands.json')
 def save():journal.write_text(json.dumps(stage,indent=2)+'\n');journal.chmod(0o600)
 save() # All nonce IDs persisted before dispatch; never regenerate/retry setup.
 def actor(uid,sid):return "select set_config('request.jwt.claim.sub',"+lit(uid)+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':uid,'role':'authenticated','session_id':sid}))+",true);set local role authenticated;"
 def owner():return actor(f['owner_id'],f['owner_session_id'])
 def customer(c):return actor(c['customer_id'],c['session_id'])
 def attach(c,n):return 'select public.attach_my_visit_recovery_claim('+','.join(map(lit,[n,c['case_id'],c['claim_id']]))+');'
 def approve(c,n):return 'select public.decide_offline_customer_claim('+','.join(map(lit,[n,c['claim_id'],'approve_with_secret','QA canonical bridge actual original receipt approval']))+');'
 def revoke(link,n):return 'select public.revoke_offline_customer_link('+','.join(map(lit,[n,link,'QA canonical bridge isolated cleanup revocation']))+');'
 def session(name):s=PsqlSession(q.command,q.env,'qa-bridge-'+name);sessions.append(s);return s
 def wait_blocked(second,first):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if q.sql('select '+str(first.pid)+'=any(pg_blocking_pids('+str(second.pid)+'));')=='t':return
   time.sleep(.05)
  raise RuntimeError('Actual expected lock wait missing')
 def launch(s,body):mark='BRIDGE_'+uuid.uuid4().hex;s.send('begin;'+body+'commit;\n\\echo '+mark);return mark
 def link(c):
  value=q.sql('select link_id from private.offline_customer_trusted_links where claim_id='+lit(c['claim_id'])+' and profile_id='+lit(c['profile_id'])+' and auth_user_id='+lit(c['customer_id'])+';');return str(uuid.UUID(value))if value else None
 def assertion(c,cmd,status):
  assert q.sql('select status from private.visit_recovery_customer_requests where case_id='+lit(c['case_id'])+';')==status
  expected='attach_existing'if c is f['cases'][1]else'decision'
  source=cmd['attach']if expected=='attach_existing'else cmd['approve']
  assert q.sql('select count(*)from private.visit_recovery_canonical_events where case_id='+lit(c['case_id'])+' and source_kind='+lit(expected)+' and source_request_id='+lit(source)+" and new_status='linked';")=='1'
  assert q.sql('select count(*)from private.app_inbox_events where source_event_id='+lit(source)+" and template_code='recovery_approved';")=='1'
 try:
  for who,sid in [(f['owner_id'],f['owner_session_id'])]+[(c['customer_id'],c['session_id'])for c in f['cases']]:
   assert q.sql('select exists(select 1 from auth.sessions s join auth.users u on u.id=s.user_id where s.id='+lit(sid)+' and s.user_id='+lit(who)+' and(s.not_after is null or s.not_after>clock_timestamp())and u.deleted_at is null and u.email_confirmed_at is not null and(u.banned_until is null or u.banned_until<=clock_timestamp()));')=='t'
  for c in f['cases']:
   assert q.sql('select exists(select 1 from private.visit_recovery_customer_requests v join public.customers u on u.id=v.requester_id where v.case_id='+lit(c['case_id'])+' and v.requester_id='+lit(c['customer_id'])+" and v.status='awaiting_matching'and private.offline_phone_key(u.phone,'EG')is not null);")=='t'
   assert q.sql('select exists(select 1 from private.offline_claim_requests c join private.offline_customer_profiles p on p.profile_id=c.profile_id join public.business_branches b on b.branch_id=p.created_branch_id where c.request_id='+lit(c['claim_id'])+' and c.actor_id='+lit(c['customer_id'])+' and p.profile_id='+lit(c['profile_id'])+' and b.branch_id='+lit(f['branch_id'])+' and b.name_en='+lit(f['branch_tag'])+" and c.mode='original_receipt'and c.secret_proved and c.expires_at>clock_timestamp());")=='t'
   assert q.sql('select not exists(select 1 from private.offline_claim_decisions where claim_id='+lit(c['claim_id'])+')and not exists(select 1 from private.visit_recovery_case_claims where case_id='+lit(c['case_id'])+');')=='t'
  first=session('first');second=session('second')
  c=f['cases'][0];cmd=stage['commands'][0]
  first.run('begin;'+customer(c)+attach(c,cmd['attach']))
  marker=launch(second,owner()+approve(c,cmd['approve']));wait_blocked(second,first);first.run('commit;');second.wait(marker);assertion(c,cmd,'linked')
  stage['checks'].append('attach_commits_before_waiting_approval_one_notice');save()
  # Same authoritative attachment nonce: live replay locks before revocation.
  first.run('begin;'+customer(c)+attach(c,cmd['attach']))
  marker=launch(second,owner()+revoke(link(c),cmd['revoke']));wait_blocked(second,first);first.run('commit;');second.wait(marker);assertion(c,cmd,'revoked')
  stage['checks'].append('attachment_replay_commits_before_waiting_revoke');save()
  c=f['cases'][1];cmd=stage['commands'][1]
  first.run('begin;'+owner()+approve(c,cmd['approve']))
  marker=launch(second,customer(c)+attach(c,cmd['attach']));wait_blocked(second,first);first.run('commit;');second.wait(marker);assertion(c,cmd,'linked')
  stage['checks'].append('approval_commits_before_waiting_attach_one_notice');save()
  first.run('begin;'+owner()+revoke(link(c),cmd['revoke']))
  marker=launch(second,customer(c)+attach(c,cmd['attach']));wait_blocked(second,first);first.run('commit;');answer=second.wait(marker);assertion(c,cmd,'revoked')
  assert any('revoked'in line for line in answer)
  stage['checks'].append('revoke_commits_before_waiting_attachment_replay');save()
 except Exception as error:stage['error_type']=type(error).__name__
 finally:
  for s in sessions:s.rollback_close()
  cleanup=True
  for c,cmd in zip(f['cases'],stage['commands']):
   try:
    # Exact nonce fence settles late approval before looking for/revoking link.
    q.sql('begin;'+owner()+'select public.close_offline_claim_command('+lit(cmd['approve'])+');commit;')
    actual=link(c)
    if actual:q.sql('begin;'+owner()+revoke(actual,cmd['revoke'])+'commit;')
   except Exception:cleanup=False
  try:
   stage['no_active_qa_links']=all(q.sql('select not exists(select 1 from private.offline_customer_trusted_links where claim_id='+lit(c['claim_id'])+' and revoked_at is null);')=='t'for c in f['cases'])
   stage['prior_rows_unchanged']=not bool(Counter(f['before_rows'])-q.rows())
   stage['auth_users_unchanged']=f['before_auth']==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u where id not in("+','.join(lit(c['customer_id'])for c in f['cases'])+');')
   stage['counters_unchanged']=f['before_counters']==json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
  except Exception:cleanup=False
  stage['cleanup_complete']=cleanup;stage['all_passed']=len(stage['checks'])==4 and cleanup and all(stage.get(k)is True for k in ['no_active_qa_links','prior_rows_unchanged','auth_users_unchanged','counters_unchanged'])
  save();a.proof.write_text(json.dumps(stage,indent=2)+'\n');a.proof.chmod(0o600)
 print('PASS canonical bridge concurrency'if stage['all_passed']else'INCOMPLETE sanitized bridge proof retained')
 if not stage['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
