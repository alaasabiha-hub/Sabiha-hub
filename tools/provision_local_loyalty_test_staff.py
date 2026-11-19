"""Create ONE dedicated LOCAL QA STAFF, never Auth for an offline customer.
No I/O without --execute. Existing Auth/staff/HR rows are immutable inputs.
Admin secret/password remain in private runtime memory/files, never client/Git/logs.
"""
import argparse,datetime,json,os,secrets,sys,urllib.request,urllib.error,urllib.parse,uuid
from pathlib import Path
from types import SimpleNamespace
from owner_redemption_rules_browser import Harness

def save(path,data):
 path.write_text(json.dumps(data,indent=2)+'\n');path.chmod(0o600)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
 if not a.execute:print(__doc__);return
 r=a.runtime.resolve();h=Harness(SimpleNamespace(runtime=r,proof=r/'unused',screenshots=r,app_url='http://127.0.0.1:8080'))
 assert h.base=='http://127.0.0.1:54321'
 statefile=r/'loyalty-component-staff.local.json';proof_file=r/'loyalty-component-staff-provision-proof.json'
 if statefile.exists():
  s=json.loads(statefile.read_text());assert s['local_only']and not s['production_touched']
  assert s.get('completed'),'Resolve existing provisioning journal before retrying a mutation'
  print('Dedicated local staff already provisioned; no repeated Auth or HR changes.');return
 tag='loyalty-staff-'+uuid.uuid4().hex[:12]
 s={'local_only':True,'production_touched':False,'tag':tag,'email':tag+'@example.invalid','password':secrets.token_urlsafe(32),'user_id':None,'completed':False}
 old_auth=h.sql("select jsonb_object_agg(id,md5((to_jsonb(u)-array['updated_at','last_sign_in_at'])::text))from auth.users u;")
 old_hr=h.sql("select md5(coalesce(string_agg(to_jsonb(e)::text,''order by staff_id),''))from private.hr_employment e;")
 save(statefile,s)
 key=h.settings['SERVICE_ROLE_KEY']
 def admin(path,body=None,method='POST'):
  req=urllib.request.Request(h.base+'/auth/v1/admin/'+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={'apikey':key,'Authorization':'Bearer '+key,'Content-Type':'application/json'})
  try:
   with urllib.request.urlopen(req,timeout=30)as response:return json.load(response)
  except urllib.error.HTTPError as e:
   e.read();raise RuntimeError('Local Auth Admin failed HTTP '+str(e.code))from None
 result=admin('users',{'email':s['email'],'password':s['password'],'email_confirm':True,'user_metadata':{'full_name':'QA isolated loyalty staff '+tag}})
 user=result.get('user',result);s['user_id']=str(uuid.UUID(user['id']));save(statefile,s)
 assert h.sql("select not exists(select 1 from public.staff_profiles where user_id='"+s['user_id']+"')and not exists(select 1 from private.hr_employment where staff_id='"+s['user_id']+"');")=='t'
 h.sql("insert into public.staff_profiles(user_id,full_name,role,permissions,is_active)values('"+s['user_id']+"','QA isolated loyalty staff "+tag+"','employee','{}',true);")
 owner=h.accounts['users']['owner'];h.token=h.call('/auth/v1/token?grant_type=password',{'email':owner['email'],'password':owner['password']})['access_token']
 today=datetime.date.fromisoformat(h.sql("select(clock_timestamp()at time zone'Africa/Cairo')::date;"));s['employment_request']=str(uuid.uuid4());save(statefile,s)
 h.rpc('hr_action',{'p_action':'employment','p_data':{'staff_id':s['user_id'],'request_id':s['employment_request'],'salary':0,'commission_percent':15,'currency':'EGP','starts_on':today.isoformat(),'ends_on':(today+datetime.timedelta(days=1)).isoformat()}})
 same_auth=h.sql("select '"+old_auth.replace("'","''")+"'::jsonb=(select jsonb_object_agg(id,md5((to_jsonb(u)-array['updated_at','last_sign_in_at'])::text))from auth.users u where id<>'"+s['user_id']+"');")=='t'
 same_hr=h.sql("select md5(coalesce(string_agg(to_jsonb(e)::text,''order by staff_id),''))from private.hr_employment e where staff_id<>'"+s['user_id']+"';")==old_hr
 assert same_auth and same_hr
 assert h.sql("select not exists(select 1 from public.staff_branch_access where user_id='"+s['user_id']+"');")=='t'
 s['completed']=True;save(statefile,s)
 proof={'local_only':True,'production_touched':False,'new_auth_staff_accounts':1,'offline_customer_auth_accounts_created':0,'old_auth_rows_unchanged':same_auth,'old_hr_contracts_unchanged':same_hr,'staff_role':'employee','branch_access_granted':False,'outgoing_email_or_sms_requested':False,'hr_created_via_owner_api':True,'credentials_kept_private':True,'staff_id':s['user_id']}
 save(proof_file,proof);print(json.dumps(proof))
if __name__=='__main__':
 try:main()
 except Exception as e:print('INCOMPLETE private provisioning journal retained; '+type(e).__name__);sys.exit(1)
