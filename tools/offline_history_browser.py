"""SOURCE-ONLY plan by default. One local customer claim/link and received invoice.
AR390 then EN1440 reuse SAME profile/invoice: explicit scope, actual price/status,
read-only history, fresh-authorized PDF, decoded QR into same Flutter build8501.
Then owner revoke; cached PDF export and QR must deny/clear. No Auth creation,
payment, work completion, loyalty, HR updates, hosted traffic or raw receipt-code
artifacts. Root must approve/release exclusive DB before --execute. All QA retained,
links revoked/orders voided/setup hidden/gate restored false; outbox must remain0.
"""
import argparse
from collections import Counter
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
import traceback

from offline_customer_registration_browser import Harness as IntakeHarness
from service_booking_acceptance import Acceptance


def uid():return str(uuid.uuid4())
def lit(value):return "'"+str(value).replace("'","''")+"'"
class RedactedFailure(RuntimeError):pass

class Harness(IntakeHarness):
 def __init__(self,args):
  super().__init__(args)
  self.accepted_readonly_proof=args.accepted_readonly_proof
  self.accepted_readonly_state=args.accepted_readonly_state
  self.reused_readonly=False
  self.build_proof=args.build_proof or self.r/'walkin-history-routing-web-build-source.json'
  self.qr_app=args.qr_app_url.rstrip('/');assert self.qr_app=='http://127.0.0.1:8501'
  self.branch,self.service=uid(),uid();self.tokens={};self.staff=[];self.contract_hashes=None
  self.case={key:uid()for key in ['registration','claim','approve','command','revoke','cancel']}
  self.state_file=self.r/('offline-history-browser-state-'+self.tag+'.json')
  self.state={'tag':self.tag,'branch_id':self.branch,'service_id':self.service,'case':self.case,'completed_locales':[],'stage':'source_ready','cleanup_complete':False}
  self.proof={'local_only':True,'production_touched':False,'all_passed':False,'raw_secret_persisted':False,'auth_accounts_created':0,'payments_created':0,'hr_updates':0,'screens':[],'journeys':[],'render_errors':[],'blocked_requests':[],'blocked_unrelated_ad_claims':0}
  self.branch_created=self.service_created=self.gate_touched=False;self.secret_window=False;self.scope_notice=None;self.price=Decimal('137.45');self.invoice_token=None;self.scope_count=0
  self.out.mkdir(parents=True,exist_ok=True)
 def save_state(self):
  self.state.update(branch_created=self.branch_created,service_created=self.service_created,gate_touched=self.gate_touched)
  super().save_state()
 def sql(self,source):
  result=subprocess.run(self.command,input=source,text=True,capture_output=True,env=self.env,timeout=40)
  if result.returncode:raise RedactedFailure('Local SQL failed; output redacted')
  return result.stdout.strip()
 def http(self,path,data=None,role=None,method='POST',prefer='return=representation'):
  headers={'apikey':self.accounts['anon_key'],'Content-Type':'application/json','Prefer':prefer}
  if role:headers['Authorization']='Bearer '+self.tokens[role]
  req=urllib.request.Request(self.base+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
  try:
   with urllib.request.urlopen(req,timeout=30)as response:
    raw=response.read();return response.status,json.loads(raw)if raw.strip()else None
  except urllib.error.HTTPError as error:error.read();return error.code,None
 def rpc(self,name,data,role='owner'):
  status,result=self.http('/rest/v1/rpc/'+name,data,role)
  if status!=200:raise RedactedFailure('Unexpected RPC status '+name)
  return result
 def actor(self,role):return str(uuid.UUID(self.accounts['users'][role]['id']))
 def auth_fingerprint(self):return self.sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
 def preflight(self):
  self.verify_build();root=Path(__file__).resolve().parents[1]
  self.build_proof.resolve().relative_to(self.r)
  manifest=json.loads(self.build_proof.read_text());assert manifest['source_unchanged']
  assert self.proof['served_build_sha256']==manifest['main_dart_js_sha256']
  for origin in [self.app,self.qr_app]:
   with urllib.request.urlopen(origin+'/main.dart.js',timeout=30)as response:assert hashlib.sha256(response.read()).hexdigest()==self.proof['served_build_sha256']
  assert all((root/'build/web/main.dart.js').stat().st_mtime>=(root/path).stat().st_mtime for path in ['lib/offline_history.dart','lib/invoices.dart','lib/main.dart'])
  if self.accepted_readonly_proof:
   assert self.accepted_readonly_state,'Accepted readonly state must be supplied with its proof'
   for path in [self.accepted_readonly_proof,self.accepted_readonly_state]:path.resolve().relative_to(self.r)
   accepted=json.loads(self.accepted_readonly_proof.read_text());oldstate=json.loads(self.accepted_readonly_state.read_text())
   assert accepted['local_only']and not accepted['production_touched']
   assert accepted['served_build_sha256']==self.proof['served_build_sha256']
   assert oldstate['readonly_route_locales']==['ar','en']and oldstate['cleanup_complete']
   assert accepted.get('failed_stage')==oldstate['stage'] or accepted['all_passed']
   assert all(accepted.get(key)is True for key in ['auth_identities_unchanged','borrowed_qa_contracts_unchanged','qa_link_revoked','qa_invoice_void','gate_restored_disabled'])
   self.reused_readonly=True
   self.proof['accepted_readonly_reused']={'proof':str(self.accepted_readonly_proof),'state':str(self.accepted_readonly_state),
    'proof_sha256':hashlib.sha256(self.accepted_readonly_proof.read_bytes()).hexdigest(),
    'state_sha256':hashlib.sha256(self.accepted_readonly_state.read_bytes()).hexdigest(),'same_build':True,'locales':['ar','en']}
  assert self.sql('select not enabled from private.offline_history_runtime where id;')=='t'
  assert self.sql('select public_origin from public.business_invoice_portal_settings where id;')==self.qr_app,'Root must configure LOCAL QR origin8501 before any new invoice'
  assert self.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0'
  assert self.sql("select(clock_timestamp()at time zone'Africa/Cairo')::time between '00:01'and '23:50';")=='t'
  actor=self.actor('customer')
  budget=json.loads(self.sql('select json_build_object(\'hour\',count(*)filter(where created_at>clock_timestamp()-interval\'1 hour\'),\'day\',count(*)filter(where created_at>clock_timestamp()-interval\'1 day\'))from private.offline_claim_requests where actor_id='+lit(actor)+';'))
  assert budget['hour']<=4 and budget['day']<=19,'No new claim without legitimate remaining quota; never reset or switch actor'
  assert self.sql('select exists(select 1 from auth.users u join public.customers c on c.id=u.id where u.id='+lit(actor)+" and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<clock_timestamp()))and not exists(select 1 from private.offline_customer_trusted_links where auth_user_id="+lit(actor)+' and revoked_at is null);')=='t'
  self.proof['budget_preflight']=budget
  assert self.sql('select not exists(select 1 from public.business_branches where branch_id='+lit(self.branch)+')and not exists(select 1 from public.business_catalog_items where item_id='+lit(self.service)+');')=='t'
  journal=json.loads((self.r/'walkin-financial-concurrency-state.json').read_text());prior=json.loads((self.r/'walkin-financial-concurrency-proof.json').read_text())
  assert prior['all_passed']and prior['borrowed_contracts_untouched']and prior['only_explicit_journal_proven_qa_contracts_reused']
  assert journal['local_only']and journal['tag']==prior['tag']and set(journal['worker_roles'])=={'manager','other_employee'}
  self.staff=sorted(self.actor(role)for role in journal['worker_roles']);assert self.staff==sorted(journal['borrowed_contract_staff_ids'])
  self.contract_hashes=journal['borrowed_contract_hashes'];assert self.employment_hashes()==self.contract_hashes
  today=self.sql("select(clock_timestamp()at time zone'Africa/Cairo')::date;")
  for role,rate in zip(journal['worker_roles'],[15,25]):
   assert self.sql('select exists(select 1 from private.hr_employment where staff_id='+lit(self.actor(role))+" and salary=0 and currency='EGP'and commission_percent="+str(rate)+' and starts_on='+lit(today)+'::date and ends_on='+lit(today)+'::date);')=='t'
  assert self.sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id='+lit(self.actor('manager'))+' and acknowledged_at is null);')=='t'
  assert (self.r/'read_qr').is_file()
  self.scope_notice=self.sql("select private.offline_history_notice('ar');")
 def employment_hashes(self):return json.loads(self.sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+','.join(map(lit,self.staff))+');'))
 def setup(self):
  self.stage('backend-setup-secret-protected');self.secret_window=True
  try:
   for role in ['owner','manager','customer']:
    status,result=self.http('/auth/v1/token?grant_type=password',{'email':self.accounts['users'][role]['email'],'password':self.accounts['users'][role]['password']});assert status==200 and result['user']['id']==self.actor(role);self.tokens[role]=result['access_token']
   # Login timestamp effects are excluded from Auth identity hash; no Auth account is created.
   self.state['branch_dispatch_planned']=True;self.save_state()
   assert self.http('/rest/v1/business_branches',{'branch_id':self.branch,'name_ar':'QA History '+self.tag,'name_en':'QA History '+self.tag,'is_default':False},'owner')[0]in(200,201);self.branch_created=True;self.save_state()
   assert self.http('/rest/v1/business_branch_hours?branch_id=eq.'+self.branch,{'is_open':True,'opens_at':'00:00','closes_at':'23:59'},'owner','PATCH')[0]in(200,204)
   assert self.http('/rest/v1/staff_branch_access',[{'user_id':worker,'branch_id':self.branch}for worker in self.staff],'owner')[0]in(200,201)
   self.state['service_dispatch_planned']=True;self.save_state()
   assert self.http('/rest/v1/business_catalog_items',{'item_id':self.service,'branch_id':self.branch,'item_type':'service','name':'QA History '+self.tag,'name_en':'QA History '+self.tag,'vehicle_type':'sedan','price':float(self.price),'duration_minutes':5,'resource_key':'wash','is_active':True,'is_public':True},'owner',prefer='return=minimal')[0]in(200,201,204);self.service_created=True;self.save_state()
   reg={'accepted':True,'version':'offline-registration-v1','language':'en','text':self.sql("select private.offline_registration_notice('en');")}
   self.state['registration_dispatch_planned']=True;self.save_state()
   intake=self.rpc('register_offline_customer',{'p_request':self.case['registration'],'p_branch':self.branch,'p_name':'QA History '+self.tag,'p_phone':self.new_phone(),'p_country':'EG','p_car':{'plate_number':'HISTORY'+self.tag.upper()},'p_consent':reg,'p_duplicate_action':None,'p_review_reason':None},'manager')
   assert intake['status']=='created_unverified';self.case.update(profile_id=intake['offline_profile_id'],receipt_id=intake['enrollment_receipt_id']);self.save_state()
   secret=intake.pop('enrollment_secret');assert len(secret)==64
   consent={'accepted':True,'version':'offline-claim-v1','language':'en','text':self.sql("select private.offline_claim_notice('en');")}
   self.state['claim_dispatch_planned']=True;self.save_state()
   claimed=self.rpc('request_offline_customer_claim',{'p_request':self.case['claim'],'p_receipt':self.case['receipt_id'],'p_secret':secret,'p_mode':'original_receipt','p_consent':consent},'customer');secret=None;intake=None;assert claimed['status']=='pending_owner_review'
   self.state['approval_dispatch_planned']=True;self.save_state()
   approved=self.rpc('decide_offline_customer_claim',{'p_request':self.case['approve'],'p_claim':self.case['claim'],'p_decision':'approve_with_secret','p_reason':'QA History '+self.tag+' original receipt continuity verified','p_evidence_type':None});self.case['link_id']=approved['link_id'];self.save_state()
   self.state['work_dispatch_planned']=True;self.save_state()
   self.rpc('prepare_offline_walk_in',{'p_request':self.case['command'],'p_registration':self.case['registration'],'p_service':self.service,'p_expected_price':float(self.price),'p_cashier':self.actor('manager'),'p_staff_ids':self.staff,'p_notes':'QA History '+self.tag})
   placed=self.rpc('place_offline_walk_in',{'p_request':self.case['command']},'manager')['result'];self.case.update(order_id=placed['order_id'],invoice_id=placed['invoice_id'],invoice_number=placed['invoice_number']);self.save_state()
   self.rpc('ack_offline_walk_in_command',{'p_request':self.case['command']},'manager')
   facts=json.loads(self.sql('select json_build_object(\'token\',document_token,\'origin\',document_origin,\'total\',total)from public.business_invoices where invoice_id='+lit(self.case['invoice_id'])+';'))
   self.invoice_token=str(uuid.UUID(facts['token']));assert facts['origin']==self.qr_app and Decimal(str(facts['total']))==self.price
   self.gate_touched=True;self.sql('update private.offline_history_runtime set enabled=true where id;')
  finally:self.secret_window=False
 def guard(self,page,language):
  def route(request_route):
   request=request_route.request;parsed=urllib.parse.urlsplit(request.url);path=parsed.path
   api=any(x in path for x in ['/auth/v1/','/rest/v1/','/functions/v1/','/storage/v1/'])
   if api and parsed.netloc!=urllib.parse.urlsplit(self.base).netloc:self.proof['blocked_requests'].append('remote_api');request_route.abort();return
   if request.method=='OPTIONS':request_route.continue_();return
   name=path.rsplit('/',1)[-1]if'/rest/v1/rpc/'in path else None
   if name=='claim_customer_product_ad':self.proof['blocked_unrelated_ad_claims']+=1;request_route.fulfill(status=200,content_type='application/json',body='[]');return
   allowed=True
   if name=='accept_my_offline_history_scope':
    params=json.loads(request.post_data or'{}');notice=params.get('p_consent',{});rid=str(uuid.UUID(params['p_request']))
    allowed=language=='ar'and notice=={'accepted':True,'version':'offline-history-v1','language':'ar','text':self.scope_notice}
    if self.case.get('scope_request'):allowed=allowed and self.case['scope_request']==rid
    elif allowed:self.case['scope_request']=rid;self.save_state()
    if allowed:self.scope_count+=1
   elif name is not None:
    allowed=name in {'get_public_home','get_public_promotions','default_branch_id','get_public_customer_coupons','get_my_canonical_service_visits','get_my_reward_wallet','get_my_offline_history_context','get_my_offline_visit_history','list_invoice_documents','resolve_invoice_document','get_my_offline_invoice_by_token','search_invoice_documents'}
    if allowed and name=='get_my_offline_visit_history':
     params=json.loads(request.post_data or'{}');allowed=params=={'p_before_created_at':None,'p_before_order':None,'p_limit':25}
    if allowed and name in {'resolve_invoice_document','get_my_offline_invoice_by_token'}:
     params=json.loads(request.post_data or'{}');allowed=params.get('p_token')==self.invoice_token
   elif api and request.method not in ['GET','HEAD','OPTIONS']:allowed=path in ['/auth/v1/token','/auth/v1/logout']
   if allowed:request_route.continue_()
   else:self.proof['blocked_requests'].append(name or'forbidden_mutation');request_route.abort()
  page.route('**/*',route)
  def history_response(response):
   rpc=urllib.parse.urlsplit(response.url).path.rsplit('/',1)[-1]
   if response.request.method!='POST'or rpc not in {'accept_my_offline_history_scope','get_my_offline_history_context','get_my_offline_visit_history'}:return
   event={'rpc':rpc,'http_status':response.status,'language':language,'stage':self.state['stage']}
   try:
    value=response.json();event['response_type']=type(value).__name__
    if isinstance(value,dict):
     event['state']=value.get('state')if value.get('state')in {'available','consent_required','consent_recorded','acceptance_pending','review_required','link_required'}else 'other_or_missing'
     if rpc=='get_my_offline_visit_history':
      items=value.get('items');event['items_type']=type(items).__name__;event['item_count']=len(items)if isinstance(items,list)else None
      event['known_invoice_present']=isinstance(items,list)and any(isinstance(row,dict)and row.get('invoice_id')==self.case.get('invoice_id')for row in items)
      event['known_short_number_present']=isinstance(items,list)and any(isinstance(row,dict)and row.get('invoice_number')==self.case.get('invoice_number')for row in items)
   except Exception as error:event['shape_capture_error_type']=type(error).__name__
   self.proof.setdefault('history_rpc_metadata',[]).append(event)
  page.on('response',history_response)
  page.on('pageerror',lambda _:self.proof['render_errors'].append('javascript_error'))
  page.on('console',lambda m:self.proof['render_errors'].append('render_error')if'overflowed'in m.text or'EXCEPTION CAUGHT'in m.text else None)
 def customer_login(self,browser,language,width,origin=None,invoice=False):
  page=browser.new_page(viewport={'width':width,'height':1100},accept_downloads=True);page.set_default_timeout(25000);self.guard(page,language)
  t=lambda a,e:a if language=='ar'else e;self.stage(language+':customer-login')
  url=(origin or self.app)+('/?invoice='+self.invoice_token if invoice else'')
  page.goto(url);page.wait_for_selector('flutter-view',timeout=60000)
  semantics=page.locator('flt-semantics-placeholder')
  if semantics.count():semantics.evaluate('(e)=>e.click()')
  # Fresh origin has no cached Auth; root configured invoice coordinator holds token until login.
  if not invoice:
   page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
   if language=='en':page.get_by_role('button',name='EN',exact=True).click()
   page.get_by_role('button',name=t('تسجيل الدخول','Sign in'),exact=True).first.click()
  else:
   # Pending QR is held on the genuine public landing until the same customer signs in.
   page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
   if language=='en':page.get_by_role('button',name='EN',exact=True).click()
   page.get_by_role('button',name=t('تسجيل الدخول','Sign in'),exact=True).first.click()
  user=self.accounts['users']['customer']
  for ar,en,key in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:Acceptance.type_into(page,t(ar,en),user[key])
  field=page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True);field.press('Tab')
  with page.expect_response(lambda r:r.request.method=='POST'and r.url.startswith(self.base+'/auth/v1/token?'),timeout=30000)as signed:
   Acceptance.near(page,page.get_by_role('button',name=t('تسجيل الدخول','Sign in'),exact=True)).click()
  assert signed.value.status==200 and signed.value.json()['user']['id']==self.actor('customer')
  self.tokens['customer']=signed.value.json()['access_token'];return page
 def open_history(self,page,language):
  t=lambda a,e:a if language=='ar'else e;self.stage(language+':history-route')
  profile=page.get_by_role('button',name=re.compile(re.escape(t('حسابي','Profile'))))
  self.stage(language+':profile-control-ready');profile.first.wait_for(state='visible',timeout=30000)
  page.wait_for_timeout(450);profile.first.click()
  self.stage(language+':account-screen-ready')
  page.get_by_role('button',name=t('حفظ بياناتي','Save profile'),exact=True).wait_for(state='visible',timeout=30000)
  page.wait_for_timeout(450)
  self.stage(language+':history-tile-scroll')
  tile=page.get_by_role('button',name=re.compile(re.escape(t('سجل زيارات الاستقبال السابق','Previous reception history'))))
  if not tile.count():tile=page.get_by_text(t('سجل زيارات الاستقبال السابق','Previous reception history'),exact=True).first
  Acceptance.near(page,tile).click()
 def doc_assert(self,page,language):
  self.stage(language+':typed-invoice')
  number=page.get_by_text(re.compile('^'+re.escape(self.case['invoice_number'])+r'\n'))
  Acceptance.near(page,number);assert number.count()>0
  assert page.get_by_role('button',name=re.compile('Payment options|خيارات الدفع')).count()==0
  assert page.get_by_text('Tax not recorded in legacy invoice',exact=True).count()==0
  return page.get_by_role('button',name='تنزيل PDF مع QR / Download PDF with QR',exact=True)
 def pdf(self,page,language,width):
  from pypdf import PdfReader
  import pypdfium2 as pdfium
  control=self.doc_assert(page,language);Acceptance.near(page,control)
  with page.expect_response(lambda r:r.request.method=='POST'and '/rpc/get_my_offline_invoice_by_token'in r.url,timeout=30000)as checked,page.expect_download(timeout=30000)as downloaded:control.click()
  assert checked.value.status==200
  file=self.out/('offline-history-'+self.tag+'-'+language+'.pdf');downloaded.value.save_as(str(file));assert file.read_bytes().startswith(b'%PDF-')
  text=''.join(p.extract_text()for p in PdfReader(file).pages);assert str(self.price)in text and self.case['invoice_number']in text
  pdf=pdfium.PdfDocument(str(file));first=pdf[0];bitmap=first.render(scale=3);image=file.with_suffix('.png');bitmap.to_pil().save(image);bitmap.close();first.close();pdf.close()
  result=subprocess.run([str(self.r/'read_qr'),str(image)],capture_output=True,text=True,timeout=20)
  assert result.returncode==0;values=[v for line in result.stdout.splitlines()for v in json.loads(line).get('qr_values',[])]
  expected=self.qr_app+'/?invoice='+self.invoice_token;assert expected in values
  self.proof['journeys'][-1].update(pdf_downloaded=True,pdf_price_verified=True,qr_decoded_to_local_same_build=True)
  return expected
 def browser(self):
  from playwright.sync_api import sync_playwright,expect
  os.environ.pop('DEBUG',None);os.environ.pop('PWDEBUG',None)
  with sync_playwright()as p:
   browser=p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True,args=['--disk-cache-size=0','--media-cache-size=0'])
   kept=[]
   try:
    # Read-only actual new route first, before producer secrets or quota consumption.
    if self.reused_readonly:
     self.state['readonly_route_locales']=['ar','en'];self.save_state()
    else:
     self.state['readonly_route_locales']=[]
     for language,width in [('ar',390),('en',1440)]:
      page=self.customer_login(browser,language,width);self.open_history(page,language)
      expected='يلزم ربط إيصال ومراجعة هوية سارية من المالك.'if language=='ar'else'A receipt link and current owner-reviewed identity are required.'
      expect(page.get_by_text(expected,exact=True)).to_be_visible()
      self.state['readonly_route_locales'].append(language);self.save_state();page.close()
     assert self.state['readonly_route_locales']==['ar','en']
    self.setup()
    for language,width in [('ar',390),('en',1440)]:
     assert language not in self.state['completed_locales'],'Do not repeat accepted locale'
     page=self.customer_login(browser,language,width)
     if language=='en':
      with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_my_offline_visit_history'),timeout=30000)as history:self.open_history(page,language)
     else:self.open_history(page,language)
     if language=='ar':
      self.stage('ar:unchecked-history-scope');checkbox=page.get_by_role('checkbox',name='أوافق على نطاق عرض السجلات هذا',exact=True);Acceptance.near(page,checkbox);expect(checkbox).not_to_be_checked()
      record=page.get_by_role('button',name='تسجيل الموافقة',exact=True);expect(record).to_be_disabled();checkbox.click()
      with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_my_offline_visit_history'),timeout=30000)as history, page.expect_response(lambda r:r.request.method=='POST'and '/rpc/accept_my_offline_history_scope'in r.url,timeout=30000)as consent:Acceptance.near(page,record).click()
      assert consent.value.status==200
     else:assert page.get_by_role('checkbox',name='I agree to this history access scope',exact=True).count()==0
     self.stage(language+':actual-history-card')
     data=history.value.json();assert history.value.status==200 and data['state']=='available'and isinstance(data['items'],list)
     known=[row for row in data['items']if row.get('invoice_id')==self.case['invoice_id']]
     assert len(known)==1 and known[0]['invoice_number']==self.case['invoice_number']
     assert Decimal(str(known[0]['invoice_total']))==self.price and known[0]['service_status']=='received'
     self.proof.setdefault('history_known_invoice_checks',[]).append({'language':language,'http_status':200,'state':'available','item_count':len(data['items']),'known_invoice':True,'actual_price':True,'actual_received_status':True})
     open_control=page.get_by_role('button',name='فتح الفاتورة'if language=='ar'else'Open invoice',exact=True)
     Acceptance.near(page,open_control);expect(open_control).to_be_enabled()
     page.wait_for_timeout(450)
     self.safe_screenshot(page,language,width,'linked-history-no-secret')
     open_button=page.get_by_role('button',name='فتح الفاتورة'if language=='ar'else'Open invoice',exact=True)
     with page.expect_response(lambda r:r.request.method=='POST'and '/rpc/resolve_invoice_document'in r.url,timeout=30000)as generic,page.expect_response(lambda r:r.request.method=='POST'and '/rpc/get_my_offline_invoice_by_token'in r.url,timeout=30000)as typed:Acceptance.near(page,open_button).click()
     assert generic.value.status==403 and typed.value.status==200
     self.proof['journeys'].append({'language':language,'width':width,'same_profile_and_invoice':True,'scope_not_repeated':language=='en','own_actual_price_and_received_status':True,'generic_denied_typed_authorized':True})
     qr_url=self.pdf(page,language,width);self.safe_screenshot(page,language,width,'typed-invoice')
     qr_page=self.customer_login(browser,language,width,self.qr_app,invoice=True);kept.append(qr_page)
     self.doc_assert(qr_page,language);self.proof['journeys'][-1]['decoded_qr_fresh_login_authorized']=True
     self.state['completed_locales'].append(language);self.save_state();kept.append(page)
    # Revoke after all positives. Cached documents remain in memory only until fresh export denial.
    self.stage('owner-revoke-after-both-locales');self.revoke();self.case['revoked']=True;self.save_state()
    page=kept[-1];download=page.get_by_role('button',name='تنزيل PDF مع QR / Download PDF with QR',exact=True);Acceptance.near(page,download)
    with page.expect_response(lambda r:r.request.method=='POST'and '/rpc/get_my_offline_invoice_by_token'in r.url,timeout=30000)as denied:download.click()
    assert denied.value.status==403
    expect(page.get_by_role('button',name='تنزيل PDF مع QR / Download PDF with QR',exact=True)).to_have_count(0)
    self.proof['cached_pdf_reauthorized_denied_and_cleared']=True
    revoked=self.customer_login(browser,'ar',390,self.qr_app,invoice=True)
    self.stage('revoked-qr-fresh-session-denied')
    expect(revoked.get_by_text(re.compile('Invoice unavailable or not authorized'))).to_be_visible()
    expect(revoked.get_by_role('button',name='تنزيل PDF مع QR / Download PDF with QR',exact=True)).to_have_count(0)
    self.proof['fresh_qr_after_revocation_denied']=True;revoked.close()
    self.proof['scope_acceptance_exactly_once']=self.scope_count==1
   except Exception as error:
    self.proof['failure_locations']=[{'function':x.name,'line':x.lineno}for x in traceback.extract_tb(error.__traceback__)if Path(x.filename).name==Path(__file__).name]
    if 'page'in locals()and not self.secret_window:
     try:
      self.proof['failure_dom_summary']={'open_invoice_controls':page.get_by_role('button',name=re.compile('فتح الفاتورة|Open invoice')).count(),
       'scope_checkbox_count':page.get_by_role('checkbox').count(),'known_number_static_matches':page.get_by_text(self.case.get('invoice_number','unavailable'),exact=True).count()}
      page.evaluate("""()=>{const m=document.createElement('div');Object.assign(m.style,{position:'fixed',left:'0',right:'0',top:'90px',bottom:'65px',background:'#071a36',zIndex:'2147483647',pointerEvents:'none'});document.body.appendChild(m);} """)
      target=self.out/('history-'+self.tag+'-failure-content-masked.png');page.screenshot(path=str(target),mask=[page.get_by_role('textbox')]);target.chmod(0o600);self.proof['failure_masked_screenshot']=str(target)
     except Exception as diagnostic:self.proof['diagnostic_error_type']=type(diagnostic).__name__
    raise
   finally:browser.close()
 def revoke(self):return self.rpc('revoke_offline_customer_link',{'p_request':self.case['revoke'],'p_link':self.case['link_id'],'p_reason':'QA History '+self.tag+' remove reviewed reader access'})
 def cleanup(self):
  ok=True
  if self.gate_touched:
   try:self.sql('update private.offline_history_runtime set enabled=false where id;')
   except Exception:ok=False
  # IDs and exact tags were journaled BEFORE dispatch. Never trust only response flags.
  try:
   if self.state.get('branch_dispatch_planned'):
    exists=self.sql('select exists(select 1 from public.business_branches where branch_id='+lit(self.branch)+');')=='t'
    if exists:
     assert self.sql('select exists(select 1 from public.business_branches where branch_id='+lit(self.branch)+' and name_ar='+lit('QA History '+self.tag)+' and name_en='+lit('QA History '+self.tag)+' and not is_default);')=='t'
    self.branch_created=exists
  except Exception:self.branch_created=False;ok=False
  try:
   if self.state.get('service_dispatch_planned'):
    exists=self.sql('select exists(select 1 from public.business_catalog_items where item_id='+lit(self.service)+');')=='t'
    if exists:
     assert self.sql('select exists(select 1 from public.business_catalog_items where item_id='+lit(self.service)+' and branch_id='+lit(self.branch)+' and name='+lit('QA History '+self.tag)+' and name_en='+lit('QA History '+self.tag)+" and item_type='service'and price="+str(self.price)+" and duration_minutes=5 and resource_key='wash');")=='t'
    self.service_created=exists
  except Exception:
   # A UUID/tag mismatch blocks cleanup rather than touching an unvalidated row.
   self.service_created=False;ok=False
  self.save_state()
  if self.branch_created and self.state.get('registration_dispatch_planned'):
   try:
    if self.state.get('approval_dispatch_planned'):self.rpc('close_offline_claim_command',{'p_request':self.case['approve']})
    self.rpc('close_offline_customer_registration',{'p_request':self.case['registration'],'p_branch':self.branch},'manager')
    closed=self.rpc('close_offline_walk_in_command',{'p_request':self.case['command']},'manager')if self.state.get('work_dispatch_planned')else None
    registration=self.rpc('get_offline_customer_registration',{'p_request':self.case['registration']},'manager')
    profile=registration.get('offline_profile_id')
    if profile:
     uuid.UUID(profile);assert not self.case.get('profile_id')or profile==self.case['profile_id']
     assert self.sql('select exists(select 1 from private.offline_customer_profiles where profile_id='+lit(profile)+' and created_branch_id='+lit(self.branch)+' and full_name='+lit('QA History '+self.tag)+');')=='t';self.case['profile_id']=profile
     link=self.sql('select link_id from private.offline_customer_trusted_links where profile_id='+lit(profile)+' and auth_user_id='+lit(self.actor('customer'))+' and claim_id='+lit(self.case['claim'])+' and revoked_at is null;')
     if link:uuid.UUID(link);assert not self.case.get('link_id')or self.case['link_id']==link;self.case['link_id']=link;self.revoke()
    if closed and closed['status']=='succeeded':
     result=closed['result'];order=result['order_id'];invoice=result['invoice_id']
     assert profile and self.sql('select exists(select 1 from private.offline_walk_in_subjects s where s.order_id='+lit(order)+' and s.invoice_id='+lit(invoice)+' and s.profile_id='+lit(profile)+' and s.branch_id='+lit(self.branch)+' and not exists(select 1 from public.business_payment_events e where e.invoice_id=s.invoice_id));')=='t'
     self.case.update(order_id=order,invoice_id=invoice);self.rpc('cancel_offline_walk_in',{'p_request':self.case['cancel'],'p_order':order,'p_reason':'QA History '+self.tag+' void only unpaid received fixture'})
    if closed:self.rpc('ack_offline_walk_in_command',{'p_request':self.case['command']},'manager')
   except Exception:ok=False
  for created,path,payload,prefer in [(self.service_created,'/rest/v1/business_catalog_items?item_id=eq.'+self.service,{'is_active':False,'is_public':False},'return=minimal'),(self.branch_created,'/rest/v1/business_branches?branch_id=eq.'+self.branch,{'is_active':False,'temporarily_closed':True},'return=representation')]:
   if created:
    try:assert self.http(path,payload,'owner','PATCH',prefer)[0]in(200,204)
    except Exception:ok=False
  self.state['cleanup_complete']=ok;self.save_state();return ok

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--screenshots',type=Path,required=True);p.add_argument('--app-url',default='http://127.0.0.1:8080');p.add_argument('--qr-app-url',default='http://127.0.0.1:8501');p.add_argument('--build-proof',type=Path);p.add_argument('--accepted-readonly-proof',type=Path);p.add_argument('--accepted-readonly-state',type=Path);p.add_argument('--execute',action='store_true')
 args=p.parse_args();args.staff_role='manager';args.languages=['ar','en'];args.recover_request=None
 if not args.execute:print(__doc__);return
 h=Harness(args);before=auth=counters=None;ok=False
 try:
  h.preflight();before=h.snapshot();auth=h.auth_fingerprint();counters=h.counters();h.browser();ok=True
 except Exception as e:
  h.proof['error_type']=type(e).__name__;h.proof['failed_stage']=h.state['stage']
  h.proof['failure_locations']=[{'function':x.name,'line':x.lineno}for x in traceback.extract_tb(e.__traceback__)if Path(x.filename).name==Path(__file__).name]
 finally:
  cleanup=h.cleanup()
  try:
   if before is not None:
    after=h.snapshot();missing={t:sum((old-after.get(t,Counter())).values())for t,old in before.items()if old-after.get(t,Counter())}
    h.proof['preexisting_rows_unchanged_except_invoice_counter']=set(missing)<= {'private.document_number_counters'}
    added={t:sum((now-before.get(t,Counter())).values())for t,now in after.items()if now-before.get(t,Counter())}
    allowed={'public.business_branches','public.business_branch_hours','public.business_branch_resources','public.staff_branch_access','public.business_catalog_items','public.business_audit_log','public.business_orders','public.business_order_items','public.business_invoices','private.document_number_counters','private.offline_customer_profiles','private.offline_customer_contacts','private.offline_customer_car_refs','private.offline_customer_registration_requests','private.offline_customer_enrollment_receipts','private.offline_claim_requests','private.offline_claim_decisions','private.offline_customer_trusted_links','private.offline_claim_revocations','private.offline_claim_owner_commands','private.offline_history_scope_consents','private.offline_registration_closed_requests','private.offline_walk_in_commands','private.offline_walk_in_subjects','private.offline_walk_in_commissions','private.offline_walk_in_reception','private.offline_walk_in_events'}
    h.proof['new_row_counts']=added;h.proof['only_expected_new_tables']=set(added)<=allowed
    now=h.counters();expected=dict(counters);expected['INV']+=1 if h.case.get('invoice_id') else 0;h.proof['only_one_actual_invoice_counter_delta']=now==expected
    h.proof['auth_identities_unchanged']=auth==h.auth_fingerprint();h.proof['borrowed_qa_contracts_unchanged']=h.contract_hashes==h.employment_hashes()
    h.proof['exactly_one_claim_attempt']=h.sql('select count(*)from private.offline_claim_requests where request_id='+lit(h.case['claim'])+';')=='1'
    h.proof['qa_link_revoked']=not h.case.get('link_id')or h.sql('select revoked_at is not null from private.offline_customer_trusted_links where link_id='+lit(h.case['link_id'])+';')=='t'
    h.proof['qa_invoice_void']=not h.case.get('invoice_id')or h.sql('select status=\'void\'from public.business_invoices where invoice_id='+lit(h.case['invoice_id'])+';')=='t'
   h.proof['canonical_outbox_finally_empty']=h.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0'
   h.proof['gate_restored_disabled']=h.sql('select not enabled from private.offline_history_runtime where id;')=='t'
  except Exception as e:h.proof['preservation_error_type']=type(e).__name__;ok=False
  required=['preexisting_rows_unchanged_except_invoice_counter','only_expected_new_tables','only_one_actual_invoice_counter_delta','auth_identities_unchanged','borrowed_qa_contracts_unchanged','exactly_one_claim_attempt','qa_link_revoked','qa_invoice_void','canonical_outbox_finally_empty','gate_restored_disabled','cached_pdf_reauthorized_denied_and_cleared','fresh_qr_after_revocation_denied','scope_acceptance_exactly_once']
  h.proof['all_passed']=ok and cleanup and all(h.proof.get(k)is True for k in required)and len(h.state['completed_locales'])==2 and not h.proof['blocked_requests']and not h.proof['render_errors']
  h.proof_file.parent.mkdir(parents=True,exist_ok=True);h.proof_file.write_text(json.dumps(h.proof,indent=2,ensure_ascii=False)+'\n');h.proof_file.chmod(0o600);h.save_state()
 print('PASS actual linked-history AR390 EN1440 PDF/QR/revocation'if h.proof['all_passed']else'INCOMPLETE; sanitized stage retained, no secret artifacts')
 if not h.proof['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
