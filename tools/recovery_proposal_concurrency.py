"""SOURCE PLAN by default. Root-approved LOCAL proposal acceptance lock acceptance.
prepare -> run -> cleanup; retain QA audit, no deletes/Auth/phone/quota/HR edits.
Uses TWO dedicated existing QA accounts and ACTUAL persisted sessions. No tokens,
passwords or raw registration secrets are written to this tool's proof/journal.
"""
import argparse,json,time,uuid
from pathlib import Path
from collections import Counter
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def uid():return str(uuid.uuid4())
def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n');path.chmod(0o600)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--action',choices=['plan','prepare','recover','run','cleanup'],default='plan');a=p.parse_args()
 if a.action=='plan':print('PLAN: 2 existing dedicated QA actors, 2 actual unverified intakes with explicit owner duplicate review, 4 sequential case/proposal fixtures; actual accept/customer-close and accept/owner-close both commit orders; no approvals/links; exact nonce fences and canonical rejects; no identity/phone/quota edits.');return
 r=a.runtime.resolve();state=r/'recovery-proposal-concurrency-state.json';proof_path=r/'recovery-proposal-concurrency-proof.json'
 q=WorkQA(SimpleNamespace(runtime=r,state=state,proof=proof_path));d=None;sessions=[]
 def sql(s):return q.sql("set statement_timeout='25s';set lock_timeout='20s';"+s)
 def hashes():
  raw=sql("""create temp table qa_proposal_hash(t text,h text);do $$declare row record;begin for row in select schemaname,tablename from pg_tables where schemaname in('public','private','auth')and not(schemaname='private'and tablename='document_number_counters')loop execute format('insert into qa_proposal_hash select %L,md5(row_to_json(x)::text)from %I.%I x',row.schemaname||'.'||row.tablename,row.schemaname,row.tablename);end loop;end$$;select t||'|'||h from qa_proposal_hash order by t,h;""");return Counter(raw.splitlines())
 def actor(user,sid):return "select set_config('request.jwt.claim.sub',"+lit(user)+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':user,'session_id':sid,'role':'authenticated'}))+",true);set local role authenticated;"
 def owner():return actor(d['owner_id'],d['owner_session_id'])
 def customer(c):return actor(c['customer_id'],c['session_id'])
 def live(user):
  value=sql('select id from auth.sessions where user_id='+lit(user)+' and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;');return str(uuid.UUID(value))
 def recover_profiles():
  # Shared setup mutex settles uncertain atomic producer before discovery.
  sql("begin;select pg_advisory_xact_lock(hashtextextended("+lit('qa-recovery-proposal-fixture:'+d['branch'])+",0));commit;")
  assert sql('select exists(select 1 from public.business_branches where branch_id='+lit(d['branch'])+' and name_en='+lit(d['tag'])+' and not is_default);')=='t','Atomic producer absent: manual review, never reissue'
  for profile in d['profiles']:
   value=sql("select r.result->>'offline_profile_id'from private.offline_customer_registration_requests r join private.offline_customer_profiles p on p.profile_id=(r.result->>'offline_profile_id')::uuid where r.request_id="+lit(profile['registration'])+' and r.actor_id='+lit(d['owner_id'])+' and r.branch_id='+lit(d['branch'])+' and p.full_name='+lit(profile['name'])+' and p.created_branch_id='+lit(d['branch'])+';')
   profile['profile_id']=str(uuid.UUID(value))
  for case in d['cases']:case['profile_id']=next(p['profile_id']for p in d['profiles']if p['customer_id']==case['customer_id'])
  d['ready']=True;save(state,d)
 def financial_counts():return json.loads(sql("select jsonb_build_object('orders',(select count(*)from public.business_orders),'invoices',(select count(*)from public.business_invoices),'payments',(select count(*)from public.business_payment_events),'bookings',(select count(*)from public.bookings),'credits',(select count(*)from private.canonical_loyalty_visits),'auth_users',(select count(*)from auth.users));"))
 def validate_case(c):
  return sql('select exists(select 1 from private.visit_recovery_submission_requests s join private.visit_recovery_customer_requests v on v.case_id=s.case_id where s.request_id='+lit(c['case_nonce'])+' and s.actor_id='+lit(c['customer_id'])+' and v.requester_id='+lit(c['customer_id'])+' and v.case_id='+lit(c['case_id'])+');')=='t'
 def get_case(c):
  value=sql('select case_id from private.visit_recovery_submission_requests where request_id='+lit(c['case_nonce'])+' and actor_id='+lit(c['customer_id'])+';')
  if value:c['case_id']=str(uuid.UUID(value));save(state,d)
  return bool(value)
 def seed_case(c):
  if c.get('seed_started'):
   assert get_case(c),'Uncertain setup absent: manual review, never producer reissue'
   assert sql('select exists(select 1 from private.visit_recovery_owner_proposals where proposal_id='+lit(c['proposal'])+' and case_id='+lit(c['case_id'])+' and profile_id='+lit(c['profile_id'])+');')=='t'
   return
  assert sql('select not exists(select 1 from private.visit_recovery_customer_requests where requester_id='+lit(c['customer_id'])+" and status in('awaiting_matching','more_info'));")=='t'
  c['seed_started']=True;save(state,d)
  # Atomic case + owner candidate query + actual independent-evidence selection.
  # private lookup in expression must be resolved BEFORE restricted role.
  body="begin;"+customer(c)+"select public.submit_visit_recovery_request("+lit(c['case_nonce'])+",jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',"+lit(d['notices']['case'])+"));reset role;do $$declare v_case uuid;begin select case_id into strict v_case from private.visit_recovery_submission_requests where request_id="+lit(c['case_nonce'])+";perform set_config('request.jwt.claim.sub',"+lit(d['owner_id'])+",true);perform set_config('request.jwt.claims',"+lit(json.dumps({'sub':d['owner_id'],'session_id':d['owner_session_id']}))+",true);execute 'set local role authenticated';perform public.search_visit_recovery_candidates("+lit(c['query'])+",v_case,'QA independent case evidence investigation');perform public.prepare_visit_recovery_proposal("+lit(c['proposal'])+','+lit(c['query'])+','+lit(c['profile_id'])+",'in_person_original_service_documents','QA isolated in-person evidence attestation',true);end$$;commit;"
  sql(body);assert get_case(c);assert validate_case(c)
 def accept_expr(c):
  # Notices originate from the actual opaque own-proposal response; no private
  # notice helper is called after SET ROLE and no client consent is invented.
  return "public.accept_my_visit_recovery_proposal("+lit(c['accept'])+','+lit(c['proposal'])+",jsonb_build_object('accepted',true,'version',notice->>'consent_version','language','en','text',notice->>'notice_en'),jsonb_build_object('accepted',true,'version',notice->>'canonical_consent_version','language','en','text',notice->>'canonical_notice_en'))"
 def accept(c):return 'with offered as(select public.get_my_visit_recovery_proposal('+lit(c['case_id'])+')notice)select '+accept_expr(c)+' from offered;'
 def late_accept(c):return "do $$declare notice jsonb;begin notice:=public.get_my_visit_recovery_proposal("+lit(c['case_id'])+");perform "+accept_expr(c)+";raise exception 'Unexpected late accept'using errcode='PZ001';exception when object_not_in_prerequisite_state then raise notice 'QA_LATE_ACCEPT_FENCED';end$$;"
 def close_accept(c):return 'select public.close_my_visit_recovery_acceptance('+lit(c['accept'])+');'
 def close_proposal(c):return 'select public.close_visit_recovery_proposal('+lit(c['proposal'])+');'
 def session(name):x=PsqlSession(q.command,q.env,'qa-proposal-'+name);sessions.append(x);return x
 def blocked(second,first):
  deadline=time.monotonic()+8
  while time.monotonic()<deadline:
   if sql('select '+str(first.pid)+'=any(pg_blocking_pids('+str(second.pid)+'));')=='t':return
   time.sleep(.05)
  raise RuntimeError('Expected real mutex wait absent')
 def launch(s,body):marker='PROPOSAL_'+uuid.uuid4().hex;s.send(body+'\n\\echo '+marker);return marker
 def settle(c):
  # Every delayed adapter accept first settles under its canonical request fence.
  sql('begin;'+customer(c)+close_accept(c)+'commit;')
  sql('begin;'+owner()+close_proposal(c)+'commit;')
  if not get_case(c):return
  assert validate_case(c)
  found=sql('select coalesce((select status from private.visit_recovery_customer_requests where case_id='+lit(c['case_id'])+'),\'absent\');')
  if found not in ['awaiting_matching','more_info']:return
  mapped=sql('select claim_id from private.visit_recovery_case_claims where case_id='+lit(c['case_id'])+';')
  if mapped:
   assert mapped==c['accept']
   assert sql('select exists(select 1 from private.offline_claim_requests where request_id='+lit(mapped)+' and actor_id='+lit(c['customer_id'])+' and profile_id='+lit(c['profile_id'])+');')=='t'
   payload={'p_claim':mapped,'p_decision':'reject','p_reason':'QA isolated canonical review cleanup','p_evidence_type':None}
   sql('begin;'+owner()+'select public.prepare_offline_claim_command('+lit(c['reject_claim'])+",'decide',"+lit(json.dumps(payload))+"::jsonb);select public.decide_offline_customer_claim("+lit(c['reject_claim'])+','+lit(mapped)+",'reject','QA isolated canonical review cleanup');commit;")
  else:
   sql('begin;'+owner()+'select public.prepare_visit_recovery_review('+lit(c['reject_case'])+','+lit(c['case_id'])+','+lit(found)+",'reject','QA isolated unmapped case cleanup');select public.apply_visit_recovery_review("+lit(c['reject_case'])+');commit;')
 try:
  if a.action=='prepare':
   assert not state.exists(),'Existing journal: run/cleanup only; never repeat producer'
   identities=json.loads((r/'recovery-bridge-fixture.private.json').read_text());assert identities['local_only']and len(identities['customers'])==2
   d={'local_only':True,'tag':'QA-proposal-'+uuid.uuid4().hex[:10],'owner_id':q.actors['owner'],'owner_session_id':live(q.actors['owner']),'branch':uid(),'profiles':[],'cases':[],'checks':[],'before_rows':dict(hashes()),'before_counters':json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))}
   d['notices']={'case':sql("select private.visit_recovery_request_notice('en');"),'registration':sql("select private.offline_registration_notice('en');")}
   for n,identity in enumerate(identities['customers']):
    user=str(uuid.UUID(identity['user_id']));sid=live(user)
    assert sql('select exists(select 1 from public.customers c join auth.users u on u.id=c.id where c.id='+lit(user)+" and c.full_name like'QA-%'and u.email like'%@example.invalid'and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and private.offline_phone_key(c.phone,'EG')is not null);")=='t'
    assert sql('select not exists(select 1 from private.offline_customer_trusted_links where auth_user_id='+lit(user)+' and revoked_at is null)and not exists(select 1 from private.visit_recovery_customer_requests where requester_id='+lit(user)+" and status in('awaiting_matching','more_info'));")=='t'
    assert sql('select count(*)filter(where created_at>clock_timestamp()-interval\'1 hour\')<=3 and count(*)<=18 from private.offline_claim_requests where actor_id='+lit(user)+" and created_at>clock_timestamp()-interval'1 day';")=='t'
    d['profiles'].append({'customer_id':user,'session_id':sid,'registration':uid(),'name':d['tag']+' '+str(n),'plate':'QP'+uuid.uuid4().hex[:10]})
   for n,which in enumerate([0,1,1,0]):
    d['cases'].append({**d['profiles'][which],'case_nonce':uid(),'query':uid(),'proposal':uid(),'accept':uid(),'reject_claim':uid(),'reject_case':uid(),'mode':['accept_then_customer_close','customer_close_then_accept','accept_then_owner_close','owner_close_then_accept'][n]})
   assert sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'
   d['before_claims']=int(sql('select count(*)from private.offline_claim_requests;'));d['before_fact_counts']=financial_counts();d['prepare_started']=True;save(state,d) # ALL IDs, before hashes and counters BEFORE any producer dispatch.
   body="begin;select pg_advisory_xact_lock(hashtextextended("+lit('qa-recovery-proposal-fixture:'+d['branch'])+",0));insert into public.business_branches(branch_id,name_ar,name_en)values("+','.join(map(lit,[d['branch'],d['tag'],d['tag']]))+");do $$declare v_phone text;notice text;intake jsonb;begin notice:=private.offline_registration_notice('en');perform set_config('request.jwt.claim.sub',"+lit(d['owner_id'])+",true);perform set_config('request.jwt.claims',"+lit(json.dumps({'sub':d['owner_id'],'session_id':d['owner_session_id']}))+",true);"
   for profile in d['profiles']:
    body+='select c.phone into strict v_phone from public.customers c where c.id='+lit(profile['customer_id'])+";execute 'set local role authenticated';intake:=public.register_offline_customer("+lit(profile['registration'])+','+lit(d['branch'])+','+lit(profile['name'])+",v_phone,'EG',jsonb_build_object('plate_number',"+lit(profile['plate'])+"),jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',notice),'create_separate','QA explicit separate unverified fixture; phone is not identity proof');execute 'reset role';assert intake->>'status'='created_unverified';"
   body+='end$$;commit;';sql(body)
   recover_profiles()
  else:
   d=json.loads(state.read_text());assert d['local_only']
   if not d.get('ready'):recover_profiles()
  if a.action=='recover':print('Recovered only exact journaled atomic producer; no producer reissue.');return
  if a.action=='run':
   assert not d.get('cleanup_complete'),'Finished/fenced journal: cleanup only, never repeat producer or accepted races'
   first=session('first');second=session('second')
   for index,c in enumerate(d['cases']):
    if c.get('passed'):continue
    seed_case(c);mode=c['mode']
    if mode.startswith('accept_then'):
     first.run('begin;'+customer(c)+accept(c))
     closer=customer(c)+close_accept(c)if'customer'in mode else owner()+close_proposal(c)
     marker=launch(second,'begin;'+closer+'commit;');blocked(second,first);first.run('commit;');second.wait(marker)
     assert sql('select count(*)from private.visit_recovery_proposal_acceptances where request_id='+lit(c['accept'])+" and result->>'state'='accepted'and actor_id="+lit(c['customer_id'])+';')=='1'
    else:
     closer=customer(c)+close_accept(c)if mode.startswith('customer')else owner()+close_proposal(c)
     first.run('begin;'+closer)
     marker=launch(second,'begin;'+customer(c)+late_accept(c)+'commit;');blocked(second,first);first.run('commit;');answer=second.wait(marker);assert any('QA_LATE_ACCEPT_FENCED'in x for x in answer)
     assert sql('select count(*)from private.offline_claim_requests where request_id='+lit(c['accept'])+';')=='0'
    assert sql('select not exists(select 1 from private.offline_customer_trusted_links where profile_id='+lit(c['profile_id'])+');')=='t'
    c['passed']=True;d['checks'].append(mode);save(state,d);settle(c)
   d['races_passed']=len(d['checks'])==4;save(state,d)
 except Exception as error:
  if d is not None:d['last_error_type']=type(error).__name__;save(state,d)
 finally:
  for s in sessions:s.rollback_close()
  if d is not None and a.action in ['run','cleanup']:
   complete=True
   for c in d['cases']:
    try:settle(c)
    except Exception:complete=False
   try:
    for profile in d['profiles']:sql('begin;'+owner()+'select public.close_offline_customer_registration('+lit(profile['registration'])+','+lit(d['branch'])+');commit;')
    sql('update public.business_branches set is_active=false where branch_id='+lit(d['branch'])+' and name_en='+lit(d['tag'])+' and not is_default;')
    counters=json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
    proof={'local_only':True,'races':d['checks'],'races_passed':d.get('races_passed',False),'all_preexisting_public_private_auth_rows_unchanged':not bool(Counter(d['before_rows'])-hashes()),'document_counters_unchanged':counters==d['before_counters'],'canonical_outbox_empty':sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t','no_qa_links':all(sql('select not exists(select 1 from private.offline_customer_trusted_links where profile_id='+lit(x['profile_id'])+');')=='t'for x in d['profiles']),'qa_branch_inactive':sql('select not is_active and not is_default from public.business_branches where branch_id='+lit(d['branch'])+';')=='t','cleanup_complete':complete,'production_touched':False,'new_auth_accounts':financial_counts()['auth_users']-d['before_fact_counts']['auth_users'],'phone_or_quota_edits_expected':0,'financial_or_credit_writes_expected':0,'financial_and_auth_counts_unchanged':financial_counts()==d['before_fact_counts'],'exact_two_new_canonical_claims':int(sql('select count(*)from private.offline_claim_requests;'))==d['before_claims']+2,'no_active_new_cases':all(not c.get('case_id')or sql('select status not in(\'awaiting_matching\',\'more_info\')from private.visit_recovery_customer_requests where case_id='+lit(c['case_id'])+';')=='t'for c in d['cases'])}
    proof['all_passed']=proof['races_passed']and all(proof[x]for x in ['all_preexisting_public_private_auth_rows_unchanged','document_counters_unchanged','canonical_outbox_empty','no_qa_links','qa_branch_inactive','cleanup_complete','financial_and_auth_counts_unchanged','exact_two_new_canonical_claims','no_active_new_cases']);save(proof_path,proof);d['cleanup_complete']=complete;d['all_passed']=proof['all_passed'];save(state,d)
   except Exception as error:d['cleanup_error_type']=type(error).__name__;save(state,d)
 if a.action=='prepare':print('Prepared private QA profiles; source reviewed races require separate run action.')
 elif d.get('all_passed'):print('PASS local proposal races and retained QA cleanup')
 else:raise SystemExit('INCOMPLETE sanitized journal retained; root review required, no producer retry')
if __name__=='__main__':main()
