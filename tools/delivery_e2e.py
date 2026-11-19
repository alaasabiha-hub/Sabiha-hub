"""Real local delivery contract test. Only synthetic accounts on loopback."""
import concurrent.futures,json,secrets,sys,urllib.request,urllib.error,urllib.parse,uuid
from pathlib import Path
accounts=json.loads(Path(sys.argv[1]).read_text());base=accounts['url'];key=accounts['anon_key']
assert urllib.parse.urlsplit(base).hostname=='127.0.0.1'
service=json.loads(Path(sys.argv[2]).read_text())['SERVICE_ROLE_KEY']
def call(path,data=None,token=None,method='POST',expected=None):
    request=urllib.request.Request(base+path,method=method,data=json.dumps(data).encode() if data is not None else None,headers={'apikey':key,'Authorization':'Bearer '+(token or key),'Content-Type':'application/json','Prefer':'return=representation'})
    try:
        with urllib.request.urlopen(request,timeout=30) as r:raw=r.read();result=json.loads(raw) if raw else None;code=r.status
    except urllib.error.HTTPError as e:code=e.code;result=json.loads(e.read())
    assert code in expected if expected else 200<=code<300,(path,code,result)
    return result
def login(role):
    user=accounts['users'][role];return call('/auth/v1/token?grant_type=password',{'email':user['email'],'password':user['password']})['access_token']
owner=login('owner');customer=login('customer');employee=login('employee')
def api(table,data=None,token=owner,method='POST',query='',expected=None):return call('/rest/v1/'+table+query,data,token,method,expected)
suffix=secrets.token_hex(4)
product=api('business_catalog_items',{'name':'Delivery local '+suffix,'item_type':'product','price':120,'stock_quantity':10,'is_active':True,'is_public':True},token=service)[0]
zone=api('business_delivery_zones',{'name':'Local delivery '+suffix,'fee':30})[0]
settings=api('business_contact_delivery_settings',token=owner,method='GET',query='?id=eq.true')[0]
api('business_contact_delivery_settings',{'delivery_enabled':True,'minimum_subtotal':100},query='?id=eq.true',method='PATCH')
items=[{'item_id':product['item_id'],'quantity':2}]
quote=api('rpc/quote_product_fulfillment',{'p_items':items,'p_method':'delivery','p_zone':zone['zone_id'],'p_coupon':None},customer)
assert quote['total']==270 and quote['delivery_fee']==30
payload={'p_items':items,'p_request_id':str(uuid.uuid4()),'p_method':'delivery','p_zone':zone['zone_id'],'p_address':'Local test street 1 building 2','p_phone':'+201000000001','p_note':'Synthetic delivery','p_coupon':None,'p_expected_total':270}
api('rpc/place_product_fulfillment',{**payload,'p_expected_total':1},customer,expected={400})
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:orders=list(pool.map(lambda _:api('rpc/place_product_fulfillment',payload,customer),range(2)))
assert orders[0]['order_id']==orders[1]['order_id'];order=orders[0]
assert api('business_catalog_items',token=service,method='GET',query='?select=stock_quantity&item_id=eq.'+product['item_id'])[0]['stock_quantity']==8
print('PASS real delivery quote, price tampering rejection and concurrent idempotency')
api('rpc/update_product_fulfillment',{'p_order':order['order_id'],'p_expected':'new','p_status':'cancelled','p_courier':None},customer)
assert api('business_catalog_items',token=service,method='GET',query='?select=stock_quantity&item_id=eq.'+product['item_id'])[0]['stock_quantity']==10
print('PASS real customer cancellation and stock restoration')
pickup=api('rpc/place_product_fulfillment',{**payload,'p_request_id':str(uuid.uuid4()),'p_method':'pickup','p_zone':None,'p_address':None,'p_phone':None,'p_expected_total':240},customer)
for before,after in [('new','confirmed'),('confirmed','preparing'),('preparing','delivered')]:api('rpc/update_product_fulfillment',{'p_order':pickup['order_id'],'p_expected':before,'p_status':after,'p_courier':None})
invoices=api('business_invoices',token=owner,method='GET',query='?select=invoice_id,total&order_id=eq.'+pickup['order_id']);assert len(invoices)==1 and invoices[0]['total']==240
notices=api('customer_order_notifications',token=customer,method='GET',query='?select=status&order_id=eq.'+pickup['order_id']);assert len(notices)==4
api('rpc/update_product_fulfillment',{'p_order':pickup['order_id'],'p_expected':'delivered','p_status':'cancelled','p_courier':None},expected={400})
print('PASS real pickup completion, single invoice and customer inbox updates')
# Restore pre-test operational settings; synthetic records remain available for review.
api('business_contact_delivery_settings',{k:settings[k] for k in ('delivery_enabled','minimum_subtotal','whatsapp_enabled','whatsapp_phone','whatsapp_message')},query='?id=eq.true',method='PATCH')
print('Real local delivery tests passed; no hosted or external provider calls.')
