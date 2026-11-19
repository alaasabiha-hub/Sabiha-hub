"""Local-only actual cashier -> customer -> owner identity-review acceptance.

Default prints this plan only. --execute requires the root-approved current build
and consistent DB window. Two private QA intakes, two existing other_customer
claims (at most two NEW nonces), prepared owner approvals and revocations only.
No history/wallet bridge, Auth creation, phone verification or financial writes.
Secrets stay in RAM; visual/log artifacts are disabled from intake dispatch until
customer proof is erased. Failure cleanup fences known command/intake UUIDs before
checking and revoking ONLY validated current-case QA links. No registration or
approval fallback, deletion, quota reset or existing permission change.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.parse
import uuid

from offline_customer_registration_browser import Harness as IntakeHarness, NOTICE
from service_booking_acceptance import Acceptance

CLAIM_NOTICE = {
 'en':'I request owner review to link this reception receipt to my confirmed app account. I consent to this identity review. Phone matching alone is not proof. History and rewards remain unavailable until secure access is implemented.',
 'ar':'أطلب مراجعة المالك لربط إيصال الاستقبال بحسابي المؤكد في التطبيق وأوافق على مراجعة الهوية. تطابق الهاتف وحده ليس إثباتاً. تبقى السجلات والمكافآت غير متاحة حتى تنفيذ الوصول الآمن.',
}


class Harness(IntakeHarness):
 def __init__(self,args):
  super().__init__(args)
  self.state_file=self.r/('offline-claim-browser-state-'+self.tag+'.json')
  self.state={'tag':self.tag,'stage':'source_prepared','cases':[],'cleanup_complete':False}
  self.proof={'local_only':True,'production_touched':False,'financial_action_executed':False,
   'auth_account_created':False,'raw_secret_persisted':False,'screens':[],'journeys':[],
   'render_errors':[],'blocked_requests':[],'blocked_unrelated_ad_claims':0,'all_passed':False}
  self.tokens={};self.case=None;self.secret_digest=None
 def call_as(self,role,name,params):
  previous=self.token;self.token=self.tokens[role]
  try:return self.rpc(name,params)
  finally:self.token=previous
 def preflight(self):
  self.verify_build()
  root=Path(__file__).resolve().parents[1]
  manifest=json.loads((self.r/'offline-static-reference-web-build-source.json').read_text())
  assert manifest['source_unchanged'] and manifest['main_dart_js_sha256']==self.proof['served_build_sha256'],'Use the approved combined build'
  assert hashlib.sha256((root/'lib/offline_customer_claim.dart').read_bytes()).hexdigest()==manifest['source_after']['lib/offline_customer_claim.dart']
  actor=str(uuid.UUID(self.accounts['users']['other_customer']['id']))
  self.actor=actor
  self.branch=self.sql('select branch_id from public.business_branches where is_default and is_active;');uuid.UUID(self.branch)
  budget=json.loads(self.sql("select json_build_object('hour',count(*)filter(where created_at>clock_timestamp()-interval '1 hour'),'day',count(*)filter(where created_at>clock_timestamp()-interval '1 day'))from private.offline_claim_requests where actor_id='"+actor+"';"))
  assert budget['hour']<=3 and budget['day']<=18,'Do not reset limits; two legitimate claim slots required'
  current=self.sql("select exists(select 1 from auth.users a join public.customers c on c.id=a.id where a.id='"+actor+"'and a.email_confirmed_at is not null and a.deleted_at is null and(a.banned_until is null or a.banned_until<clock_timestamp()))and not exists(select 1 from private.offline_customer_trusted_links where auth_user_id='"+actor+"'and revoked_at is null);")
  assert current=='t','Existing confirmed customer without an active link required'
  self.proof['claim_budget_before']=budget
  assert self.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0','Root must settle its financial QA outbox before identity preservation window'
 def text(self,page):
  # Playwright CSS pierces Flutter open shadow roots; native document queries do not.
  # Values remain RAM-only and are never part of a locator/error or artifact.
  return page.locator('flt-semantics,[role=textbox],input:not([type=password]),textarea').evaluate_all("""nodes=>nodes.flatMap(n=>[n.textContent,n.getAttribute('aria-label'),n.getAttribute('aria-valuetext'),n.getAttribute('value'),n.value]).filter(value=>typeof value==='string').join('\\n')""")
 def probe(self,page,expected,prefix):
  target=page.locator('[aria-label^='+json.dumps(prefix,ensure_ascii=False)+']').or_(page.get_by_text(re.compile('^'+re.escape(prefix)))).first
  for _ in range(8):
   if target.count():
    box=target.first.bounding_box()
    if box and box['y']>=0 and box['y']+box['height']<=page.viewport_size['height']:
     value=target.first.get_attribute('aria-label')or target.first.text_content()or''
     if value.startswith(prefix)and expected in value:return True
   page.mouse.move(page.viewport_size['width']//2,550);page.mouse.wheel(0,140);page.wait_for_timeout(140)
  return False
 def enter(self,page,label,value):
  target=page.get_by_role('textbox',name=re.compile(re.escape(label))).first
  Acceptance.near(page,target).click();target.press('ControlOrMeta+A');target.press_sequentially(value,delay=10);target.press('Tab')
 def near_click(self,page,target):Acceptance.near(page,target).click()
 def label(self,language,arabic,english):return arabic if language=='ar'else english
 def install_guard(self,page,role):
  def guard(route):
   req=route.request;parsed=urllib.parse.urlsplit(req.url);path=parsed.path
   api=any(x in path for x in ['/auth/v1/','/rest/v1/','/functions/v1/','/storage/v1/'])
   if api and parsed.netloc!=urllib.parse.urlsplit(self.base).netloc:
    self.proof['blocked_requests'].append('remote_api');route.abort();return
   name=path.rsplit('/',1)[-1]if'/rest/v1/rpc/'in path else None
   if name=='claim_customer_product_ad':self.proof['blocked_unrelated_ad_claims']+=1;route.fulfill(status=200,content_type='application/json',body='[]');return
   reads={'get_public_home','get_public_promotions','default_branch_id','get_admin_console','get_public_customer_coupons','get_my_canonical_service_visits','get_my_reward_wallet','get_offline_customer_registration','get_my_offline_customer_claim','list_offline_customer_claim_reviews','get_offline_customer_claim_command','cashier_shift_totals'}
   writes={'register_offline_customer','request_offline_customer_claim','prepare_offline_claim_command','decide_offline_customer_claim','revoke_offline_customer_link'}
   valid=True
   if name in writes:
    p=json.loads(req.post_data or '{}');case=self.case
    rid=str(uuid.UUID(p['p_request']))
    if name=='register_offline_customer':
     valid=role=='manager'and p.get('p_branch')==self.branch and p.get('p_name')==case['name']and p.get('p_phone')==case['phone']and p.get('p_car',{}).get('plate_number')==case['plate']and p.get('p_duplicate_action')is None
     if valid:
      if case.get('intake_request'):valid=case['intake_request']==rid
      else:case['intake_request']=rid
    elif name=='request_offline_customer_claim':
     valid=role=='other_customer'and p.get('p_receipt')==case.get('receipt_id')and p.get('p_mode')=='original_receipt'and isinstance(p.get('p_secret'),str)and hashlib.sha256(p['p_secret'].encode()).hexdigest()==self.secret_digest
     if valid:
      if case.get('claim_request'):valid=case['claim_request']==rid
      else:case['claim_request']=rid
    elif name=='prepare_offline_claim_command':
     payload=p.get('p_payload',{});kind=p.get('p_kind')
     valid=role=='owner'and((kind=='decide'and payload.get('p_claim')==case.get('claim_request')and payload.get('p_decision')=='approve_with_secret')or(kind=='revoke'and payload.get('p_link')==case.get('link_id')))
     if valid:
      command={'request_id':rid,'kind':kind}
      if command not in case['commands']:case['commands'].append(command)
    elif name=='decide_offline_customer_claim':valid=role=='owner'and p.get('p_claim')==case.get('claim_request')and p.get('p_decision')=='approve_with_secret'and{'request_id':rid,'kind':'decide'}in case['commands']
    elif name=='revoke_offline_customer_link':valid=role=='owner'and p.get('p_link')==case.get('link_id')and{'request_id':rid,'kind':'revoke'}in case['commands']
    if valid:self.save_state()
   elif name is not None:valid=name in reads
   elif api and req.method not in ['GET','HEAD','OPTIONS']:valid=path in['/auth/v1/token','/auth/v1/logout']
   if not valid:self.proof['blocked_requests'].append(name or'forbidden_mutation');route.abort()
   else:route.continue_()
  page.route('**/*',guard)
  page.on('pageerror',lambda _:self.proof['render_errors'].append('javascript_error'))
  page.on('console',lambda m:self.proof['render_errors'].append('render_error')if'overflowed'in m.text or'EXCEPTION CAUGHT'in m.text else None)
 def login(self,browser,role,language,width):
  page=browser.new_page(viewport={'width':width,'height':1100});page.set_default_timeout(25000);self.install_guard(page,role)
  t=lambda a,e:self.label(language,a,e)
  self.stage(language+':'+role+':landing');page.goto(self.app);page.wait_for_selector('flutter-view',timeout=60000)
  semantics=page.locator('flt-semantics-placeholder')
  if semantics.count():semantics.evaluate('(e)=>e.click()')
  page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
  if language=='en':page.get_by_role('button',name='EN',exact=True).click()
  if role=='other_customer':
   page.get_by_role('button',name=t('تسجيل الدخول','Sign in'),exact=True).first.click()
  else:self.near_click(page,page.get_by_role('button',name=t('دخول الموظفين','Staff sign in'),exact=True))
  user=self.accounts['users'][role]
  for a,e,key in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:Acceptance.type_into(page,t(a,e),user[key])
  page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True).press('Tab')
  self.stage(language+':'+role+':existing-signin')
  with page.expect_response(lambda r:r.url.startswith(self.base+'/auth/v1/token?'),timeout=30000)as signed:
   self.near_click(page,page.get_by_role('button',name=t('تسجيل الدخول','Sign in'if role=='other_customer'else'Sign In'),exact=True))
  assert signed.value.status==200,'Existing account sign-in failed'
  self.tokens[role]=signed.value.json()['access_token']
  return page
 def admin_section(self,page,language,arabic,english):
  target=page.get_by_role('button',name=self.label(language,arabic,english),exact=True)
  for _ in range(12):
   if target.count():
    box=target.first.bounding_box()
    if box and 1<box['x']<page.viewport_size['width']-40:target.first.click();return
   reports=page.get_by_role('button',name=self.label(language,'التقارير','Reports'),exact=True)
   box=reports.first.bounding_box()if reports.count()else None
   page.mouse.move(page.viewport_size['width']//2,box['y']+30 if box else 225);page.mouse.wheel(500,0);page.wait_for_timeout(180)
  raise AssertionError('Admin section not reached')
 def intake(self,browser,language,width):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e);page=self.login(browser,'manager',language,width)
  self.admin_section(page,language,'التقارير','Reports')
  self.near_click(page,page.get_by_role('button',name=t('ورديات الكاشير','Cashier shifts'),exact=True))
  icon=page.get_by_role('button',name=t('تسجيل عميل بدون تطبيق','Register customer without the app'),exact=True);expect(icon).to_be_enabled();icon.click()
  assert page.get_by_role('textbox',name=re.compile('email|password|بريد|مرور',re.I)).count()==0
  self.stage(language+':intake:fill-before-secret')
  for a,e,v in [('اسم العميل','Customer name',self.case['name']),('رقم الهاتف','Phone number',self.case['phone']),('رقم اللوحة','Plate number',self.case['plate'])]:self.enter(page,t(a,e),v)
  consent=page.get_by_role('checkbox',name=t('وافق العميل على إشعار التسجيل هذا','The customer agreed to this registration notice'),exact=True);self.near_click(page,consent);expect(consent).to_be_checked()
  self.safe_screenshot(page,language,width,'intake-before-submit')
  self.secret_window=True;self.stage(language+':intake:dispatch-no-artifacts')
  with page.expect_response(lambda r:'/rpc/register_offline_customer'in r.url,timeout=35000)as saved:self.near_click(page,page.get_by_role('button',name=t('حفظ تسجيل العميل','Save customer registration'),exact=True))
  assert saved.value.status==200,'Actual intake failed'
  result=saved.value.json();secret=result.pop('enrollment_secret',None)
  assert isinstance(secret,str)and re.fullmatch('[0-9a-f]{64}',secret),'Invalid private code'
  assert result['status']=='created_unverified'and result['identity_verified']is False
  for field in ['offline_profile_id','enrollment_receipt_id']:uuid.UUID(result[field])
  self.case.update(profile_id=result['offline_profile_id'],receipt_id=result['enrollment_receipt_id']);self.secret_digest=hashlib.sha256(secret.encode()).hexdigest();self.save_state()
  self.scroll_top(page);self.stage(language+':intake:receipt-reference-probe')
  self.case['receipt_reference_visible']=self.probe(page,self.case['receipt_id'],t('مرجع إيصال العميل','Customer receipt reference')+': ');self.save_state()
  assert self.case['receipt_reference_visible'],'Actual receipt reference not detected'
  self.stage(language+':intake:staff-reference-probe')
  self.case['staff_reference_visible']=self.probe(page,self.case['intake_request'],t('مرجع استعادة الموظف','Staff recovery reference')+': ');self.save_state()
  assert self.case['staff_reference_visible'],'Actual staff recovery reference not detected'
  self.stage(language+':intake:private-code-ram-probe')
  self.case['private_code_visible']=self.probe(page,secret,t('رمز الإيصال السري · يظهر مرة واحدة','Private receipt code · shown once')+': ');self.save_state()
  assert self.case['private_code_visible'],'Actual receipt code not detected in memory'
  assert self.case['receipt_id']!=self.case['intake_request']
  self.stage(language+':intake:receipt-ack-control')
  checkbox=page.get_by_role('checkbox',name=t('حفظ العميل رمز الإيصال السري','The customer saved the private receipt code'),exact=True);Acceptance.near(page,checkbox);expect(checkbox).to_be_enabled()
  stored=self.sql("select encode(secret_hash,'hex')from private.offline_customer_enrollment_receipts where receipt_id='"+self.case['receipt_id']+"';")
  assert stored==self.secret_digest,'Private hash mismatch'
  checkbox.click();self.near_click(page,page.get_by_role('button',name=t('إنهاء وبدء تسجيل آخر','Finish and start another registration'),exact=True))
  self.scroll_top(page);assert secret not in self.text(page),'Producer did not clear code'
  safe=self.call_as('manager','get_offline_customer_registration',{'p_request':self.case['intake_request']});assert safe['enrollment_secret']is None
  page.close();return secret
 def open_customer(self,browser,language,width):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e);page=self.login(browser,'other_customer',language,width)
  self.stage(language+':customer:profile-link-tile')
  profile=page.get_by_role('button',name=re.compile(re.escape(t('حسابي','Profile'))))
  self.stage(language+':customer:profile-control-wait')
  profile.first.wait_for(state='visible',timeout=30000);self.stage(language+':customer:profile-control-click');profile.first.click()
  self.stage(language+':customer:account-link-scroll')
  tile=page.get_by_role('button',name=re.compile(re.escape(t('طلب ربط سجل زيارات سابق','Request a previous visit record link'))))
  if not tile.count():tile=page.get_by_text(re.compile(re.escape(t('طلب ربط سجل زيارات سابق','Request a previous visit record link')))).first
  self.near_click(page,tile)
  self.stage(language+':customer:claim-form-ready')
  from playwright.sync_api import expect
  expect(page.get_by_role('button',name=t('طلب مراجعة الهوية من المالك','Request owner identity review'),exact=True)).to_be_enabled()
  return page
 def customer(self,browser,language,width,secret,page):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e)
  self.enter(page,t('مرجع الإيصال الأصلي','Original receipt reference'),self.case['receipt_id'])
  self.enter(page,t('رمز الإيصال السري الأصلي','Original private receipt code'),secret)
  checkbox=page.get_by_role('checkbox',name=t('أوافق على مراجعة الهوية هذه','I agree to this identity review'),exact=True);self.near_click(page,checkbox);expect(checkbox).to_be_checked()
  self.stage(language+':customer:one-claim-dispatch')
  with page.expect_response(lambda r:'/rpc/request_offline_customer_claim'in r.url,timeout=35000)as requested:self.near_click(page,page.get_by_role('button',name=t('طلب مراجعة الهوية من المالك','Request owner identity review'),exact=True))
  assert requested.value.status==200,'Actual identity review request failed'
  result=requested.value.json();assert result['status']=='pending_owner_review','Only one legitimate claim attempt per case allowed'
  assert result['request_id']==self.case['claim_request']
  assert all(result['capabilities'][key]is False for key in ['history_visible','wallet_access','guest_redemption','reader_bridge_implemented'])
  self.scroll_top(page);refresh=page.get_by_role('button',name=t('فحص حالة طلبي','Check my review status'),exact=True);Acceptance.near(page,refresh);expect(refresh).to_be_enabled()
  body=self.text(page);assert secret not in body,'Customer proof was not erased after known result'
  assert page.get_by_role('textbox',name=t('رمز الإيصال السري الأصلي','Original private receipt code'),exact=True).count()==0
  return page
 def open_owner(self,browser,language,width):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e);page=self.login(browser,'owner',language,width)
  self.stage(language+':owner:security-nav');self.admin_section(page,language,'الأمان والصلاحيات','Security')
  with page.expect_response(lambda r:'/rpc/list_offline_customer_claim_reviews'in r.url,timeout=30000)as listed:self.near_click(page,page.get_by_role('button',name=t('مراجعة ربط سجلات العملاء','Review customer record links'),exact=True))
  assert listed.value.status==200
  return page
 def owner(self,browser,language,width,page):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e)
  self.stage(language+':owner:refresh-current-case')
  with page.expect_response(lambda r:'/rpc/list_offline_customer_claim_reviews'in r.url,timeout=30000)as listed:self.near_click(page,page.get_by_role('button',name=t('تحديث مراجعات الهوية','Refresh identity reviews'),exact=True))
  assert listed.value.status==200
  rows=listed.value.json();assert rows and rows[0]['claim_id']==self.case['claim_request']and rows[0]['profile_reference']==self.case['profile_id'],'Never approve a different case'
  row=rows[0];assert row['secret_proved']and row['confirmed_account_current']and row['contact_current']
  self.scroll_top(page);self.near_click(page,page.get_by_role('button',name=t('مراجعة الإثبات','Review evidence'),exact=True).first)
  self.enter(page,t('الإثبات الفعلي وسبب القرار','Actual review evidence and reason'),'Synthetic local QA original receipt and current account evidence checked')
  approve=page.get_by_role('button',name=t('الموافقة على إثبات الإيصال الأصلي بعد مراجعته','Approve the reviewed original receipt evidence'),exact=True);Acceptance.near(page,approve);expect(approve).to_be_enabled()
  self.stage(language+':owner:prepared-approve')
  with page.expect_response(lambda r:'/rpc/prepare_offline_claim_command'in r.url,timeout=30000)as prepared,page.expect_response(lambda r:'/rpc/decide_offline_customer_claim'in r.url,timeout=35000)as decided:approve.click()
  assert prepared.value.status==200 and prepared.value.json()['state']=='open'and decided.value.status==200
  result=decided.value.json();assert result['status']=='approved_pending_reader_bridge'and result['claim_id']==self.case['claim_request']
  self.case['link_id']=str(uuid.UUID(result['link_id']));self.save_state()
  ack=page.get_by_role('button',name=t('تأكيد هذه النتيجة','Acknowledge this result'),exact=True);Acceptance.near(page,ack);expect(ack).to_be_enabled();self.safe_screenshot(page,language,width,'owner-approved-no-access');ack.click()
  return page
 def customer_status(self,page,language,wanted):
  t=lambda a,e:self.label(language,a,e);self.stage(language+':customer:status-'+wanted)
  with page.expect_response(lambda r:'/rpc/get_my_offline_customer_claim'in r.url,timeout=30000)as checked:self.near_click(page,page.get_by_role('button',name=t('فحص حالة طلبي','Check my review status'),exact=True))
  assert checked.value.status==200 and checked.value.json()['status']==wanted
  assert all(checked.value.json()['capabilities'][key]is False for key in ['history_visible','wallet_access','guest_redemption','reader_bridge_implemented'])
 def revoke_ui(self,page,language,width):
  from playwright.sync_api import expect
  t=lambda a,e:self.label(language,a,e);self.stage(language+':owner:prepared-revoke')
  field=page.get_by_role('textbox',name=t('الإثبات الفعلي وسبب القرار','Actual review evidence and reason'),exact=True)
  if not field.count():self.near_click(page,page.get_by_role('button',name=t('مراجعة الإثبات','Review evidence'),exact=True).first)
  self.enter(page,t('الإثبات الفعلي وسبب القرار','Actual review evidence and reason'),'Synthetic local QA complete; revoke test identity approval')
  revoke=page.get_by_role('button',name=t('إلغاء الموافقة على الهوية','Revoke identity approval'),exact=True);Acceptance.near(page,revoke);expect(revoke).to_be_enabled()
  with page.expect_response(lambda r:'/rpc/prepare_offline_claim_command'in r.url,timeout=30000)as prepared,page.expect_response(lambda r:'/rpc/revoke_offline_customer_link'in r.url,timeout=35000)as revoked:revoke.click()
  assert prepared.value.status==200 and revoked.value.status==200 and revoked.value.json()['link_id']==self.case['link_id']and revoked.value.json()['status']=='revoked'
  self.case['revoked']=True;self.save_state()
  ack=page.get_by_role('button',name=t('تأكيد هذه النتيجة','Acknowledge this result'),exact=True);Acceptance.near(page,ack);expect(ack).to_be_enabled();ack.click()
 def browser(self):
  os.environ.pop('DEBUG',None);os.environ.pop('PWDEBUG',None)
  from playwright.sync_api import sync_playwright
  with sync_playwright()as playwright:
   browser=playwright.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True,args=['--disk-cache-size=0','--media-cache-size=0'])
   try:
    for language,width in [('ar',390),('en',1440)]:
     self.case={'language':language,'width':width,'name':'QA Claim '+self.tag+' '+language.upper(),'phone':self.new_phone(),'plate':'QA-'+self.tag[:6]+'-'+language.upper(),'commands':[],'revoked':False}
     # Phone/name/car are synthetic. Do not persist proof or plaintext code.
     self.state['cases'].append(self.case);self.save_state()
     secret=None;customer=None;owner=None
     try:
      # Check unverified navigation BEFORE creating a private intake or spending a claim slot.
      customer=self.open_customer(browser,language,width)
      owner=self.open_owner(browser,language,width)
      readonly_now=self.snapshot();assert not any(old-readonly_now[table]for table,old in self.baseline.items()),'Baseline changed before intake; abort without writes'
      self.case['readonly_routes_ready']=True;self.save_state()
      secret=self.intake(browser,language,width)
      customer=self.customer(browser,language,width,secret,customer)
      secret=None;self.secret_digest=None;self.secret_window=False;self.save_state()
      self.stage(language+':customer:proof-erased');self.safe_screenshot(customer,language,width,'customer-pending-review')
      owner=self.owner(browser,language,width,owner)
      self.customer_status(customer,language,'approved_pending_reader_bridge');self.safe_screenshot(customer,language,width,'customer-approved-access-unavailable')
      self.revoke_ui(owner,language,width);self.customer_status(customer,language,'revoked');self.safe_screenshot(customer,language,width,'customer-revoked')
      self.proof['journeys'].append({'language':language,'width':width,'intake_request':self.case['intake_request'],'claim_request':self.case['claim_request'],'profile_id':self.case['profile_id'],'receipt_reference_distinct':True,'code_ui_and_hash_verified_in_ram':True,'customer_proof_erased':True,'prepared_owner_approval':True,'customer_approved_status':True,'prepared_owner_revocation':True,'customer_revoked_status':True,'history_wallet_rewards_unavailable':True})
      self.case['journey_complete']=True;self.save_state()
     finally:
      secret=None;self.secret_digest=None
      if customer:customer.close()
      if owner:owner.close()
      self.secret_window=False
    assert len(self.proof['journeys'])==2 and not self.proof['blocked_requests']and not self.proof['render_errors']
   finally:browser.close()
 def cleanup(self):
  errors=[]
  for case in self.state['cases']:
   try:
    # Settle/fence commands FIRST; an absence read alone is not an abort.
    for command in case['commands']:
     self.call_as('owner','close_offline_claim_command',{'p_request':command['request_id']})
    if case.get('intake_request'):
     settled=self.call_as('manager','close_offline_customer_registration',{'p_request':case['intake_request'],'p_branch':self.branch})
     if settled.get('offline_profile_id'):case['profile_id']=settled['offline_profile_id']
    if not case.get('profile_id')or not case.get('claim_request'):continue
    profile=str(uuid.UUID(case['profile_id']));claim=str(uuid.UUID(case['claim_request']))
    links=json.loads(self.sql("select coalesce(jsonb_agg(jsonb_build_object('link_id',l.link_id,'revoked',l.revoked_at is not null)),'[]'::jsonb)from private.offline_customer_trusted_links l join private.offline_customer_profiles p on p.profile_id=l.profile_id join private.offline_claim_requests c on c.request_id=l.claim_id where l.profile_id='"+profile+"'and l.claim_id='"+claim+"'and l.auth_user_id='"+self.actor+"'and p.full_name like'QA Claim "+self.tag+" %'and p.created_branch_id='"+self.branch+"';"))
    for link in links:
     if link['revoked']:continue
     cleanup_id=str(uuid.uuid4());payload={'p_link':link['link_id'],'p_reason':'Synthetic local QA cleanup after browser acceptance'}
     case['commands'].append({'request_id':cleanup_id,'kind':'revoke'});self.save_state()
     try:
      self.call_as('owner','prepare_offline_claim_command',{'p_request':cleanup_id,'p_kind':'revoke','p_payload':payload})
      self.call_as('owner','revoke_offline_customer_link',{'p_request':cleanup_id,**payload})
     except Exception:
      self.call_as('owner','close_offline_claim_command',{'p_request':cleanup_id})
      raise
    assert self.sql("select not exists(select 1 from private.offline_customer_trusted_links where profile_id='"+profile+"'and revoked_at is null);")=='t'
    case['revoked']=True
   except Exception as error:errors.append(type(error).__name__)
  self.state['cleanup_complete']=not errors;self.save_state()
  if errors:self.proof['cleanup_error_types']=errors
  return not errors


def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--screenshots',type=Path,required=True);p.add_argument('--app-url',default='http://127.0.0.1:8080');p.add_argument('--execute',action='store_true')
 args=p.parse_args();args.staff_role='manager';args.languages=['ar','en'];args.recover_request=None
 if not args.execute:print(__doc__);return
 h=Harness(args);before=None;auth=None;counters=None;ok=False
 try:
  h.preflight();before=h.snapshot();h.baseline=before;auth=h.auth_fingerprint();counters=h.counters();h.browser();ok=True
 except Exception as error:h.proof['error_type']=type(error).__name__;h.proof['failed_stage']=h.state['stage']
 finally:
  clean=h.cleanup()if h.state['cases']else True
  if before is not None:
   try:
    after=h.snapshot();missing={t:sum((r-after[t]).values())for t,r in before.items()if r-after[t]}
    added={t:sum((r-before[t]).values())for t,r in after.items()if r-before[t]}
    h.proof.update(preexisting_rows_unchanged=not missing,changed_preexisting_tables=missing,new_row_counts=added,document_counters_unchanged=h.counters()==counters,auth_user_ids_and_count_unchanged=h.auth_fingerprint()==auth)
    allowed={'public.business_audit_log',*['private.'+x for x in ['offline_customer_profiles','offline_customer_contacts','offline_customer_car_refs','offline_customer_registration_requests','offline_customer_enrollment_receipts','offline_registration_closed_requests','offline_claim_requests','offline_claim_decisions','offline_customer_trusted_links','offline_claim_revocations','offline_claim_owner_commands']]}
    h.proof['only_expected_private_identity_and_audit_added']=not(set(added)-allowed)
    h.proof['claim_attempt_delta']=added.get('private.offline_claim_requests',0);assert h.proof['claim_attempt_delta']<=2
   except Exception as error:h.proof['preservation_error_type']=type(error).__name__
  h.proof['qa_links_revoked']=clean;h.proof['all_passed']=ok and clean and all(h.proof.get(k)for k in ['preexisting_rows_unchanged','document_counters_unchanged','auth_user_ids_and_count_unchanged','only_expected_private_identity_and_audit_added'])
  args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(h.proof,indent=2,ensure_ascii=False)+'\n');args.proof.chmod(0o600)
 if not h.proof['all_passed']:raise SystemExit('FAIL combined identity browser; inspect sanitized stage/proof. QA retained and known actions fenced; no secret artifacts.')
 print('PASS actual cashier/customer/owner AR390 EN1440; two private reviewed then revoked claims; no history/wallet access, Auth creation, financial or prior-row changes')
if __name__=='__main__':main()
