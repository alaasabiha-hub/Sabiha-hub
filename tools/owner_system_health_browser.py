"""Source-only owner EN1440 health UI probe; PLAN unless --execute.
No fixtures, business mutations, scheduler actions or provider calls.
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
    for field in ('runtime', 'proof', 'screenshots', 'build-proof'):
        parser.add_argument('--' + field, type=Path, required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({'plan_only': True, 'scope': 'owner_en1440_read_only', 'journey': ['actual_owner_login', 'Settings', 'System health', 'compare_actual_response_and_provenance', 'independent_checks_not_checked'], 'business_mutations': False}))
        return
    h = Harness(args)
    repo = Path(__file__).resolve().parents[1]
    manifest = json.loads(args.build_proof.read_text())
    assert manifest['exit_code'] == 0 and manifest['source_unchanged']
    assert all(path in manifest['source_after'] for path in ('lib/main.dart', 'lib/owner_system_health.dart'))
    for path, digest in manifest['source_after'].items():
        assert hashlib.sha256((repo / path).read_bytes()).hexdigest() == digest
    with urllib.request.urlopen(h.app + '/main.dart.js', timeout=30) as response:
        assert hashlib.sha256(response.read()).hexdigest() == manifest['main_dart_js_sha256']
    before, counters = Intake.snapshot(h), Intake.counters(h)
    def auth_hash():
        return h.sql("select md5(coalesce(string_agg(md5((to_jsonb(u)-'last_sign_in_at'-'updated_at')::text),','order by id),''))from auth.users u;")
    auth = auth_hash()
    proof = {'local_only': True, 'production_touched': False, 'scope': 'owner_en1440_read_only',
             'build_sha256': manifest['main_dart_js_sha256'], 'business_mutations': False,
             'rpc_metadata': [], 'blocked_requests': [], 'render_errors': [], 'screens': [], 'all_passed': False}
    def save():
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
        args.proof.chmod(0o600)
    def stage(value):
        proof['stage'] = value
        save()
    allowed_origins = {urllib.parse.urlsplit(h.app).netloc, urllib.parse.urlsplit(h.base).netloc}
    def guard(route, request):
        url = urllib.parse.urlsplit(request.url)
        name = url.path.rsplit('/', 1)[-1] if '/rest/v1/rpc/' in url.path else None
        if name == 'claim_customer_product_ad':
            route.fulfill(status=200, content_type='application/json', body='[]')
            return
        font = request.method in ('GET', 'HEAD') and url.scheme == 'https' and url.hostname == 'fonts.gstatic.com' and url.path.startswith('/s/') and url.path.endswith('.woff2') and not url.query
        allowed = url.scheme not in ('http', 'https') or (url.scheme == 'http' and url.netloc in allowed_origins) or font
        if name and request.method == 'POST':
            body = json.loads(request.post_data or '{}')
            if body is None and name in ('get_public_home', 'get_public_promotions', 'default_branch_id'):
                body = {}
            if name in ('get_public_home', 'get_public_promotions', 'default_branch_id'):
                allowed = allowed and body == {}
            elif name == 'get_owner_system_health':
                allowed = allowed and body == {'p_branch': None}
            elif name == 'get_admin_console':
                allowed = allowed and isinstance(body, dict) and set(body) == {'p_from_local', 'p_to_local', 'p_branch', 'p_employee', 'p_service', 'p_method', 'p_search'} and body['p_employee'] is None and body['p_service'] is None and body['p_method'] is None and body['p_search'] == ''
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
    def metadata(response):
        path = urllib.parse.urlsplit(response.url).path
        if '/rest/v1/rpc/' in path and response.request.method == 'POST':
            proof['rpc_metadata'].append({'name': path.rsplit('/', 1)[-1], 'status': response.status})
            # No response body, wait or nested browser call in event callbacks.
    from playwright.sync_api import sync_playwright, expect
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
            try:
                page = browser.new_page(viewport={'width': 1440, 'height': 1100})
                page.set_default_timeout(30000)
                page.route('**/*', guard)
                page.on('response', metadata)
                page.on('pageerror', lambda _: proof['render_errors'].append('javascript_error'))
                page.on('console', lambda msg: proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                button = lambda text: page.get_by_role('button', name=text, exact=True)
                def click(locator):
                    Acceptance.near(page, locator)
                    expect(locator).to_be_enabled()
                    locator.click()
                    page.wait_for_timeout(450)
                stage('owner_login')
                page.goto(h.app)
                page.wait_for_selector('flutter-view', timeout=60000)
                sem = page.locator('flt-semantics-placeholder')
                if sem.count():
                    sem.evaluate('(e)=>e.click()')
                button('احجز الآن').first.wait_for(state='visible')
                click(button('EN'))
                click(button('Staff sign in'))
                owner = h.accounts['users']['owner']
                Acceptance.type_into(page, 'Email address', owner['email'])
                Acceptance.type_into(page, 'Password', owner['password'])
                page.get_by_role('textbox', name='Password', exact=True).press('Tab')
                with page.expect_response(lambda r: '/auth/v1/token' in r.url and r.request.method == 'POST') as signed:
                    click(button('Sign In'))
                assert signed.value.status == 200
                actual_id = signed.value.json()['user']['id']
                expected_id = owner.get('id', owner.get('user_id'))
                assert actual_id == expected_id
                proof['actual_owner_login'] = True
                stage('settings_health')
                click(button('Settings'))
                with page.expect_response(lambda r: r.url.endswith('/rpc/get_owner_system_health') and r.request.method == 'POST') as response:
                    click(button('System health'))
                # Explicit context ended: body reading is safe outside event callback.
                assert response.value.status == 200
                actual = response.value.json()
                worker = actual['background_worker']
                assert worker['source'] == 'canonical_loyalty_cron_and_outbox' and worker['scope'] == 'execution_observation_only'
                assert actual['database_probe']['source'] == 'authenticated_database_round_trip' and actual['database_probe']['state'] == 'working'
                assert worker['checked_at'] == actual['checked_at']
                assert worker['state'] in ('working', 'failed', 'not_checked')
                assert actual['other_checks'] and all(value['state'] == 'not_checked' for value in actual['other_checks'].values())
                # Persist real server metadata before any display assertion.
                proof['actual_observed_worker_state'] = worker['state']
                proof['actual_worker_reason'] = worker['reason']
                proof['checked_at'] = actual['checked_at']
                proof['provenance_scope'] = worker['scope']
                proof['independent_checks_all_not_checked'] = True
                args.screenshots.mkdir(parents=True, exist_ok=True)
                page.wait_for_timeout(650)
                before_display = args.screenshots / 'en1440-health-before-display-assert.png'
                page.screenshot(path=str(before_display), mask=[page.get_by_role('textbox')])
                before_display.chmod(0o600)
                proof['screens'].append({'path': str(before_display), 'actual_browser': True})
                # Only health-route aria labels; no DOM/body dumps, inputs, auth data
                # or underlying owner dashboard. Bound to explicitly known health
                # strings, actual server timestamp, and numeric observation fields.
                allowed_labels = ('System health', 'Only actual observations',
                    'Server checked at', 'Database connection', 'This authorized response',
                    'Source:', 'Background visit worker', 'Execution observed',
                    'Observed failure needs review', 'Not checked', 'Evidence scope:',
                    'Last successful run', 'Observed success age', 'Last failed run',
                    'Pending events', 'Due events', 'Retried events', 'Pending failed attempts',
                    'Unresolved events', 'This does not prove', 'Independent checks',
                    'Booking success', 'Invoice success', 'Payments and integrations',
                    'Device sync', 'In-app notifications', 'PDF generation',
                    'Backup and restore', 'Global security', 'Financial correctness')
                labels = page.locator('[aria-label]').evaluate_all(
                    '(nodes)=>nodes.map(n=>({label:n.getAttribute("aria-label"),role:n.getAttribute("role"),visible:!!(n.getClientRects().length)}))')
                diagnostic = [{'label': row['label'], 'role': row['role'], 'visible': row['visible']}
                    for row in labels if isinstance(row.get('label'), str)
                    and row['label'].startswith(allowed_labels) and len(row['label']) <= 1200]
                diag_path = args.proof.with_name(args.proof.stem + '-health-labels.private.json')
                diag_path.write_text(json.dumps({'health_route_only': True, 'worker_state': worker['state'],
                    'labels': diagnostic}, indent=2) + '\n')
                diag_path.chmod(0o600)
                proof['health_label_diagnostic'] = str(diag_path)
                save()
                display = {'working': 'Execution observed', 'failed': 'Observed failure needs review', 'not_checked': 'Not checked'}[worker['state']]
                # Actual Flutter paragraph semantics are labels, not DOM text nodes.
                for text in (display, 'Source: Actual visit scheduler and queue', 'Evidence scope: Observed execution only', 'This does not prove financial correctness or all system tasks.'):
                    locator = page.get_by_label(text, exact=True).first
                    Acceptance.near(page, locator)
                    expect(locator).to_be_visible()
                args.screenshots.mkdir(parents=True, exist_ok=True)
                for name, anchor in (('observed-worker', 'Evidence scope: Observed execution only'), ('independent-not-checked', 'Financial correctness: Not checked')):
                    locator = page.get_by_label(anchor, exact=True).first
                    Acceptance.near(page, locator)
                    expect(locator).to_be_visible()
                    page.wait_for_timeout(450)
                    path = args.screenshots / ('en1440-health-' + name + '.png')
                    page.screenshot(path=str(path), mask=[page.get_by_role('textbox')])
                    path.chmod(0o600)
                    proof['screens'].append({'path': str(path), 'actual_browser': True})
                proof['actual_observed_worker_state'] = worker['state']
                proof['actual_worker_reason'] = worker['reason']
                proof['checked_at'] = actual['checked_at']
                proof['provenance_scope'] = worker['scope']
                proof['independent_checks_all_not_checked'] = True
                assert not proof['blocked_requests'] and not proof['render_errors']
                proof['all_passed'] = True
            except Exception as error:
                proof['failure_type'] = type(error).__name__
                raise
            finally:
                browser.close()
    finally:
        proof['all_public_private_rows_unchanged'] = Intake.snapshot(h) == before
        proof['document_counters_unchanged'] = Intake.counters(h) == counters
        proof['auth_users_unchanged_except_signin_metadata'] = auth_hash() == auth
        save()
    assert proof['all_passed'] and proof['all_public_private_rows_unchanged'] and proof['document_counters_unchanged'] and proof['auth_users_unchanged_except_signin_metadata']


if __name__ == '__main__':
    main()
