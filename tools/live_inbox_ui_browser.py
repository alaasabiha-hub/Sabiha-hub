"""PLAN by default: one AR390 live inbox UI journey, no receipt-proof/finance writes.
Root executes only after backend WS acceptance and the pinned combined build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.parse

from visit_recovery_requests_browser import RequestJourney, nonce
from service_booking_acceptance import Acceptance


def decode_inbox_frame(raw):
    """Pinned realtime_client2.13.2 Serializer._decodeUserBroadcast, lines143-195.

    Receive kind4: kind,topicSize,eventSize,metadataSize,encoding; offset5;
    UTF8 topic/event/optional JSONmeta, then encoding1 JSON payload. No binary
    send support: kind3 client publishes must never be accepted by this probe.
    """
    assert isinstance(raw, (str, bytes)) and len(raw) <= 65536
    diagnostic = {'binary': isinstance(raw, bytes), 'length': len(raw)}
    if isinstance(raw, bytes):
        assert len(raw) >= 5 and raw[0] == 4 and raw[4] == 1
        topic_size, event_size, meta_size = raw[1:4]
        offset = 5
        assert offset + topic_size + event_size + meta_size <= len(raw)
        topic = raw[offset:offset + topic_size].decode('utf-8')
        offset += topic_size
        event = raw[offset:offset + event_size].decode('utf-8')
        offset += event_size
        meta = json.loads(raw[offset:offset + meta_size].decode('utf-8')) if meta_size else None
        offset += meta_size
        envelope = {'type': 'broadcast', 'event': event,
                    'payload': json.loads(raw[offset:].decode('utf-8'))}
        if meta_size:
            envelope['meta'] = meta
        frame = {'join_ref': None, 'ref': None, 'topic': topic,
                 'event': 'broadcast', 'payload': envelope}
        diagnostic.update({'frame_kind': 4, 'encoding': 1})
    else:
        frame = json.loads(raw)
        if isinstance(frame, list):
            assert len(frame) == 5
            frame = dict(zip(('join_ref', 'ref', 'topic', 'event', 'payload'), frame))
        assert isinstance(frame, dict)
    return frame, diagnostic


def validate_inbox_hint(frame, forbidden):
    envelope = frame.get('payload')
    assert isinstance(envelope, dict) and set(envelope) <= {'type', 'event', 'payload', 'meta'}
    assert envelope.get('type') == 'broadcast' and envelope.get('event') == 'inbox_changed'
    body, meta = envelope.get('payload'), envelope.get('meta', {})
    assert isinstance(body, dict) and set(body) in ({'kind'}, {'kind', 'id'}) and body['kind'] == 'inbox_changed'
    assert isinstance(meta, dict) and set(meta) <= {'id'}
    transport_id = body.get('id', meta.get('id'))
    assert nonce(transport_id) and transport_id not in forbidden
    if 'id' in meta:
        assert nonce(meta['id']) and meta['id'] == transport_id


def hint_shape(frame, diagnostic, expected_topic):
    """Only fixed whitelisted metadata; never raw values, identifiers or frames."""
    envelope = frame.get('payload')
    body = envelope.get('payload') if isinstance(envelope, dict) else None
    meta = envelope.get('meta') if isinstance(envelope, dict) else None
    def keys(value, allowed):
        return sorted(set(value) & allowed) if isinstance(value, dict) else []
    diagnostic.update({
        'event': frame.get('event') if frame.get('event') in ('broadcast', 'phx_join', 'phx_reply', 'phx_leave', 'heartbeat', 'access_token', 'system', 'phx_error', 'phx_close') else 'unexpected',
        'topic_matches_actor': frame.get('topic') == expected_topic,
        'envelope_keys': keys(envelope, {'type', 'event', 'payload', 'meta'}),
        'envelope_extra_keys': isinstance(envelope, dict) and bool(set(envelope) - {'type', 'event', 'payload', 'meta'}),
        'body_keys': keys(body, {'kind', 'id'}),
        'body_extra_keys': isinstance(body, dict) and bool(set(body) - {'kind', 'id'}),
        'meta_keys': keys(meta, {'id'}),
        'meta_extra_keys': isinstance(meta, dict) and bool(set(meta) - {'id'}),
        'type': 'broadcast' if isinstance(envelope, dict) and envelope.get('type') == 'broadcast' else 'other',
        'kind_is_fixed_hint': isinstance(body, dict) and body.get('kind') == 'inbox_changed',
        'body_id_is_uuid': isinstance(body, dict) and safe_uuid(body.get('id')),
        'meta_id_is_uuid': isinstance(meta, dict) and safe_uuid(meta.get('id')),
    })
    return diagnostic


def safe_uuid(value):
    try:
        return nonce(value)
    except (ValueError, TypeError, AttributeError):
        return False


class LiveJourney(RequestJourney):
    def __init__(self, args):
        super().__init__(args)
        self.started = time.monotonic()
        self.ws_rows = []
        self.ws_errors = []
        self.joined = {'owner': 0, 'customer': 0}
        self.join_refs = {}
        self.hints = {'owner': [], 'customer': []}
        self.rpc_times = {}
        self.submit_sent_at = self.apply_sent_at = None
        self.proof['proof_scope'] = 'one_ar390_live_badge_and_open_inbox_plus_receipt_context_sync'
        self.proof['websocket_callbacks_metadata_only'] = True
        self.proof['websocket_client_publish_intercepted'] = False
        self.proof['websocket_monitoring'] = 'Endpoint guarded; frames observed without alteration. Unexpected private topics/client publishes fail acceptance.'
        self.proof['checks'] = {}

    def observe(self, response, role):
        if '/rest/v1/rpc/' in urllib.parse.urlsplit(response.url).path and response.request.method == 'POST':
            self.rpc_times.setdefault((role, urllib.parse.urlsplit(response.url).path.rsplit('/', 1)[-1]), []).append(time.monotonic())
        super().observe(response, role)

    def owner_id(self):
        return self.owner.get('id', self.owner.get('user_id'))

    def parse_frame(self, raw, role, direction):
        # Event callbacks parse only in-memory metadata: no body/RPC/browser calls,
        # filesystem writes, raw frames/JWTs/query strings or transport IDs persisted.
        shape = {'binary': isinstance(raw, bytes),
                 'length': len(raw) if isinstance(raw, (str, bytes)) else None}
        if isinstance(raw, bytes):
            shape.update({'frame_kind': raw[0] if raw else None,
                          'encoding': raw[4] if len(raw) >= 5 else None})
        self.proof.setdefault('websocket_shapes', []).append(shape)
        try:
            frame, decoded_shape = decode_inbox_frame(raw)
            shape.update(decoded_shape)
            event, topic, payload = frame.get('event'), frame.get('topic'), frame.get('payload')
            expected = 'realtime:app-inbox:' + (self.actor if role == 'customer' else self.owner_id())
            safe_shape = hint_shape(frame, shape, expected)
            safe_shape.update({'role': role, 'direction': direction})
            # Append safe shape BEFORE assertions, including an unexpected envelope.
            shape.update(safe_shape)
            assert topic in ('phoenix', expected)
            now = time.monotonic()
            if direction == 'sent':
                assert event in ('phx_join', 'phx_leave', 'heartbeat', 'access_token')
                if event == 'phx_join':
                    assert topic == expected and isinstance(payload, dict) and payload.get('config', {}).get('private') is True
                    self.join_refs[(role, str(frame.get('ref')))] = True
            elif event == 'phx_reply' and (role, str(frame.get('ref'))) in self.join_refs:
                assert isinstance(payload, dict) and payload.get('status') == 'ok'
                self.joined[role] += 1
                self.join_refs.pop((role, str(frame.get('ref'))), None)
            elif event == 'broadcast':
                assert topic == expected
                forbidden = {self.actor, self.owner_id(), self.state.get('case_id'), self.state.get('submission'), *self.state.get('old_case_ids', []), *self.state.get('reviews', {})}
                forbidden.update(value for key in ('claim_id', 'case_nonce', 'registration')
                                 if isinstance((value := self.customer.get(key)), str))
                validate_inbox_hint(frame, forbidden)
                self.hints[role].append(now)
            elif event in ('phx_error', 'phx_close'):
                # Normal leave/dispose may close a channel. Only successful joins
                # and fixed hints count as evidence; no error is promoted to health.
                pass
            self.ws_rows.append({'role': role, 'direction': direction, 'event': str(event),
                                 'topic_matches_actor': topic == expected,
                                 'elapsed_ms': round((now - self.started) * 1000)})
        except (AssertionError, ValueError, TypeError, UnicodeError, AttributeError):
            self.ws_errors.append({'role': role, 'direction': direction, 'failure': 'unexpected_frame_metadata'})

    def socket_created(self, socket, role):
        url = urllib.parse.urlsplit(socket.url)
        target = urllib.parse.urlsplit(self.h.base)
        if not (url.scheme == 'ws' and url.netloc == target.netloc and url.path == '/realtime/v1/websocket'):
            self.ws_errors.append({'role': role, 'failure': 'unexpected_websocket_endpoint'})
        socket.on('framesent', lambda data: self.parse_frame(data, role, 'sent'))
        socket.on('framereceived', lambda data: self.parse_frame(data, role, 'received'))

    def guard_socket(self, route):
        # Installed Playwright WebSocketRoute.connect_to_server forwards normally
        # without on_message interception. Do not nest send/body/wait inside frames.
        url = urllib.parse.urlsplit(route.url)
        base = urllib.parse.urlsplit(self.h.base)
        if url.scheme == 'ws' and url.netloc == base.netloc and url.path == '/realtime/v1/websocket':
            route.connect_to_server()
        else:
            self.ws_errors.append({'failure': 'blocked_websocket_endpoint'})
            route.close(code=1008, reason='Local realtime endpoint only')

    def wait_condition(self, page, predicate, seconds=5):
        until = time.monotonic() + seconds
        while not predicate() and time.monotonic() < until:
            page.wait_for_timeout(50)
        assert predicate(), 'Expected bounded live observation missing'
        assert not self.ws_errors

    def allow_rpc(self, name, body, role):
        if name == 'prepare_visit_recovery_review':
            assert role == 'owner' and set(body) == {'p_request', 'p_case', 'p_expected_status', 'p_action', 'p_reason'}
            assert self.state['case_id'] and body['p_case'] == self.state['case_id'] and nonce(body['p_request'])
            assert body['p_expected_status'] == 'awaiting_matching' and body['p_action'] == 'reject' and body['p_reason'] == self.tag + ' reject'
            self.state['reviews'][body['p_request']] = body.copy()
            self.save()
            return True
        allowed = super().allow_rpc(name, body, role)
        if allowed and name == 'submit_visit_recovery_request':
            self.submit_sent_at = time.monotonic()
        if allowed and name == 'apply_visit_recovery_review':
            self.apply_sent_at = time.monotonic()
        return allowed

    def live_button(self, page, count=None):
        name = re.compile(r'^التنبيهات · \d+ غير مقروءة$') if count is None else 'التنبيهات · ' + str(count) + ' غير مقروءة'
        return page.get_by_role('button', name=name, exact=count is not None).first

    def paragraph(self, page, text):
        # Match actual paragraph semantics with renderer whitespace/merged nodes.
        # This is the proven earlier request/inbox harness pattern, not a product
        # text change or an injected substitute value.
        pattern = re.compile(r'\s+'.join(re.escape(word) for word in text.split()))
        return page.get_by_label(pattern).or_(page.get_by_text(pattern)).first

    def accepted_scopes(self):
        path = self.args.accepted_scope_proof.resolve()
        path.relative_to(self.args.runtime.resolve())
        accepted = json.loads(path.read_text())
        manifest = json.loads(self.args.build_proof.read_text())
        assert accepted['local_only'] and accepted['production_touched'] is False
        assert accepted['build_sha256'] == manifest['main_dart_js_sha256']
        assert accepted['owner_live_badge_accepted'] is True
        assert accepted['receipt_context_visual_accepted'] is True
        source_path = Path(accepted['source_attempt_proof']).resolve()
        source_path.relative_to(self.args.runtime.resolve())
        assert hashlib.sha256(source_path.read_bytes()).hexdigest() == accepted['source_attempt_sha256']
        screenshot = Path(accepted['receipt_screenshot']).resolve()
        assert hashlib.sha256(screenshot.read_bytes()).hexdigest() == accepted['receipt_screenshot_sha256']
        assert accepted['actual_generic_hint_and_private_join_verified'] is True
        assert accepted['old_rows_counters_auth_preserved'] is True
        assert accepted['customer_open_inbox_live_scope_accepted'] is False
        source = json.loads(source_path.read_text())
        assert source['local_only'] and source['production_touched'] is False
        assert source['build_sha256'] == accepted['build_sha256']
        assert source['cleanup_complete'] and source['preexisting_public_private_rows_unchanged']
        assert source['document_counters_unchanged'] and source['auth_users_unchanged_except_signin_metadata']
        assert source['owner_live_unread_plus_one'] is True
        assert source['owner_live_rpc_ms'] < 5000 and source['owner_actual_badge_visible_ms'] < 5000
        assert not source['websocket_metadata_errors'] and not source['blocked_requests']
        self.proof['previous_accepted_scope_proof'] = str(path)
        self.proof['previous_accepted_scope_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.proof['previous_accepted_attempt_proof'] = str(source_path)
        self.proof['previous_accepted_scopes_not_repeated'] = ['owner_live_badge', 'new_receipt_current_context_visual']

    def run_live(self):
        assert self.args.remaining_customer_only and self.args.accepted_scope_proof
        self.accepted_scopes()
        self.preflight()
        self.proof['proof_scope'] = 'remaining_customer_open_inbox_private_resubscription_and_live_reject_content_only'
        manifest = json.loads(self.args.build_proof.read_text())
        assert 'lib/app_inbox_live.dart' in manifest['source_after']
        from playwright.sync_api import sync_playwright, expect
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
                pages = {}
                try:
                    for role in ('owner', 'customer'):
                        page = browser.new_page(viewport={'width': 390, 'height': 1100})
                        page.set_default_timeout(30000)
                        self.page_roles[page] = role
                        page.route('**/*', lambda route, request, role=role: self.guard(route, role))
                        page.route_web_socket('**/*', self.guard_socket)
                        page.on('websocket', lambda socket, role=role: self.socket_created(socket, role))
                        page.on('response', lambda response, role=role: self.observe(response, role))
                        page.on('pageerror', lambda _: self.proof['render_errors'].append('javascript_error'))
                        page.on('console', lambda msg: self.proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                        pages[role] = page
                    owner, customer = pages['owner'], pages['customer']
                    # Owner session is cleanup-ready before the one necessary new
                    # case. Its already accepted latency/badge scope is not rerun.
                    self.login(owner, 'owner')
                    self.login(customer, 'customer')
                    context = self.customer_panel(customer)
                    assert context['new_request_allowed'] is True and self.case_from(context)['status'] in ('rejected', 'revoked')
                    consent = customer.get_by_role('checkbox', name='أوافق على طلب المراجعة بهذا النطاق', exact=True)
                    Acceptance.near(customer, consent)
                    expect(consent).not_to_be_checked()
                    consent.click()
                    self.stage('necessary_new_request_setup_only')
                    with self.wait_rpc(customer, 'submit_visit_recovery_request') as submitted:
                        self.click(customer, self.button(customer, 'إرسال طلب جديد للمراجعة'))
                    assert submitted.value.status == 200
                    assert self.case_from(submitted.value.json())['status'] == 'awaiting_matching'
                    self.click(customer, self.button(customer, 'راجعت النتيجة'))
                    self.proof['necessary_fresh_case_setup_only'] = True
                    # No owner badge timing, receipt-context assertions or more-info
                    # chain: those accepted scopes are explicitly referenced above.
                    self.customer_home(customer)
                    before_child = self.joined['customer']
                    with self.wait_rpc(customer, 'list_my_app_inbox') as customer_inbox:
                        self.click(customer, self.live_button(customer), fixed=True)
                    assert customer_inbox.value.status == 200
                    self.wait_condition(customer, lambda: self.joined['customer'] > before_child)
                    self.proof['checks']['customer_open_inbox_private_resubscription'] = True
                    self.shot(customer, 'remaining-open-inbox-private-resubscribed')
                    self.owner_list(owner)
                    self.stage('exact_case_reject_customer_live_content')
                    with self.wait_rpc(customer, 'list_my_app_inbox') as updated:
                        self.review(owner, 'reject', 'awaiting_matching')
                    rejected_at = self.apply_sent_at
                    assert rejected_at is not None
                    elapsed = min(value for value in self.rpc_times[('customer', 'list_my_app_inbox')] if value >= rejected_at) - rejected_at
                    assert updated.value.status == 200
                    matches = [row for row in updated.value.json()['items'] if row['case_reference'] == self.state['case_id'] and row['template_code'] == 'recovery_rejected']
                    self.proof['customer_live_rpc_ms'] = round(elapsed * 1000)
                    self.proof['customer_live_new_case_rejected_template_found'] = len(matches) == 1
                    self.proof['customer_live_fixed_hint_after_apply'] = any(value >= rejected_at for value in self.hints['customer'])
                    self.save()
                    assert len(matches) == 1 and elapsed < 5 and self.proof['customer_live_fixed_hint_after_apply']
                    remaining_ms = int((5 - (time.monotonic() - rejected_at)) * 1000)
                    assert remaining_ms > 0
                    expect(self.paragraph(customer, matches[0]['title_ar'])).to_be_visible(timeout=remaining_ms)
                    self.proof['customer_actual_notice_visible_ms'] = round((time.monotonic() - rejected_at) * 1000)
                    self.shot(customer, 'live-customer-rejected-notice-without-refresh')
                    self.proof['checks']['customer_hint_fresh_content_before_poll_no_manual_refresh'] = True
                    self.proof['customer_live_update_ms'] = round(elapsed * 1000)
                    assert not self.ws_errors and not self.proof['blocked_requests'] and not self.proof['render_errors']
                    self.proof['all_passed'] = True
                except Exception as error:
                    self.proof['failure_type'] = type(error).__name__
                    for role, page in pages.items():
                        try:
                            self.shot(page, role + '-live-failure-private')
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
            from offline_customer_registration_browser import Harness as Intake
            from collections import Counter
            after = Intake.snapshot(self.h)
            self.proof['preexisting_public_private_rows_unchanged'] = all(not (rows - after.get(table, Counter())) for table, rows in self.before.items())
            self.proof['document_counters_unchanged'] = Intake.counters(self.h) == self.counters
            self.proof['auth_users_unchanged_except_signin_metadata'] = self.auth_hash() == self.auth_before
            self.proof['websocket_metadata'] = self.ws_rows
            self.proof['websocket_metadata_errors'] = self.ws_errors
            self.save()
        assert self.proof['all_passed'] and self.state['cleanup_complete'] and self.proof['preexisting_public_private_rows_unchanged'] and self.proof['document_counters_unchanged'] and self.proof['auth_users_unchanged_except_signin_metadata']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'proof', 'screenshots', 'build-proof'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--remaining-customer-only', action='store_true')
    parser.add_argument('--accepted-scope-proof', type=Path)
    args = parser.parse_args()
    args.language = 'ar'
    if not args.execute:
        print(json.dumps({'plan_only': True, 'scope': 'one_ar390', 'new_cases': 1, 'mode': 'remaining_customer_only', 'accepted_scopes_referenced_not_repeated': ['owner_live_badge', 'receipt_context_visual'], 'ui_actions': ['necessary_new_request_setup', 'customer_open_inbox_private_resubscribe', 'owner_reject_exact_case', 'automatic_customer_inbox_notice'], 'no_more_info_or_proof_or_finance': True}))
        return
    assert args.remaining_customer_only and args.accepted_scope_proof, 'Only remaining-customer mode with accepted same-build scope proof may execute'
    LiveJourney(args).run_live()


if __name__ == '__main__':
    main()
