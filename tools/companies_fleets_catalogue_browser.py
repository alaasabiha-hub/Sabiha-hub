"""PLAN by default. Owner catalogue route/layout only, one locale per invocation.
No fixtures or mutations. Root already verified HTTP role denial separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

from owner_redemption_rules_browser import Harness
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('runtime', 'proof', 'screenshots', 'build-proof'):
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--language', choices=('ar', 'en'), required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({'plan_only': True, 'language': args.language, 'scope': 'owner CRM catalogue route, actual context/list, optional archived filter, responsive screenshots', 'business_mutations': False, 'permission_tests_repeated': False}))
        return
    h = Harness(args)
    repo = Path(__file__).resolve().parents[1]
    manifest = json.loads(args.build_proof.read_text())
    assert manifest['exit_code'] == 0 and manifest['source_unchanged']
    assert all(file in manifest['source_after'] for file in ('lib/main.dart', 'lib/companies_fleets_catalogue.dart'))
    for file, digest in manifest['source_after'].items():
        assert hashlib.sha256((repo / file).read_bytes()).hexdigest() == digest
    with urllib.request.urlopen(h.app + '/main.dart.js', timeout=30) as response:
        assert hashlib.sha256(response.read()).hexdigest() == manifest['main_dart_js_sha256']
    before, counters = Intake.snapshot(h), Intake.counters(h)
    def auth_hash():
        return h.sql("select md5(coalesce(string_agg(md5((to_jsonb(u)-'last_sign_in_at'-'updated_at')::text),','order by id),''))from auth.users u;")
    auth_before = auth_hash()
    proof = {'local_only': True, 'production_touched': False, 'language': args.language,
             'build_sha256': manifest['main_dart_js_sha256'], 'scope': 'owner catalogue readonly route and responsive layout',
             'business_mutations': False, 'permission_tests_repeated': False, 'screens': [],
             'rpc_metadata': [], 'blocked_requests': [], 'render_errors': [], 'all_passed': False}
    def save():
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
        args.proof.chmod(0o600)
    def guard(route, request):
        url = urllib.parse.urlsplit(request.url)
        name = url.path.rsplit('/', 1)[-1] if '/rest/v1/rpc/' in url.path else None
        # Serve the exact bundled Flutter engine locally; no CDN/network exception.
        if request.method in ('GET', 'HEAD') and url.scheme == 'https' and url.hostname == 'www.gstatic.com' and not url.query:
            match = re.fullmatch(r'/flutter-canvaskit/[0-9a-f]{40}/(chromium/)?(canvaskit\.(?:js|wasm))', url.path)
            if match:
                asset = repo / 'build/web/canvaskit' / ((match[1] or '') + match[2])
                route.fulfill(path=str(asset), content_type='application/wasm' if asset.suffix == '.wasm' else 'application/javascript', headers={'Access-Control-Allow-Origin': '*'})
                return
        if name == 'claim_customer_product_ad':
            route.fulfill(status=200, content_type='application/json', body='[]')
            return
        font = request.method in ('GET', 'HEAD') and url.scheme == 'https' and url.hostname == 'fonts.gstatic.com' and url.path.startswith('/s/') and url.path.endswith('.woff2') and not url.query
        allowed = url.scheme not in ('http', 'https') or (url.scheme == 'http' and url.netloc in {urllib.parse.urlsplit(h.app).netloc, urllib.parse.urlsplit(h.base).netloc}) or font
        if name and request.method == 'POST':
            body = json.loads(request.post_data or '{}')
            if name in ('get_public_home', 'get_public_promotions', 'default_branch_id', 'get_fleet_catalogue_context'):
                allowed = allowed and body in ({}, None)
            elif name == 'get_admin_console':
                allowed = allowed and isinstance(body, dict) and set(body) == {'p_from_local', 'p_to_local', 'p_branch', 'p_employee', 'p_service', 'p_method', 'p_search'} and body['p_employee'] is None and body['p_service'] is None and body['p_method'] is None and body['p_search'] == ''
            elif name == 'list_my_app_inbox':
                allowed = allowed and body == {'p_before_created_at': None, 'p_before_event': None, 'p_limit': 25}
            elif name == 'list_fleet_parties':
                allowed = allowed and isinstance(body, dict) and set(body) == {'p_search', 'p_include_archived', 'p_before_created_at', 'p_before_id', 'p_limit'} and body['p_search'] == '' and body['p_include_archived'] in (True, False) and body['p_before_created_at'] is None and body['p_before_id'] is None and body['p_limit'] == 25
            else:
                allowed = False
        elif name and request.method != 'OPTIONS':
            allowed = False
        elif request.method not in ('GET', 'HEAD', 'OPTIONS'):
            allowed = allowed and url.path in ('/auth/v1/token', '/auth/v1/logout')
            if url.path == '/auth/v1/token':
                body = json.loads(request.post_data or '{}')
                owner = h.accounts['users']['owner']
                allowed = allowed and body.get('email') == owner['email'] and body.get('password') == owner['password']
        if allowed:
            route.continue_()
        else:
            proof['blocked_requests'].append({'path': url.path, 'method': request.method})
            save()
            route.abort()
    def guard_socket(route):
        url, base = urllib.parse.urlsplit(route.url), urllib.parse.urlsplit(h.base)
        if url.scheme == 'ws' and url.hostname == '127.0.0.1' and url.netloc == base.netloc and url.path == '/realtime/v1/websocket':
            route.connect_to_server()
        else:
            proof['blocked_requests'].append({'kind': 'websocket', 'failure': 'unexpected_endpoint'})
            route.close(code=1008, reason='Local realtime endpoint only')
    def metadata(response):
        path = urllib.parse.urlsplit(response.url).path
        if '/rest/v1/rpc/' in path and response.request.method == 'POST':
            proof['rpc_metadata'].append({'name': path.rsplit('/', 1)[-1], 'status': response.status})
        # Never call response.json/body/wait from an event listener.
    from playwright.sync_api import sync_playwright, expect
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
            try:
                ar = args.language == 'ar'
                t = lambda a, e: a if ar else e
                page = browser.new_page(viewport={'width': 390 if ar else 1440, 'height': 1100})
                page.set_default_timeout(30000)
                page.route('**/*', guard)
                page.route_web_socket('**/*', guard_socket)
                page.on('response', metadata)
                page.on('pageerror', lambda _: proof['render_errors'].append('javascript_error'))
                page.on('console', lambda msg: proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                button = lambda text: page.get_by_role('button', name=text, exact=True)
                def click(locator, fixed=False):
                    if not fixed:
                        Acceptance.near(page, locator)
                    locator.wait_for(state='visible')
                    expect(locator).to_be_enabled()
                    locator.click()
                    page.wait_for_timeout(450)
                def wait_rpc(name):
                    return page.expect_response(lambda response: response.url.endswith('/rpc/' + name) and response.request.method == 'POST')
                masks = []
                def add_masks(data):
                    for row in data['items']:
                        masks.extend(str(row[key]) for key in ('legal_name', 'trading_name') if row.get(key))
                def screenshot(name):
                    page.wait_for_timeout(450)
                    args.screenshots.mkdir(parents=True, exist_ok=True)
                    path = args.screenshots / (args.language + '-catalogue-' + name + '.png')
                    page.screenshot(path=str(path), mask=[page.get_by_role('textbox'), *[page.get_by_label(re.compile(re.escape(value))).or_(page.get_by_text(value, exact=True)) for value in masks]])
                    path.chmod(0o600)
                    proof['screens'].append({'path': str(path), 'actual_browser': True, 'private_names_masked': True})
                    save()
                proof['stage'] = 'actual_owner_login'
                save()
                page.goto(h.app)
                page.wait_for_selector('flutter-view', timeout=60000)
                sem = page.locator('flt-semantics-placeholder')
                if sem.count():
                    sem.evaluate('(e)=>e.click()')
                button('احجز الآن').first.wait_for(state='visible')
                if not ar:
                    click(button('EN'))
                click(button(t('دخول الموظفين', 'Staff sign in')))
                owner = h.accounts['users']['owner']
                for field, key in ((t('البريد الإلكتروني', 'Email address'), 'email'), (t('كلمة المرور', 'Password'), 'password')):
                    Acceptance.type_into(page, field, owner[key])
                page.get_by_role('textbox', name=t('كلمة المرور', 'Password'), exact=True).press('Tab')
                with page.expect_response(lambda response: '/auth/v1/token' in response.url and response.request.method == 'POST') as signed:
                    click(button(t('تسجيل الدخول', 'Sign In')))
                assert signed.value.status == 200 and signed.value.json()['user']['id'] == owner['id']
                category = button(t('إدارة العملاء', 'CRM'))
                for _ in range(10):
                    box = category.bounding_box() if category.count() else None
                    if box and 1 <= box['x'] <= page.viewport_size['width'] - 40:
                        break
                    reports = button(t('التقارير', 'Reports')).bounding_box()
                    assert reports
                    page.mouse.move(page.viewport_size['width'] // 2, reports['y'] + reports['height'] // 2)
                    page.mouse.wheel(330 if ar else -330, 0)
                    page.wait_for_timeout(150)
                click(category, fixed=True)
                proof['stage'] = 'owner_catalogue_actual_context_and_list'
                save()
                with wait_rpc('get_fleet_catalogue_context') as context, wait_rpc('list_fleet_parties') as listed:
                    click(button(t('الشركات والأساطيل', 'Companies & fleets')))
                assert context.value.status == 200 and listed.value.status == 200
                caps, data = context.value.json(), listed.value.json()
                assert caps['owner_only'] and caps['view_allowed'] and caps['manage_allowed'] and caps['verification_state'] == 'unverified'
                assert all(caps[key] is False for key in ('company_auth_accounts', 'billing_enabled', 'contracts_enabled', 'pricing_enabled', 'bulk_work_enabled', 'receivables_enabled', 'eta_submission_enabled'))
                assert caps['tax_rate'] is None and caps['actual_profit'] is None
                assert len(data['items']) <= 25 and data['verification_state'] == 'unverified'
                add_masks(data)
                target = page.locator('[flt-semantics-identifier="fleet-add-party"]')
                expect(target).to_be_visible()
                archived = page.get_by_role('checkbox', name=t('إظهار المؤرشف أيضاً', 'Include archived records'), exact=True)
                expect(archived).not_to_be_checked()
                proof['actual_default_page_count'] = len(data['items'])
                proof['actual_owner_context_and_route'] = True
                screenshot('default-page')
                # Read-only filter exercises retained actual catalogue rows without
                # opening contact details or starting any create/edit command.
                click(archived)
                with wait_rpc('list_fleet_parties') as listed:
                    click(button(t('بحث وتحديث النتائج', 'Search and refresh results')))
                assert listed.value.status == 200
                data = listed.value.json()
                assert len(data['items']) <= 25
                add_masks(data)
                expect(archived).to_be_checked()
                proof['actual_archived_inclusive_page_count'] = len(data['items'])
                screenshot('include-archived-page')
                assert not proof['blocked_requests'] and not proof['render_errors']
                proof['all_passed'] = True
            except Exception as error:
                proof['failure_type'] = type(error).__name__
                try:
                    screenshot('failure-private')
                except Exception:
                    pass
                raise
            finally:
                browser.close()
    finally:
        proof['all_public_private_rows_unchanged'] = Intake.snapshot(h) == before
        proof['document_counters_unchanged'] = Intake.counters(h) == counters
        proof['auth_users_unchanged_except_signin_metadata'] = auth_hash() == auth_before
        save()
    assert proof['all_passed'] and proof['all_public_private_rows_unchanged'] and proof['document_counters_unchanged'] and proof['auth_users_unchanged_except_signin_metadata']


if __name__ == '__main__':
    main()
