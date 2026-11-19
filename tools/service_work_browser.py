"""Actual service-work route acceptance. Source plan; no execution by default.
Root supplies one NEW tagged received Walk-in fixture on the actual default branch.
Read-only route/context comes first. --transitions additionally permits ONLY the
fixture's exact operational prepare/place/ack commands. Never creates fixtures,
Auth accounts, payments, loyalty, invoices or provider calls. Pending commands
remain recorded for root recovery; no automatic mutation cleanup or repeats.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request
import uuid
import traceback
from owner_redemption_rules_browser import Harness as Base
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for key in ['runtime','proof','screenshots','fixture']:p.add_argument('--'+key,type=Path,required=True)
    p.add_argument('--app-url',default='http://127.0.0.1:8080')
    p.add_argument('--language',choices=['ar','en'],required=True)
    p.add_argument('--entry-mode',choices=['queue','service_card'],default='queue')
    p.add_argument('--build-proof',type=Path)
    p.add_argument('--transitions',action='store_true')
    p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    if not a.execute:print(__doc__);return
    h=Base(a);root=Path(__file__).resolve().parents[1]
    fixture=json.loads(a.fixture.read_text());a.fixture.resolve().relative_to(h.r)
    assert fixture['local_only'] and fixture['root_approved'] and fixture['fresh_qa']
    assert fixture['source_kind']=='walk_in' and fixture['initial_status']=='received'
    for key in ['order_id','branch_id','service_id']:uuid.UUID(fixture[key])
    assert re.fullmatch(r'[a-zA-Z0-9-]{6,80}',fixture['tag']) and fixture['tag'] in fixture['service_name']
    assert fixture['actor_role'] in ['manager','owner']
    actor=h.accounts['users'][fixture['actor_role']]
    manifest=json.loads((a.build_proof or h.r/'service-work-integrated-web-build-source.json').read_text())
    assert manifest['exit_code']==0 and manifest['source_unchanged'] and manifest['backend_loopback']
    for name,digest in manifest['source_after'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest
    js=root/'build/web/main.dart.js';assert hashlib.sha256(js.read_bytes()).hexdigest()==manifest['main_dart_js_sha256']
    with urllib.request.urlopen(h.app+'/main.dart.js',timeout=30)as response:assert hashlib.sha256(response.read()).hexdigest()==manifest['main_dart_js_sha256']
    literal=lambda value:"'"+str(value).replace("'","''")+"'"
    if a.entry_mode=='queue':
        assert h.sql('select branch_id from public.business_branches where is_default and is_active;')==fixture['branch_id']
    assert h.sql('select exists(select 1 from private.offline_walk_in_subjects s join public.business_orders o on o.order_id=s.order_id '
        'join public.business_catalog_items i on i.item_id=s.service_id where s.order_id='+literal(fixture['order_id'])+
        ' and s.invoice_id='+literal(fixture['invoice_id'])+' and s.service_id='+literal(fixture['service_id'])+
        ' and s.branch_id='+literal(fixture['branch_id'])+' and i.name='+literal(fixture['service_name'])+
        " and o.booking_id is null and o.customer_id is null and o.status='received' and s.gross="+str(float(fixture['gross_amount']))+');')=='t'
    proof={'local_only':True,'producer_or_finance_or_provider_calls':False,'fixture':str(a.fixture),'language':a.language,
        'entry_mode':a.entry_mode,'build_sha256':manifest['main_dart_js_sha256'],'screens':[],'blocked_requests':[],'rpc_metadata':[],'steps':[],'all_passed':False}
    state={'order_id':fixture['order_id'],'tag':fixture['tag'],'request_id':None,'prepared_payload':None,'stage':'preflight'}
    statefile=a.proof.with_name(a.proof.stem+'-state.json');a.proof.parent.mkdir(parents=True,exist_ok=True);a.screenshots.mkdir(parents=True,exist_ok=True)
    def save():
        statefile.write_text(json.dumps(state,indent=2)+'\n');statefile.chmod(0o600)
        a.proof.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');a.proof.chmod(0o600)
    def stage(name):state['stage']=name;save()
    def hashes(tables):return {name:h.sql('select coalesce(string_agg(md5(to_jsonb(t)::text),\'\'order by md5(to_jsonb(t)::text)),\'\')from '+name+' t;')for name in tables}
    assert h.sql('select not exists(select 1 from private.service_work_commands where actor_id='+literal(actor['id'])+" and acknowledged_at is null and state in('prepared','succeeded'));")=='t'
    assert h.sql('select not exists(select 1 from private.service_resource_spans where walk_in_order_id='+literal(fixture['order_id'])+');')=='t'
    immutable=['public.business_invoices','public.business_payment_events','private.canonical_loyalty_visits','private.reward_credit_claims','private.service_reward_redemptions','private.hr_employment']
    before=hashes(immutable);auth=Intake.auth_fingerprint(h);counters=Intake.counters(h)
    expected=None;requests=Counter();render=[]
    try:
        from playwright.sync_api import sync_playwright,expect
        with sync_playwright()as pw:
            browser=pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
            try:
                ar=a.language=='ar';label=lambda arabic,english:arabic if ar else english
                page=browser.new_page(viewport={'width':390 if ar else 1440,'height':1100});page.set_default_timeout(25000)
                def guard(route):
                    nonlocal expected
                    q=route.request;u=urllib.parse.urlsplit(q.url);rpc=u.path.rsplit('/',1)[-1]if'/rest/v1/rpc/'in u.path else None
                    if rpc=='claim_customer_product_ad':route.fulfill(status=200,content_type='application/json',body='[]');return
                    staticfont=u.scheme=='https'and u.hostname=='fonts.gstatic.com'and u.path.startswith('/s/')and u.path.endswith('.woff2')and not u.query
                    bad=u.scheme in('http','https')and u.hostname!='127.0.0.1'and not(q.method in('GET','HEAD')and staticfont)
                    reads={'get_staff_operations','get_public_home','get_public_promotions','default_branch_id','get_admin_console','list_service_work_queue','get_service_work_context','get_service_work_command'}
                    if a.entry_mode=='service_card':reads.remove('list_service_work_queue')
                    writes={'prepare_service_work','place_service_work','ack_service_work_command'}if a.transitions else set()
                    bad|=rpc is not None and rpc not in reads|writes
                    bad|=q.method not in('GET','HEAD','OPTIONS')and rpc is None and u.path not in('/auth/v1/token','/auth/v1/logout')
                    if rpc and q.method=='POST':
                        body=json.loads(q.post_data or '{}')
                        if body is None and rpc in{'get_staff_operations','get_public_home','get_public_promotions','default_branch_id'}:body={}
                        if not isinstance(body,dict):bad=True;body={}
                        if rpc=='get_staff_operations':bad|=body!={}
                        if rpc=='list_service_work_queue':bad|=body!={'p_branch':fixture['branch_id']}
                        if rpc=='get_service_work_context':bad|=body!={'p_order':fixture['order_id'],'p_booking':None}
                        if rpc=='get_service_work_command':bad|=body!={'p_request':state['request_id']}and body!={'p_request':None}
                        if rpc=='prepare_service_work':
                            bad|=expected is None or set(body)!={'p_request','p_order','p_expected_status','p_next_status','p_reason'}
                            bad|=any(body.get(k)!=v for k,v in(expected or {}).items())
                            if not bad:
                                uuid.UUID(body['p_request']);state['request_id']=body['p_request'];state['prepared_payload']=body;save()
                        if rpc in{'place_service_work','ack_service_work_command'}:bad|=not state['request_id']or body!={'p_request':state['request_id']}
                    if bad:proof['blocked_requests'].append({'path':u.path,'method':q.method});route.abort()
                    else:
                        if rpc in writes and q.method=='POST':requests[rpc]+=1
                        route.continue_()
                page.route('**/*',guard)
                page.on('pageerror',lambda _:render.append('javascript_error'))
                page.on('response',lambda response:proof['rpc_metadata'].append({'rpc':urllib.parse.urlsplit(response.url).path.rsplit('/',1)[-1],'status':response.status,'method':response.request.method})if'/rest/v1/rpc/'in response.url else None)
                def remember(locator,kind):
                    proof['last_control']={'kind':kind,'locator':str(locator),'stage':state['stage']}
                    save()
                def direct(locator):
                    remember(locator,'fixed-visible-control')
                    locator.wait_for(state='visible');expect(locator).to_be_enabled();locator.click()
                def near(locator):
                    remember(locator,'existing-content-control')
                    Acceptance.near(page,locator).click()
                def long_content(locator):
                    remember(locator,'exact-qa-service-card')
                    height=page.viewport_size['height'];step=max(440,int(height*.80))
                    search={'attempts':0,'step_pixels':step,'max_attempts':160,'matched':False}
                    proof['last_scroll_search']=search
                    for attempt in range(160):
                        search['attempts']=attempt+1
                        count=locator.count();box=locator.first.bounding_box()if count else None
                        search['match_count']=count
                        if box and 4<box['y']<height-90:
                            expect(locator.first).to_be_enabled()
                            locator.first.click();search['matched']=True;save();return
                        # A wheel gesture only, never a click on an unverified list row.
                        page.mouse.move(page.viewport_size['width']//2,height//2)
                        page.mouse.wheel(0,-step if box and box['y']<=4 else step)
                        page.wait_for_timeout(90)
                    save()
                    raise AssertionError('Exact requested content control not found within bounded scroll budget')
                def button(name):return page.get_by_role('button',name=name,exact=True)
                def screen(name):
                    page.wait_for_timeout(450);target=a.screenshots/(a.language+'-'+name+'.png');page.screenshot(path=str(target));proof['screens'].append(str(target));save()
                stage('staff-login');page.goto(h.app);page.wait_for_selector('flutter-view',timeout=60000)
                sem=page.locator('flt-semantics-placeholder')
                if sem.count():sem.evaluate('(e)=>e.click()')
                button('احجز الآن').first.wait_for(timeout=30000)
                if not ar:near(button('EN'))
                near(button(label('دخول الموظفين','Staff sign in')))
                for name,key in[(label('البريد الإلكتروني','Email address'),'email'),(label('كلمة المرور','Password'),'password')]:Acceptance.type_into(page,name,actor[key])
                page.get_by_role('textbox',name=label('كلمة المرور','Password'),exact=True).press('Tab')
                with page.expect_response(lambda r:r.request.method=='POST'and r.url.startswith(h.base+'/auth/v1/token?'))as login:near(button(label('تسجيل الدخول','Sign In')))
                signed=login.value.json();proof['auth_probe']={'http_status':login.value.status,'user_match':signed.get('user',{}).get('id')==actor['id']};assert login.value.status==200 and proof['auth_probe']['user_match']
                def open_work():
                    stage('staff-dashboard-schedules')
                    # The existing AdminAction is registered under schedules,
                    # not reports. Reach its real horizontal navigation item.
                    anchor=button(label('التقارير','Reports'))
                    anchor.wait_for(state='visible')
                    navbox=anchor.bounding_box();assert navbox is not None
                    nav_y=navbox['y']+navbox['height']/2
                    schedules=button(label('الجداول والمواعيد','Schedules'))
                    for attempt in range(8):
                        box=schedules.bounding_box() if schedules.count() else None
                        if box and 6<box['x']+box['width']/2<page.viewport_size['width']-6:
                            direct(schedules);break
                        page.mouse.move(page.viewport_size['width']//2,nav_y)
                        page.mouse.wheel(330,0);page.wait_for_timeout(150)
                    else:raise AssertionError('Actual schedules navigation not reached')
                    stage('open-staff-operations-action')
                    near(button(label('إدارة الحجوزات والمهام','Manage bookings & assigned work')))
                    if a.entry_mode=='service_card':
                        stage('locate-exact-qa-service-card')
                        page.wait_for_timeout(450)
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_service_work_context'))as opened:
                            long_content(page.get_by_role('button',name=re.compile('^'+re.escape(fixture['service_name']))).first)
                        context=opened.value.json()
                        assert opened.value.status==200 and context['order_id']==fixture['order_id']
                        assert context['source_kind']=='walk_in'and context['branch']['id']==fixture['branch_id']
                    else:
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/list_service_work_queue'))as queued:direct(button(label('طابور الخدمات','Service queue')))
                        queue=queued.value.json();assert queued.value.status==200 and queue['branch_id']==fixture['branch_id']
                        row=next(item for item in queue['items']if item['order_id']==fixture['order_id'])
                        assert row['service']['name']==fixture['service_name'];reference=row['work_reference']
                        page.wait_for_timeout(450)
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_service_work_context'))as opened:
                            near(page.get_by_role('button',name=re.compile('^'+re.escape(reference))).first)
                        context=opened.value.json();assert opened.value.status==200 and context['order_id']==fixture['order_id']
                        assert context['source_kind']=='walk_in'and context['branch']['id']==fixture['branch_id']
                    page.wait_for_timeout(450);return context
                stage('readonly-queue-and-context');context=open_work();screen('actual-work-context');proof['readonly_route_passed']=True
                if a.transitions:
                    actions={'in_progress':('بدء الخدمة','Start service'),'quality_check':('الانتقال لمراجعة الجودة','Move to quality check'),'completed':('تأكيد اكتمال الخدمة','Confirm completion'),'delivered':('تأكيد التسليم','Confirm delivery')}
                    for target in fixture['allowed_transitions']:
                        assert target in actions and context['next_status']==target and context['can_prepare']
                        reason='Isolated operational UI acceptance '+fixture['tag']
                        expected={'p_order':fixture['order_id'],'p_expected_status':context['work_status'],'p_next_status':target,'p_reason':reason}
                        stage('prepare-'+target);Acceptance.type_into(page,label('سبب الخطوة أو ملاحظتها','Step reason or note'),reason)
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/prepare_service_work'))as prepared:near(button(label(*actions[target])))
                        receipt=prepared.value.json();assert prepared.value.status==200 and receipt['request_id']==state['request_id']and receipt['status']=='prepared'
                        assert receipt['payload']['order_id']==fixture['order_id']and receipt['payload']['next_status']==target
                        screen('prepared-'+target)
                        if not proof.get('prepared_exact_nonce_reload'):
                            stage('reload-exact-prepared-command')
                            with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_service_work_command')and json.loads(r.request.post_data or '{}').get('p_request')==state['request_id'])as recovered:
                                page.reload();page.wait_for_selector('flutter-view',timeout=60000)
                                sem=page.locator('flt-semantics-placeholder')
                                if sem.count():sem.evaluate('(e)=>e.click()')
                                open_work()
                            same=recovered.value.json();assert recovered.value.status==200 and same['request_id']==state['request_id']and same['status']=='prepared'
                            assert same['payload']==receipt['payload']
                            proof['prepared_exact_nonce_reload']=True
                        stage('apply-'+target)
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/place_service_work'))as placed:near(button(label('تطبيق التغيير المحفوظ','Apply saved change')))
                        result=placed.value.json();assert placed.value.status==200 and result['request_id']==state['request_id']and result['status']=='succeeded'
                        assert result['result']['order_id']==fixture['order_id']and result['result']['performed_status']==target
                        screen('applied-'+target);proof['steps'].append({'request_id':state['request_id'],'performed_status':target});save()
                        with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/ack_service_work_command'))as acked:near(button(label('تأكيد وتحديث','Confirm and refresh')))
                        ack=acked.value.json();assert acked.value.status==200 and ack['request_id']==state['request_id']and ack['acknowledged']is True
                        page.wait_for_function('!Object.keys(localStorage).some(k=>k.includes("service_work_request_"))')
                        state['request_id']=None;state['prepared_payload']=None;expected=None;save()
                        if target!=fixture['allowed_transitions'][-1]:
                            with page.expect_response(lambda r:r.request.method=='POST'and r.url.endswith('/rpc/get_service_work_context'))as refreshed:near(button(label('تحديث الحالة','Refresh status')))
                            context=refreshed.value.json()
                proof['requested_journey_passed']=True
            except Exception as exc:
                proof['failure_locations']=[{'file':Path(frame.filename).name,'line':frame.lineno,'function':frame.name}for frame in traceback.extract_tb(exc.__traceback__)if Path(frame.filename).name==Path(__file__).name]
                try:
                    proof['failure_dom_summary']={'button_count':page.get_by_role('button').count(),
                        'textbox_count':page.get_by_role('textbox').count(),
                        'exact_qa_service_control_count':page.get_by_role('button',name=re.compile('^'+re.escape(fixture['service_name']))).count(),
                        'service_queue_control_count':page.get_by_role('button',name=label('طابور الخدمات','Service queue'),exact=True).count(),
                        'staff_operations_action_count':page.get_by_role('button',name=label('إدارة الحجوزات والمهام','Manage bookings & assigned work'),exact=True).count()}
                    # Redact all central list content; local pre-existing customers must not
                    # leak into a failure artifact. This is a diagnostic, not visual QA.
                    page.evaluate("""()=>{const mask=document.createElement('div');mask.id='qa-private-list-mask';Object.assign(mask.style,{position:'fixed',left:'0',right:'0',top:'90px',bottom:'65px',background:'#071a36',zIndex:'2147483647',pointerEvents:'none'});document.body.appendChild(mask);} """)
                    target=a.screenshots/(a.language+'-failure-private-list-masked.png')
                    page.screenshot(path=str(target),mask=[page.get_by_role('textbox')]);proof['failure_masked_screenshot']=str(target)
                    proof['failure_screenshot_privacy_mask']='central list content redacted; not a visual acceptance screenshot'
                except Exception as diagnostic:proof['diagnostic_error_type']=type(diagnostic).__name__
                save();raise
            finally:browser.close()
    except Exception as exc:proof.update(error_type=type(exc).__name__,failed_stage=state['stage'])
    finally:
        proof['financial_loyalty_employment_rows_unchanged']=before==hashes(immutable)
        proof['document_counters_unchanged']=counters==Intake.counters(h);proof['auth_identity_unchanged']=auth==Intake.auth_fingerprint(h)
        proof['operational_rpc_counts']=dict(requests);proof['render_errors']=render
        proof['all_passed']=all(proof.get(k)is True for k in['readonly_route_passed','requested_journey_passed','financial_loyalty_employment_rows_unchanged','document_counters_unchanged','auth_identity_unchanged'])and not proof['blocked_requests']and not render
        save();print(json.dumps({'all_passed':proof['all_passed'],'stage':state['stage'],'proof':str(a.proof)}))
    if not proof['all_passed']:raise SystemExit(1)

if __name__=='__main__':main()
