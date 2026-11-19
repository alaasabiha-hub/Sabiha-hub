"""Read-only existing Walk-in staff invoice via its existing own staff command receipt.
No setup, registration, claims, work, payment or command mutations are allowed.
"""
import argparse
import json
from pathlib import Path
import re
import traceback
import urllib.parse
from offline_walk_in_browser import Harness, literal
from service_booking_acceptance import Acceptance


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['runtime', 'proof', 'screenshots', 'checkpoint']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--app-url', default='http://127.0.0.1:8080')
    p.add_argument('--build-proof', type=Path)
    p.add_argument('--execute', action='store_true')
    a = p.parse_args()
    if not a.execute:
        print(__doc__)
        return
    old = json.loads(a.checkpoint.read_text())
    assert old['language'] == 'ar' and old['received_work_checkpoint'] and old['invoice_created']
    assert all(old[k] is True for k in ['preexisting_rows_unchanged', 'borrowed_full_contracts_unchanged', 'auth_user_ids_and_count_unchanged', 'cleanup_complete'])
    prior = json.loads((a.runtime / ('walkin-browser-state-' + old['tag'] + '.json')).read_text())
    record = old['received_work_checkpoint']
    assert prior['command_id'] == record['request_id'] and prior['order_id'] == record['order_id'] and prior['invoice_id'] == record['invoice_id']
    assert prior['cleanup_complete'] and prior['local_only']
    a.staff_role = 'manager'; a.languages = ['ar']; a.recover_request = prior['registration_request_id']
    a.probe_only = True; a.resume_handoff_proof = a.resume_handoff_manifest = None
    a.contract_state = a.runtime / 'walkin-financial-concurrency-state.json'
    a.contract_proof = a.runtime / 'walkin-financial-concurrency-proof.json'
    h = Harness(a)
    h.proof.update(probe='recovery-route-existing-void-walkin-staff-invoice', fixture_writes=False, checkpoint=str(a.checkpoint), invoice_created=False)
    before = counters = auth = None
    browser = None
    try:
        h.preflight()
        if a.build_proof:
            current=json.loads(a.build_proof.read_text())
            former=json.loads((a.runtime/'walkin-history-routing-web-build-source.json').read_text())
            assert current['exit_code']==0 and current['source_unchanged']
            assert former['main_dart_js_sha256']==old['served_build_sha256']
            assert current['main_dart_js_sha256']==h.proof['served_build_sha256']
            for name in ['lib/offline_walk_in.dart','lib/offline_customer_registration.dart','lib/cashier_shifts.dart']:
                assert former['source_after'][name]==current['source_after'][name]
            if former['source_after']['lib/invoices.dart'] != current['source_after']['lib/invoices.dart']:
                accepted=json.loads((a.runtime/'invoice-history-auth-replay-fix-proof.json').read_text())
                assert accepted['four_genuine_sdk_replay_and_signout_cases_passed'] and accepted['targeted_analysis_clean'] and accepted['pdf_and_qr_builder_unchanged']
                assert former['source_after']['lib/invoices.dart']==accepted['invoice_sha256_before']
                assert current['source_after']['lib/invoices.dart']==accepted['invoice_sha256_after']
                h.proof['accepted_auth_replay_fix_in_current_build']=True
            h.proof['unchanged_invoice_and_handoff_sources_in_new_build']=True
        else:
            assert h.proof['served_build_sha256'] == old['served_build_sha256']
        facts = json.loads(h.sql('select jsonb_build_object(\'token\',i.document_token,\'number\',i.display_number,\'origin\',i.document_origin) '
            'from private.offline_walk_in_subjects s join public.business_invoices i on i.invoice_id=s.invoice_id '
            'join public.business_orders o on o.order_id=s.order_id join private.offline_walk_in_commands c on c.request_id=s.command_id '
            'where s.order_id=' + literal(record['order_id']) + ' and s.invoice_id=' + literal(record['invoice_id']) +
            ' and s.command_id=' + literal(record['request_id']) + ' and s.registration_request_id=' + literal(h.recover_request) +
            ' and s.service_id=' + literal(prior['service_id']) + ' and s.branch_id=' + literal(prior['branch_id']) +
            ' and c.actor_id=' + literal(h.manager) + ' and c.acknowledged_at is not null and s.gross=137.45 '
            "and i.total=137.45 and i.discount=0 and i.status='void' and o.status='cancelled' "
            'and not exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id);'))
        assert facts['number'] and facts['token']
        origin = urllib.parse.urlsplit(facts['origin'])
        assert origin.scheme == 'http' and origin.hostname == '127.0.0.1' and origin.port == 8501
        assert urllib.parse.urlsplit(h.app).hostname == '127.0.0.1'
        before, counters, auth = h.snapshot(), h.counters(), h.auth_fingerprint()
        from playwright.sync_api import sync_playwright, expect
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
            page = browser.new_page(viewport={'width':390,'height':1100})
            page.set_default_timeout(25000)
            page.add_init_script("""(()=>{
              window.__safeAuthMeta=[];
              const actor="""+json.dumps(h.manager)+""";
              const record=(kind,v)=>{const session=v&&v.session?v.session:v;
                window.__safeAuthMeta.push({kind,at_ms:Math.round(performance.now()),
                  event:v&&typeof v.event==='string'?v.event:null,
                  has_session:!!(session&&session.access_token),
                  actor_matches:!!(session&&session.user&&session.user.id===actor)});};
              const set=Storage.prototype.setItem,remove=Storage.prototype.removeItem;
              Storage.prototype.setItem=function(k,v){if(k.includes('auth-token')){try{record('auth_storage_write',JSON.parse(v));}catch(_){record('auth_storage_write_unparsed',null);}}return set.call(this,k,v);};
              Storage.prototype.removeItem=function(k){if(k.includes('auth-token'))record('auth_storage_remove',null);return remove.call(this,k);};
              if(window.BroadcastChannel){const post=BroadcastChannel.prototype.postMessage;
                BroadcastChannel.prototype.postMessage=function(v){if(v&&typeof v.event==='string'&&['SIGNED_IN','SIGNED_OUT','TOKEN_REFRESHED','INITIAL_SESSION','signedIn','signedOut','tokenRefreshed'].includes(v.event))record('auth_broadcast',v);return post.call(this,v);};}
            })();""")

            def guard(route):
                q = route.request; url = urllib.parse.urlsplit(q.url)
                rpc = url.path.rsplit('/',1)[-1] if '/rest/v1/rpc/' in url.path else None
                if rpc and q.method == 'POST': h.proof.setdefault('rpc_request_metadata',[]).append({'rpc':rpc,'method':q.method})
                if rpc == 'claim_customer_product_ad':
                    route.fulfill(status=200,content_type='application/json',body='[]'); return
                renderer_prefix = 'https://www.gstatic.com/flutter-canvaskit/89c39edfdfae2949f6806e4a315c0c08522238b7/'
                static_renderer = q.url.startswith(renderer_prefix) and not url.query
                static_font = url.scheme == 'https' and url.hostname == 'fonts.gstatic.com' and url.path.startswith('/s/') and url.path.endswith('.woff2') and not url.query
                if q.method in ('GET','HEAD') and (static_renderer or static_font):
                    h.proof['verified_static_renderer_requests'] = h.proof.get('verified_static_renderer_requests',0) + 1
                    route.continue_(); return
                allowed = {'get_public_home','get_public_promotions','default_branch_id','get_admin_console','get_offline_walk_in_command','list_invoice_documents','resolve_invoice_document'}
                bad = url.scheme in ('http','https') and url.hostname != '127.0.0.1'
                bad |= rpc is not None and rpc not in allowed
                bad |= q.method not in ('GET','HEAD','OPTIONS') and rpc is None and url.path not in ('/auth/v1/token','/auth/v1/logout')
                if rpc and q.method == 'POST':
                    body = json.loads(q.post_data or '{}')
                    if body is None and rpc in allowed - {'get_admin_console','resolve_invoice_document','get_offline_walk_in_command'}: body = {}
                    bad |= not isinstance(body,dict)
                    if rpc == 'resolve_invoice_document': bad |= body != {'p_token':facts['token']}
                    if rpc == 'list_invoice_documents': bad |= body != {}
                    if rpc == 'get_offline_walk_in_command': bad |= body != {'p_request':record['request_id']}
                if bad:
                    h.proof['blocked_requests'].append({'path':url.path,'method':q.method});route.abort()
                else: route.continue_()
            page.route('**/*',guard)
            page.on('response',lambda response: h.proof.setdefault('rpc_response_metadata',[]).append({'rpc':urllib.parse.urlsplit(response.url).path.rsplit('/',1)[-1],'status':response.status,'method':response.request.method}) if '/rest/v1/rpc/' in response.url else None)
            def response_shape(response):
                if response.request.method!='POST' or not response.url.endswith('/rpc/list_invoice_documents'): return
                try:
                    value=response.json()
                    rows=value if isinstance(value,list) else []
                    h.proof['invoice_list_shape']={'http_status':response.status,'response_type':type(value).__name__,
                        'row_count':len(rows),'all_rows_objects':all(isinstance(x,dict)for x in rows),
                        'row_keys':sorted({key for row in rows if isinstance(row,dict)for key in row}),
                        'known_invoice_present':any(isinstance(x,dict)and x.get('invoice_id')==record['invoice_id']for x in rows),
                        'known_token_present':any(isinstance(x,dict)and x.get('document_token')==facts['token']for x in rows)}
                except Exception as exc:h.proof['invoice_list_shape']={'capture_error_type':type(exc).__name__}
            page.on('response',response_shape)
            page.on('pageerror',lambda _:h.proof['render_errors'].append('javascript_error'))
            key = 'flutter.offline_walk_in_request_' + h.manager
            page.add_init_script('if(location.origin===' + json.dumps(h.app) + '&&!sessionStorage.getItem("knownCommandSeeded")){localStorage.setItem(' + json.dumps(key) + ',JSON.stringify(' + json.dumps(record['request_id']) + '));sessionStorage.setItem("knownCommandSeeded","1");}')
            h.stage('recovery-route-staff-login')
            page.goto(h.app)
            page.wait_for_selector('flutter-view',timeout=60000)
            sem = page.locator('flt-semantics-placeholder')
            if sem.count(): sem.evaluate('(e)=>e.click()')
            page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
            h.stage('staff-footer-login-control')
            h.near_click(page,page.get_by_role('button',name='دخول الموظفين',exact=True))
            h.stage('staff-login-form')
            account = h.accounts['users']['manager']
            for label,key in [('البريد الإلكتروني','email'),('كلمة المرور','password')]: Acceptance.type_into(page,label,account[key])
            page.get_by_role('textbox',name='كلمة المرور',exact=True).press('Tab')
            h.stage('staff-login-auth-and-dashboard')
            with page.expect_response(lambda r:r.request.method=='POST' and r.url.startswith(h.base+'/auth/v1/token?')) as login:
                h.near_click(page,page.get_by_role('button',name='تسجيل الدخول',exact=True))
            auth_result = login.value.json()
            h.proof['auth_probe'] = {'http_status':login.value.status,'user_matches_manager':auth_result.get('user',{}).get('id')==h.manager}
            assert login.value.status==200 and h.proof['auth_probe']['user_matches_manager']
            reports=page.get_by_role('button',name='التقارير',exact=True)
            expect(reports).to_be_visible(timeout=30000)
            h.proof['staff_dashboard_visible'] = True
            h.cashier(page,lambda ar,en:ar)
            h.stage('read-own-existing-command')
            with page.expect_response(lambda r:r.request.method=='POST' and r.url.endswith('/rpc/get_offline_walk_in_command')) as recovered:
                h.direct_click(page.get_by_role('button',name='استقبال خدمة مباشرة',exact=True))
            recovered_result = recovered.value.json()
            assert recovered.value.status==200 and recovered_result['request_id']==record['request_id'] and recovered_result['status']=='succeeded'
            actual = recovered_result['result']
            assert actual['invoice_id']==record['invoice_id'] and actual['order_id']==record['order_id'] and actual['invoice_token']==facts['token']
            assert actual['invoice_status']=='void' and actual['work_status']=='cancelled' and actual['payment_status']=='cancelled'
            h.proof['exact_existing_command_recovered'] = True
            page.wait_for_timeout(450)  # Let the actual Walk-in route finish its slide before tapping.
            h.stage('open-known-command-staff-invoice')
            with page.expect_response(lambda r:r.request.method=='POST' and r.url.endswith('/rpc/resolve_invoice_document')) as opened:
                button=page.get_by_role('button',name='عرض الفاتورة الفعلية',exact=True)
                h.near_click(page,button)
                h.proof['invoice_button_click_dispatched'] = True
                page.wait_for_timeout(700)
                h.proof['safe_auth_timeline']=page.evaluate('window.__safeAuthMeta||[]')
                h.proof['post_click_dom_summary']={
                    'textbox_count':page.get_by_role('textbox').count(),
                    'invoice_open_button_count':page.get_by_role('button',name='فتح الفاتورة / Open Invoice',exact=True).count(),
                    'invalid_code_visible':page.get_by_text('رمز فاتورة غير صالح / Invalid invoice code',exact=True).count()>0,
                    'authorization_error_visible':page.get_by_text('الفاتورة غير متاحة أو غير مصرح بها / Invoice unavailable or not authorized',exact=True).count()>0,
                    'list_error_visible':page.get_by_text('تعذر تحميل الفواتير / Unable to load invoices',exact=True).count()>0,
                    'pdf_button_count':page.get_by_role('button',name=re.compile('Download PDF with QR')).count(),
                }
                diagnostic=a.screenshots/'readonly-invoice-post-click-diagnostic.png'
                page.screenshot(path=str(diagnostic),mask=[page.get_by_role('textbox')])
                h.proof['masked_diagnostic_screenshot']=str(diagnostic)
            h.stage('validate-actual-generic-invoice')
            doc = opened.value.json()
            h.proof['generic_resolver_http_status'] = opened.value.status
            assert opened.value.status==200 and doc['invoice_id']==record['invoice_id'] and doc['order_id']==record['order_id']
            assert doc['invoice_number']==facts['number'] and float(doc['invoice_total'])==137.45
            assert doc['booking_id'] is None and doc['payment_status']=='cancelled' and doc['service_status']=='cancelled'
            assert doc['portal_origin']==facts['origin'] and doc['document_token']==facts['token']
            h.stage('settled-staff-invoice-visual')
            Acceptance.near(page,page.get_by_role('button',name=re.compile('Download PDF with QR')))
            assert page.get_by_role('button',name=re.compile('Payment options|خيارات الدفع')).count()==0
            h.safe_screenshot(page,'ar',390,'existing-cancelled-staff-invoice')
            h.proof.update(readonly_invoice_passed=True, invoice_id=record['invoice_id'], invoice_number=facts['number'],
                actual_total=137.45,current_payment_status='cancelled',current_service_status='cancelled',
                actual_origin_preserved=True,qr_acceptance_claimed=False,staff_generic_resolver=True)
            browser.close();browser=None
    except Exception as exc:
        if 'page' in locals():
            try:
                h.proof['safe_auth_timeline']=page.evaluate('window.__safeAuthMeta||[]')
                h.proof['failure_dom_summary']={
                    'textbox_count':page.get_by_role('textbox').count(),
                    'invoice_open_button_count':page.get_by_role('button',name='فتح الفاتورة / Open Invoice',exact=True).count(),
                    'invoice_open_enabled':page.get_by_role('button',name='فتح الفاتورة / Open Invoice',exact=True).is_enabled() if page.get_by_role('button',name='فتح الفاتورة / Open Invoice',exact=True).count()==1 else None,
                    'invalid_code_visible':page.get_by_text('رمز فاتورة غير صالح / Invalid invoice code',exact=True).count()>0,
                    'authorization_error_visible':page.get_by_text('الفاتورة غير متاحة أو غير مصرح بها / Invoice unavailable or not authorized',exact=True).count()>0,
                    'list_error_visible':page.get_by_text('تعذر تحميل الفواتير / Unable to load invoices',exact=True).count()>0,
                    'pdf_button_count':page.get_by_role('button',name=re.compile('Download PDF with QR')).count(),
                }
            except Exception as diagnostic:h.proof['dom_capture_error_type']=type(diagnostic).__name__
        h.proof.update(error_type=type(exc).__name__,failed_stage=h.state.get('stage'), failure_locations=[{'file':Path(x.filename).name,'line':x.lineno,'function':x.name} for x in traceback.extract_tb(exc.__traceback__) if Path(x.filename).name == Path(__file__).name])
    finally:
        if browser:
            try: browser.close()
            except Exception: pass
        if before is not None:
            after=h.snapshot()
            h.proof['all_business_rows_unchanged']=before==after
            h.proof['document_counters_unchanged']=counters==h.counters()
            h.proof['auth_user_identity_unchanged']=auth==h.auth_fingerprint()
            h.proof['borrowed_contracts_unchanged']=h.employment_hashes()==h.borrowed_hashes
        h.proof['all_passed']=all(h.proof.get(k) is True for k in ['readonly_invoice_passed','staff_dashboard_visible','exact_existing_command_recovered','all_business_rows_unchanged','document_counters_unchanged','auth_user_identity_unchanged','borrowed_contracts_unchanged']) and not h.proof['blocked_requests'] and not h.proof['render_errors']
        a.proof.write_text(json.dumps(h.proof,ensure_ascii=False,indent=2)+'\n');a.proof.chmod(0o600)
        print(json.dumps({'all_passed':h.proof['all_passed'],'error_type':h.proof.get('error_type'),'failed_stage':h.proof.get('failed_stage'),'proof':str(a.proof)}))
    if not h.proof['all_passed']: raise SystemExit(1)

if __name__=='__main__': main()
