"""Read-only actual Flutter service/vehicle selection proof; no booking submissions."""
import argparse,json,re,sys,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from owner_redemption_rules_browser import Harness
from service_booking_acceptance import Acceptance


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--runtime',type=Path,required=True);ap.add_argument('--proof',type=Path,required=True);ap.add_argument('--screenshots',type=Path,required=True);ap.add_argument('--app-url',default='http://127.0.0.1:8080');a=ap.parse_args();h=Harness(a)
    proof={'local_only':True,'financial_mutations':False,'cases':[],'blocked_mutations':[],'screens':[]};a.screenshots.mkdir(parents=True,exist_ok=True)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
        try:
            for lang,width in [('ar',390),('en',1440)]:
                page=browser.new_page(viewport={'width':width,'height':1100});page.set_default_timeout(12000);t=lambda x,y:x if lang=='ar' else y;catalog=[];cars=[]
                def guard(route):
                    req=route.request;path=urllib.parse.urlsplit(req.url).path
                    if req.method in ('GET','HEAD','OPTIONS') or (req.method=='POST' and (path=='/auth/v1/token' or re.match(r'^/rest/v1/rpc/(get_|list_|available_|resolve_)',path))):route.continue_()
                    else:proof['blocked_mutations'].append(path);route.abort()
                page.route('**/*',guard)
                def response(r):
                    if r.status!=200:return
                    if '/rest/v1/business_catalog_items?' in r.url and 'vehicle_type' in r.url:
                        catalog[:]=[x for x in r.json() if not re.search(r'ceramic|سيراميك|paint\s*protect|حماية\s*الطلاء|\bppf\b',str(x.get('name',''))+' '+str(x.get('name_en','')),re.I)]
                    if '/rest/v1/vehicles?' in r.url and 'plate_number' in r.url:cars[:]=r.json()
                page.on('response',response)
                def button(x,y):return page.get_by_role('button',name=t(x,y),exact=True)
                def click(loc):Acceptance.near(page,loc).click();page.wait_for_timeout(200)
                def shot(stage):
                    f=a.screenshots/f'dropdown-{lang}-{width}-{stage}.png';page.screenshot(path=str(f));proof['screens'].append(str(f))
                    (a.screenshots/f'dropdown-{lang}-{stage}.html').write_text(page.content())
                def pick(label,display):
                    # Narrow to exact dropdown's own label, then target its actual
                    # interactive option; never synthesize a selection from ordering.
                    loc=page.get_by_role('button',name=re.compile('^'+re.escape(label)+r'\s')).or_(page.get_by_role('combobox',name=re.compile('^'+re.escape(label)+r'\s'))).last
                    click(loc);shot(label+'-open')
                    roles=page.locator('[role="menuitem"], [role="option"]').evaluate_all("es=>es.map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label')||e.innerText||e.textContent}))")
                    (a.screenshots/f'dropdown-{lang}-options.json').write_text(json.dumps(roles,ensure_ascii=False,indent=2)+'\n')
                    target=page.get_by_role('menuitem',name=display,exact=True).or_(page.get_by_role('option',name=display,exact=True))
                    if target.count()!=1:raise AssertionError('Actual interactive option unavailable: '+display+'; observed '+json.dumps(roles,ensure_ascii=False))
                    target.click();page.wait_for_timeout(250)
                    assert display in (loc.get_attribute('aria-label') or loc.inner_text()), 'Selected display must reflect the clicked actual item'
                try:
                    page.goto(a.app_url);page.wait_for_selector('flutter-view',timeout=60000);sem=page.locator('flt-semantics-placeholder')
                    if sem.count():sem.evaluate('(e)=>e.click()')
                    page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
                    if lang=='en':click(page.get_by_role('button',name='EN',exact=True))
                    click(button('احجز الآن','Book now').first)
                    for x,y,key in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:Acceptance.type_into(page,t(x,y),h.accounts['users']['customer'][key])
                    page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True).press('Tab')
                    with page.expect_response(lambda r:'/auth/v1/token?' in r.url) as auth:click(button('تسجيل الدخول','Sign in'))
                    assert auth.value.status==200;button('إرسال طلب الحجز','Send booking request').wait_for();assert len(catalog)>=2 and len(cars)>=2,'Two actual services and own cars required'
                    rounds=[]
                    for index in range(2):
                        service=catalog[index];car=cars[index]
                        service_display=service['name']+' · '+format(float(service['price']),'.15g')+' ج.م'
                        # Dart numeric interpolation may render a trailing .0.
                        own_label=page.get_by_role('button',name=re.compile('^'+re.escape(t('الخدمة','Service'))+r'\s')).last.get_attribute('aria-label')
                        pick(t('الخدمة','Service'),service_display)
                        pick(t('السيارة','Vehicle'),car['brand']+' '+car['model']+' · '+car['plate_number'])
                        timer=page.get_by_role('button',name=re.compile('^'+t('الوقت:','Time:')))
                        with page.expect_response(lambda r:'/rpc/available_booking_slots' in r.url) as slots:click(timer)
                        sent=json.loads(slots.value.request.post_data);assert slots.value.status==200
                        assert sent['p_service']==service['item_id'],'Slot request must use actual selected service'
                        if 'p_vehicle' in sent:assert sent['p_vehicle']==car['id']
                        page.keyboard.press('Escape');page.wait_for_timeout(150);shot('selection-'+str(index))
                        rounds.append({'service_id':service['item_id'],'vehicle_id':car['id'],'selected_service_display':service_display,'selected_vehicle_display':car['brand']+' '+car['model']+' · '+car['plate_number'],'slot_request':sent})
                    proof['cases'].append({'language':lang,'width':width,'selections':rounds,'passed':True})
                except Exception as e:proof['error']=str(e);shot('diagnostic');raise
                finally:page.close()
        finally:
            browser.close();proof['all_passed']=len(proof['cases'])==2 and all(x=='/rest/v1/rpc/claim_customer_product_ad' for x in proof['blocked_mutations']);a.proof.write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n');a.proof.chmod(0o600)
    print('PASS real dropdown selections AR390 EN1440; no booking/payment/policy mutations')


if __name__=='__main__':main()
