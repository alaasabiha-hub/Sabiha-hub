"""Source-prepared, local-only actual Flutter cashier intake acceptance.

Default invocation prints this plan and does not open a browser/database.
After root approves the current web build, --execute uses the EXISTING manager
account, actual Cashier shifts > Register customer route, AR390 and EN1440.
Two distinct synthetic contacts/cars are registered through Flutter only. No
fixture preparation writes, staff permission changes, Auth user creation, cash,
booking, invoice, loyalty or link writes are allowed. Private unverified intake
and audit rows remain; nothing is deleted or rekeyed.

Screenshots capture filled forms BEFORE dispatch and clean forms AFTER receipt
acknowledgement. From dispatch until code clearance, no screenshots, semantics,
response bodies or raw codes are logged or written. The code exists only in
memory for format/UI/server-hash assertions. Recovery must return no code.
Every old public/private row and document counter must remain unchanged; Auth
user IDs/count stay unchanged (existing staff sign-in sessions are expected).
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from owner_redemption_rules_browser import Harness as BaseHarness
from service_booking_acceptance import Acceptance

NOTICE = {
    'en': 'I agree to record my name, phone and car details for service reception. This does not authorize marketing, app account linking or reward redemption.',
    'ar': 'أوافق على تسجيل اسمي ورقم هاتفي وبيانات سيارتي لاستقبال الخدمة. لا يشمل ذلك التسويق أو ربط حساب تطبيق أو استبدال المكافآت.',
}
INTAKE = ['offline_customer_profiles', 'offline_customer_contacts',
          'offline_customer_car_refs', 'offline_customer_registration_requests',
          'offline_customer_enrollment_receipts']


class Harness(BaseHarness):
    def __init__(self, args):
        super().__init__(args)
        self.tag = uuid.uuid4().hex[:10]
        self.state_file = self.r / ('offline-registration-browser-state-' + self.tag + '.json')
        self.state = {'tag': self.tag, 'stage': 'prepared', 'request_ids': [], 'retained_private_qa': True}
        self.secret_window = False
        self.staff_role = args.staff_role
        self.languages = args.languages or ['ar', 'en']
        self.recover_request = str(uuid.UUID(args.recover_request)) if args.recover_request else None
        if self.recover_request: assert len(self.languages) == 1, 'Read-only recovery diagnoses one language at a time'
        self.proof = {'local_only': True, 'production_touched': False,
                      'financial_action_executed': False, 'auth_account_created': False,
                      'raw_secret_persisted': False, 'screens': [], 'journeys': [],
                      'render_errors': [], 'blocked_requests': [], 'blocked_unrelated_ad_claims': 0, 'all_passed': False}

    def stage(self, value):
        self.state['stage'] = value
        self.save_state()

    def snapshot(self):
        text = self.sql("""create temp table intake_old_rows(t text,h text);do $$declare t record;h text;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop
        execute format('select coalesce(string_agg(md5(row_to_json(r)::text),%L),%L)from %I.%I r',',','',t.schemaname,t.tablename)into h;
        insert into intake_old_rows values(t.schemaname||'.'||t.tablename,h);end loop;end $$;
        select t||'|'||h from intake_old_rows order by t;""")
        return {line.split('|', 1)[0]: Counter(filter(None, line.split('|', 1)[1].split(',')))
                for line in text.splitlines() if '|' in line}

    def auth_fingerprint(self):
        return self.sql("select count(*)::text||':'||md5(coalesce(string_agg(id::text,','order by id),''))from auth.users;")

    def counters(self):
        return json.loads(self.sql('select json_object_agg(kind,last_value)from private.document_number_counters;'))

    def verify_build(self):
        root = Path(__file__).resolve().parents[1]
        built = root / 'build/web/main.dart.js'
        assert built.is_file(), 'Current web build required'
        assert all(built.stat().st_mtime >= (root / path).stat().st_mtime for path in [
            'lib/offline_customer_registration.dart', 'lib/cashier_shifts.dart']), 'Build predates frozen intake module'
        local = hashlib.sha256(built.read_bytes()).hexdigest()
        digest = hashlib.sha256()
        with urllib.request.urlopen(self.app + '/main.dart.js', timeout=30) as response:
            while chunk := response.read(1024 * 1024): digest.update(chunk)
        assert digest.hexdigest() == local, 'Served web differs from current local build'
        self.proof['served_build_sha256'] = local
        self.proof['module_sha256'] = hashlib.sha256((root / 'lib/offline_customer_registration.dart').read_bytes()).hexdigest()

    def new_phone(self):
        for _ in range(8):
            phone = '010' + str(uuid.uuid4().int % 100000000).zfill(8)
            # Read only: avoid existing legacy/private contact collisions.
            normalized = '+20' + phone[1:]
            absent = self.sql("select not exists(select 1 from private.offline_customer_contacts where phone_e164='" + normalized + "')and not exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')='" + normalized + "');")
            if absent == 't': return phone
        raise AssertionError('Could not select an isolated synthetic contact')

    def safe_screenshot(self, page, language, width, stage):
        assert not self.secret_window, 'Screenshot forbidden while receipt code may be visible'
        target = self.out / ('offline-registration-' + self.tag + '-' + language + '-' + stage + '.png')
        page.screenshot(path=str(target))
        self.proof['screens'].append({'language': language, 'width': width, 'stage': stage, 'file': str(target)})

    def scroll_top(self, page):
        page.mouse.move(page.viewport_size['width'] // 2, page.viewport_size['height'] // 2)
        page.mouse.wheel(0, -10000)
        page.wait_for_timeout(250)
        page.mouse.wheel(0, -10000)
        page.wait_for_timeout(250)

    def recover_existing(self, page, intake, language, width, actor, branch):
        from playwright.sync_api import expect
        ar = language == 'ar'
        label = lambda arabic, english: arabic if ar else english
        request_id = self.recover_request
        self.stage(language + ':readonly-enter-existing-receipt')
        with page.expect_response(lambda response:response.url.startswith(self.base+'/rest/v1/rpc/get_offline_customer_registration'), timeout=30000) as found:
            intake.click()
        assert found.value.status == 200, 'Existing receipt recovery failed'
        result = found.value.json()
        assert result['request_id'] == request_id and result['status'] == 'created_unverified' and result['enrollment_secret'] is None
        self.stage(language + ':readonly-scroll-top')
        self.scroll_top(page)
        self.stage(language + ':readonly-selectable-reference-probe')
        expected_reference=result['enrollment_receipt_id']
        self.stage(language+':readonly-static-reference-label')
        prefix=label('مرجع إيصال العميل','Customer receipt reference')+': '
        aria=page.locator('[aria-label^='+json.dumps(prefix,ensure_ascii=False)+']')
        text=page.get_by_text(re.compile('^'+re.escape(prefix)))
        field=aria.or_(text).first
        field.wait_for(state='attached',timeout=10000)
        actual=field.get_attribute('aria-label') or field.text_content() or ''
        matched=actual.startswith(prefix) and expected_reference in actual
        secret_prefix=label('رمز الإيصال السري · يظهر مرة واحدة','Private receipt code · shown once')+': '
        self.proof['readonly_selectable_reference_probe']={'found':matched,'matching_fields':['static_display_aria_label']if matched else [],'geometry':field.bounding_box(),'named_reference_count':field.count(),'recovered_private_code_count':page.locator('[aria-label^='+json.dumps(secret_prefix,ensure_ascii=False)+']').count()}
        actual=None
        assert matched,'Actual static receipt accessibility value missing'
        assert self.proof['readonly_selectable_reference_probe']['recovered_private_code_count']==0
        self.stage(language + ':readonly-missing-code-ack')
        checkbox = page.get_by_role('checkbox',name=label('أفهم أن الرمز المفقود يحتاج مراجعة المالك','I understand that owner review is required for the missing code'),exact=True)
        Acceptance.near(page,checkbox)
        expect(checkbox).to_be_enabled()
        done = page.get_by_role('button',name=label('إنهاء وبدء تسجيل آخر','Finish and start another registration'),exact=True)
        expect(done).to_be_disabled()
        self.safe_screenshot(page,language,width,'readonly-lost-code-receipt')
        checkbox.click()
        expect(checkbox).to_be_checked()
        self.stage(language + ':readonly-finish-client-only')
        Acceptance.near(page,done).click()
        self.scroll_top(page)
        assert page.evaluate("Object.keys(localStorage).filter(key=>key.includes('offline_registration_uuid_')).length") == 0
        self.safe_screenshot(page,language,width,'readonly-after-client-ack')
        self.proof['journeys'].append({'language':language,'width':width,'request_id':request_id,'readonly_existing_receipt':True,'recovery_returned_no_secret':True,'lost_code_acknowledged':True,'local_uuid_cleared':True,'registration_executed':False})

    def browser(self):
        from playwright.sync_api import sync_playwright, expect
        self.out.mkdir(parents=True, exist_ok=True)
        branch = self.sql('select branch_id from public.business_branches where is_default and is_active;')
        uuid.UUID(branch)
        manager = self.accounts['users'][self.staff_role]
        actor = str(uuid.UUID(manager['id']))
        permitted = self.sql("begin;select set_config('request.jwt.claim.sub','" + actor + "',true);set local role authenticated;select private.can_cashier_branch('" + branch + "');rollback;").splitlines()[-1]
        assert permitted == 't', 'Existing manager branch cashier permission required; never grant it here'
        self.state['branch'] = branch
        self.save_state()
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                headless=True, args=['--disk-cache-size=0', '--media-cache-size=0'])
            try:
                for language in self.languages:
                    width = 390 if language == 'ar' else 1440
                    ar = language == 'ar'
                    label = lambda arabic, english: arabic if ar else english
                    page = browser.new_page(viewport={'width': width, 'height': 1100})
                    page.set_default_timeout(25000)
                    if self.recover_request:
                        seeded_key = 'flutter.offline_registration_uuid_' + actor + '_' + branch
                        page.add_init_script('if(location.origin===' + json.dumps(self.app) + '){localStorage.setItem(' + json.dumps(seeded_key) + ',JSON.stringify(' + json.dumps(self.recover_request) + '));}')
                    self.stage(language + ':navigation')
                    page.on('pageerror', lambda _: self.proof['render_errors'].append('javascript_error'))
                    # Never persist diagnostic text: it may contain a displayed receipt code.
                    page.on('console', lambda message: self.proof['render_errors'].append('render_error')
                            if 'overflowed' in message.text or 'EXCEPTION CAUGHT' in message.text else None)
                    expected_intake = None
                    def guard(route):
                        parsed = urllib.parse.urlsplit(route.request.url)
                        backend_path = any(part in parsed.path for part in ['/auth/v1/', '/rest/v1/', '/functions/v1/', '/storage/v1/'])
                        forbidden_auth = '/auth/v1/' in parsed.path and route.request.method not in ['GET', 'HEAD'] and parsed.path not in ['/auth/v1/token', '/auth/v1/logout']
                        rpc_name = parsed.path.rsplit('/', 1)[-1] if '/rest/v1/rpc/' in parsed.path else None
                        if rpc_name == 'claim_customer_product_ad':
                            self.proof['blocked_unrelated_ad_claims'] += 1
                            route.fulfill(status=200, content_type='application/json', body='[]')
                            return
                        allowed_rpc = {'get_public_home', 'get_public_promotions', 'default_branch_id', 'get_admin_console', 'get_offline_customer_registration', 'register_offline_customer', 'cashier_shift_totals'}
                        forbidden_rpc = rpc_name is not None and (rpc_name not in allowed_rpc or (self.recover_request is not None and rpc_name == 'register_offline_customer'))
                        wrong_intake = False
                        if rpc_name == 'register_offline_customer':
                            submitted = json.loads(route.request.post_data or '{}')
                            wrong_intake = expected_intake is None or any(submitted.get(key) != expected_intake[key] for key in ['p_branch','p_name','p_phone']) or submitted.get('p_car',{}).get('plate_number') != expected_intake['plate_number'] or submitted.get('p_duplicate_action') is not None

                        direct_write = backend_path and route.request.method not in ['GET', 'HEAD', 'OPTIONS'] and rpc_name is None and '/auth/v1/' not in parsed.path

                        remote_api = backend_path and (parsed.scheme, parsed.netloc) != (urllib.parse.urlsplit(self.base).scheme, urllib.parse.urlsplit(self.base).netloc)
                        if forbidden_auth or remote_api or forbidden_rpc or wrong_intake or direct_write or '/functions/v1/' in parsed.path:
                            self.proof['blocked_requests'].append({'auth_creation_or_otp': forbidden_auth, 'remote_api': remote_api, 'edge': '/functions/v1/' in parsed.path, 'nonallowlisted_rpc': rpc_name if forbidden_rpc else None, 'direct_write': direct_write, 'wrong_intake': wrong_intake})
                            route.abort()
                        else: route.continue_()
                    page.route('**/*', guard)
                    def remember(request, lang=language):
                        if request.url.startswith(self.base + '/rest/v1/rpc/register_offline_customer'):
                            payload = json.loads(request.post_data or '{}')
                            request_id = str(uuid.UUID(payload['p_request']))
                            assert not any(key in payload for key in ['p_email', 'p_password', 'p_auth_user'])
                            self.state['request_ids'].append({'language': lang, 'request_id': request_id})
                            self.save_state()
                    page.on('request', remember)
                    secret = None
                    response_data = None
                    body = None
                    try:
                        self.stage(language+':landing-navigation')
                        page.goto(self.app)
                        self.stage(language+':flutter-view-wait')
                        page.wait_for_selector('flutter-view', timeout=60000)
                        semantics = page.locator('flt-semantics-placeholder')
                        if semantics.count(): semantics.evaluate('(element)=>element.click()')
                        page.get_by_role('button', name='احجز الآن', exact=True).first.wait_for(timeout=30000)
                        if not ar: Acceptance.near(page, page.get_by_role('button', name='EN', exact=True)).click()
                        Acceptance.near(page, page.get_by_role('button', name=label('دخول الموظفين', 'Staff sign in'), exact=True)).click()
                        for arabic, english, key in [('البريد الإلكتروني', 'Email address', 'email'), ('كلمة المرور', 'Password', 'password')]:
                            Acceptance.type_into(page, label(arabic, english), manager[key])
                        page.get_by_role('textbox', name=label('كلمة المرور', 'Password'), exact=True).press('Tab')
                        self.stage(language+':existing-staff-signin')
                        with page.expect_response(lambda r: r.url.startswith(self.base + '/auth/v1/token?'), timeout=30000) as login:
                            Acceptance.near(page, page.get_by_role('button', name=label('تسجيل الدخول', 'Sign In'), exact=True)).click()
                        assert login.value.status == 200, 'Existing staff login failed'
                        self.token = login.value.json()['access_token']  # Ephemeral; never persisted.
                        self.stage(language+':reports-nav')
                        reports = page.get_by_role('button', name=label('التقارير', 'Reports'), exact=True)
                        reports.wait_for(state='visible', timeout=30000)
                        reports.click()  # Fixed navigation/footer controls must not be scrolled.
                        self.stage(language+':cashier-nav')
                        cashier = page.get_by_role('button', name=label('ورديات الكاشير', 'Cashier shifts'), exact=True)
                        Acceptance.near(page, cashier).click()
                        intake = page.get_by_role('button', name=label('تسجيل عميل بدون تطبيق', 'Register customer without the app'), exact=True)
                        self.stage(language+':intake-entry-wait')
                        expect(intake).to_be_enabled(timeout=30000)
                        if self.recover_request:
                            self.recover_existing(page,intake,language,width,actor,branch)
                            continue
                        Acceptance.near(page, intake).click()
                        page.get_by_text(label('تسجيل عميل دون حساب للتطبيق', 'Register a customer without an app account'), exact=True).wait_for()
                        assert page.get_by_role('textbox', name=re.compile('email|password|بريد|مرور', re.I)).count() == 0, 'Cashier intake must have no account credential fields'
                        def enter(arabic, english, value):
                            field = page.get_by_role('textbox', name=re.compile(re.escape(label(arabic, english)))).first
                            Acceptance.near(page, field).click()
                            field.press('ControlOrMeta+A')
                            field.press_sequentially(value, delay=12)
                            field.press('Tab')
                        phone = self.new_phone()
                        expected_intake = {'p_branch':branch,'p_name':'QA Offline '+self.tag+' '+language.upper(),'p_phone':phone,'plate_number':'QA-'+self.tag[:6]+'-'+language.upper()}
                        enter('اسم العميل', 'Customer name', expected_intake['p_name'])
                        enter('رقم الهاتف', 'Phone number', phone)
                        enter('رقم اللوحة', 'Plate number', expected_intake['plate_number'])
                        enter('الماركة (اختياري)', 'Brand (optional)', 'QA Brand')
                        enter('الطراز (اختياري)', 'Model (optional)', 'QA Model')
                        enter('سنة الصنع (اختياري)', 'Year (optional)', '2020')
                        enter('اللون (اختياري)', 'Color (optional)', 'QA Silver')
                        name_field = page.get_by_role('textbox', name=re.compile(re.escape(label('اسم العميل', 'Customer name')))).first
                        Acceptance.near(page, name_field)
                        self.safe_screenshot(page, language, width, 'filled-form')
                        consent = page.get_by_role('checkbox', name=label('وافق العميل على إشعار التسجيل هذا', 'The customer agreed to this registration notice'), exact=True)
                        Acceptance.near(page, consent).click()
                        expect(consent).to_be_checked()
                        assert NOTICE[language] in page.locator('body').inner_text(), 'Actual operational consent notice missing'
                        self.safe_screenshot(page, language, width, 'consent-before-submit')
                        self.stage(language + ':dispatch-no-visual-artifacts')
                        self.secret_window = True  # Before dispatch: failure paths must never capture a code.
                        submit = page.get_by_role('button', name=label('حفظ تسجيل العميل', 'Save customer registration'), exact=True)
                        with page.expect_response(lambda r: r.url.startswith(self.base + '/rest/v1/rpc/register_offline_customer'), timeout=35000) as registered:
                            Acceptance.near(page, submit).click()
                        self.stage(language+':intake-response-received')
                        assert registered.value.status == 200, 'Intake RPC failed'
                        sent = json.loads(registered.value.request.post_data)
                        assert set(sent) == {'p_request', 'p_branch', 'p_name', 'p_phone', 'p_country', 'p_car', 'p_consent', 'p_duplicate_action', 'p_review_reason'}
                        assert sent['p_branch'] == branch and sent['p_country'] == 'EG' and sent['p_duplicate_action'] is None
                        assert sent['p_consent'] == {'accepted': True, 'version': 'offline-registration-v1', 'text': NOTICE[language], 'language': language}
                        response_data = registered.value.json()
                        secret = response_data.pop('enrollment_secret', None)
                        assert isinstance(secret, str) and re.fullmatch('[0-9a-f]{64}', secret), 'One-time receipt code format invalid'
                        assert response_data['status'] == 'created_unverified' and response_data['identity_verified'] is False
                        assert response_data['enrollment_secret_issued'] is True and response_data['enrollment_secret_recoverable'] is False
                        assert all(response_data['capabilities'][flag] is False for flag in ['phone_verification', 'guest_redemption', 'auth_linking', 'walk_in_loyalty_accrual'])
                        request_id = str(uuid.UUID(response_data['request_id']))
                        profile_id = str(uuid.UUID(response_data['offline_profile_id']))
                        receipt_id = str(uuid.UUID(response_data['enrollment_receipt_id']))
                        # Actual text is inspected only in memory, never emitted or written.
                        self.stage(language+':intake-response-validated-scroll-top')
                        self.scroll_top(page)
                        self.stage(language+':receipt-interactive-control')
                        receipt_control = page.get_by_role('checkbox',name=label('حفظ العميل رمز الإيصال السري','The customer saved the private receipt code'),exact=True)
                        Acceptance.near(page,receipt_control)
                        expect(receipt_control).to_be_enabled()
                        def visible_text():
                            return page.evaluate("""() => [document.body.innerText,...Array.from(document.querySelectorAll('flt-semantics,[role=\"textbox\"],input:not([type=\"password\"]),textarea')).flatMap(node=>[node.textContent,node.getAttribute('aria-label'),node.value])].filter(Boolean).join('\\n')""")
                        body = visible_text()
                        assert secret in body or secret in re.sub(r'\s+', '', body), 'One-time receipt code not visible in actual Flutter'
                        digest = hashlib.sha256(secret.encode()).hexdigest()
                        self.stage(language+':private-hash-check')
                        private = json.loads(self.sql("select json_build_object('hash_matches',exists(select 1 from private.offline_customer_enrollment_receipts where receipt_id='" + receipt_id + "'and request_id='" + request_id + "'and encode(secret_hash,'hex')='" + digest + "'),'unverified',exists(select 1 from private.offline_customer_profiles where profile_id='" + profile_id + "'and not identity_verified),'safe_stored_result',exists(select 1 from private.offline_customer_registration_requests where request_id='" + request_id + "'and not result?'enrollment_secret'),'safe_audit',exists(select 1 from public.business_audit_log where entity_id='" + request_id + "'and action='offline_customer_registration'and not after_data?'enrollment_secret'));") )
                        assert all(private.values()), 'Server receipt backing or privacy proof failed'
                        self.stage(language+':safe-recovery-correlation')
                        recovered = self.rpc('get_offline_customer_registration', {'p_request': request_id})
                        assert recovered['enrollment_secret'] is None and recovered['request_id'] == request_id
                        self.stage(language+':uuid-only-storage-check')
                        stored = page.evaluate("Object.entries(localStorage).filter(([key])=>key.includes('offline_registration_uuid_')).map(([key,value])=>[key,value])")
                        assert len(stored) == 1
                        try: saved_value = json.loads(stored[0][1])
                        except ValueError: saved_value = stored[0][1]
                        assert saved_value == request_id, 'Local persistence must contain UUID only'
                        self.stage(language+':receipt-ack-checkbox')
                        saved = page.get_by_role('checkbox', name=label('حفظ العميل رمز الإيصال السري', 'The customer saved the private receipt code'), exact=True)
                        Acceptance.near(page, saved).click()
                        self.stage(language+':receipt-finish-button')
                        done = page.get_by_role('button', name=label('إنهاء وبدء تسجيل آخر', 'Finish and start another registration'), exact=True)
                        Acceptance.near(page, done).click()
                        fresh_submit = page.get_by_role('button', name=label('حفظ تسجيل العميل', 'Save customer registration'), exact=True)
                        Acceptance.near(page, fresh_submit)
                        expect(fresh_submit).to_be_enabled()
                        body = visible_text()
                        assert secret not in body, 'Receipt code remained visible after acknowledgement'
                        assert page.evaluate("Object.keys(localStorage).filter(key=>key.includes('offline_registration_uuid_')).length") == 0
                        self.secret_window = False
                        secret = None
                        body = None
                        response_data = None
                        self.stage(language + ':code-cleared')
                        self.safe_screenshot(page, language, width, 'after-code-cleared')
                        self.proof['journeys'].append({'language': language, 'width': width,
                            'request_id': request_id, 'profile_id': profile_id,
                            'actual_flutter_registration': True, 'one_time_code_visible': True,
                            'private_hash_matches': True, 'recovery_returned_no_secret': True,
                            'uuid_only_local_storage': True, 'code_cleared_after_acknowledgement': True,
                            'identity_verified': False, 'auth_linking': False, 'guest_redemption': False})
                    finally:
                        secret = None
                        body = None
                        response_data = None
                        page.close()
                        self.token = None
                        self.secret_window = False
                assert len(self.proof['journeys']) == len(self.languages)
                assert not self.proof['render_errors'] and not self.proof['blocked_requests']
            finally:
                browser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--screenshots', type=Path, required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--staff-role', choices=['manager'], required=True)
    parser.add_argument('--language',choices=['ar','en'],action='append',dest='languages')
    parser.add_argument('--recover-request',help='READ ONLY: known prior QA request; seeds UUID only and forbids registration')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(__doc__)
        return
    harness = Harness(args)
    before = None
    auth_before = None
    counters_before = None
    passed = False
    try:
        harness.verify_build()
        before = harness.snapshot()
        auth_before = harness.auth_fingerprint()
        counters_before = harness.counters()
        harness.browser()
        passed = True
    except Exception as error:
        # No exception text/response/semantics dump: it could contain a receipt code.
        harness.proof['error_type'] = type(error).__name__
        harness.proof['failed_stage'] = harness.state['stage']
    finally:
        if before is not None:
            try:
                after = harness.snapshot()
                missing = {table: sum((rows - after[table]).values()) for table, rows in before.items() if rows - after[table]}
                added = {table: sum((rows - before[table]).values()) for table, rows in after.items() if rows - before[table]}
                expected = {} if harness.recover_request else {'private.' + table: len(harness.languages) for table in INTAKE}
                if not harness.recover_request: expected['public.business_audit_log'] = len(harness.languages)
                harness.proof['preexisting_rows_unchanged'] = not missing
                harness.proof['changed_preexisting_tables'] = missing
                harness.proof['only_expected_private_intake_and_audit_added'] = added == expected
                harness.proof['new_row_counts'] = added
                harness.proof['document_counters_unchanged'] = harness.counters() == counters_before
                harness.proof['auth_user_ids_and_count_unchanged'] = harness.auth_fingerprint() == auth_before
                harness.proof['qa_retained_private_unverified'] = True
            except Exception as error:
                harness.proof['preservation_error_type'] = type(error).__name__
        harness.proof['all_passed'] = passed and all(harness.proof.get(key) for key in [
            'preexisting_rows_unchanged', 'only_expected_private_intake_and_audit_added',
            'document_counters_unchanged', 'auth_user_ids_and_count_unchanged'])
        harness.state['finished'] = True
        harness.save_state()
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(harness.proof, indent=2, ensure_ascii=False) + '\n')
        args.proof.chmod(0o600)
    if not harness.proof['all_passed']:
        raise SystemExit('FAIL local cashier intake; inspect sanitized stage/proof. Private records retained; no deletion.')
    print('PASS read-only existing cashier receipt recovery; no registration or business changes' if harness.recover_request else 'PASS actual cashier Flutter intake; code verified only in memory and cleared; no Auth user creation/finance actions or prior-row changes')


if __name__ == '__main__':
    main()
