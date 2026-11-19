"""Read-only real Flutter navigation smoke: customer Auth only, no fixture writes.
Blocks all POST APIs except Auth login and named read RPC families. Never places,
prepares, closes, acknowledges or changes a booking, policy, shift or payment.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import urllib.parse
sys.path.insert(0,str(Path(__file__).resolve().parent))
from owner_redemption_rules_browser import Harness
from service_booking_acceptance import Acceptance


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--runtime',type=Path,required=True)
    ap.add_argument('--proof',type=Path,required=True);ap.add_argument('--screenshots',type=Path,required=True)
    ap.add_argument('--resume-english',action='store_true');ap.add_argument('--app-url',default='http://127.0.0.1:8080');args=ap.parse_args()
    h=Harness(args);proof={'local_only':True,'fixture_writes':False,'screens':[],'cases':[],'blocked_mutations':[],'render_errors':[]}
    if args.resume_english:
        proof=json.loads(args.proof.read_text());assert proof['cases']==[{'language':'ar','width':390,'passed':True,'auth_only_no_fixture_writes':True}]
        args.proof.with_name(args.proof.stem+'-partial-ar.json').write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n')
        proof.pop('error',None)
    args.screenshots.mkdir(parents=True,exist_ok=True)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
        try:
            for lang,width in ([('en',1440)] if args.resume_english else [('ar',390),('en',1440)]):
                page=browser.new_page(viewport={'width':width,'height':1100});page.set_default_timeout(15000)
                t=lambda a,e:a if lang=='ar' else e
                def guard(route):
                    req=route.request;path=urllib.parse.urlsplit(req.url).path
                    allowed=req.method in ('GET','HEAD','OPTIONS') or (req.method=='POST' and
                      (path=='/auth/v1/token' or re.match(r'^/rest/v1/rpc/(get_|list_|available_|resolve_)',path)))
                    if allowed:route.continue_()
                    else:proof['blocked_mutations'].append({'method':req.method,'path':path});route.abort()
                page.route('**/*',guard)
                page.on('pageerror',lambda e:proof['render_errors'].append(str(e)))
                def controls():
                    return page.get_by_role('button').evaluate_all("es=>es.map(e=>{let b=e.getBoundingClientRect();return {name:e.getAttribute('aria-label')||e.innerText||e.textContent,x:b.x,y:b.y,width:b.width,height:b.height,visible:b.width>0&&b.height>0&&b.bottom>0&&b.top<innerHeight}})")
                def shot(stage):
                    file=args.screenshots/f'nav-{lang}-{width}-{stage}.png';page.screenshot(path=str(file))
                    proof['screens'].append({'language':lang,'width':width,'stage':stage,'file':str(file),'controls':controls()})
                    args.proof.write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n')
                def button(a,e):return page.get_by_role('button',name=t(a,e),exact=True)
                def content(loc):Acceptance.near(page,loc).click();page.wait_for_timeout(250)
                def nav(a,e):
                    # Fixed bottom controls never use the scroll-content helper.
                    loc=page.get_by_role('button',name=re.compile('^'+re.escape(t(a,e))+r'(?:\s|$)')).last
                    loc.wait_for(state='visible');assert loc.is_enabled();loc.click();page.wait_for_timeout(400)
                try:
                    page.goto(args.app_url);page.wait_for_selector('flutter-view',timeout=60000)
                    sem=page.locator('flt-semantics-placeholder')
                    if sem.count():sem.evaluate('(e)=>e.click()')
                    page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
                    if lang=='en':content(page.get_by_role('button',name='EN',exact=True))
                    content(button('احجز الآن','Book now').first)
                    for a,e,k in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:
                        Acceptance.type_into(page,t(a,e),h.accounts['users']['customer'][k])
                    page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True).press('Tab')
                    with page.expect_response(lambda r:'/auth/v1/token?' in r.url) as signed:content(button('تسجيل الدخول','Sign in'))
                    assert signed.value.status==200
                    button('إرسال طلب الحجز','Send booking request').wait_for();shot('initial-form')
                    nav('الرئيسية','Home');shot('home')
                    nav('حجوزاتي','Bookings');shot('bookings')
                    # Inspect actual existing booking details if available; no invoice
                    # creation or state-changing action is clicked.
                    details=button('التفاصيل والفاتورة','Details & invoice').first
                    if details.count():
                        content(details);shot('booking-details-modal');page.keyboard.press('Escape');page.wait_for_timeout(250)
                    nav('الرئيسية','Home');nav('الخدمات','Services');shot('services')
                    nav('الرئيسية','Home')
                    content(button('عروضي ونقاطي','Offers & loyalty').last)
                    refresh=button('تحديث رصيد البرامج','Refresh program balances');Acceptance.near(page,refresh);shot('offers-wallet')
                    nav('الرئيسية','Home');shot('home-return')
                    proof['cases'].append({'language':lang,'width':width,'passed':True,'auth_only_no_fixture_writes':True})
                except Exception as e:
                    proof['error']=str(e);shot('diagnostic')
                    (args.screenshots/f'nav-{lang}-semantics.html').write_text(page.content())
                    raise
                finally:page.close()
        finally:
            browser.close();proof['all_passed']=len(proof['cases'])==2 and all(x['path']=='/rest/v1/rpc/claim_customer_product_ad' for x in proof['blocked_mutations']) and not proof['render_errors']
            args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n');args.proof.chmod(0o600)
    assert proof['all_passed'];print('PASS actual read-only navigation AR390 EN1440; no fixture or financial mutations')


if __name__=='__main__':main()
