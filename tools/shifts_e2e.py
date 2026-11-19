"""Real local shift accounting with synthetic invoices only."""
import concurrent.futures,json,secrets,sys,urllib.request,urllib.error,urllib.parse,uuid
from pathlib import Path
accounts=json.loads(Path(sys.argv[1]).read_text());status=json.loads(Path(sys.argv[2]).read_text());base=accounts['url'];key=accounts['anon_key'];service=status['SERVICE_ROLE_KEY']
assert urllib.parse.urlsplit(base).hostname=='127.0.0.1'
def call(path,data=None,token=None,method='POST',allowed=(200,201,204)):
    req=urllib.request.Request(base+path,method=method,data=json.dumps(data).encode() if data is not None else None,headers={'apikey':key,'Authorization':'Bearer '+(token or key),'Content-Type':'application/json','Prefer':'return=representation'})
    try:
        with urllib.request.urlopen(req,timeout=30) as r:raw=r.read();result=json.loads(raw) if raw else None;code=r.status
    except urllib.error.HTTPError as e:code=e.code;result=json.loads(e.read())
    assert code in allowed,(path,code,result)
    return result
u=accounts['users']['owner'];owner=call('/auth/v1/token?grant_type=password',{'email':u['email'],'password':u['password']})['access_token']
def api(table,data=None,token=owner,method='POST',query='',allowed=(200,201,204)):return call('/rest/v1/'+table+query,data,token,method,allowed)
bid=api('business_branches',method='GET',query='?select=branch_id&is_default=eq.true')[0]['branch_id'];sid=str(uuid.uuid4());suffix=secrets.token_hex(5)
# Complete any earlier synthetic test shift only if this test owner created it.
for existing in api('business_cashier_shifts',method='GET',query='?branch_id=eq.'+bid+'&cashier_id=eq.'+u['id']+'&status=neq.closed'):
    if existing['status']=='open':
        t=api('rpc/cashier_shift_totals',{'p_shift':existing['shift_id']});api('rpc/close_cashier_shift',{'p_shift':existing['shift_id'],'p_actual':t['expected_cash'],'p_reason':'Synthetic prior test reconciliation'})
    api('rpc/approve_cashier_shift',{'p_shift':existing['shift_id']})
api('rpc/open_cashier_shift',{'p_request':sid,'p_branch':bid,'p_opening':100})
invoice='LOCAL-SHIFT-'+suffix
api('business_invoices',{'invoice_id':invoice,'branch_id':bid,'service_name':'Synthetic shift sale','total':150},service)
payload={'p_shift':sid,'p_invoice':invoice,'p_event':'sale','p_method':'cash'}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:ids=list(pool.map(lambda _:api('rpc/record_shift_payment',{**payload,'p_request':str(uuid.uuid4())}),range(2)))
assert ids[0]==ids[1]
api('rpc/record_shift_movement',{'p_request':str(uuid.uuid4()),'p_shift':sid,'p_type':'expense','p_amount':20,'p_reason':'Synthetic shift expense'})
t=api('rpc/cashier_shift_totals',{'p_shift':sid});assert t['expected_cash']==230
print('PASS real concurrent payment recording once and server cash total')
api('rpc/close_cashier_shift',{'p_shift':sid,'p_actual':225,'p_reason':''},allowed=(400,))
t=api('rpc/close_cashier_shift',{'p_shift':sid,'p_actual':225,'p_reason':'Synthetic cash difference'});assert t['difference']==-5
api('rpc/record_shift_movement',{'p_request':str(uuid.uuid4()),'p_shift':sid,'p_type':'deposit','p_amount':5,'p_reason':'Late synthetic deposit'},allowed=(400,))
api('rpc/approve_cashier_shift',{'p_shift':sid})
assert api('business_cashier_shifts',method='GET',query='?shift_id=eq.'+sid)[0]['status']=='closed'
print('PASS real close explanation, sealed ledger and owner approval')
print('Shift integration passed. No real financial transaction performed.')
