"""Real Auth/PostgREST/Storage checks against a loopback Supabase stack only."""
import argparse
import concurrent.futures
import datetime as dt
import json
from pathlib import Path
import secrets
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser=argparse.ArgumentParser()
parser.add_argument('status',type=Path)
parser.add_argument('--credentials-out',type=Path,required=True)
args=parser.parse_args()
status=json.loads(args.status.read_text())
base=status.get('API_URL') or status.get('api_url')
if urllib.parse.urlsplit(base or '').hostname not in ('127.0.0.1','localhost','::1'):raise SystemExit('Only loopback Supabase is allowed.')
anon=status.get('ANON_KEY') or status.get('anon_key') or status.get('PUBLISHABLE_KEY')
service=status.get('SERVICE_ROLE_KEY') or status.get('service_role_key') or status.get('SECRET_KEY')
if not anon or not service:raise SystemExit('Local API keys missing from status output.')

def call(path,method='GET',payload=None,token=None,key=None,raw=None,mime='application/json',expected=None,extra=None):
    actual_key=key or anon
    headers={'apikey':actual_key,'Content-Type':mime,'Accept':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    elif not actual_key.startswith('sb_'):headers['Authorization']='Bearer '+actual_key
    if extra:headers.update(extra)
    data=raw if raw is not None else json.dumps(payload).encode() if payload is not None else None
    request=urllib.request.Request(base+path,method=method,headers=headers,data=data)
    try:
        with urllib.request.urlopen(request,timeout=45) as response:
            content=response.read();code=response.status
            result=json.loads(content) if content and 'json' in response.headers.get('Content-Type','') else content
    except urllib.error.HTTPError as error:
        code=error.code;content=error.read()
        try:result=json.loads(content)
        except ValueError:result=content
    if expected is not None:
        assert code in expected,(path,code,result if code>=400 else 'unexpected status')
    elif not 200<=code<300:
        raise AssertionError((path,code,result))
    return result

def rest(table,method='GET',payload=None,token=None,query=None):
    query = dict(query or {})
    if token and table == 'bookings':
        query.setdefault('select','id,customer_id,service_name,vehicle_type,booking_date,booking_time,status,notes,created_at,vehicle_id,quoted_price,assigned_staff_ids')
    if token and table == 'customers':
        query.setdefault('select','id,full_name,phone,email,date_of_birth,created_at')
    return call('/rest/v1/'+table+('?' + urllib.parse.urlencode(query,safe='(),.*') if query else ''),method,payload,token,key=service if token is None else anon,extra={'Prefer':'return=representation'})

run=secrets.token_hex(4)
password=secrets.token_urlsafe(24)
users={}
for label,role in [('owner','owner'),('manager','manager'),('employee','employee'),('other_employee','employee'),('customer',None),('other_customer',None)]:
    email=f'{label}-{run}@sabiha.test'
    data={'email':email,'password':password,'email_confirm':True,'user_metadata':{'full_name':'Local '+label}}
    if role is None:data['user_metadata']['phone']='LOCAL-'+label+'-'+run
    user=call('/auth/v1/admin/users','POST',data,key=service)
    if role:
        # Identical display names deliberately test account-ID authorization.
        rest('staff_profiles','POST',{'user_id':user['id'],'full_name':'Local technician' if 'employee' in label else 'Local '+label,'role':role,'is_active':True,'permissions':{}})
    session=call('/auth/v1/token?grant_type=password','POST',{'email':email,'password':password})
    users[label]={'id':user['id'],'email':email,'password':password,'token':session['access_token']}
    verified=call('/auth/v1/user',token=session['access_token'])
    assert verified['id']==user['id']
print('PASS real Auth: owner/manager/employee/customer accounts and password sign-in')
# Keep synthetic accounts private for native/website tests; never save production credentials.
args.credentials_out.write_text(json.dumps({'url':base,'anon_key':anon,'users':users},indent=2));args.credentials_out.chmod(0o600)
owner=users['owner']['token'];customer=users['customer']['token'];other=users['other_customer']['token'];employee=users['employee']['token'];manager=users['manager']['token']
assert len(rest('customers',token=customer,query={'select':'id,full_name,email'}))==1
assert rest('customers',token=other,query={'select':'id','id':'eq.'+users['customer']['id']})==[]
call('/rest/v1/customers?select=password_hash',token=customer,expected={401,403})
rest('customers','PATCH',{'full_name':'Updated local customer'},customer,{'id':'eq.'+users['customer']['id']})
print('PASS PostgREST customer profile isolation, legacy hash protection and profile editing')
vehicle=rest('vehicles','POST',{'customer_id':users['customer']['id'],'brand':'Test','model':'Local','plate_number':'LOCAL-'+run},customer)[0]
service_item=rest('business_catalog_items','POST',{'item_type':'service','name':'Local wash '+run,'price':150,'vehicle_type':'Test'})[0]
product=rest('business_catalog_items','POST',{'item_type':'product','name':'Local product '+run,'price':100,'stock_quantity':3})[0]
booking_data={'customer_id':users['customer']['id'],'vehicle_id':vehicle['id'],'catalog_item_id':service_item['item_id'],'booking_date':(dt.date.today()+dt.timedelta(days=1)).isoformat(),'booking_time':'10:00'}
checkout=call('/rest/v1/rpc/place_customer_service_booking','POST',{
    'p_request':str(uuid.uuid4()),'p_service':service_item['item_id'],
    'p_branch':service_item['branch_id'],'p_vehicle':vehicle['id'],
    'p_date':booking_data['booking_date'],'p_time':booking_data['booking_time'],
    'p_expected_price':service_item['price'],'p_notes':None},customer)
booking=rest('bookings',token=customer,query={'id':'eq.'+checkout['booking_id']})[0]
assert float(booking['quoted_price'])==150
bad={**booking_data,'customer_id':users['other_customer']['id']}
call('/rest/v1/bookings','POST',bad,other,expected={400,403})
rest('bookings','PATCH',{'assigned_staff_ids':[users['employee']['id']],'status':'confirmed'},manager,{'id':'eq.'+booking['id']})
assert len(rest('bookings',token=employee,query={'select':'id,status','id':'eq.'+booking['id']}))==1
assert rest('bookings',token=users['other_employee']['token'],query={'select':'id,status','id':'eq.'+booking['id']})==[]
call('/rest/v1/bookings?id=eq.'+booking['id'],'PATCH',{'assigned_staff_ids':[users['other_employee']['id']]},employee,expected={400,403})
rest('bookings','PATCH',{'status':'in_progress'},employee,{'id':'eq.'+booking['id']})
rest('staff_profiles','PATCH',{'is_active':False},query={'user_id':'eq.'+users['employee']['id']})
assert rest('bookings',token=employee,query={'select':'id','id':'eq.'+booking['id']})==[]
rest('staff_profiles','PATCH',{'is_active':True},query={'user_id':'eq.'+users['employee']['id']})
print('PASS real booking snapshots, manager assignment, same-name isolation and immediate staff revocation')
request_id=str(uuid.uuid4());cart=[{'item_id':product['item_id'],'quantity':2}]
payload={'p_items':cart,'p_request_id':request_id,'p_customer_note':'Local test only','p_coupon_code':None}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(lambda _:call('/rest/v1/rpc/place_customer_product_order','POST',payload,customer),range(2)))
assert results[0][0]['order_id']==results[1][0]['order_id']
assert rest('business_catalog_items',query={'select':'stock_quantity','item_id':'eq.'+product['item_id']})[0]['stock_quantity']==1
print('PASS concurrent real Postgres checkout retry reserves stock exactly once')
order_id=results[0][0]['order_id']
rest('business_orders','PATCH',{'status':'cancelled'},query={'order_id':'eq.'+order_id})
assert rest('business_catalog_items',query={'select':'stock_quantity','item_id':'eq.'+product['item_id']})[0]['stock_quantity']==3
print('PASS real cancellation atomically restores reserved stock')
path=users['owner']['id']+'/local-'+run+'.pdf'
pdf=b'%PDF-1.4\n% synthetic local test document only\n%%EOF'
call('/storage/v1/object/business-documents/'+path,'POST',token=owner,raw=pdf,mime='application/pdf')
call('/storage/v1/object/authenticated/business-documents/'+path,token=customer,expected={400,401,403,404})
assert call('/storage/v1/object/authenticated/business-documents/'+path,token=owner)==pdf
signed=call('/storage/v1/object/sign/business-documents/'+path,'POST',{'expiresIn':60},owner)
url=signed.get('signedURL') or signed.get('signedUrl')
assert url
with urllib.request.urlopen(base+'/storage/v1'+url if url.startswith('/object/') else base+url,timeout=20) as response:
    assert response.read()==pdf
