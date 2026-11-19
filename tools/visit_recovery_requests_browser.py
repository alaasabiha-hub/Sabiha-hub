"""PLAN by default. Local request/review/inbox UI only; no claim/link/finance fixtures.
One locale per invocation. Root reviews and executes only after a pinned web build.
"""
import argparse
from collections import Counter
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request
import uuid

from owner_redemption_rules_browser import Harness
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance

READS = {
    'get_public_home', 'get_public_promotions', 'default_branch_id',
    'get_public_customer_coupons', 'get_my_canonical_service_visits',
    'get_my_reward_wallet', 'get_admin_console',
}
OWNER_PAGE = {'p_status': None, 'p_before_created_at': None, 'p_before_case': None, 'p_limit': 25}
INBOX_PAGE = {'p_before_created_at': None, 'p_before_event': None, 'p_limit': 25}


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


def nonce(value):
    return isinstance(value, str) and str(uuid.UUID(value)) == value


class RequestJourney:
    def __init__(self, args):
        self.args = args
        self.h = Harness(args)
        self.repo = Path(__file__).resolve().parents[1]
        fixture = json.loads((args.runtime / 'recovery-bridge-fixture.private.json').read_text())
        assert fixture['local_only'] and len(fixture['customers']) == 2
        self.customer = fixture['customers'][0 if args.language == 'ar' else 1]
        self.owner = self.h.accounts['users']['owner']
        self.actor = self.customer['user_id']
        assert nonce(self.actor)
        self.tag = 'request-ui-' + args.language + '-' + uuid.uuid4().hex[:10]
        self.state_file = args.runtime / (self.tag + '.private.json')
        self.state = {'local_only': True, 'tag': self.tag, 'customer_id': self.actor,
                      'language': args.language, 'submission': None, 'case_id': None,
                      'reviews': {}, 'read_requests': {}, 'cleanup_complete': False}
        self.proof = {'local_only': True, 'production_touched': False, 'language': args.language,
                      'proof_scope': 'request_more_info_reject_inbox_only',
                      'claim_proof_integration_tested': False, 'financial_operations': False,
                      'screens': [], 'checks': {}, 'blocked_requests': [], 'render_errors': [],
                      'rpc_metadata': [], 'stage': 'source_preflight', 'all_passed': False}
        self.latest = {}
        self.page_roles = {}
        self.events = set()
        self.notice = None
        self.owner_masks = []
        self.tokens = {}  # Ephemeral, never written to proof/state.
        self.ar = args.language == 'ar'
        self.before = self.counters = self.auth_before = None
        self.save()

    def t(self, ar, en):
        return ar if self.ar else en

    def save(self):
        write_private(self.state_file, self.state)
        write_private(self.args.proof, self.proof)

    def stage(self, name):
        self.proof['stage'] = name
        self.save()

    def preflight(self):
        manifest = json.loads(self.args.build_proof.read_text())
        assert manifest['exit_code'] == 0 and manifest['source_unchanged']
        for file, expected in manifest['source_after'].items():
            assert hashlib.sha256((self.repo / file).read_bytes()).hexdigest() == expected, file
        for file in ['lib/visit_recovery_request.dart', 'lib/visit_recovery_evidence.dart',
                     'lib/owner_visit_recovery.dart', 'lib/app_inbox.dart', 'lib/main.dart']:
            assert file in manifest['source_after'], 'Manifest must include integrated recovery/inbox source'
        with urllib.request.urlopen(self.h.app + '/main.dart.js', timeout=30) as response:
            assert hashlib.sha256(response.read()).hexdigest() == manifest['main_dart_js_sha256']
        self.proof['build_sha256'] = manifest['main_dart_js_sha256']
        # No setup writes. Confirm existing account details and terminal-only old cases.
        checked = json.loads(self.h.sql("select json_build_object('identity_valid',u.email_confirmed_at is not null and c.phone="
            + "'" + self.customer['phone'].replace("'", "''") + "' and private.offline_phone_key(c.phone,'EG') is not null,"
            + "'open_cases',(select count(*)from private.visit_recovery_customer_requests r where r.requester_id=u.id and r.status in('awaiting_matching','more_info','linked')),"
            + "'cases',(select coalesce(json_agg(case_id),'[]')from private.visit_recovery_customer_requests r where r.requester_id=u.id))"
            + "from auth.users u join public.customers c on c.id=u.id where u.id='" + self.actor + "';"))
        assert checked['identity_valid'] and checked['open_cases'] == 0
        self.state['old_case_ids'] = checked['cases']
        self.before = Intake.snapshot(self.h)
        self.counters = Intake.counters(self.h)
        self.auth_before = self.auth_hash()
        self.state['before_rows'] = {k: dict(v) for k, v in self.before.items()}
        self.state['before_counters'] = self.counters
        self.state['before_auth'] = self.auth_before
        self.save()

    def auth_hash(self):
        return self.h.sql("select md5(coalesce(string_agg(md5((to_jsonb(u)-'last_sign_in_at'-'updated_at')::text),','order by id),''))from auth.users u;")

    def case_from(self, data):
        case = data.get('case') if isinstance(data, dict) else None
        return case if isinstance(case, dict) else {}

    def observe(self, response, role):
        path = urllib.parse.urlsplit(response.url).path
        if '/rest/v1/rpc/' not in path or response.request.method != 'POST':
            return
        name = path.rsplit('/', 1)[-1]
        self.proof['rpc_metadata'].append({'name': name, 'status': response.status, 'role': role})
        if response.status != 200:
            # Never persist backend messages, names, phone, proof tokens or whole bodies.
            self.proof['last_rpc_failure'] = {'name': name, 'status': response.status}
            self.save()
            return
        # Event listeners intentionally inspect metadata only; no nested sync
        # Playwright body/wait calls during callback dispatch or teardown.

    def process_rpc_body(self, response, role, name):
        if response.status != 200:
            return
        data = response.json()
        self.latest[(role, name)] = data
        if role == 'customer' and name == 'get_my_visit_recovery_request':
            self.notice = data.get('consent')
        if name == 'list_visit_recovery_requests':
            self.owner_masks = [str(row[key]) for row in data.get('items', []) for key in ('requester_name', 'registered_phone') if row.get(key)]
        if name == 'submit_visit_recovery_request':
            cid = self.case_from(data).get('case_id')
            assert nonce(cid) and cid not in self.state['old_case_ids']
            assert self.state['case_id'] in (None, cid)
            self.state['case_id'] = cid
            self.proof['new_case_id'] = cid
        if name == 'list_my_app_inbox':
            for item in data.get('items', []):
                if item.get('case_reference') == self.state['case_id']:
                    self.events.add(item['event_id'])
        self.save()

    def guard(self, route, role):
        assert role in ('owner', 'customer'), 'Known browser actor required'
        request = route.request
        url = urllib.parse.urlsplit(request.url)
        rpc = url.path.rsplit('/', 1)[-1] if '/rest/v1/rpc/' in url.path else None
        if rpc == 'claim_customer_product_ad':
            route.fulfill(status=200, content_type='application/json', body='[]')
            return
        font = request.method in ('GET', 'HEAD') and url.scheme == 'https' and url.hostname == 'fonts.gstatic.com' and url.path.startswith('/s/') and url.path.endswith('.woff2') and not url.query
        allowed = url.scheme not in ('http', 'https') or (url.scheme == 'http' and url.netloc in {urllib.parse.urlsplit(self.h.app).netloc, urllib.parse.urlsplit(self.h.base).netloc}) or font
        if rpc and request.method == 'POST':
            try:
                body = json.loads(request.post_data or '{}')
                # SDK parameterless RPC serializes JSON null. Only read RPCs may normalize it.
                if body is None and rpc in READS:
                    body = {}
                assert isinstance(body, dict)
                allowed = allowed and self.allow_rpc(rpc, body, role)
            except (AssertionError, ValueError, TypeError):
                allowed = False
        elif rpc and request.method != 'OPTIONS':
            allowed = False
        elif request.method not in ('GET', 'HEAD', 'OPTIONS'):
            allowed = allowed and url.path in ('/auth/v1/token', '/auth/v1/logout')
            if url.path == '/auth/v1/token':
                body = json.loads(request.post_data or '{}')
                who = self.customer if role == 'customer' else self.owner
                allowed = allowed and body.get('email') == who['email'] and body.get('password') == who['password']
        if not allowed:
            self.proof['blocked_requests'].append({'path': url.path, 'method': request.method, 'role': role})
            self.save()
            route.abort()
        else:
            route.continue_()

    def allow_rpc(self, name, body, role):
        if name == 'get_admin_console':
            return role == 'owner' and set(body) == {'p_from_local', 'p_to_local', 'p_branch', 'p_employee', 'p_service', 'p_method', 'p_search'} and body['p_employee'] is None and body['p_service'] is None and body['p_method'] is None and body['p_search'] == '' and (body['p_branch'] is None or nonce(body['p_branch']))
        if name in READS:
            return body == {}
        if name == 'get_my_visit_recovery_request':
            return role == 'customer' and body == {'p_case': None}
        if name in ('get_my_visit_recovery_submission', 'close_my_visit_recovery_submission'):
            return role == 'customer' and self.state['submission'] is not None and body == {'p_request': self.state['submission']}
        if name == 'submit_visit_recovery_request':
            expected = {'accepted': True, 'version': 'visit-recovery-v1', 'language': self.args.language,
                        'text': (self.notice or {}).get('notice_' + self.args.language)}
            assert self.notice and expected['text'] and set(body) == {'p_request', 'p_consent'}
            assert body['p_consent'] == expected and nonce(body['p_request'])
            assert self.state['submission'] in (None, body['p_request'])
            self.state['submission'] = body['p_request']
            self.save()  # Journal before dispatch.
            return role == 'customer'
        if name == 'list_visit_recovery_requests':
            return role == 'owner' and body == OWNER_PAGE
        if name == 'prepare_visit_recovery_review':
            assert role == 'owner' and set(body) == {'p_request', 'p_case', 'p_expected_status', 'p_action', 'p_reason'}
            assert self.state['case_id'] and body['p_case'] == self.state['case_id'] and nonce(body['p_request'])
            assert (body['p_expected_status'], body['p_action']) in (('awaiting_matching', 'more_info'), ('more_info', 'reject'))
            assert body['p_reason'] == self.tag + ' ' + body['p_action']
            self.state['reviews'][body['p_request']] = body.copy()
            self.save()
            return True
        if name in ('get_visit_recovery_review', 'apply_visit_recovery_review', 'close_visit_recovery_review'):
            return role == 'owner' and set(body) == {'p_request'} and body['p_request'] in self.state['reviews']
        if name == 'list_my_app_inbox':
            return body == INBOX_PAGE
        if name == 'mark_my_app_inbox_read':
            assert set(body) == {'p_request', 'p_event'} and body['p_event'] in self.events and nonce(body['p_request'])
            old = self.state['read_requests'].get(body['p_event'])
            assert old in (None, body['p_request'])
            self.state['read_requests'][body['p_event']] = body['p_request']
            self.save()
            return True
        return False

    def button(self, page, text, exact=True):
        return page.get_by_role('button', name=text, exact=exact)

    def click(self, page, locator, fixed=False):
        self.proof['last_control'] = 'fixed_navigation' if fixed else 'content_action'
        self.save()
        if not fixed:
            Acceptance.near(page, locator)
        locator.wait_for(state='visible')
        assert locator.is_enabled()
        locator.click()
        page.wait_for_timeout(450)

    def shot(self, page, name):
        page.wait_for_timeout(450)
        path = self.args.screenshots / (self.args.language + '-' + name + '.png')
        path.parent.mkdir(parents=True, exist_ok=True)
        # Mask actual contact/name paragraphs and all inputs in private failure evidence.
        # These are real rendered fields; no hidden or invented display values.
        masks = [page.get_by_role('textbox')]
        if name.startswith('owner'):
            masks += [page.get_by_label(re.compile(re.escape(value))) for value in self.owner_masks]
        page.screenshot(path=str(path), mask=masks)
        path.chmod(0o600)
        self.proof['screens'].append({'name': name, 'path': str(path), 'actual_browser': True, 'private_local': True})
        self.save()

    @contextmanager
    def wait_rpc(self, page, name):
        # Process bodies only after the explicit expect_response context exits,
        # never from a global response listener.
        with page.expect_response(lambda r: r.url.endswith('/rpc/' + name) and r.request.method == 'POST') as pending:
            yield pending
        self.process_rpc_body(pending.value, self.page_roles[page], name)

    def login(self, page, role):
        who = self.customer if role == 'customer' else self.owner
        page.goto(self.h.app)
        page.wait_for_selector('flutter-view', timeout=60000)
        sem = page.locator('flt-semantics-placeholder')
        if sem.count():
            sem.evaluate('(e)=>e.click()')
        self.button(page, 'احجز الآن').first.wait_for(timeout=30000)
        if not self.ar:
            self.click(page, self.button(page, 'EN'))
        self.click(page, self.button(page, self.t('تسجيل الدخول', 'Sign in') if role == 'customer' else self.t('دخول الموظفين', 'Staff sign in')).first)
        for label, key in [(self.t('البريد الإلكتروني', 'Email address'), 'email'), (self.t('كلمة المرور', 'Password'), 'password')]:
            Acceptance.type_into(page, label, who[key])
        page.get_by_role('textbox', name=self.t('كلمة المرور', 'Password'), exact=True).press('Tab')
        with page.expect_response(lambda r: '/auth/v1/token' in r.url and r.request.method == 'POST') as result:
            self.click(page, self.button(page, self.t('تسجيل الدخول', 'Sign In' if role == 'owner' else 'Sign in')))
        assert result.value.status == 200
        data = result.value.json()
        expected = self.actor if role == 'customer' else self.owner.get('id', self.owner.get('user_id'))
        if role == 'owner' and not expected:
            expected = self.h.sql("select user_id from public.staff_profiles where role='owner'and user_id='" + data['user']['id'] + "';")
        assert data['user']['id'] == expected
        self.tokens[role] = data['access_token']
        self.proof['checks'][role + '_actual_login'] = True
        self.save()

    def customer_panel(self, page):
        # Navigation preserves existing session, never injects app permissions/state.
        self.click(page, self.button(page, re.compile(self.t('حسابي', 'Profile')), exact=False).first, fixed=True)
        self.button(page, self.t('حفظ بياناتي', 'Save profile')).wait_for(state='visible')
        page.wait_for_timeout(450)
        with self.wait_rpc(page, 'get_my_visit_recovery_request') as response:
            self.click(page, self.button(page, re.compile(self.t('استرجاع زياراتي السابقة', 'Recover my previous visits')), exact=False).first)
        assert response.value.status == 200
        return response.value.json()

    def customer_home(self, page):
        page.goto(self.h.app)
        page.wait_for_selector('flutter-view', timeout=60000)
        sem = page.locator('flt-semantics-placeholder')
        if sem.count():
            sem.evaluate('(e)=>e.click()')
        self.button(page, re.compile(self.t('حسابي', 'Profile')), exact=False).first.wait_for(state='visible', timeout=30000)
        page.wait_for_timeout(450)

    def inbox(self, page, template):
        self.customer_home(page)
        with self.wait_rpc(page, 'list_my_app_inbox') as response:
            self.click(page, self.button(page, self.t('تحديثات الطلبات', 'Order updates')).first, fixed=True)
        assert response.value.status == 200
        matches = [r for r in response.value.json()['items'] if r['case_reference'] == self.state['case_id'] and r['template_code'] == template]
        assert len(matches) == 1
        self.proof['checks'][template + '_customer_inbox'] = True
        title = matches[0]['title_' + self.args.language]
        Acceptance.near(page, page.get_by_label(re.compile(re.escape(title))).first)
        self.shot(page, template + '-inbox')

    def owner_list(self, page):
        target = self.button(page, self.t('إدارة العملاء', 'CRM'))
        for _ in range(9):
            if target.count():
                box = target.bounding_box()
                if box and 0 <= box['x'] < page.viewport_size['width'] - 40:
                    break
            nav = self.button(page, self.t('التقارير', 'Reports'))
            box = nav.bounding_box()
            assert box, 'Actual owner category bar required'
            page.mouse.move(page.viewport_size['width'] // 2, box['y'] + box['height'] // 2)
            page.mouse.wheel(330 if self.ar else -330, 0)
            page.wait_for_timeout(150)
        self.click(page, target, fixed=True)
        with self.wait_rpc(page, 'list_visit_recovery_requests') as response:
            self.click(page, self.button(page, re.compile(self.t('طلبات استرجاع الزيارات السابقة', 'Previous visits recovery requests')), exact=False).first)
        assert response.value.status == 200
        self.assert_first_case(response.value.json())

    def assert_first_case(self, data):
        assert data['items'] and data['items'][0]['case_id'] == self.state['case_id'], 'Never operate on another case'
        assert data['items'][0]['canonical_claim_mapped'] is False
        return data['items'][0]

    def review(self, page, action, expected):
        item = self.assert_first_case(self.latest[('owner', 'list_visit_recovery_requests')])
        assert item['status'] == expected
        self.stage('owner_' + action)
        label = self.t('طلب معلومات إضافية', 'Request more information') if action == 'more_info' else self.t('رفض', 'Reject')
        self.click(page, self.button(page, label).first)
        Acceptance.type_into(page, self.t('سبب خاص بالمالك (١٠ أحرف على الأقل)', 'Private owner reason (at least 10 characters)'), self.tag + ' ' + action)
        with self.wait_rpc(page, 'prepare_visit_recovery_review') as response:
            self.click(page, self.button(page, self.t('تحضير المراجعة', 'Prepare review')))
        assert response.value.status == 200 and response.value.json()['state'] == 'open'
        with self.wait_rpc(page, 'apply_visit_recovery_review') as response:
            self.click(page, self.button(page, self.t('تنفيذ المراجعة المحضرة', 'Apply prepared review')))
        assert response.value.status == 200 and response.value.json()['state'] == 'succeeded'
        self.button(page, self.t('تمت مراجعة النتيجة', 'Acknowledge result')).wait_for(state='visible')
        self.shot(page, 'owner-' + action + '-actual-result')
        with self.wait_rpc(page, 'list_visit_recovery_requests') as refreshed:
            self.click(page, self.button(page, self.t('تمت مراجعة النتيجة', 'Acknowledge result')))
        assert refreshed.value.status == 200
        self.assert_first_case(refreshed.value.json())
        self.proof['checks']['owner_' + action + '_ui'] = True
        self.save()

    def execute(self):
        self.preflight()
        from playwright.sync_api import sync_playwright, expect
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
                try:
                    pages = {}
                    for role in ('customer', 'owner'):
                        page = browser.new_page(viewport={'width': 390 if self.ar else 1440, 'height': 1100})
                        page.set_default_timeout(30000)
                        self.page_roles[page] = role
                        page.route('**/*', lambda route, request, role=role: self.guard(route, role))
                        page.on('response', lambda response, role=role: self.observe(response, role))
                        page.on('pageerror', lambda _: self.proof['render_errors'].append('javascript_error'))
                        page.on('console', lambda msg: self.proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                        pages[role] = page
                    customer, owner = pages['customer'], pages['owner']
                    self.stage('customer_existing_terminal_case')
                    # Establish an actual owner session before any new case can exist, so
                    # finally cleanup never needs new Auth or an unrelated actor.
                    self.login(owner, 'owner')
                    self.login(customer, 'customer')
                    context = self.customer_panel(customer)
                    assert context['new_request_allowed'] is True and self.case_from(context)['status'] in ('rejected', 'revoked')
                    check = customer.get_by_role('checkbox', name=self.t('أوافق على طلب المراجعة بهذا النطاق', 'I agree to this review request scope'), exact=True)
                    Acceptance.near(customer, check)
                    expect(check).not_to_be_checked()
                    check.click()
                    with self.wait_rpc(customer, 'submit_visit_recovery_request') as response:
                        self.click(customer, self.button(customer, self.t('إرسال طلب جديد للمراجعة', 'Send a new request for review')))
                    assert response.value.status == 200
                    assert self.case_from(response.value.json())['status'] == 'awaiting_matching'
                    self.button(customer, self.t('راجعت النتيجة', 'I reviewed the result')).wait_for(state='visible')
                    self.shot(customer, 'customer-actual-submission-receipt')
                    self.click(customer, self.button(customer, self.t('راجعت النتيجة', 'I reviewed the result')))
                    assert customer.evaluate('(key)=>localStorage.getItem(key)', 'flutter.visit_recovery_submission_uuid_' + self.actor) is None
                    self.proof['checks']['customer_submission_receipt_acknowledged'] = True
                    self.inbox(customer, 'recovery_received')
                    self.owner_list(owner)
                    self.review(owner, 'more_info', 'awaiting_matching')
                    self.customer_home(customer)
                    context = self.customer_panel(customer)
                    assert self.case_from(context)['case_id'] == self.state['case_id'] and self.case_from(context)['status'] == 'more_info'
                    self.shot(customer, 'customer-more-info-status')
                    self.inbox(customer, 'recovery_more_info')
                    self.review(owner, 'reject', 'more_info')
                    self.customer_home(customer)
                    context = self.customer_panel(customer)
                    assert self.case_from(context)['case_id'] == self.state['case_id'] and self.case_from(context)['status'] == 'rejected'
                    self.shot(customer, 'customer-rejected-status')
                    self.inbox(customer, 'recovery_rejected')
                    assert not self.proof['blocked_requests'] and not self.proof['render_errors']
                    self.proof['all_passed'] = True
                except Exception as error:
                    self.proof['failure_type'] = type(error).__name__
                    # No raw DOM/body: owner views contain registered contact details.
                    for role, page in pages.items():
                        try:
                            self.shot(page, role + '-failure-private')
                        except Exception:
                            pass
                    raise
                finally:
                    browser.close()
        finally:
            try:
                self.cleanup()
            except Exception as error:
                self.proof['cleanup_error_type'] = type(error).__name__
            if self.before is not None:
                after = Intake.snapshot(self.h)
                self.proof['preexisting_public_private_rows_unchanged'] = all(not (rows - after.get(table, Counter())) for table, rows in self.before.items())
                self.proof['document_counters_unchanged'] = Intake.counters(self.h) == self.counters
                self.proof['auth_users_unchanged_except_signin_metadata'] = self.auth_hash() == self.auth_before
            self.save()
        assert self.proof['all_passed'] and self.state['cleanup_complete']
        assert self.proof['preexisting_public_private_rows_unchanged'] and self.proof['document_counters_unchanged'] and self.proof['auth_users_unchanged_except_signin_metadata']

    def rpc_as(self, role, name, body):
        assert role in self.tokens, 'No new cleanup login'
        self.h.token = self.tokens[role]
        return self.h.rpc(name, body)

    def cleanup(self):
        self.stage('cleanup_exact_new_case_only')
        if self.state['submission'] and not self.state['case_id']:
            receipt = self.rpc_as('customer', 'close_my_visit_recovery_submission', {'p_request': self.state['submission']})
            if receipt['state'] == 'accepted':
                self.state['case_id'] = self.case_from(receipt['result'])['case_id']
            else:
                assert receipt['state'] == 'closed'
        for rid in list(self.state['reviews']):
            self.rpc_as('owner', 'close_visit_recovery_review', {'p_request': rid})
        cid = self.state['case_id']
        if cid:
            assert nonce(cid) and cid not in self.state['old_case_ids']
            # Exact source ownership + no canonical bridge. Never touch old cases/claims.
            row = json.loads(self.h.sql("select json_build_object('own',requester_id='" + self.actor + "','status',status,'mapped',exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id))from private.visit_recovery_customer_requests c where case_id='" + cid + "';"))
            assert row['own'] and not row['mapped']
            if row['status'] in ('awaiting_matching', 'more_info'):
                rid = str(uuid.uuid4())
                body = {'p_request': rid, 'p_case': cid, 'p_expected_status': row['status'], 'p_action': 'reject', 'p_reason': self.tag + ' exact new case cleanup'}
                self.state['reviews'][rid] = body
                self.save()
                self.rpc_as('owner', 'prepare_visit_recovery_review', body)
                result = self.rpc_as('owner', 'apply_visit_recovery_review', {'p_request': rid})
                assert result['state'] == 'succeeded'
            else:
                assert row['status'] == 'rejected'
        self.state['cleanup_complete'] = True
        self.proof['cleanup_complete'] = True
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('runtime', 'proof', 'screenshots', 'build-proof'):
        parser.add_argument('--' + field, type=Path, required=True)
    parser.add_argument('--language', choices=('ar', 'en'), required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({'plan_only': True, 'language': args.language,
                          'journey': ['existing_terminal_customer_login', 'explicit_new_request_and_receipt',
                                      'customer_inbox', 'owner_more_info', 'customer_status_and_inbox',
                                      'owner_reject', 'customer_status_and_inbox'],
                          'cleanup': 'exact new unmapped case rejected; immutable audit retained',
                          'no_claim_link_history_or_financial_operations': True}))
        return
    RequestJourney(args).execute()


if __name__ == '__main__':
    main()
