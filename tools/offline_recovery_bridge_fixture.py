"""SOURCE ONLY: provision TWO dedicated local QA customers plus canonical bridge fixture.
Default PLAN. Auth Admin local only, no email/SMS; confirmed local fixtures then
real password sign-in. Credentials remain 0600 private runtime; never in proof.
Never edits existing Auth/contact/quotas, no history/earning/financial capabilities.
"""
import argparse,json,secrets,uuid,urllib.request,urllib.error
from pathlib import Path
from types import SimpleNamespace
from owner_redemption_rules_browser import Harness
from service_work_kernel_concurrency import WorkQA,lit

def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n');p.chmod(0o600)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--action',choices=['plan','prepare','resume','cleanup'],default='plan');a=p.parse_args()
 if a.action=='plan':print('PLAN two NEW dedicated local confirmed customer fixtures, real sign-in sessions, one actual intake/claim/recovery case each; no old identity edits; retained QA audit, revocation and branch hide cleanup.');return
 r=a.runtime.resolve();private=r/'recovery-bridge-fixture.private.json';public=r/'recovery-bridge-fixture.json'
 h=Harness(SimpleNamespace(runtime=r,proof=r/'unused',screenshots=r,app_url='http://127.0.0.1:8080'));assert h.base=='http://127.0.0.1:54321'
 q=WorkQA(SimpleNamespace(runtime=r,state=public,proof=r/'unused'));key=h.settings['SERVICE_ROLE_KEY']
 def admin(path,body=None):
  req=urllib.request.Request(h.base+'/auth/v1/admin/'+path,data=None if body is None else json.dumps(body).encode(),headers={'apikey':key,'Authorization':'Bearer '+key,'Content-Type':'application/json'},method='GET'if body is None else'POST')
  try:
   with urllib.request.urlopen(req,timeout=30)as response:return json.load(response)
  except Exception:raise RuntimeError('Local QA Auth operation incomplete; use journal recovery')from None
 if a.action=='prepare':
  assert not private.exists()and not public.exists(),'Existing journal: resume/cleanup only'
  d={'local_only':True,'canonical_bridge_fixture':True,'tag':'QA-bridge-'+uuid.uuid4().hex[:10],'branch_id':str(uuid.uuid4()),'owner_id':q.actors['owner'],'manager_id':q.actors['manager'],'before_rows':dict(q.rows()),'before_auth':q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;"),'before_counters':json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;')),'customers':[]}
  for i in range(2):d['customers'].append({'email':d['tag']+'-'+str(i)+'@example.invalid','password':secrets.token_urlsafe(32),'phone':'010'+str(uuid.uuid4().int%100000000).zfill(8),'registration':str(uuid.uuid4()),'claim_id':str(uuid.uuid4()),'case_nonce':str(uuid.uuid4()),'admin_phase':'not_dispatched'})
  save(private,d)
 else:d=json.loads(private.read_text());assert d['local_only']
 def actor(actor,sid):return "perform set_config('request.jwt.claim.sub',"+lit(actor)+",true);perform set_config('request.jwt.claims',"+lit(json.dumps({'sub':actor,'session_id':sid,'role':'authenticated'}))+",true);"
 try:
  if a.action in ['prepare','resume']:
   for c in d['customers']:
    if not c.get('user_id'):
     if c['admin_phase']=='not_dispatched':
      c['admin_phase']='dispatch_started';save(private,d)
      answer=admin('users',{'email':c['email'],'password':c['password'],'email_confirm':True,'user_metadata':{'full_name':d['tag'],'phone':c['phone']}});c['user_id']=str(uuid.UUID(answer.get('user',answer)['id']));save(private,d)
     else:
      matches=[]
      for page in range(1,21):
       users=admin('users?page='+str(page)+'&per_page=200').get('users',[]);matches.extend(u for u in users if str(u.get('email','')).casefold()==c['email'].casefold())
       if len(users)<200:break
      assert len(matches)==1,'Uncertain Auth create must be independently resolved, never redispatched';c['user_id']=str(uuid.UUID(matches[0]['id']));save(private,d)
    if not c.get('session_id'):
     result=h.call('/auth/v1/token?grant_type=password',{'email':c['email'],'password':c['password']})
     # Real server session, no fabricated JWT/signing keys. Token not saved.
     import base64
     claims=json.loads(base64.urlsafe_b64decode(result['access_token'].split('.')[1]+'==='));c['session_id']=str(uuid.UUID(claims['session_id']));save(private,d)
   for role in ['owner','manager']:
    d[role+'_session_id']=q.sql('select id from auth.sessions where user_id='+lit(d[role+'_id'])+' and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;');uuid.UUID(d[role+'_session_id'])
   if not d.get('setup_phase'):
    d['setup_phase']='dispatch_started';save(private,d) # IDs, credentials, hashes BEFORE setup dispatch.
    body="begin;do $$declare intake jsonb;receipt jsonb;notice_registration text;notice_claim text;notice_recovery text;begin notice_registration:=private.offline_registration_notice('en');notice_claim:=private.offline_claim_notice('en');notice_recovery:=private.visit_recovery_request_notice('en');insert into public.business_branches(branch_id,name_ar,name_en)values("+','.join(map(lit,[d['branch_id'],d['tag'],d['tag']]))+');insert into public.staff_branch_access(user_id,branch_id)values('+lit(d['manager_id'])+','+lit(d['branch_id'])+');'
    for c in d['customers']:
     body+='insert into public.customers(id,email,full_name,phone)select '+','.join(map(lit,[c['user_id'],c['email'],d['tag'],c['phone']]))+' where not exists(select 1 from public.customers where id='+lit(c['user_id'])+');'
     body+='assert not exists(select 1 from private.offline_claim_requests where actor_id='+lit(c['user_id'])+');assert not exists(select 1 from private.visit_recovery_customer_requests where requester_id='+lit(c['user_id'])+');'
     body+="assert exists(select 1 from public.customers where id="+lit(c['user_id'])+' and phone='+lit(c['phone'])+');'
     body+=actor(d['manager_id'],d['manager_session_id'])+"execute 'set local role authenticated';intake:=public.register_offline_customer("+lit(c['registration'])+','+lit(d['branch_id'])+','+lit(d['tag'])+','+lit('011'+str(uuid.uuid4().int%100000000).zfill(8))+",'EG',jsonb_build_object('plate_number',"+lit('QB'+c['registration'].replace('-','')[:10])+"),jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',notice_registration));execute 'reset role';assert intake->>'status'='created_unverified';"
     body+=actor(c['user_id'],c['session_id'])+"execute 'set local role authenticated';perform public.request_offline_customer_claim("+lit(c['claim_id'])+",(intake->>'enrollment_receipt_id')::uuid,intake->>'enrollment_secret','original_receipt',jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',notice_claim));perform public.submit_visit_recovery_request("+lit(c['case_nonce'])+",jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',notice_recovery));execute 'reset role';"
    body+='end$$;commit;';q.sql(body);d['setup_phase']='response_received';save(private,d)
   # Discovery only after an uncertain atomic setup, never rerun its producer.
   cases=[]
   for c in d['customers']:
    row=json.loads(q.sql('select jsonb_build_object(\'customer_id\',r.actor_id,\'profile_id\',r.profile_id,\'claim_id\',r.request_id,\'case_id\',v.case_id)from private.offline_claim_requests r join private.visit_recovery_customer_requests v on v.requester_id=r.actor_id where r.request_id='+lit(c['claim_id'])+' and r.actor_id='+lit(c['user_id'])+" and r.secret_proved and v.status='awaiting_matching';"));row['session_id']=c['session_id'];cases.append(row)
   exposed={k:d[k]for k in ['local_only','canonical_bridge_fixture','branch_id','owner_id','owner_session_id','before_rows','before_auth','before_counters']};exposed.update(branch_tag=d['tag'],cases=cases);save(public,exposed);d['setup_phase']='ready';save(private,d)
  else:
   # Concurrency harness settles its own command nonces and revokes exact links.
   assert q.sql('select not exists(select 1 from private.offline_customer_trusted_links where auth_user_id in('+','.join(lit(c['user_id'])for c in d['customers'])+')and revoked_at is null);')=='t'
   q.sql('update public.business_branches set is_active=false where branch_id='+lit(d['branch_id'])+' and name_en='+lit(d['tag'])+';')
   old_ids=','.join(lit(c['user_id'])for c in d['customers'])
   assert d['before_auth']==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u where id not in("+old_ids+');')
   d['cleanup_complete']=True;save(private,d)
 except Exception as error:d['last_error_type']=type(error).__name__;save(private,d);raise SystemExit('Incomplete QA setup; private journal retained; no blind reissue')from None
 print('PASS source-reviewed local bridge fixture '+a.action+'; credentials private')
if __name__=='__main__':main()
