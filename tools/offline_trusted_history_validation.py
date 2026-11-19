"""SOURCE PLAN ONLY by default; --execute requires root's exclusive LOCAL DB release.
Two existing-account claims maximum (one/account), two tagged received invoices;
HTTP consent/document/privacy and real read/revoke commit orders. No Auth creation,
payments, work completion, loyalty awards, HR updates, hosted calls or raw-secret
artifacts. Reuse only journal-proven QA employment. Gate restored disabled; retain
QA audit, revoke links and void only these unpaid orders. Never reset claim limits.
"""
import argparse
import base64
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def uid(): return str(uuid.uuid4())
def lit(v): return "'" + str(v).replace("'", "''") + "'"
class RedactedFailure(RuntimeError): pass


def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True)
 p.add_argument('--state',type=Path);p.add_argument('--execute',action='store_true')
 a=p.parse_args()
 if not a.execute: print(__doc__);return
 r=a.runtime.resolve();accounts=json.loads((r/'test-accounts-final.json').read_text())
 target=urllib.parse.urlsplit(accounts['url']);assert target.scheme=='http'and target.hostname=='127.0.0.1'
 base=accounts['url'].rstrip('/');sock=r/'instances/sabiha-local/sock/docker.sock';assert sock.is_socket()
 env={**os.environ,'DOCKER_HOST':'unix://'+str(sock),'DOCKER_CONFIG':str(r/'docker-config')}
 command=[str(r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
 actors={k:str(uuid.UUID(accounts['users'][k]['id']))for k in ['owner','manager','other_employee','customer','other_customer']}
 tokens={};session_ids={};tag='historyqa-'+uuid.uuid4().hex[:10];branch=uid();service=uid();sessions=[];cases=[]
 state_path=a.state or a.proof.with_name(a.proof.stem+'-state.json')
 proof={'local_only':True,'production_touched':False,'tag':tag,'all_passed':False,'raw_secret_persisted':False,'auth_accounts_created':0,'payment_events_created':0,'hr_updates':0}
 before=auth_before=counters_before=contracts_before=None;branch_created=False;service_created=False;gate_touched=False
 def checkpoint():
  state_path.parent.mkdir(parents=True,exist_ok=True)
  state_path.write_text(json.dumps({'local_only':True,'tag':tag,'branch_id':branch,'service_id':service,'branch_created':branch_created,'service_created':service_created,'cases':cases},indent=2)+'\n');state_path.chmod(0o600)
 def stage(s):proof['stage']=s;checkpoint()
 def sql(s):
  result=subprocess.run(command,input=s,text=True,capture_output=True,env=env,timeout=35)
  if result.returncode:raise RedactedFailure('SQL assertion failed; output redacted')
  return result.stdout.strip()
 def call(path,data=None,role=None,method='POST',token=None,prefer='return=representation'):
  headers={'apikey':accounts['anon_key'],'Content-Type':'application/json','Prefer':prefer}
  if token or role:headers['Authorization']='Bearer '+(token or tokens[role])
  req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
  try:
   with urllib.request.urlopen(req,timeout=30)as response:
    raw=response.read();return response.status,json.loads(raw)if raw.strip()else None
  except urllib.error.HTTPError as e:
   # Never preserve HTTP body/arguments; errors may contain request context.
   e.read();return e.code,None
 def rpc(n,d,role='owner',expected=200):
  status,result=call('/rest/v1/rpc/'+n,d,role)
  if status!=expected:raise RedactedFailure('Unexpected HTTP status for '+n)
  return result
 def login(role):
  status,result=call('/auth/v1/token?grant_type=password',{'email':accounts['users'][role]['email'],'password':accounts['users'][role]['password']})
  assert status==200 and result['user']['id']==actors[role]
  token=result['access_token'];payload=json.loads(base64.urlsafe_b64decode(token.split('.')[1]+'==='))
  sid=str(uuid.UUID(payload['session_id']));return token,sid
 def rows():
  raw=sql("""create temp table qa_history_hash(t text,h text);do $$declare t record;begin
  for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop
  execute format('insert into qa_history_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;
  select t||'|'||h from qa_history_hash order by t,h;""")
  return Counter(raw.splitlines())
 def auth_hash():return sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
 def auth_tx(role,body):
  claims=json.dumps({'sub':actors[role],'session_id':session_ids[role]})
  return 'begin;select set_config(\'request.jwt.claim.sub\','+lit(actors[role])+',true);select set_config(\'request.jwt.claims\','+lit(claims)+',true);set local role authenticated;'+body
 def pair():
  first=PsqlSession(command,env,'qa_trusted_history_first');second=PsqlSession(command,env,'qa_trusted_history_second');sessions.extend([first,second]);return first,second
 def blocked(second,first):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if sql('select exists(select 1 from pg_stat_activity where pid='+str(second.pid)+" and wait_event_type='Lock'and "+str(first.pid)+'=any(pg_blocking_pids(pid)));')=='t':return True
   time.sleep(.05)
  return False
 def assert_denied(role,invoice):assert call('/rest/v1/rpc/get_my_offline_invoice_document',{'p_invoice':invoice},role)[0]==403
 def create_received_work(c):
  rpc('prepare_offline_walk_in',{'p_request':c['command'],'p_registration':c['registration'],'p_service':service,'p_expected_price':120,'p_cashier':actors['manager'],'p_staff_ids':staff,'p_notes':tag})
  placed=rpc('place_offline_walk_in',{'p_request':c['command']},'manager')['result']
  c.update(order_id=placed['order_id'],invoice_id=placed['invoice_id']);checkpoint()
  rpc('ack_offline_walk_in_command',{'p_request':c['command']},'manager')
 def validated_case(c):
  if not c.get('profile_id'):return False
  return sql('select exists(select 1 from private.offline_customer_profiles p join private.offline_customer_registration_requests q on q.result->>\'offline_profile_id\'=p.profile_id::text where p.profile_id='+lit(c['profile_id'])+' and p.created_branch_id='+lit(branch)+' and p.full_name='+lit(tag+' '+c['role'])+' and q.request_id='+lit(c['registration'])+' and q.actor_id='+lit(actors['manager'])+');')=='t'
 try:
  stage('preflight')
  for role in ['owner','manager','customer','other_customer']:tokens[role],session_ids[role]=login(role)
  assert sql('select not enabled from private.offline_history_runtime where id;')=='t'
  assert sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0'
  assert sql("select(clock_timestamp()at time zone'Africa/Cairo')::time between '00:01'and '23:50';")=='t'
  available=[];budgets={}
  for role in ['customer','other_customer']:
   actor=actors[role]
   budgets[role]=json.loads(sql('select json_build_object(\'hour\',count(*)filter(where created_at>clock_timestamp()-interval\'1 hour\'),\'day\',count(*)filter(where created_at>clock_timestamp()-interval\'1 day\'))from private.offline_claim_requests where actor_id='+lit(actor)+';'))
   active=sql('select exists(select 1 from private.offline_customer_trusted_links where auth_user_id='+lit(actor)+' and revoked_at is null);')=='t'
   if budgets[role]['hour']<=4 and budgets[role]['day']<=19 and not active:available.append(role)
  proof['budget_preflight']=budgets
  if not available:raise RedactedFailure('No legitimate existing-account claim quota; no fixtures written')
  proof['two_account_budget_available']=len(available)==2
  assert sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id='+lit(actors['manager'])+' and acknowledged_at is null);')=='t'
  original=json.loads((r/'walkin-financial-concurrency-state-attempt2-setup-stopped.json').read_text());original_proof=json.loads((r/'walkin-financial-concurrency-proof-attempt2-setup-stopped.json').read_text())
  final=json.loads((r/'walkin-financial-concurrency-state.json').read_text());final_proof=json.loads((r/'walkin-financial-concurrency-proof.json').read_text())
  staff=sorted([actors['manager'],actors['other_employee']]);assert len(set(staff))==2
  assert original['local_only']and original['tag']==original_proof['tag']and set(original['new_contract_staff_ids'])==set(staff)
  assert original_proof['new_qa_contracts_ended_on_today']and final_proof['all_passed']and final_proof['borrowed_contracts_untouched']
  assert set(final['borrowed_contract_staff_ids'])==set(staff)
  today=sql("select(clock_timestamp()at time zone'Africa/Cairo')::date;")
  assert set(original['worker_roles'])=={'manager','other_employee'}
  for worker_role,rate in zip(original['worker_roles'],[15,25]):
   worker=actors[worker_role]
   assert sql('select exists(select 1 from private.hr_employment where staff_id='+lit(worker)+' and salary=0 and commission_percent='+str(rate)+" and currency='EGP'and starts_on="+lit(today)+'::date and ends_on='+lit(today)+'::date);')=='t'
   assert sql('select exists(select 1 from private.hr_requests where actor='+lit(actors['owner'])+" and action='employment'and payload->>'staff_id'="+lit(worker)+" and(payload->>'salary')::numeric=0 and(payload->>'commission_percent')::numeric="+str(rate)+" and payload->>'starts_on'="+lit(today)+" and payload->>'ends_on'="+lit(today)+');')=='t'
  contracts_before=json.loads(sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+','.join(map(lit,staff))+');'))
  assert contracts_before==final['borrowed_contract_hashes']
  before=rows();auth_before=auth_hash();counters_before=json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
  status,_=call('/rest/v1/business_branches',{'branch_id':branch,'name_ar':tag,'name_en':tag,'is_default':False},'owner');assert status in(200,201);branch_created=True;checkpoint()
  assert call('/rest/v1/business_branch_hours?branch_id=eq.'+branch,{'is_open':True,'opens_at':'00:00','closes_at':'23:59'},'owner','PATCH')[0]in(200,204)
  assert call('/rest/v1/staff_branch_access',[{'user_id':worker,'branch_id':branch}for worker in staff],'owner')[0]in(200,201)
  assert call('/rest/v1/business_catalog_items',{'item_id':service,'branch_id':branch,'item_type':'service','name':tag,'vehicle_type':'sedan','price':120,'duration_minutes':5,'resource_key':'wash','is_active':True,'is_public':True},'owner',prefer='return=minimal')[0]in(200,201,204);service_created=True;checkpoint()
  registration_consent={'accepted':True,'version':'offline-registration-v1','language':'en','text':sql("select private.offline_registration_notice('en');")}
  claim_consent={'accepted':True,'version':'offline-claim-v1','language':'en','text':sql("select private.offline_claim_notice('en');")}
  scope={'accepted':True,'version':'offline-history-v1','language':'en','text':sql("select private.offline_history_notice('en');")}
  for role in available:
   stage('fixture-'+role);c={'role':role,'registration':uid(),'claim':uid(),'approve':uid(),'consent':uid(),'command':uid(),'revoke':uid(),'cancel':uid()};cases.append(c);checkpoint()
   intake=rpc('register_offline_customer',{'p_request':c['registration'],'p_branch':branch,'p_name':tag+' '+role,'p_phone':'+201'+str(uuid.uuid4().int%1000000000).zfill(9),'p_country':'EG','p_car':{'plate_number':'H'+uuid.uuid4().hex[:10]},'p_consent':registration_consent,'p_duplicate_action':None,'p_review_reason':None},'manager')
   assert intake['status']=='created_unverified';c.update(profile_id=intake['offline_profile_id'],receipt_id=intake['enrollment_receipt_id']);checkpoint()
   secret=intake.pop('enrollment_secret');assert len(secret)==64
   if len(cases)==1:create_received_work(c);c['invoice_relation_to_link']='before_link'
   claimed=rpc('request_offline_customer_claim',{'p_request':c['claim'],'p_receipt':c['receipt_id'],'p_secret':secret,'p_mode':'original_receipt','p_consent':claim_consent},role);secret=None;intake=None;assert claimed['status']=='pending_owner_review'
   approved=rpc('decide_offline_customer_claim',{'p_request':c['approve'],'p_claim':c['claim'],'p_decision':'approve_with_secret','p_reason':tag+' verified original receipt for local history acceptance','p_evidence_type':None});c['link_id']=approved['link_id'];checkpoint()
   if len(cases)>1:create_received_work(c);c['invoice_relation_to_link']='after_link'
   assert rpc('get_my_offline_history_context',{},role)['state']=='consent_required'
   assert_denied(role,c['invoice_id'])
   accepted=rpc('accept_my_offline_history_scope',{'p_request':c['consent'],'p_consent':scope},role);assert accepted['state']=='consent_recorded'
   assert rpc('get_my_offline_history_context',{},role)['state']=='acceptance_pending'
  gate_touched=True;sql('update private.offline_history_runtime set enabled=true where id;')
  for c in cases:
   stage('http-reader-'+c['role']);role=c['role'];assert validated_case(c)
   context=rpc('get_my_offline_history_context',{},role);assert context['state']=='available'and len(context['cars'])==1
   history=rpc('get_my_offline_visit_history',{'p_limit':1},role);assert len(history['items'])==1 and history['items'][0]['invoice_id']==c['invoice_id']and history['items'][0]['service_status']=='received'
   document=rpc('get_my_offline_invoice_document',{'p_invoice':c['invoice_id']},role)
   assert document['invoice_total']==120 and document['payment_status']=='unpaid'and document['snapshot']['tax_amount']is None
   assert document['snapshot']['tax_configuration']=='not_recorded_in_legacy_invoice'and document['qr_reader_bridge']is False
   assert not any(k in json.dumps(document)for k in ['employment_snapshot','commission_percent','secret_hash','contact_hash','secret_proved'])
   assert context['capabilities']['wallet_access']is False and context['capabilities']['guest_redemption']is False
   assert_denied(role,'unknown-history-invoice')
   for foreign in cases:
    if foreign is not c:assert_denied(role,foreign['invoice_id'])
   # Profile contact append is rollback-only; immutable audit is never deleted.
   sql('begin;insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values('+lit(c['profile_id'])+",'+20212345678','EG');"+auth_tx(role,'').replace('begin;','',1)+"do $$begin assert public.get_my_offline_history_context()->>'state'='review_required';end$$;rollback;")
   c['contact_append_denied_in_rollback']=True
   # A dedicated newly issued real session is removed by local signout only.
   extra_token,extra_session=login(role)
   assert call('/rest/v1/rpc/get_my_offline_history_context',{},token=extra_token)[0]==200
   assert call('/auth/v1/logout?scope=local',{},token=extra_token)[0]in(200,204)
   assert sql('select not exists(select 1 from auth.sessions where id='+lit(extra_session)+');')=='t'
   status,denied=call('/rest/v1/rpc/get_my_offline_history_context',{},token=extra_token)
   assert status in(401,403)or status==200 and denied['state']=='review_required';extra_token=None
   c['real_removed_session_denied']=True
  for index,c in enumerate(cases):
   stage('read-revoke-order-'+str(index));first,second=pair();role=c['role']
   revoke='public.revoke_offline_customer_link('+lit(c['revoke'])+','+lit(c['link_id'])+','+lit(tag+' local owner revocation')+')'
   if index==0:
    first.run(auth_tx(role,"do $$begin assert jsonb_array_length(public.get_my_offline_visit_history()->'items')=1;end$$;"))
    # Actual configured20s lock bound, rolled-back failed revoke; same nonce retries.
    marker='QA_HISTORY_BOUND_'+uuid.uuid4().hex;started=time.monotonic()
    second.send(auth_tx('owner',"do $$begin perform "+revoke+";raise exception 'Unexpected unlocked revoke'using errcode='PZ009';exception when lock_not_available then raise notice 'QA_HISTORY_LOCK_BOUND';end$$;rollback;")+'\n\\echo '+marker)
    assert blocked(second,first)
    bound_lines=second.wait(marker,timeout=30);elapsed=time.monotonic()-started
    assert any('QA_HISTORY_LOCK_BOUND'in line for line in bound_lines)and 18<=elapsed<=28
    proof['actual_lock_timeout_20s_observed']=True;proof['lock_timeout_elapsed_seconds']=round(elapsed,2)
    marker='QA_HISTORY_'+uuid.uuid4().hex
    second.send(auth_tx('owner','select ('+revoke+")->>'status';commit;")+'\n\\echo '+marker)
    assert blocked(second,first);first.run('commit;');lines=second.wait(marker);assert 'revoked'in lines
    proof['reader_first_revoke_waited_then_committed']=True
   else:
    first.run(auth_tx('owner','select ('+revoke+")->>'status';"))
    marker='QA_HISTORY_'+uuid.uuid4().hex
    second.send(auth_tx(role,"do $$begin perform public.get_my_offline_invoice_document("+lit(c['invoice_id'])+");raise exception 'Unexpected reader success'using errcode='PZ009';exception when insufficient_privilege then raise notice 'QA_HISTORY_DENIED';end$$;commit;")+'\n\\echo '+marker)
    assert blocked(second,first);first.run('commit;');assert any('QA_HISTORY_DENIED'in line for line in second.wait(marker))
    proof['revoke_first_reader_waited_then_denied']=True
   c['revoked']=True;checkpoint();assert_denied(role,c['invoice_id']);assert rpc('get_my_offline_history_context',{},role)['state']=='review_required'
   first.rollback_close();second.rollback_close()
  proof['actual_http_consent_history_documents_privacy']=True
 except Exception as e:proof['error_type']=type(e).__name__
 finally:
  for session in sessions:session.rollback_close()
  cleanup=True
  # Restore gate even when fixture/setup/HTTP or a concurrent statement failed.
  if gate_touched:
   try:sql('update private.offline_history_runtime set enabled=false where id;')
   except Exception:cleanup=False
  for c in cases:
   try:
    # Settle delayed intake/command before looking up actual canonical QA facts.
    rpc('close_offline_claim_command',{'p_request':c['approve']},'owner')
    rpc('close_offline_customer_registration',{'p_request':c['registration'],'p_branch':branch},'manager')
    rpc('close_offline_walk_in_command',{'p_request':c['command']},'manager')
    if not c.get('profile_id'):
     recovered=rpc('get_offline_customer_registration',{'p_request':c['registration']},'manager')
     if recovered.get('offline_profile_id'):c['profile_id']=recovered['offline_profile_id']
    if c.get('profile_id'):
     assert validated_case(c)
     link=sql('select link_id from private.offline_customer_trusted_links where profile_id='+lit(c['profile_id'])+' and auth_user_id='+lit(actors[c['role']])+' and claim_id='+lit(c['claim'])+' and revoked_at is null;')
     if link:
      uuid.UUID(link);assert not c.get('link_id')or link==c['link_id'];c['link_id']=link
      rpc('revoke_offline_customer_link',{'p_request':c['revoke'],'p_link':link,'p_reason':tag+' local owner revocation'});c['revoked']=True
     recovered=rpc('get_offline_walk_in_command',{'p_request':c['command']},'manager')
     if recovered['status']=='succeeded':
      actual=recovered['result'];c['order_id']=actual['order_id'];c['invoice_id']=actual['invoice_id']
      assert sql('select exists(select 1 from private.offline_walk_in_subjects s join public.business_invoices i on i.invoice_id=s.invoice_id where s.order_id='+lit(c['order_id'])+' and s.invoice_id='+lit(c['invoice_id'])+' and s.profile_id='+lit(c['profile_id'])+' and s.branch_id='+lit(branch)+' and not exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id));')=='t'
      rpc('cancel_offline_walk_in',{'p_request':c['cancel'],'p_order':c['order_id'],'p_reason':tag+' cleanup unpaid received QA only'})
      rpc('ack_offline_walk_in_command',{'p_request':c['command']},'manager')
     elif recovered['status']=='closed':rpc('ack_offline_walk_in_command',{'p_request':c['command']},'manager')
   except Exception:cleanup=False
  for created,path,data in [(service_created,'/rest/v1/business_catalog_items?item_id=eq.'+service,{'is_active':False,'is_public':False}),(branch_created,'/rest/v1/business_branches?branch_id=eq.'+branch,{'is_active':False,'temporarily_closed':True})]:
   if created:
    try:assert call(path,data,'owner','PATCH',prefer='return=minimal'if '/business_catalog_items?'in path else'return=representation')[0]in(200,204)
    except Exception:cleanup=False
  try:
   qa_orders=[c['order_id']for c in cases if c.get('order_id')];ids=','.join(map(lit,qa_orders))or'null'
   proof['canonical_outbox_finally_empty']=sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0'
   assert proof['canonical_outbox_finally_empty'],'Unexpected outbox event; do not drain or mask it'
   proof['gate_restored_disabled']=sql('select not enabled from private.offline_history_runtime where id;')=='t'
   proof['no_qa_payments_or_loyalty']=sql('select not exists(select 1 from public.business_payment_events where invoice_id in(select invoice_id from private.offline_walk_in_subjects where branch_id='+lit(branch)+'))and not exists(select 1 from private.canonical_loyalty_visits where order_id in('+ids+'))and not exists(select 1 from public.business_loyalty_transactions where order_id in('+ids+'));')=='t'
   proof['all_qa_links_revoked']=all(not c.get('link_id')or sql('select revoked_at is not null from private.offline_customer_trusted_links where link_id='+lit(c['link_id'])+';')=='t'for c in cases)
   proof['all_qa_invoices_void']=sql('select not exists(select 1 from public.business_invoices where invoice_id in(select invoice_id from private.offline_walk_in_subjects where branch_id='+lit(branch)+")and status<>'void');")=='t'
   if before is not None:
    after=rows();missing=before-after;added=after-before
    proof['preexisting_rows_unchanged_except_invoice_counter']=all(row.startswith('private.document_number_counters|')for row in missing)
    allowed={'public.business_branches','public.business_branch_hours','public.business_branch_resources','public.staff_branch_access','public.business_catalog_items','public.business_audit_log','public.business_orders','public.business_order_items','public.business_invoices','private.offline_customer_profiles','private.offline_customer_contacts','private.offline_customer_car_refs','private.offline_customer_registration_requests','private.offline_customer_enrollment_receipts','private.offline_registration_closed_requests','private.offline_claim_owner_commands','private.offline_claim_requests','private.offline_claim_decisions','private.offline_customer_trusted_links','private.offline_claim_revocations','private.offline_history_scope_consents','private.offline_walk_in_commands','private.offline_walk_in_subjects','private.offline_walk_in_commissions','private.offline_walk_in_reception','private.offline_walk_in_events','private.document_number_counters'}
    proof['only_expected_new_row_tables']={row.split('|',1)[0]for row in added}<=allowed
    proof['new_row_counts']=dict(Counter(row.split('|',1)[0]for row in added))
    now=json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));expected=dict(counters_before);expected['INV']+=len(qa_orders);proof['only_actual_new_invoice_counter_delta']=now==expected
    proof['auth_identities_unchanged']=auth_hash()==auth_before
    proof['borrowed_qa_employment_unchanged']=contracts_before==json.loads(sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+','.join(map(lit,[actors['manager'],actors['other_employee']]))+');'))
  except Exception:cleanup=False
  proof['cleanup_complete']=cleanup
  try:proof['claim_attempt_count']=int(sql('select count(*)from private.offline_claim_requests where request_id in('+(','.join(lit(c['claim'])for c in cases)or'null')+');'))
  except Exception:proof['claim_attempt_count']=None
  required=['canonical_outbox_finally_empty','actual_lock_timeout_20s_observed','two_account_budget_available','actual_http_consent_history_documents_privacy','reader_first_revoke_waited_then_committed','revoke_first_reader_waited_then_denied','gate_restored_disabled','no_qa_payments_or_loyalty','all_qa_links_revoked','all_qa_invoices_void','preexisting_rows_unchanged_except_invoice_counter','only_expected_new_row_tables','only_actual_new_invoice_counter_delta','auth_identities_unchanged','borrowed_qa_employment_unchanged','cleanup_complete']
  proof['all_passed']=all(proof.get(k)is True for k in required)and all(c.get('contact_append_denied_in_rollback')and c.get('real_removed_session_denied')for c in cases)
  checkpoint();a.proof.parent.mkdir(parents=True,exist_ok=True);a.proof.write_text(json.dumps(proof,indent=2)+'\n');a.proof.chmod(0o600)
 print('PASS local trusted-history HTTP/concurrency'if proof['all_passed']else'INCOMPLETE trusted-history proof; sanitized journal retained')
 if not proof['all_passed']:raise SystemExit(1)

if __name__=='__main__':main()