call('/storage/v1/object/business-documents/'+path,'POST',token=owner,raw=pdf+b'\n% replacement',mime='application/pdf',extra={'x-upsert':'true'})
print('PASS real private Storage upload, forbidden customer access, signed download and replacement')
doc=rest('business_documents','POST',{'category':'Other','title':'Local evidence '+run,'original_filename':'local.pdf','mime_type':'application/pdf','storage_path':path,'created_by':users['owner']['id']},owner)[0]
assert rest('business_documents',token=customer,query={'select':'document_id'})==[]
call('/functions/v1/ask-business-documents','POST',{'question':'expiry','consent':True},employee,expected={401,403})
call('/functions/v1/ask-business-documents','POST',{'question':'expiry','consent':False},owner,expected={400})
approved=rest('business_documents',token=owner,query={'select':'document_id','approved_at':'not.is.null'})
answer=call('/functions/v1/ask-business-documents','POST',{'question':'expiry','consent':True},owner,expected={503} if approved else {200})
if not approved:assert answer['citations']==[]
rest('business_documents','PATCH',{'approved_at':dt.datetime.now(dt.timezone.utc).isoformat()},owner,{'document_id':'eq.'+doc['document_id']})
call('/functions/v1/ask-business-documents','POST',{'question':'expiry','consent':True},owner,expected={503})
call('/functions/v1/dispatch-marketing-campaigns','POST',{},expected={401})
call('/functions/v1/dispatch-document-expiry-alerts','POST',{},expected={401})
print('PASS actual Edge gateway: owner/consent guards, unapproved evidence excluded, missing AI credentials explicit, dispatch unauthorized')
report_data={'p_from':dt.date.today().isoformat(),'p_to':dt.date.today().isoformat()}
report=call('/rest/v1/rpc/get_owner_report','POST',report_data,owner)
assert 'sales' in report and 'daily' in report
call('/rest/v1/rpc/get_owner_report','POST',report_data,customer,expected={401,403})
call('/rest/v1/rpc/get_owner_report','POST',report_data,manager,expected={401,403})
print('PASS real owner report RPC and financial authorization')
print('All real local service scenarios passed. No hosted URL or production data used.')
