"""New actual owner assistant acceptance only. No business/loyalty/payment writes.
Reads existing default-branch evidence; no fixtures and no paid/network providers.
"""
import argparse,json,hashlib,urllib.parse,urllib.request,re
from pathlib import Path
from owner_redemption_rules_browser import Harness
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for key in ['runtime','proof','screenshots']:p.add_argument('--'+key,type=Path,required=True)
 p.add_argument('--language',choices=['ar','en'],required=True);p.add_argument('--app-url',default='http://127.0.0.1:8080');p.add_argument('--execute',action='store_true');a=p.parse_args()
 if not a.execute:print(__doc__);return
 h=Harness(a);repo=Path(__file__).resolve().parents[1];manifest=json.loads((h.r/'free-owner-assistant-web-build-source.json').read_text());assert manifest['exit_code']==0 and manifest['source_unchanged']
 for file,digest in manifest['source_after'].items():assert hashlib.sha256((repo/file).read_bytes()).hexdigest()==digest
 with urllib.request.urlopen(h.app+'/main.dart.js')as response:assert hashlib.sha256(response.read()).hexdigest()==manifest['main_dart_js_sha256']
 before=Intake.snapshot(h);counters=Intake.counters(h);out=a.screenshots;out.mkdir(parents=True,exist_ok=True)
 proof={'local_only':True,'production_touched':False,'language':a.language,'no_fixture_or_business_mutations':True,'build_sha256':manifest['main_dart_js_sha256'],'rpc_metadata':[],'blocked_requests':[],'render_errors':[],'all_passed':False}
 def save():a.proof.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');a.proof.chmod(0o600)
 from playwright.sync_api import sync_playwright,expect
 try:
  with sync_playwright()as pw:
   browser=pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
   try:
    ar=a.language=='ar';t=lambda arabic,english:arabic if ar else english;page=browser.new_page(viewport={'width':390 if ar else 1440,'height':1100});page.set_default_timeout(25000)
    def guard(route):
     req=route.request;url=urllib.parse.urlsplit(req.url);rpc=url.path.rsplit('/',1)[-1]if'/rest/v1/rpc/'in url.path else None
     if rpc=='claim_customer_product_ad':route.fulfill(status=200,content_type='application/json',body='[]');return
     allowed={'get_public_home','get_public_promotions','default_branch_id','get_admin_console','get_owner_business_insights'}
     font=req.method in('GET','HEAD')and url.hostname=='fonts.gstatic.com'and url.path.startswith('/s/')and url.path.endswith('.woff2')and not url.query
     bad=url.scheme in('http','https')and url.hostname!='127.0.0.1'and not font
     bad|=rpc is not None and rpc not in allowed
     bad|=req.method not in('GET','HEAD','OPTIONS')and rpc is None and url.path not in('/auth/v1/token','/auth/v1/logout','/functions/v1/owner-evidence-advisor')
     if url.path=='/functions/v1/owner-evidence-advisor'and req.method=='POST':
      body=json.loads(req.post_data or '{}');bad|=body.get('action')!='ask'or body.get('question')not in('summary','billing','collections','expenses','stock','bookings','reviews','profit','forecast')
     if bad:proof['blocked_requests'].append({'path':url.path,'method':req.method});route.abort()
     else:route.continue_()
    page.route('**/*',guard);page.on('pageerror',lambda _:proof['render_errors'].append('javascript_error'));page.on('console',lambda msg:proof['render_errors'].append('flutter_render_error')if'overflowed'in msg.text or'EXCEPTION CAUGHT'in msg.text else None)
    page.on('response',lambda res:proof['rpc_metadata'].append({'path':urllib.parse.urlsplit(res.url).path,'status':res.status})if'/rest/v1/rpc/'in res.url or'/functions/v1/'in res.url else None)
    button=lambda text:page.get_by_role('button',name=text,exact=True)
    near=lambda loc:Acceptance.near(page,loc).click()
    proof['stage']='owner_login';save();page.goto(h.app);page.wait_for_selector('flutter-view',timeout=60000);sem=page.locator('flt-semantics-placeholder')
    if sem.count():sem.evaluate('(e)=>e.click()')
    button('احجز الآن').first.wait_for(timeout=30000)
    if not ar:near(button('EN'))
    near(button(t('دخول الموظفين','Staff sign in')));actor=h.accounts['users']['owner']
    for label,key in[(t('البريد الإلكتروني','Email address'),'email'),(t('كلمة المرور','Password'),'password')]:Acceptance.type_into(page,label,actor[key])
    page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True).press('Tab')
    with page.expect_response(lambda res:'/rpc/get_admin_console'in res.url)as loaded:near(button(t('تسجيل الدخول','Sign In')))
    assert loaded.value.status==200
    proof['stage']='evidence_host';save();near(button(t('التقارير','Reports')))
    with page.expect_response(lambda res:res.url.endswith('/rpc/get_owner_business_insights')and res.request.method=='POST')as response:near(button(t('تحليل الأعمال بالأدلة','Business insights with evidence')))
    assert response.value.status==200;evidence=response.value.json();actual={row['code']:row for row in evidence['metrics']}
    ask=button(t('عرض الإجابة','Show answer'));Acceptance.near(page,ask);expect(ask).to_be_enabled()
    proof['summary_reused_from']='free-owner-assistant-browser-ar-summary-accepted.json'
    # A second NEW bounded topic proves missing-cost disclosure in the actual app.
    topic=page.get_by_role('button',name=re.compile(re.escape(t('ملخص النشاط','Business summary')))).or_(page.get_by_role('combobox',name=re.compile(re.escape(t('ملخص النشاط','Business summary'))))).first
    page.mouse.move(page.viewport_size['width']//2,400);page.mouse.wheel(0,-650);page.wait_for_timeout(200);near(topic)
    option=page.get_by_label(t('هل الربح الفعلي متاح؟','Is actual profit available?'),exact=True).first;option.wait_for(state='visible');option.click();page.wait_for_timeout(200)
    expect(page.get_by_role('button',name=re.compile(re.escape(t('هل الربح الفعلي متاح؟','Is actual profit available?')))).first).to_be_visible()
    proof['stage']='profit_unavailable';save()
    with page.expect_response(lambda res:res.url.endswith('/functions/v1/owner-evidence-advisor')and res.request.method=='POST')as reply:near(ask)
    payload=reply.value.json();assert reply.value.status==200 and payload['topic']=='profit'and payload['state']=='missing_data'
    missing=page.get_by_label(re.compile(re.escape(payload['answer'].split('\n')[0]))).first;Acceptance.near(page,missing);expect(missing).to_be_visible()
    Acceptance.near(page,ask);page.wait_for_timeout(250);screenshot=out/(a.language+'-actual-missing-profit.png');page.screenshot(path=str(screenshot));screenshot.chmod(0o600);proof['missing_profit_screenshot']=str(screenshot)
    assert not proof['render_errors']and not proof['blocked_requests'];proof['scope']='profit_only';proof['missing_profit_honest']=True;proof['all_passed']=True
   finally:browser.close()
 finally:
  proof['all_public_private_rows_unchanged']=Intake.snapshot(h)==before;proof['document_counters_unchanged']=Intake.counters(h)==counters;save()
 assert proof['all_passed']and proof['all_public_private_rows_unchanged']and proof['document_counters_unchanged'];print(json.dumps(proof,ensure_ascii=False))
if __name__=='__main__':main()
