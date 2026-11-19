"""Verify email OTP, recovery, token refresh and logout on the local Auth service."""
import json,secrets,sys,urllib.request,urllib.error,urllib.parse
from pathlib import Path
status=json.loads(Path(sys.argv[1]).read_text());base=status['API_URL']
assert urllib.parse.urlsplit(base).hostname=='127.0.0.1'
anon=status['ANON_KEY'];service=status['SERVICE_ROLE_KEY']
def call(path,data=None,token=None,admin=False,expected=None,method='POST'):
 key=service if admin else anon
 req=urllib.request.Request(base+'/auth/v1/'+path,method=method,data=json.dumps(data).encode() if data is not None else None,headers={'apikey':key,'Authorization':'Bearer '+(token or key),'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=30) as r:
   raw=r.read();code=r.status;result=json.loads(raw) if raw else None
 except urllib.error.HTTPError as e:
  code=e.code;result=json.loads(e.read())
 assert code in expected if expected else 200<=code<300,(path,code,result)
 return result
email='otp-'+secrets.token_hex(4)+'@sabiha.test';password=secrets.token_urlsafe(20)
link=call('admin/generate_link',{'type':'signup','email':email,'password':password,'data':{'full_name':'Local OTP test','phone':'LOCAL-OTP-'+secrets.token_hex(4)}},admin=True)
code=link.get('properties',link)['email_otp']
session=call('verify',{'type':'signup','email':email,'token':code})
assert session['user']['email']==email
print('PASS real signup email OTP verification')
req=urllib.request.Request(base+'/rest/v1/customers?select=email_verified&id=eq.'+session['user']['id'],headers={'apikey':anon,'Authorization':'Bearer '+session['access_token']})
with urllib.request.urlopen(req,timeout=20) as r:assert json.load(r)[0]['email_verified'] is True
print('PASS captured Auth trigger synchronizes verified customer profile')
refreshed=call('token?grant_type=refresh_token',{'refresh_token':session['refresh_token']})
assert refreshed['user']['id']==session['user']['id']
recovery=call('admin/generate_link',{'type':'recovery','email':email},admin=True)
recovered=call('verify',{'type':'recovery','email':email,'token':recovery.get('properties',recovery)['email_otp']})
new_password=secrets.token_urlsafe(20)
call('user',{'password':new_password},token=recovered['access_token'],method='PUT')
call('token?grant_type=password',{'email':email,'password':password},expected={400})
new_session=call('token?grant_type=password',{'email':email,'password':new_password})
call('logout',token=new_session['access_token'])
call('token?grant_type=refresh_token',{'refresh_token':new_session['refresh_token']},expected={400})
print('PASS real token refresh, recovery password change, old-password rejection and logout refresh revocation')
