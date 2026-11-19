"""Independent read-only default service queue AR390/EN1440 acceptance.
Default is plan only. Root runs --execute after fixture cleanup. No fixture,
work transition, invoice, finance, claim, loyalty or Auth-account writes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request
from owner_redemption_rules_browser import Harness as Base
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['runtime','proof','screenshots']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--app-url',default='http://127.0.0.1:8080')
    p.add_argument('--build-proof',type=Path)
    p.add_argument('--language',choices=['ar','en'],required=True)
    p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    if not a.execute:print(__doc__);return
    h=Base(a);repo=Path(__file__).resolve().parents[1]
    manifest=json.loads((a.build_proof or h.r/'service-work-scoped-reader-web-build-source.json').read_text())
    assert manifest['exit_code']==0 and manifest['source_unchanged']and manifest['backend_loopback']
    for name,digest in manifest['source_after'].items():assert hashlib.sha256((repo/name).read_bytes()).hexdigest()==digest
    local=hashlib.sha256((repo/'build/web/main.dart.js').read_bytes()).hexdigest()
    assert local==manifest['main_dart_js_sha256']
    with urllib.request.urlopen(h.app+'/main.dart.js',timeout=30)as response:assert hashlib.sha256(response.read()).hexdigest()==local
    branch=h.sql('select branch_id from public.business_branches where is_default and is_active;')
    import uuid
    uuid.UUID(branch)
    proof={'local_only':True,'read_only':True,'fixture_created':False,'business_mutations':False,'language':a.language,
        'build_sha256':local,'default_branch_id':branch,'rpc_metadata':[],'blocked_requests':[],
        'blocked_automatic_ad_claims':0,'render_errors':[],'screens':[],'all_passed':False}
    a.proof.parent.mkdir(parents=True,exist_ok=True);a.screenshots.mkdir(parents=True,exist_ok=True)
    def save():a.proof.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');a.proof.chmod(0o600)
    def stage(name):proof['stage']=name;save()
    def auth_hash():return h.sql("select count(*)::text||':'||md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
    before=Intake.snapshot(h);auth=auth_hash();counters=Intake.counters(h)
    try:
        from playwright.sync_api import sync_playwright,expect
        with sync_playwright()as pw:
            browser=pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
            try:
                ar=a.language=='ar';label=lambda arabic,english:arabic if ar else english
                page=browser.new_page(viewport={'width':390 if ar else 1440,'height':1100});page.set_default_timeout(25000)
                def guard(route):
                    q=route.request;url=urllib.parse.urlsplit(q.url)
                    rpc=url.path.rsplit('/',1)[-1]if'/rest/v1/rpc/'in url.path else None
                    if rpc=='claim_customer_product_ad':
                        proof['blocked_automatic_ad_claims']+=1;route.fulfill(status=200,content_type='application/json',body='[]');return
                    renderer=q.url.startswith('https://www.gstatic.com/flutter-canvaskit/89c39edfdfae2949f6806e4a315c0c08522238b7/')and not url.query
                    font=url.scheme=='https'and url.hostname=='fonts.gstatic.com'and url.path.startswith('/s/')and url.path.endswith('.woff2')and not url.query
                    bad=url.scheme in('http','https')and url.hostname!='127.0.0.1'and not(q.method in('GET','HEAD')and(renderer or font))
                    allowed={'get_public_promotions','get_public_home','default_branch_id','get_admin_console','get_staff_operations','list_service_work_queue'}
                    bad|=rpc is not None and rpc not in allowed
                    bad|=q.method not in('GET','HEAD','OPTIONS')and rpc is None and url.path not in('/auth/v1/token','/auth/v1/logout')
                    if rpc and q.method=='POST':
                        body=json.loads(q.post_data or '{}')
                        empty={'get_staff_operations','get_public_home','get_public_promotions','default_branch_id'}
                        if body is None and rpc in empty:body={}
                        bad|=not isinstance(body,dict)
                        if rpc in empty:bad|=body!={}
                        if rpc=='list_service_work_queue':bad|=body!={'p_branch':branch}
                    if bad:proof['blocked_requests'].append({'path':url.path,'method':q.method});route.abort()
                    else:route.continue_()
                page.route('**/*',guard)
                page.on('pageerror',lambda _:proof['render_errors'].append('javascript_error'))
                page.on('response',lambda response:proof['rpc_metadata'].append({'rpc':urllib.parse.urlsplit(response.url).path.rsplit('/',1)[-1],'status':response.status,'method':response.request.method})if'/rest/v1/rpc/'in response.url else None)
                def button(name):return page.get_by_role('button',name=name,exact=True)
                def direct(locator):locator.wait_for(state='visible');expect(locator).to_be_enabled();locator.click()
                def near(locator):Acceptance.near(page,locator).click()
                stage('staff-login');page.goto(h.app);page.wait_for_selector('flutter-view',timeout=60000)
                sem=page.locator('flt-semantics-placeholder')
                if sem.count():sem.evaluate('(e)=>e.click()')
                button('احجز الآن').first.wait_for(timeout=30000)
                if not ar:near(button('EN'))
                near(button(label('دخول الموظفين','Staff sign in')))
                actor=h.accounts['users']['manager']
                for name,key in[(label('البريد الإلكتروني','Email address'),'email'),(label('كلمة المرور','Password'),'password')]:Acceptance.type_into(page,name,actor[key])
                page.get_by_role('textbox',name=label('كلمة المرور','Password'),exact=True).press('Tab')
                with page.expect_response(lambda response:response.request.method=='POST'and response.url.startswith(h.base+'/auth/v1/token?'))as login:near(button(label('تسجيل الدخول','Sign In')))
                signed=login.value.json();proof['auth_probe']={'http_status':login.value.status,'manager_matches':signed.get('user',{}).get('id')==actor['id']}
                assert login.value.status==200 and proof['auth_probe']['manager_matches']
                stage('schedules-horizontal-navigation')
                anchor=button(label('التقارير','Reports'));anchor.wait_for(state='visible');box=anchor.bounding_box();assert box is not None
                nav_y=box['y']+box['height']/2;schedules=button(label('الجداول والمواعيد','Schedules'))
                for attempt in range(8):
                    box=schedules.bounding_box()if schedules.count()else None
                    if box and 6<box['x']+box['width']/2<page.viewport_size['width']-6:direct(schedules);break
                    page.mouse.move(page.viewport_size['width']//2,nav_y);page.mouse.wheel(330,0);page.wait_for_timeout(150)
                else:raise AssertionError('Exact Schedules navigation not reached')
                stage('staff-operations-read')
                with page.expect_response(lambda response:response.request.method=='POST'and response.url.endswith('/rpc/get_staff_operations'))as operations:near(button(label('إدارة الحجوزات والمهام','Manage bookings & assigned work')))
                assert operations.value.status==200
                page.wait_for_timeout(450)
                stage('default-queue-read')
                with page.expect_response(lambda response:response.request.method=='POST'and response.url.endswith('/rpc/list_service_work_queue'))as queued:direct(button(label('طابور الخدمات','Service queue')))
                data=queued.value.json();assert queued.value.status==200 and data['branch_id']==branch and isinstance(data['items'],list)
                assert data.get('walk_in_loyalty_enabled')is False and data.get('active_stop_supported')is False
                proof['queue_response']={'http_status':queued.value.status,'actual_default_branch_match':True,'item_count':len(data['items']),'more_available':data['more_available']}
                page.wait_for_timeout(450)
                target=a.screenshots/(a.language+'-actual-default-service-queue.png');page.screenshot(path=str(target));target.chmod(0o600);proof['screens'].append(str(target))
                proof['readonly_queue_passed']=True;save()
            finally:browser.close()
    except Exception as exc:proof['error_type']=type(exc).__name__
    finally:
        proof['all_business_rows_unchanged']=before==Intake.snapshot(h)
        proof['document_counters_unchanged']=counters==Intake.counters(h);proof['auth_identity_unchanged']=auth==auth_hash()
        proof['all_passed']=all(proof.get(k)is True for k in['readonly_queue_passed','all_business_rows_unchanged','document_counters_unchanged','auth_identity_unchanged'])and not proof['blocked_requests']and not proof['render_errors']
        save();print(json.dumps({'all_passed':proof['all_passed'],'stage':proof['stage'],'proof':str(a.proof)}))
    if not proof['all_passed']:raise SystemExit(1)

if __name__=='__main__':main()
