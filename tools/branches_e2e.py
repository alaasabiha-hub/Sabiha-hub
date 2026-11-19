"""Real branch pricing, schedules and concurrent capacity on isolated local Supabase."""
import concurrent.futures,datetime as dt,json,secrets,sys,urllib.request,urllib.error,urllib.parse
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

def login(role):
    u=accounts['users'][role];return call('/auth/v1/token?grant_type=password',{'email':u['email'],'password':u['password']})['access_token']
owner=login('owner');customer=login('customer');other=login('other_customer');manager=login('manager')
def api(table,data=None,token=owner,method='POST',query='',allowed=(200,201,204)):
    if table=='bookings' and 'select=' not in query:query+=('&' if query else '?')+'select=id,customer_id,quoted_price,status'
    if table=='business_catalog_items' and method=='PATCH':query+=('&' if query else '?')+'select=item_id,price'
    return call('/rest/v1/'+table+query,data,token,method,allowed)
suffix=secrets.token_hex(4);branch=api('business_branches',{'name_ar':'فرع اختبار '+suffix,'name_en':'Local branch '+suffix})[0];bid=branch['branch_id']
api('business_branch_resources',{'capacity':1},method='PATCH',query='?branch_id=eq.'+bid+'&resource_key=eq.wash')
item=api('business_catalog_items',{'branch_id':bid,'name':'Local branch service '+suffix,'item_type':'service','price':175,'duration_minutes':60,'is_active':True,'is_public':True},token=service)[0]
day=(dt.date.today()+dt.timedelta(days=30)).isoformat()
vehicles=[]
for role,token in [('customer',customer),('other_customer',other)]:
    vehicles.append(api('vehicles',{'customer_id':accounts['users'][role]['id'],'brand':'Local','model':'Capacity','plate_number':'LOCAL-'+secrets.token_hex(4)},token)[0])
payloads=[{'branch_id':bid,'catalog_item_id':item['item_id'],'vehicle_id':v['id'],'customer_id':v['customer_id'],'booking_date':day,'booking_time':'11:00'} for v in vehicles]
slots=api('rpc/available_booking_slots',{'p_branch':bid,'p_service':item['item_id'],'p_date':day},customer);assert any(s['slot_time']=='11:00:00' for s in slots)
def book(pair):
    payload,token=pair
    return api('bookings',payload,token,allowed=(201,400))
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(book,zip(payloads,[customer,other])))
success=[r for r in results if isinstance(r,list)];failure=[r for r in results if isinstance(r,dict)];assert len(success)==1 and len(failure)==1,(success,failure)
assert 'capacity' in failure[0]['message'];booking=success[0][0]
print('PASS real concurrent capacity: exactly one booking accepted')
assert not api('bookings',token=manager,method='GET',query='?select=id&branch_id=eq.'+bid)
api('business_catalog_items',{'price':240},token=owner,method='PATCH',query='?item_id=eq.'+item['item_id'])
row=api('bookings',token=owner,method='GET',query='?select=quoted_price&id=eq.'+booking['id'])[0];assert row['quoted_price']==175
print('PASS real branch manager isolation and immutable booked price snapshot')
api('business_branch_exceptions',{'branch_id':bid,'exception_date':(dt.date.today()+dt.timedelta(days=31)).isoformat(),'is_closed':True,'reason':'Synthetic closure'})
blocked=api('bookings',{**payloads[0],'booking_date':(dt.date.today()+dt.timedelta(days=31)).isoformat()},customer,allowed=(400,));assert 'closed' in blocked['message']
slots=api('rpc/available_booking_slots',{'p_branch':bid,'p_service':item['item_id'],'p_date':(dt.date.today()+dt.timedelta(days=31)).isoformat()},customer);assert slots==[]
print('PASS real schedule exception reflected in slots and insert validation')
api('bookings',{'status':'cancelled'},method='PATCH',query='?id=eq.'+booking['id'])
slots=api('rpc/available_booking_slots',{'p_branch':bid,'p_service':item['item_id'],'p_date':day},customer);assert any(s['slot_time']=='11:00:00' for s in slots)
print('PASS real cancellation immediately reopens capacity')
print('Real branch integration passed; synthetic local data only.')
