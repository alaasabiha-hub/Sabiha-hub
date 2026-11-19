"""SOURCE PLAN by default. Root-reviewed LOCAL private hold component acceptance.
Requires a root-authored allocator_fixture journal with REAL already-earned QA
credits and exact owner/profile/car/channel/branch labels; creates ONLY private
reservation commands/quotes/claims/events, releases them finally. No earning gate,
Auth account, HR, invoice, payment, refund, public API or hosted write. No run until
root releases DB and explicitly approves --execute. This is not customer consent
or a public spend/issuer test.
"""
import argparse
from decimal import Decimal
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from checkout_retry_lock_concurrency import PsqlSession

def lit(v):return "'"+str(v).replace("'","''")+"'"
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
 if not a.execute:print(__doc__);return
 r=a.runtime.resolve();a.fixture.resolve().relative_to(r);f=json.loads(a.fixture.read_text());assert f['local_only']and f['allocator_fixture']
 for key in ['owner_id','owner_session_id','profile_id','car_ref_id','channel_version_id','branch_id']:f[key]=str(uuid.UUID(f[key]))
 credits=[str(uuid.UUID(x))for x in f['earning_ids']];assert credits and len(set(credits))==len(credits)
 assert 'QA'in f['branch_name']and f['profile_name'].startswith('QA')
 sock=r/'instances/sabiha-local/sock/docker.sock';assert sock.is_socket()
 env={**os.environ,'DOCKER_HOST':'unix://'+str(sock),'DOCKER_CONFIG':str(r/'docker-config')}
 command=[str(r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
 requests=[str(uuid.uuid4())for _ in range(3)];sessions=[];before=None;proof={'local_only':True,'all_passed':False,'new_money_or_credit_created':False,'public_spend_enabled':False}
 journal=a.proof.with_name(a.proof.stem+'-requests.json');journal.write_text(json.dumps({'local_only':True,'fixture':str(a.fixture),'request_ids':requests},indent=2)+'\n');journal.chmod(0o600)
 def sql(s):
  z=subprocess.run(command,input=s,text=True,capture_output=True,env=env,timeout=35)
  if z.returncode:raise RuntimeError('Local component SQL failed; output redacted')
  return z.stdout.strip()
 def tx(body):return 'begin;select set_config(\'request.jwt.claim.sub\','+lit(f['owner_id'])+',true);select set_config(\'request.jwt.claims\','+lit(json.dumps({'sub':f['owner_id'],'session_id':f['owner_session_id']}))+',true);'+body
 def reserve(n):return 'private.reserve_offline_reward_candidates('+','.join(map(lit,[n,f['profile_id'],f['car_ref_id'],f['channel_version_id']]))+','+str(Decimal(str(f['gross_amount'])))+')'
 def result(lines):return json.loads(next(line for line in reversed(lines)if line.startswith('{')))
 def blocked(second,first):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if sql('select exists(select 1 from pg_stat_activity where pid='+str(second.pid)+" and wait_event_type='Lock'and "+str(first.pid)+'=any(pg_blocking_pids(pid)));')=='t':return True
   time.sleep(.05)
  return False
 def rows():
  raw=sql("""create temp table qa_reserve_hash(t text,h text);do $$declare t record;begin for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop execute format('insert into qa_reserve_hash select %L,md5(row_to_json(x)::text)from %I.%I x',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;select t||'|'||h from qa_reserve_hash order by t,h;""")
  return Counter(raw.splitlines())
 def release(n):sql(tx("select private.release_offline_reward_reservation("+lit(n)+",'Release only root-journaled unconsumed QA reservation');commit;"))
 try:
  gross=Decimal(str(f['gross_amount']));assert gross.is_finite()and gross>0
  assert sql('select exists(select 1 from auth.sessions where id='+lit(f['owner_session_id'])+' and user_id='+lit(f['owner_id'])+' and(not_after is null or not_after>clock_timestamp()));')=='t'
  assert sql('select exists(select 1 from public.staff_profiles s join auth.users u on u.id=s.user_id where s.user_id='+lit(f['owner_id'])+" and s.role='owner'and s.is_active and u.deleted_at is null);")=='t'
  assert sql('select exists(select 1 from private.offline_customer_profiles p join public.business_branches b on b.branch_id=p.created_branch_id where p.profile_id='+lit(f['profile_id'])+' and p.full_name='+lit(f['profile_name'])+' and b.branch_id='+lit(f['branch_id'])+' and b.name_en='+lit(f['branch_name'])+');')=='t'
  assert sql('select not exists(select 1 from private.offline_reward_reservation_commands where offline_profile_id='+lit(f['profile_id'])+" and state in('active','preparing'));")=='t'
  assert sql('select count(*)='+str(len(credits))+' from private.canonical_loyalty_visits where id in('+','.join(map(lit,credits))+')and offline_profile_id='+lit(f['profile_id'])+" and source_channel='offline_walk_in'and kind='earn'and private.reward_credit_refund(id)is null;")=='t'
  plan=json.loads(sql('select private.plan_reward_owner_candidates(\'offline_profile\','+lit(f['profile_id'])+','+lit(str(uuid.UUID(f['rules_version_id'])))+','+lit(f['channel_version_id'])+');'))
  assert plan['threshold_met']and len(credits)==plan['required_visits']and set(plan['candidate_ids'])==set(credits)
  before=rows()
  first=PsqlSession(command,env,'qa_offline_reserve_first');second=PsqlSession(command,env,'qa_offline_reserve_second');sessions=[first,second]
  one=result(first.run(tx('select '+reserve(requests[0])+';')))
  marker='QA_RESERVE_'+uuid.uuid4().hex;second.send(tx('select '+reserve(requests[0])+';commit;')+'\n\\echo '+marker)
  assert blocked(second,first);first.run('commit;');two=result(second.wait(marker));assert one==two
  proof['same_nonce_actual_wait_one_quote_claim_set']=True;release(requests[0])
  one=result(first.run(tx('select '+reserve(requests[1])+';')))
  marker='QA_RESERVE_'+uuid.uuid4().hex
  second.send(tx("do $$begin perform "+reserve(requests[2])+";raise exception 'Unexpected second occupancy'using errcode='PZ001';exception when object_not_in_prerequisite_state then raise notice 'QA_INSUFFICIENT';end$$;commit;")+'\n\\echo '+marker)
  assert blocked(second,first);first.run('commit;');assert any('QA_INSUFFICIENT'in x for x in second.wait(marker))
  proof['different_nonce_actual_wait_no_double_occupancy']=True
 except Exception as e:proof['error_type']=type(e).__name__
 finally:
  for s in sessions:s.rollback_close()
  cleanup=True
  for n in requests:
   try:
    if sql('select exists(select 1 from private.offline_reward_reservation_commands where request_id='+lit(n)+' and offline_profile_id='+lit(f['profile_id'])+' and requested_by='+lit(f['owner_id'])+');')=='t':release(n)
   except Exception:cleanup=False
  try:
   proof['no_active_qa_holds']=sql('select not exists(select 1 from private.reward_credit_claims where reserve_request_id in('+','.join(map(lit,requests))+')and released_at is null);')=='t'
   if before is not None:
    after=rows();proof['all_preexisting_rows_unchanged']=not(before-after)
    proof['only_private_component_additions']={x.split('|',1)[0]for x in(after-before)}<={'private.offline_reward_reservation_commands','private.offline_reward_reservation_events','private.service_reward_quotes','private.reward_credit_claims'}
  except Exception:cleanup=False
  proof['cleanup_complete']=cleanup
  proof['all_passed']=all(proof.get(x)is True for x in ['same_nonce_actual_wait_one_quote_claim_set','different_nonce_actual_wait_no_double_occupancy','no_active_qa_holds','all_preexisting_rows_unchanged','only_private_component_additions','cleanup_complete'])
  a.proof.write_text(json.dumps(proof,indent=2)+'\n');a.proof.chmod(0o600)
 print('PASS private offline hold concurrency'if proof['all_passed']else'INCOMPLETE private component proof; sanitized journal retained')
 if not proof['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
