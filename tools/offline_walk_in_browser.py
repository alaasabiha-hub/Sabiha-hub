"""Local actual received-only Walk-in acceptance; plan only without --execute.

Reuses ONE known prior QA registration (no new secret/claim/Auth account), adds
one explicitly tagged local catalogue service and one unpaid work/invoice.
Checks durable handoff/command reload, true catalogue price and staff invoice.
Only the validated new work may be voided during cleanup. Never pays, starts
washing, awards loyalty, sends ETA, deletes rows or touches a hosted endpoint.
Run each locale separately; retain a completed locale rather than repeating it.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid

from offline_customer_registration_browser import Harness as IntakeHarness
from service_booking_acceptance import Acceptance


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class Harness(IntakeHarness):
    def safe_screenshot(self, page, language, width, stage):
        # HTTP may finish before the Material route transition. Preserve settled
        # screens, rather than interpreting an intermediate slide as overflow.
        page.wait_for_timeout(450)
        return super().safe_screenshot(page, language, width, stage)

    def __init__(self, args):
        super().__init__(args)
        self.proof_file.parent.mkdir(parents=True, exist_ok=True)
        self.probe_only = args.probe_only
        self.resume_handoff = args.resume_handoff_proof
        self.resume_manifest = args.resume_handoff_manifest
        self.language = args.languages[0]
        self.service = str(uuid.uuid4())
        self.service_name = 'QA Walk-in UI ' + self.tag
        self.price = 137.45
        self.preparation = None
        self.result = None
        self.owner_token = None
        self.borrowed_hashes = None
        self.borrowed_source = args.contract_state
        self.borrowed_proof = args.contract_proof
        self.service_created = False
        self.ui_mutations = Counter()
        self.state_file = self.r / ('walkin-browser-state-' + self.tag + '.json')
        self.state = {'local_only': True, 'tag': self.tag, 'service_id': self.service,
                      'registration_request_id': self.recover_request,
                      'command_id': None, 'order_id': None, 'cleanup_complete': False}
        self.proof = {'local_only': True, 'production_touched': False,
                      'cash_or_gateway_payment_executed': False, 'invoice_created': False,
                      'auth_account_created': False,
                      'raw_secret_persisted': False, 'all_passed': False,
                      'screens': [], 'render_errors': [], 'blocked_requests': [],
                      'language': self.language, 'tag': self.tag}

    def call(self, path, data):
        request = urllib.request.Request(self.base + path, data=json.dumps(data).encode(), method='POST',
            headers={'apikey': self.settings['ANON_KEY'], 'Authorization': 'Bearer ' + (self.token or self.settings['ANON_KEY']),
                     'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            raise RuntimeError(path.split('?')[0] + ' failed HTTP ' + str(error.code)) from error

    def employment_hashes(self):
        return json.loads(self.sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text)) '
            'from private.hr_employment e where staff_id in(' + ','.join(map(literal, self.staff)) + ');'))

    def auth_fingerprint(self):
        return self.sql("select count(*)::text||':'||md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")

    def preflight(self):
        self.verify_build()
        project = Path(__file__).resolve().parents[1]
        built = project / 'build/web/main.dart.js'
        assert all(built.stat().st_mtime >= (project / n).stat().st_mtime for n in
                   ['lib/offline_walk_in.dart', 'lib/offline_customer_registration.dart', 'lib/cashier_shifts.dart'])
        prior = json.loads((self.r / 'offline-claim-browser-proof-static-resolved.json').read_text())
        assert prior['all_passed'] and prior['qa_links_revoked']
        known = next(x for x in prior['journeys'] if x['language'] == self.language)
        assert self.recover_request == known['intake_request']
        self.branch = self.sql('select branch_id from public.business_branches where is_default and is_active;')
        uuid.UUID(self.branch)
        self.manager = self.accounts['users']['manager']['id']
        if self.resume_handoff:
            assert not self.probe_only
            self.resume_handoff.resolve().relative_to(self.r)
            checkpoint = json.loads(self.resume_handoff.read_text())
            journal_path = self.r / ('walkin-browser-state-' + checkpoint['tag'] + '.json')
            staged = json.loads(journal_path.read_text())
            assert checkpoint['language'] == self.language and checkpoint['local_only']
            assert all(checkpoint.get(k) is True for k in ['known_receipt_recovered_without_secret_reissue',
                'handoff_removed_original_reference_and_code','preexisting_rows_unchanged',
                'auth_user_ids_and_count_unchanged','borrowed_full_contracts_unchanged','cleanup_complete'])
            assert checkpoint['receipt_probe']['request_matches'] and checkpoint['receipt_probe']['no_secret']
            assert staged['registration_request_id'] == self.recover_request and staged['branch_id'] == self.branch
            assert staged['command_id'] is None and staged['order_id'] is None and staged['cleanup_complete']
            manifest = json.loads(self.resume_manifest.read_text())
            assert manifest['exit_code'] == 0 and manifest['source_unchanged']
            assert manifest['main_dart_js_sha256'] == checkpoint['served_build_sha256']
            for source in ['lib/offline_walk_in.dart','lib/offline_customer_registration.dart','lib/cashier_shifts.dart']:
                assert manifest['source_before'][source] == manifest['source_after'][source]
                assert hashlib.sha256((project / source).read_bytes()).hexdigest() == manifest['source_after'][source]
            self.proof['resumed_prior_handoff'] = {'proof': str(self.resume_handoff),
                'proof_sha256': hashlib.sha256(self.resume_handoff.read_bytes()).hexdigest(),
                'original_build_sha256': checkpoint['served_build_sha256'], 'exact_handoff_sources_unchanged': True}
            # Proven prior checkpoints are referenced explicitly, never claimed as rerun.
            for key in ['known_receipt_recovered_without_secret_reissue','handoff_removed_original_reference_and_code']:
                self.proof[key] = checkpoint[key]

        for path in [self.borrowed_source, self.borrowed_proof]:
            path.resolve().relative_to(self.r)
        journal = json.loads(self.borrowed_source.read_text())
        journal_proof = json.loads(self.borrowed_proof.read_text())
        assert journal['local_only'] and journal_proof['local_only'] and journal_proof['all_passed']
        assert journal['tag'] == journal_proof['tag']
        assert journal_proof['borrowed_contracts_untouched'] and journal_proof['only_explicit_journal_proven_qa_contracts_reused']
        roles = journal['worker_roles']
        assert len(roles) == 2 and set(roles) == {'manager', 'other_employee'}
        self.staff = sorted(self.accounts['users'][role]['id'] for role in roles)
        assert self.staff == sorted(journal['selected_worker_ids']) == sorted(journal['borrowed_contract_staff_ids'])
        self.rates = {self.accounts['users'][role]['id']: rate for role, rate in zip(roles, [15, 25])}
        self.borrowed_hashes = journal['borrowed_contract_hashes']
        assert self.employment_hashes() == self.borrowed_hashes, 'Borrowed full contracts changed since accepted journal'
        assert self.sql('select exists(select 1 from private.offline_customer_registration_requests where request_id=' +
                        literal(self.recover_request) + ' and actor_id=' + literal(self.manager) + ' and branch_id=' +
                        literal(self.branch) + " and result->>'status'='created_unverified');") == 't'
        today = self.sql("select(clock_timestamp()at time zone'Africa/Cairo')::date;")
        for worker in self.staff:
            assert self.sql('select exists(select 1 from private.hr_employment e join public.staff_branch_access a on a.user_id=e.staff_id '
                'where e.staff_id=' + literal(worker) + ' and a.branch_id=' + literal(self.branch) +
                " and e.salary=0 and e.currency='EGP' and e.commission_percent=" + str(self.rates[worker]) +
                ' and e.starts_on=' + literal(today) + '::date and e.ends_on=' + literal(today) + '::date);') == 't'
        self.proof['journal_contract_full_hashes_verified'] = True
        self.state['borrowed_contract_hashes'] = self.borrowed_hashes
        self.state['worker_rates_by_id'] = self.rates
        assert self.sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id=' +
                        literal(self.manager) + ' and acknowledged_at is null);') == 't'
        assert self.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;') == '0'
        # Mirror the actual receiver's branch-hours eligibility BEFORE fixture setup.
        window = json.loads(self.sql("with now_local as(select clock_timestamp()at time zone'Africa/Cairo' n),"
            "configured as(select n,h.is_open,h.opens_at,h.closes_at,e.exception_date,e.is_closed,"
            "e.opens_at exception_open,e.closes_at exception_close from now_local "
            "left join public.business_branch_hours h on h.branch_id=" + literal(self.branch) +
            " and h.weekday=extract(dow from n)::int left join public.business_branch_exceptions e on e.branch_id=" +
            literal(self.branch) + " and e.exception_date=n::date)select jsonb_build_object('cairo_now',n,"
            "'duration_minutes',5,'configured',is_open is not null,'reception_window_open',coalesce("
            "(case when exception_date is not null then not is_closed else is_open end) and "
            "n::time >=(case when exception_date is not null then exception_open else opens_at end) and "
            "n+interval'5 minutes'<=n::date+(case when exception_date is not null then exception_close else closes_at end),false))from configured;"))
        self.proof['pre_setup_operating_window'] = window
        if not self.probe_only:
            assert window['configured'] and window['reception_window_open'], 'Actual reception window closed; no fixture setup allowed'
        self.proof['reused_verified_qa_registration'] = True
        self.state['branch_id'] = self.branch
        self.save_state()

    def setup(self):
        owner = self.accounts['users']['owner']
        self.owner_token = self.call('/auth/v1/token?grant_type=password',
                                     {'email': owner['email'], 'password': owner['password']})['access_token']
        # Local tagged data only; no existing service, branch, employment or price changes.
        self.service_created = True
        self.save_state()
        self.sql('begin;do $$begin if (select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text)) from private.hr_employment e where staff_id in(' + ','.join(map(literal, self.staff)) + ')) is distinct from ' + literal(json.dumps(self.borrowed_hashes)) + "::jsonb then raise exception 'Borrowed contracts changed';end if;end$$;insert into public.business_catalog_items(item_id,branch_id,item_type,name,name_en,vehicle_type,price,"
                 'duration_minutes,resource_key,is_active,is_public)values(' +
                 ','.join(map(literal, [self.service, self.branch, 'service', self.service_name,
                                       self.service_name, 'sedan'])) + ',137.45,5,\'wash\',true,true);commit;')

    def direct_click(self, locator):
        locator.wait_for(state='visible')
        from playwright.sync_api import expect
        expect(locator).to_be_enabled(timeout=25000)
        locator.click()

    def near_click(self, page, locator):
        Acceptance.near(page, locator).click()

    def guard(self, route):
        req = route.request
        parsed = urllib.parse.urlsplit(req.url)
        api = any(x in parsed.path for x in ['/auth/v1/', '/rest/v1/', '/functions/v1/', '/storage/v1/'])
        rpc = parsed.path.rsplit('/', 1)[-1] if '/rest/v1/rpc/' in parsed.path else None
        if rpc == 'claim_customer_product_ad':
            route.fulfill(status=200, content_type='application/json', body='[]')
            return
        if req.method == 'OPTIONS':
            if api and parsed.hostname != '127.0.0.1': route.abort()
            else: route.continue_()
            return
        allowed = {'get_public_home', 'get_public_promotions', 'default_branch_id', 'get_admin_console',
                   'get_offline_customer_registration', 'get_offline_walk_in_context', 'get_offline_walk_in_command',
                   'prepare_offline_walk_in', 'place_offline_walk_in', 'ack_offline_walk_in_command',
                   'close_offline_walk_in_command', 'cashier_shift_totals', 'list_invoice_documents',
                   'resolve_invoice_document'}
        if self.probe_only:
            allowed -= {'prepare_offline_walk_in','place_offline_walk_in','ack_offline_walk_in_command','close_offline_walk_in_command'}
        bad = api and parsed.hostname != '127.0.0.1'
        bad |= rpc is not None and rpc not in allowed
        bad |= api and rpc is None and req.method not in ['GET', 'HEAD', 'OPTIONS'] and parsed.path not in ['/auth/v1/token', '/auth/v1/logout']
        body = json.loads(req.post_data or '{}') if rpc else {}
        parameterless = {'get_public_home','get_public_promotions','default_branch_id','list_invoice_documents'}
        if body is None and rpc in parameterless:
            body = {}
        if not isinstance(body, dict):
            self.proof['blocked_requests'].append({'path': parsed.path, 'method': req.method, 'reason': 'nonobject_rpc_body'})
            route.abort()
            return
        if rpc in ['get_offline_customer_registration', 'get_offline_walk_in_context']:
            bad |= body.get('p_request', body.get('p_registration')) != self.recover_request
        exact_keys = {
            'get_offline_customer_registration': {'p_request'},
            'get_offline_walk_in_context': {'p_registration'},
            'get_offline_walk_in_command': {'p_request'},
            'prepare_offline_walk_in': {'p_request','p_registration','p_service','p_expected_price','p_cashier','p_staff_ids','p_notes'},
            'place_offline_walk_in': {'p_request'}, 'ack_offline_walk_in_command': {'p_request'},
            'close_offline_walk_in_command': {'p_request'},
            'list_invoice_documents': set(), 'resolve_invoice_document': {'p_token'},
        }
        if rpc in exact_keys:
            bad |= set(body) != exact_keys[rpc]
        if rpc == 'get_offline_walk_in_command':
            bad |= body.get('p_request') not in [None, self.state.get('command_id')]
        if rpc == 'resolve_invoice_document':
            bad |= self.result is None or body.get('p_token') != self.result['invoice_token']
        if rpc == 'prepare_offline_walk_in':
            bad |= body.get('p_registration') != self.recover_request or body.get('p_service') != self.service
            bad |= body.get('p_expected_price') != self.price or body.get('p_cashier') != self.manager
            bad |= sorted(body.get('p_staff_ids', [])) != self.staff or body.get('p_notes') is not None
            if self.preparation is not None:
                bad |= body != self.preparation
            if not bad:
                uuid.UUID(body['p_request'])
                self.preparation = body
                self.state['command_id'] = body['p_request']
                self.save_state()
        if rpc in ['place_offline_walk_in', 'ack_offline_walk_in_command', 'close_offline_walk_in_command']:
            bad |= self.preparation is None or body.get('p_request') != self.preparation['p_request']
        if rpc == 'place_offline_walk_in' and not bad:
            self.state['placement_dispatched'] = True
            self.save_state()
        if bad:
            self.proof['blocked_requests'].append({'path': parsed.path, 'method': req.method})
            route.abort()
        else:
            if rpc in ['prepare_offline_walk_in', 'place_offline_walk_in']:
                self.ui_mutations[rpc] += 1
            route.continue_()

    def cashier(self, page, label):
        reports = page.get_by_role('button', name=label('التقارير', 'Reports'), exact=True)
        reports.wait_for(state='visible', timeout=30000)
        reports.click()
        self.near_click(page, page.get_by_role('button', name=label('ورديات الكاشير', 'Cashier shifts'), exact=True))

    def browser(self):
        from playwright.sync_api import sync_playwright, expect
        ar = self.language == 'ar'
        width = 390 if ar else 1440
        label = lambda a, e: a if ar else e
        self.out.mkdir(parents=True, exist_ok=True)
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                                         headless=True, args=['--disk-cache-size=0'])
            try:
                page = browser.new_page(viewport={'width': width, 'height': 1100})
                page.set_default_timeout(25000)
                page.route('**/*', self.guard)
                page.on('pageerror', lambda _: self.proof['render_errors'].append('javascript_error'))
                key = ('flutter.offline_walk_in_handoff_' + self.manager + '_' + self.branch + '_registration'
                       if self.resume_handoff else 'flutter.offline_registration_uuid_' + self.manager + '_' + self.branch)
                page.add_init_script('if(location.origin===' + json.dumps(self.app) + '&&!sessionStorage.getItem("walkinQaSeeded"))'
                                     '{localStorage.setItem(' + json.dumps(key) + ',JSON.stringify(' + json.dumps(self.recover_request) + '));sessionStorage.setItem("walkinQaSeeded","1");}')
                self.stage('navigation')
                page.goto(self.app)
                page.wait_for_selector('flutter-view', timeout=60000)
                placeholder = page.locator('flt-semantics-placeholder')
                if placeholder.count(): placeholder.evaluate('(e)=>e.click()')
                page.get_by_role('button', name='احجز الآن', exact=True).first.wait_for(timeout=30000)
                if not ar: self.near_click(page, page.get_by_role('button', name='EN', exact=True))
                self.near_click(page, page.get_by_role('button', name=label('دخول الموظفين', 'Staff sign in'), exact=True))
                account = self.accounts['users']['manager']
                for a, e, k in [('البريد الإلكتروني', 'Email address', 'email'), ('كلمة المرور', 'Password', 'password')]:
                    Acceptance.type_into(page, label(a, e), account[k])
                page.get_by_role('textbox', name=label('كلمة المرور', 'Password'), exact=True).press('Tab')
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.startswith(self.base + '/auth/v1/token?')) as login:
                    self.near_click(page, page.get_by_role('button', name=label('تسجيل الدخول', 'Sign In'), exact=True))
                assert login.value.status == 200
                self.token = login.value.json()['access_token']  # RAM only.
                self.cashier(page, label)
                if self.resume_handoff:
                    self.stage('resume-proven-handoff-context')
                    with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/get_offline_walk_in_context')) as context:
                        self.direct_click(page.get_by_role('button', name=label('استقبال خدمة مباشرة', 'Walk-in reception'), exact=True))
                else:
                    self.stage('recover-known-receipt')
                    with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/get_offline_customer_registration')) as intake:
                        self.direct_click(page.get_by_role('button', name=label('تسجيل عميل بدون تطبيق', 'Register customer without the app'), exact=True))
                    receipt = intake.value.json()
                    self.proof['receipt_probe'] = {
                        'http_status': intake.value.status, 'request_method': intake.value.request.method,
                        'response_type': type(receipt).__name__,
                        'keys': sorted(receipt.keys()) if isinstance(receipt, dict) else [],
                        'status': receipt.get('status') if isinstance(receipt, dict) else None,
                        'request_matches': isinstance(receipt, dict) and receipt.get('request_id') == self.recover_request,
                        'no_secret': isinstance(receipt, dict) and not receipt.get('enrollment_secret'),
                    }
                    self.proof_file.write_text(json.dumps(self.proof, ensure_ascii=False, indent=2) + '\n')
                    self.proof_file.chmod(0o600)
                    assert intake.value.status == 200 and receipt['request_id'] == self.recover_request
                    assert not receipt.get('enrollment_secret') and receipt['status'] == 'created_unverified'
                    self.proof['known_receipt_recovered_without_secret_reissue'] = True
                    # Final route/control names are checked against the integrated source before execution.
                    handoff = page.get_by_role('button', name=label('تأكيد استلام الإيصال وفتح استقبال الخدمة المباشرة',
                                   'Acknowledge receipt and open walk-in reception'), exact=True)
                    expect(handoff).to_be_disabled()
                    checkbox = page.get_by_role('checkbox', name=label('أفهم أن الرمز المفقود يحتاج مراجعة المالك',
                                                            'I understand that owner review is required for the missing code'), exact=True)
                    if self.probe_only:
                        expect(checkbox).not_to_be_checked()
                        self.safe_screenshot(page, self.language, width, 'known-receipt-readonly-probe')
                        self.proof['readonly_probe_passed'] = True
                        self.proof['checkbox_unchecked_handoff_disabled'] = True
                        return
                    self.near_click(page, checkbox)
                    with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/get_offline_walk_in_context')) as context:
                        self.near_click(page, handoff)
                assert context.value.status == 200
                data = context.value.json()
                assert data['registration_request_id'] == self.recover_request
                assert data['branch']['id'] == self.branch and data['bound_cashier']['id'] == self.manager
                assert any(x['id'] == self.service and float(x['price']) == self.price for x in data['services'])
                assert set(self.staff).issubset(x['id'] for x in data['workers'])
                self.stage('handoff-context')
                assert page.evaluate('Object.keys(localStorage).filter(k=>k.includes("offline_registration_uuid_")).length') == 0
                assert page.locator('[aria-label*="Private receipt code"],[aria-label*="رمز الإيصال السري"]').count() == 0
                self.proof['handoff_removed_original_reference_and_code'] = True
                prepare = lambda: page.get_by_role('button', name=label('حفظ هذا التحضير نفسه', 'Save this exact preparation'), exact=True)
                expect(prepare()).to_be_disabled()
                self.safe_screenshot(page, self.language, width, 'authorized-context')

                def reopen():
                    page.reload()
                    page.wait_for_selector('flutter-view', timeout=60000)
                    semantics = page.locator('flt-semantics-placeholder')
                    if semantics.count(): semantics.evaluate('(e)=>e.click()')
                    self.cashier(page, label)
                    self.direct_click(page.get_by_role('button', name=label('استقبال خدمة مباشرة', 'Walk-in reception'), exact=True))

                self.stage('reload-handoff-context-only')
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/get_offline_walk_in_context')) as restored:
                    reopen()
                assert restored.value.status == 200 and restored.value.json()['registration_request_id'] == self.recover_request
                assert restored.value.json()['branch']['id'] == self.branch
                assert restored.value.json()['bound_cashier']['id'] == self.manager
                expect(prepare()).to_be_disabled()
                assert self.ui_mutations['prepare_offline_walk_in'] == 0
                self.proof['handoff_reload_context_only'] = True
                self.stage('explicit-service-workers')
                field_label = label('الخدمة الفعلية المختارة', 'Explicit actual service')
                dropdown = page.get_by_role('button', name=re.compile('^' + re.escape(field_label))).or_(
                    page.get_by_role('combobox', name=re.compile('^' + re.escape(field_label)))).last
                self.near_click(page, dropdown)
                display = self.service_name + ' · 137.45 EGP'
                option = page.get_by_role('menuitem', name=display, exact=True).or_(page.get_by_role('option', name=display, exact=True))
                option.wait_for(state='visible')
                option.click()
                for worker in self.staff:
                    name = next(x['name'] for x in data['workers'] if x['id'] == worker)
                    self.near_click(page, page.get_by_role('checkbox', name=name, exact=True))
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/prepare_offline_walk_in')) as prepared:
                    self.near_click(page, prepare())
                response = prepared.value.json()
                if prepared.value.status != 200 or response.get('status') != 'prepared':
                    allowed_messages = {
                        'Reception service outside configured hours', 'Branch closed today', 'Configured branch hours required',
                        'Every assigned branch worker needs actual current EGP employment',
                        'Supported actual positive-price service required', 'Service price changed; close this preparation and refresh',
                        'Authorized same-cashier branch intake receipt required', 'Active EGP branch required',
                        'Active owner or branch manager required to assign workers', 'Preparation receipt unavailable',
                        'Preparation payload changed', 'Actual intake profile and car binding required',
                    }
                    code = str(response.get('code',''))
                    self.proof['prepare_failure'] = {'http_status':prepared.value.status,
                        'code':code if re.fullmatch(r'[A-Z0-9]{1,10}',code) else 'unavailable',
                        'message':response.get('message') if response.get('message') in allowed_messages else 'Unrecognized server error (raw details not exported)'}
                    self.proof_file.write_text(json.dumps(self.proof,ensure_ascii=False,indent=2)+'\n')
                    self.proof_file.chmod(0o600)
                assert prepared.value.status == 200 and response['status'] == 'prepared'
                assert response['request_id'] == self.state['command_id']
                self.stage('reload-prepared-command')
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/get_offline_walk_in_command')) as recovered:
                    reopen()
                response = recovered.value.json()
                assert recovered.value.status == 200 and response['status'] == 'prepared'
                assert response['request_id'] == self.state['command_id']
                payload = response['payload']
                assert payload['registration_request_id'] == self.recover_request
                assert payload['service_id'] == self.service and payload['cashier_id'] == self.manager
                assert sorted(payload['staff_ids']) == self.staff and float(payload['expected_price']) == self.price
                assert payload['notes'] is None
                assert self.ui_mutations['prepare_offline_walk_in'] == 1
                self.proof['prepared_command_reload_exact_nonce'] = True
                self.stage('create-received-work')
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/place_offline_walk_in')) as placed:
                    self.near_click(page, page.get_by_role('button', name=label('إنشاء أو إعادة هذا العمل المستلم نفسه',
                                                           'Create or retry this exact received work'), exact=True))
                response = placed.value.json()
                assert placed.value.status == 200 and response['status'] == 'succeeded'
                result = response['result']
                assert float(result['gross_amount']) == self.price and result['work_status'] == 'received'
                assert result['payment_status'] == 'unpaid' and result['invoice_status'] == 'active'
                assert response['request_id'] == self.state['command_id']
                self.result = result
                self.proof['invoice_created'] = True
                self.state['order_id'] = result['order_id']
                self.state['invoice_id'] = result['invoice_id']
                self.save_state()
                self.proof['received_work_checkpoint'] = {'request_id': response['request_id'], 'order_id': result['order_id'], 'invoice_id': result['invoice_id']}
                self.proof_file.write_text(json.dumps(self.proof, ensure_ascii=False, indent=2) + '\n')
                self.proof_file.chmod(0o600)
                self.safe_screenshot(page, self.language, width, 'received-invoice')
                self.stage('staff-invoice')
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/resolve_invoice_document')) as invoice:
                    self.near_click(page, page.get_by_role('button', name=label('عرض الفاتورة الفعلية', 'View actual invoice'), exact=True))
                document = invoice.value.json()
                assert invoice.value.status == 200 and document['invoice_id'] == result['invoice_id']
                assert document['invoice_number'] == result['invoice_number'] and float(document['invoice_total']) == self.price
                assert document['booking_id'] is None and document['payment_status'] == 'unpaid'
                assert page.get_by_role('button', name=re.compile('Payment options|خيارات الدفع')).count() == 0
                self.safe_screenshot(page, self.language, width, 'actual-staff-invoice')
                self.proof['actual_invoice_price_uuid_and_unpaid_state'] = True
                self.proof['one_explicit_command_one_placement'] = self.ui_mutations == Counter(
                    {'prepare_offline_walk_in': 1, 'place_offline_walk_in': 1})
                self.stage('terminal-ui-acknowledgement')
                back = page.get_by_role('button', name=re.compile(r'^(Back|رجوع)$')).first
                self.direct_click(back)
                with page.expect_response(lambda r: r.request.method == 'POST' and r.url.endswith('/rpc/ack_offline_walk_in_command')) as acknowledged:
                    self.near_click(page, page.get_by_role('button', name=label('راجعت هذه النتيجة · إنهاء', 'I reviewed this result · Finish'), exact=True))
                ack = acknowledged.value.json()
                assert acknowledged.value.status == 200 and ack['request_id'] == self.state['command_id'] and ack['acknowledged'] is True
                assert ack['status'] == 'succeeded' and ack['result']['invoice_id'] == result['invoice_id']
                page.wait_for_function('!Object.keys(localStorage).some(k=>k.includes("offline_walk_in_handoff_")||k.includes("offline_walk_in_request_"))')
                self.proof['terminal_ui_ack_cleared_handoff_and_command_uuid'] = True
                self.proof['journey_completed'] = True
            finally:
                browser.close()

    def cleanup(self):
        # No fallback creation: authoritative close of a recorded nonce can only
        # preserve an already-created validated result or fence a delayed place.
        old = self.token
        try:
            # The browser command belongs to its actual manager. Closing an absent
            # nonce must create that manager's tombstone, not an owner-held one.
            self.token = old
            command = self.state.get('command_id')
            if command:
                assert old is not None, 'Bound manager session required for exact-nonce cleanup'
                response = self.rpc('close_offline_walk_in_command', {'p_request': command})
                assert response['request_id'] == command and response['status'] in ['closed', 'succeeded']
                result = response.get('result') or {}
                order = result.get('order_id')
                if order:
                    uuid.UUID(order)
                    valid = self.sql('select exists(select 1 from private.offline_walk_in_subjects where order_id=' +
                                     literal(order) + ' and registration_request_id=' + literal(self.recover_request) +
                                     ' and service_id=' + literal(self.service) + ' and branch_id=' + literal(self.branch) + ');')
                    assert valid == 't'
                    assert response['status'] == 'succeeded'
                    assert float(result['gross_amount']) == self.price and result['work_status'] == 'received'
                    assert result['invoice_status'] == 'active' and result['payment_status'] == 'unpaid'
                    assert self.sql('select exists(select 1 from private.offline_walk_in_subjects s join public.business_invoices i on i.invoice_id=s.invoice_id '
                        'where s.order_id=' + literal(order) + ' and s.command_id=' + literal(command) +
                        ' and s.invoice_id=' + literal(result['invoice_id']) + ' and s.gross=137.45 and i.total=137.45 and i.discount=0 '
                        "and i.status='active' and not exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id));") == 't'
                    self.state['order_id'], self.state['invoice_id'] = order, result['invoice_id']
                    self.save_state()
                    self.state.setdefault('cancel_id', str(uuid.uuid4()))
                    self.save_state()
                    self.token = self.owner_token
                    self.rpc('cancel_offline_walk_in', {'p_request': self.state['cancel_id'], 'p_order': order,
                                                       'p_reason': 'Isolated unpaid browser QA cleanup ' + self.tag})
                self.token = old  # Actual bound cashier acknowledges its command.
                ack = self.rpc('ack_offline_walk_in_command', {'p_request': command})
                assert ack['request_id'] == command and ack['acknowledged'] is True
                assert ack['status'] == response['status']
                if order: assert ack['result']['invoice_status'] != 'active' and ack['result']['work_status'] == 'cancelled'
            if self.service_created:
                self.sql('update public.business_catalog_items set is_active=false,is_public=false where item_id=' + literal(self.service) + ' and branch_id=' + literal(self.branch) + ' and name=' + literal(self.service_name) + ';')
                assert self.sql('select exists(select 1 from public.business_catalog_items where item_id=' + literal(self.service) +
                    ' and branch_id=' + literal(self.branch) + ' and name=' + literal(self.service_name) + ' and not is_active and not is_public);') == 't'
            self.state['cleanup_complete'] = True
            self.save_state()
        finally:
            self.token = old


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--proof', type=Path, required=True)
    p.add_argument('--screenshots', type=Path, required=True)
    p.add_argument('--app-url', default='http://127.0.0.1:8080')
    p.add_argument('--staff-role', choices=['manager'], default='manager')
    p.add_argument('--language', choices=['ar', 'en'], required=True)
    p.add_argument('--recover-request', required=True)
    p.add_argument('--contract-state', type=Path)
    p.add_argument('--contract-proof', type=Path)
    p.add_argument('--resume-handoff-proof', type=Path)
    p.add_argument('--resume-handoff-manifest', type=Path)
    p.add_argument('--probe-only', action='store_true', help='Read known receipt only; no catalogue/setup/command writes')
    p.add_argument('--execute', action='store_true')
    args = p.parse_args()
    if not args.execute:
        print(__doc__)
        return
    args.contract_state = args.contract_state or args.runtime / 'walkin-financial-concurrency-state.json'
    args.contract_proof = args.contract_proof or args.runtime / 'walkin-financial-concurrency-proof.json'
    if args.resume_handoff_proof:
        assert args.resume_handoff_manifest, 'Original successful build manifest required'
    args.languages = [args.language]
    h = Harness(args)
    before = counters = auth = None
    try:
        h.preflight()
        before, counters, auth = h.snapshot(), h.counters(), h.auth_fingerprint()
        if not args.probe_only: h.setup()
        h.browser()
    except Exception as exc:
        h.proof.update(error_type=type(exc).__name__, failed_stage=h.state.get('stage'))
    finally:
        try:
            if args.probe_only:
                assert h.preparation is None and not h.service_created and not h.state.get('command_id')
                h.state['cleanup_complete'] = True
                h.save_state()
            else:
                h.cleanup()
        except Exception as exc:
            h.proof['cleanup_error_type'] = type(exc).__name__
        try:
            if before is not None:
                after = h.snapshot()
                changed = {name: sum((rows - after.get(name, Counter())).values())
                           for name, rows in before.items() if name != 'private.document_number_counters'
                           and rows - after.get(name, Counter())}
                current = h.counters()
                count = int(h.sql('select count(*)from private.offline_walk_in_subjects where service_id=' + literal(h.service) + ';'))
                h.proof['borrowed_full_contracts_unchanged'] = h.employment_hashes() == h.borrowed_hashes
                h.proof['preexisting_rows_unchanged'] = not changed
                h.proof['changed_preexisting_tables'] = changed
                h.proof['only_actual_invoice_counter_allocations'] = current['BKG'] == counters['BKG'] and current['INV'] - counters['INV'] == count
                h.proof['exactly_one_new_work_invoice'] = count == 1
                h.proof['auth_user_ids_and_count_unchanged'] = auth == h.auth_fingerprint()
                h.proof['no_pending_loyalty_jobs'] = h.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;') == '0'
        except Exception as exc:
            h.proof['preservation_check_error_type'] = type(exc).__name__
        h.proof['cleanup_complete'] = h.state['cleanup_complete']
        h.proof['all_passed'] = all(h.proof.get(k) is True for k in ['journey_completed', 'terminal_ui_ack_cleared_handoff_and_command_uuid', 'one_explicit_command_one_placement',
            'preexisting_rows_unchanged', 'only_actual_invoice_counter_allocations', 'exactly_one_new_work_invoice',
            'auth_user_ids_and_count_unchanged', 'no_pending_loyalty_jobs', 'cleanup_complete', 'borrowed_full_contracts_unchanged', 'journal_contract_full_hashes_verified', 'known_receipt_recovered_without_secret_reissue']) and not h.proof['blocked_requests'] and not h.proof['render_errors']
        if args.probe_only:
            h.proof['probe_only'] = True
            h.proof['zero_business_mutations'] = not h.ui_mutations and not h.service_created and not h.state.get('command_id')
            h.proof['all_passed'] = all(h.proof.get(k) is True for k in ['readonly_probe_passed','checkbox_unchecked_handoff_disabled','zero_business_mutations','preexisting_rows_unchanged','auth_user_ids_and_count_unchanged','borrowed_full_contracts_unchanged','cleanup_complete']) and not h.proof['blocked_requests'] and not h.proof['render_errors']
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(h.proof, ensure_ascii=False, indent=2) + '\n')
        args.proof.chmod(0o600)
        print(json.dumps({'all_passed': h.proof['all_passed'], 'failed_stage': h.proof.get('failed_stage'),
                          'error_type': h.proof.get('error_type'), 'proof': str(args.proof)}))
    if not h.proof['all_passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
