"""PLAN unless --execute: one locale's controlled proposal/consent/canonical review.
No new Auth/profile/phone/quota/finance/loyalty fixtures. Root reviews and executes.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import uuid

from owner_recovery_investigation_browser import InvestigationJourney
from visit_recovery_requests_browser import RequestJourney, nonce, write_private
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance

EVIDENCE = 'in_person_independent_continuity_witness'


class ProposalJourney(InvestigationJourney):
    def __init__(self, args):
        self.owner_payloads = {}
        self.proposal_payloads = {}
        self.proposal_terms = None
        super().__init__(args)
        self.proof['proof_scope'] = 'new_proposal_two_customer_consents_canonical_owner_exception_then_revoke'
        self.proof['no_new_auth_or_profiles_or_phone_edits'] = True
        self.proof['independent_evidence_is_isolated_QA_simulation'] = True
        self.state.update({'owner_proposals': {}, 'canonical_commands': {}, 'acceptance': None, 'claim_id': None, 'link_id': None})
        self.save()

    def save(self):
        # UUID command journal only; never persist plate, evidence text, reasons,
        # notices, consent payloads, contacts, raw RPC bodies or bearer tokens.
        safe = {k: v for k, v in self.state.items() if k not in ('qa_candidate', 'queries', 'detail_reads')}
        safe['queries'] = {q: {k: v for k, v in body.items() if k in ('p_query', 'p_case')} for q, body in self.state.get('queries', {}).items()}
        safe['detail_reads'] = {q: {k: v for k, v in body.items() if k in ('p_request', 'p_query', 'p_profile')} for q, body in self.state.get('detail_reads', {}).items()}
        write_private(self.state_file, safe)
        write_private(self.args.proof, self.proof)

    def preflight(self):
        RequestJourney.preflight(self)
        manifest = json.loads(self.args.build_proof.read_text())
        assert all(file in manifest['source_after'] for file in ('lib/owner_recovery_proposal.dart', 'lib/visit_recovery_proposal.dart', 'lib/offline_customer_claim.dart'))
        source = self.args.runtime / 'recovery-proposal-concurrency-state.json'
        fixture = json.loads(source.read_text())
        assert fixture['local_only'] and fixture['all_passed'] and fixture['cleanup_complete']
        choices = [row for row in fixture['profiles'] if row['customer_id'] == self.actor]
        assert len(choices) == 1
        row = dict(choices[0])
        # The registration journal retains the original mixed-case input. Read
        # the exact canonical plate through its recorded car FK; never assume a
        # journal input is the normalized stored value or choose another car.
        assert nonce(row['registration']) and nonce(row['profile_id'])
        plate = self.h.sql("select c.plate_key from private.offline_customer_registration_requests r join private.offline_customer_car_refs c on c.car_ref_id=(r.result->>'car_ref_id')::uuid and c.profile_id=(r.result->>'offline_profile_id')::uuid where r.request_id='" + row['registration'] + "' and c.profile_id='" + row['profile_id'] + "';")
        assert plate and '\n' not in plate
        row['plate'] = plate
        assert all(nonce(row[key]) for key in ('profile_id', 'registration', 'customer_id'))
        assert nonce(fixture['branch']) and fixture['owner_id'] == self.owner['id']
        self.candidate = {'profile_id': row['profile_id'], 'plate': row['plate']}
        facts = json.loads(self.h.sql("select json_build_object('controlled',exists(select 1 from private.offline_customer_registration_requests r join private.offline_customer_profiles p on p.profile_id=(r.result->>'offline_profile_id')::uuid join private.offline_customer_car_refs c on c.profile_id=p.profile_id where r.request_id='" + row['registration'] + "' and r.actor_id='" + self.owner['id'] + "' and r.branch_id='" + fixture['branch'] + "' and p.created_branch_id=r.branch_id and p.profile_id='" + row['profile_id'] + "' and c.plate_key='" + row['plate'].replace("'", "''") + "'), 'never_linked',not exists(select 1 from private.offline_customer_trusted_links where profile_id='" + row['profile_id'] + "'),'history_disabled',not exists(select 1 from private.offline_history_runtime where enabled),'unique_plate',(select count(distinct profile_id)=1 from private.offline_customer_car_refs where plate_key='" + row['plate'].replace("'", "''") + "'))"))
        assert all(facts.values())
        # Respect the existing canonical producer's unchanged5/hour,20/day
        # actor+receipt budgets BEFORE any new request/proposal setup.
        budget = self.h.sql("select (select count(*)filter(where created_at>clock_timestamp()-interval'1 hour')<5 and count(*)<20 from private.offline_claim_requests where actor_id='" + self.actor + "' and created_at>clock_timestamp()-interval'1 day') and (select count(*)filter(where c.created_at>clock_timestamp()-interval'1 hour')<5 and count(*)<20 from private.offline_claim_requests c join private.offline_customer_enrollment_receipts e on e.receipt_id=c.receipt_key where e.profile_id='" + row['profile_id'] + "' and c.created_at>clock_timestamp()-interval'1 day')")
        assert budget == 't', 'Existing canonical claim budget unavailable; no setup writes permitted'
        self.state['before_fact_counts'] = self.fact_counts()
        self.state['old_claim_ids'] = json.loads(self.h.sql("select coalesce(json_agg(request_id),'[]')from private.offline_claim_requests where actor_id='" + self.actor + "' or profile_id='" + row['profile_id'] + "'"))
        self.state['controlled_profile'] = row['profile_id']
        self.state['controlled_registration'] = row['registration']
        self.state['controlled_branch'] = fixture['branch']
        self.proof['controlled_fixture_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        self.save()

    def fact_counts(self):
        return json.loads(self.h.sql("select jsonb_build_object('orders',(select count(*)from public.business_orders),'invoices',(select count(*)from public.business_invoices),'payments',(select count(*)from public.business_payment_events),'bookings',(select count(*)from public.bookings),'credits',(select count(*)from private.canonical_loyalty_visits),'auth_users',(select count(*)from auth.users),'profiles',(select count(*)from private.offline_customer_profiles),'contacts',(select count(*)from private.offline_customer_contacts),'cars',(select count(*)from private.offline_customer_car_refs),'receipts',(select count(*)from private.offline_customer_enrollment_receipts))"))

    def guard_socket(self, route):
        url, base = urllib.parse.urlsplit(route.url), urllib.parse.urlsplit(self.h.base)
        if url.scheme == 'ws' and url.hostname == '127.0.0.1' and url.netloc == base.netloc and url.path == '/realtime/v1/websocket':
            route.connect_to_server()
        else:
            # Never log URL/query, frames, access tokens or endpoint credentials.
            self.proof['blocked_requests'].append({'kind': 'websocket', 'failure': 'unexpected_endpoint'})
            self.save()
            route.close(code=1008, reason='Local realtime endpoint only')

    def assert_bound_link(self, link):
        claim, case = self.state.get('claim_id'), self.state.get('case_id')
        assert nonce(link) and nonce(claim) and nonce(case)
        assert claim == self.state['acceptance'] and claim not in self.state['old_claim_ids']
        # Actual server tuple, not a response/list UUID: link→claim→receipt and
        # controlled intake→proposal acceptance→exact new case must all agree.
        value = self.h.sql("select exists(select 1 from private.offline_customer_trusted_links l join private.offline_claim_requests c on c.request_id=l.claim_id join private.offline_customer_enrollment_receipts e on e.receipt_id=l.receipt_id join private.visit_recovery_proposal_acceptances a on a.claim_id=c.request_id join private.visit_recovery_owner_proposals p on p.proposal_id=a.proposal_id join private.visit_recovery_case_claims m on m.claim_id=c.request_id where l.link_id='" + link + "' and l.claim_id='" + claim + "' and c.request_id='" + claim + "' and c.receipt_key=e.receipt_id and l.profile_id=e.profile_id and c.profile_id=e.profile_id and p.profile_id=e.profile_id and p.receipt_id=e.receipt_id and e.profile_id='" + self.candidate['profile_id'] + "' and e.request_id='" + self.state['controlled_registration'] + "' and l.auth_user_id='" + self.actor + "' and c.actor_id=l.auth_user_id and a.actor_id=l.auth_user_id and a.request_id='" + claim + "' and p.case_id='" + case + "' and m.case_id=p.case_id)")
        assert value == 't', 'Exact newly created claim/link/receipt tuple required'
        self.proof['actual_new_link_tuple_verified'] = True

    def fixed_diagnostic(self, page):
        fields = {}
        for identifier in ('owner-proposal-open', 'owner-proposal-evidence', 'owner-proposal-reason', 'owner-proposal-attestation', 'owner-proposal-prepare'):
            loc = page.locator('[flt-semantics-identifier="' + identifier + '"]')
            fields[identifier] = {'count': loc.count(), 'visible': loc.first.is_visible() if loc.count() else False,
                                  'role': loc.first.get_attribute('role') if loc.count() else None}
        options = {}
        for text in ('Independent continuity witness in person', 'شهادة مستقلة باستمرارية الهوية بحضور العميل', 'Independent continuity witness', 'شاهد مستقل لاستمرارية الهوية'):
            options[text] = page.get_by_role('option', name=text, exact=True).count()
        self.proof['fixed_selector_diagnostic'] = {'fields': fields, 'fixed_option_role_counts': options}

    def accepted_scopes(self):
        path = self.args.accepted_scope_proof.resolve()
        path.relative_to(self.args.runtime.resolve())
        accepted = json.loads(path.read_text())
        manifest = json.loads(self.args.build_proof.read_text())
        assert accepted['local_only'] and accepted['production_touched'] is False
        assert accepted['independent_evidence_is_isolated_QA_simulation'] is True
        assert accepted['build_sha256'] == manifest['main_dart_js_sha256']
        assert accepted['owner_proposal_ui_accepted'] and accepted['customer_dual_consent_ui_accepted'] and accepted['canonical_pending_without_link_accepted']
        assert accepted['final_canonical_owner_ui_accepted'] is False
        assert accepted['full_original_attempt_all_passed'] is False
        source_path = Path(accepted['source_attempt_proof']).resolve()
        source_path.relative_to(self.args.runtime.resolve())
        assert hashlib.sha256(source_path.read_bytes()).hexdigest() == accepted['source_attempt_sha256']
        source = json.loads(source_path.read_text())
        assert source['local_only'] and source['production_touched'] is False
        assert source['build_sha256'] == accepted['build_sha256'] and source['all_passed'] is False
        assert source['language'] == 'ar'
        assert source['controlled_fixture_sha256'] == hashlib.sha256((self.args.runtime / 'recovery-proposal-concurrency-state.json').read_bytes()).hexdigest()
        assert source['cleanup_complete'] and source['preexisting_public_private_rows_unchanged']
        assert source['document_counters_unchanged'] and source['auth_users_unchanged_except_signin_metadata']
        assert source['financial_credit_auth_and_profile_counts_unchanged']
        assert source['checks']['owner_actual_independent_proposal_prepared']
        assert source['checks']['customer_actual_dual_consent_canonical_pending_no_link']
        self.proof['accepted_scope_proof'] = str(path)
        self.proof['accepted_scope_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.proof['reused_accepted_ui_scopes_not_repeated'] = ['owner_proposal_ui', 'customer_dual_consent_ui', 'canonical_pending_without_link']

    def guarded_setup_rpc(self, role, name, body):
        assert self.allow_rpc(name, body, role)
        data = self.rpc_as(role, name, body)
        self.proof.setdefault('necessary_current_auth_rpc_setup', []).append({'role': role, 'name': name, 'result_received': True})
        self.save()
        return data

    def setup_canonical_pending(self):
        self.stage('remaining_mode_necessary_new_state_current_auth_rpc_only')
        data = self.guarded_setup_rpc('customer', 'get_my_visit_recovery_request', {'p_case': None})
        assert data['new_request_allowed'] and self.case_from(data)['status'] in ('rejected', 'revoked')
        self.notice = data['consent']
        request = str(uuid.uuid4())
        result = self.guarded_setup_rpc('customer', 'submit_visit_recovery_request', {
            'p_request': request, 'p_consent': {'accepted': True, 'version': self.notice['version'],
                'language': self.args.language, 'text': self.notice['notice_' + self.args.language]}})
        cid = self.case_from(result)['case_id']
        assert nonce(cid) and cid not in self.state['old_case_ids'] and self.case_from(result)['status'] == 'awaiting_matching'
        self.state['case_id'] = self.proof['new_case_id'] = cid
        self.save()
        query = str(uuid.uuid4())
        data = self.guarded_setup_rpc('owner', 'search_visit_recovery_candidates', {
            'p_query': query, 'p_case': cid, 'p_purpose': self.tag + ' investigation', 'p_plate': self.candidate['plate'], 'p_limit': 10})
        assert data['candidate_count'] == 1 and data['candidates'][0]['profile_reference'] == self.candidate['profile_id']
        # New per-case audit query is necessary; no previously accepted lookup UI
        # or customer403 check is re-exercised by remaining mode.
        data = self.guarded_setup_rpc('owner', 'get_visit_recovery_candidate', {
            'p_request': str(uuid.uuid4()), 'p_query': query, 'p_profile': self.candidate['profile_id'],
            'p_purpose': self.tag + ' investigation', 'p_plate': self.candidate['plate']})
        row = data['candidate']
        assert row['profile_reference'] == self.candidate['profile_id'] and row['real_receipt_available'] and not row['receipt_ever_linked']
        self.owner_masks += [str(row['name']), self.candidate['plate']] + [str(c['phone']) for c in row['contacts']]
        proposal = str(uuid.uuid4())
        data = self.guarded_setup_rpc('owner', 'prepare_visit_recovery_proposal', {
            'p_proposal': proposal, 'p_query': query, 'p_profile': self.candidate['profile_id'],
            'p_evidence_type': EVIDENCE, 'p_reason': self.tag + ' actual independent physical evidence',
            'p_attested': True, 'p_plate': self.candidate['plate']})
        assert data['proposal_id'] == proposal and data['state'] == 'open' and data['link_created'] is False
        terms = self.guarded_setup_rpc('customer', 'get_my_visit_recovery_proposal', {'p_case': cid})
        assert terms['state'] == 'open' and terms['proposal']['proposal_id'] == proposal
        assert set(terms['proposal']) <= {'proposal_id', 'expires_at'}
        self.proposal_terms = terms
        data = self.guarded_setup_rpc('customer', 'accept_my_visit_recovery_proposal', {
            'p_request': str(uuid.uuid4()), 'p_proposal': proposal,
            'p_consent': {'accepted': True, 'version': terms['consent_version'], 'language': self.args.language, 'text': terms['notice_' + self.args.language]},
            'p_claim_consent': {'accepted': True, 'version': terms['canonical_consent_version'], 'language': self.args.language, 'text': terms['canonical_notice_' + self.args.language]}})
        assert data['state'] == 'accepted' and data['attached'] is True and data['link_created'] is False
        assert data['claim_id'] == data['request_id'] == self.state['acceptance']
        self.state['claim_id'] = data['claim_id']
        self.save()
        self.assert_bound_claim()
        self.proof['necessary_new_canonical_pending_state_not_ui_reacceptance'] = True

    def owner_root(self, page):
        # Actual app startup/auth resolver; never inject navigation/client state.
        page.goto(self.h.app)
        page.wait_for_selector('flutter-view', timeout=60000)
        sem = page.locator('flt-semantics-placeholder')
        if sem.count():
            sem.evaluate('(e)=>e.click()')
        self.button(page, self.t('التقارير', 'Reports')).wait_for(state='visible', timeout=30000)
        page.wait_for_timeout(650)

    def assert_first_case(self, data):
        assert data['items'] and data['items'][0]['case_id'] == self.state['case_id']
        row = data['items'][0]
        if row['canonical_claim_mapped']:
            assert self.state['claim_id'] and row['canonical_claim_reference'] == self.state['claim_id']
            self.assert_bound_claim()
        else:
            assert row['canonical_claim_mapped'] is False
        return row

    def allow_rpc(self, name, body, role):
        if name == 'get_my_visit_recovery_request':
            return role == 'customer' and set(body) == {'p_case'} and body['p_case'] in (None, self.state['case_id'])
        if name == 'prepare_visit_recovery_proposal':
            assert role == 'owner' and set(body) == {'p_proposal', 'p_query', 'p_profile', 'p_evidence_type', 'p_reason', 'p_attested', 'p_plate'}
            assert nonce(body['p_proposal']) and body['p_query'] in self.queries and body['p_profile'] == self.candidate['profile_id']
            assert body['p_evidence_type'] == EVIDENCE and body['p_reason'] == self.tag + ' actual independent physical evidence' and body['p_attested'] is True and body['p_plate'] == self.candidate['plate']
            assert self.proposal_payloads.get(body['p_proposal']) in (None, body)
            self.proposal_payloads[body['p_proposal']] = dict(body)
            self.state['owner_proposals'][body['p_proposal']] = {'query_id': body['p_query'], 'profile_id': body['p_profile']}
            self.save()
            return True
        if name in ('get_visit_recovery_proposal', 'close_visit_recovery_proposal'):
            return role == 'owner' and set(body) == {'p_proposal'} and body['p_proposal'] in self.state['owner_proposals']
        if name == 'accept_my_visit_recovery_proposal':
            assert role == 'customer' and set(body) == {'p_request', 'p_proposal', 'p_consent', 'p_claim_consent'}
            assert nonce(body['p_request']) and body['p_request'] not in self.state['old_claim_ids']
            assert body['p_proposal'] in self.state['owner_proposals'] and self.proposal_terms
            terms = self.proposal_terms
            assert body['p_consent'] == {'accepted': True, 'version': terms['consent_version'], 'language': self.args.language, 'text': terms['notice_' + self.args.language]}
            assert body['p_claim_consent'] == {'accepted': True, 'version': terms['canonical_consent_version'], 'language': self.args.language, 'text': terms['canonical_notice_' + self.args.language]}
            assert self.state['acceptance'] in (None, body['p_request'])
            self.state['acceptance'] = body['p_request']
            self.save()
            return True
        if name in ('get_my_visit_recovery_acceptance', 'close_my_visit_recovery_acceptance'):
            return role == 'customer' and self.state['acceptance'] is not None and body == {'p_request': self.state['acceptance']}
        if name == 'list_offline_customer_claim_reviews':
            return role == 'owner' and body == {'p_branch': None}
        if name == 'prepare_offline_claim_command':
            assert role == 'owner' and set(body) == {'p_request', 'p_kind', 'p_payload'} and nonce(body['p_request'])
            payload, kind = body['p_payload'], body['p_kind']
            if kind == 'decide':
                assert payload == {'p_claim': self.state['claim_id'], 'p_decision': 'approve_exception', 'p_reason': self.tag + ' final independent evidence review', 'p_evidence_type': EVIDENCE}
            else:
                assert kind == 'revoke' and self.state['link_id'] and payload == {'p_link': self.state['link_id'], 'p_reason': self.tag + ' revoke exact new QA approval'}
                self.assert_bound_link(payload['p_link'])
            assert self.owner_payloads.get(body['p_request']) in (None, body)
            self.owner_payloads[body['p_request']] = dict(body)
            self.state['canonical_commands'][body['p_request']] = {'kind': kind, 'claim_id': self.state['claim_id'], 'link_id': self.state['link_id']}
            self.save()
            return True
        if name in ('decide_offline_customer_claim', 'revoke_offline_customer_link'):
            assert role == 'owner' and body.get('p_request') in self.owner_payloads
            prepared = self.owner_payloads[body['p_request']]
            assert name == ('decide_offline_customer_claim' if prepared['p_kind'] == 'decide' else 'revoke_offline_customer_link')
            if name == 'revoke_offline_customer_link':
                self.assert_bound_link(body.get('p_link'))
            return body == {'p_request': prepared['p_request'], **prepared['p_payload']}
        if name in ('get_offline_customer_claim_command', 'close_offline_claim_command'):
            return role == 'owner' and set(body) == {'p_request'} and body['p_request'] in self.state['canonical_commands']
        if name == 'get_my_offline_history_context':
            return role == 'customer' and body in ({}, None)
        return super().allow_rpc(name, body, role)

    def process_rpc_body(self, response, role, name):
        super().process_rpc_body(response, role, name)
        if response.status != 200:
            return
        data = response.json()
        if name == 'get_my_visit_recovery_proposal':
            assert set(data.get('proposal') or {}) <= {'proposal_id', 'expires_at'}
            assert all(key not in data for key in ('profile_reference', 'phone', 'name', 'private_reason', 'receipt_id'))
            if data['state'] == 'open':
                self.proposal_terms = data  # RAM only; never written into proof.
        if name == 'accept_my_visit_recovery_proposal':
            assert data['request_id'] == self.state['acceptance'] and data['claim_id'] == self.state['acceptance']
            self.state['claim_id'] = data['claim_id']
        if name == 'decide_offline_customer_claim' and data.get('link_id'):
            assert data['claim_id'] == self.state['claim_id'] and nonce(data['link_id'])
            self.state['link_id'] = data['link_id']
        if name == 'list_offline_customer_claim_reviews':
            self.owner_masks += [str(row[key]) for row in data for key in ('name', 'registered_phone', 'customer_name') if row.get(key)]
        self.save()

    def paragraph(self, page, text):
        pattern = re.compile(r'\s+'.join(re.escape(word) for word in text.split()))
        return page.get_by_label(pattern).or_(page.get_by_text(pattern)).first

    def pick(self, page, field, option, identifier=None):
        # Actual installed Flutter engine exposes Semantics.identifier through
        # flt-semantics-identifier; preserve native menu interaction.
        if identifier:
            target = page.locator('[flt-semantics-identifier="' + identifier + '"]')
        else:
            pattern = re.compile(re.escape(field))
            target = page.get_by_role('combobox', name=pattern).or_(page.get_by_role('button', name=pattern)).or_(page.get_by_label(pattern)).first
        self.click(page, target)
        item = page.get_by_role('option', name=option, exact=True).or_(page.get_by_role('button', name=option, exact=True)).or_(page.get_by_label(option, exact=True)).or_(page.get_by_text(option, exact=True)).last
        item.wait_for(state='visible')
        item.click()
        page.wait_for_timeout(450)

    def select_controlled(self, page):
        self.stage('necessary_case_bound_controlled_query_and_detail')
        self.click(page, self.button(page, self.t('التحقق من سجلات الاستقبال', 'Investigate reception records')).first)
        Acceptance.type_into(page, self.t('الغرض من التحقق (١٠ أحرف على الأقل)', 'Investigation purpose (at least 10 characters)'), self.tag + ' investigation')
        field = self.t('لوحة السيارة الدقيقة (اختياري)', 'Exact vehicle plate (optional)')
        Acceptance.type_into(page, field, self.candidate['plate'])
        page.get_by_role('textbox', name=field, exact=True).press('Tab')
        with self.wait_rpc(page, 'search_visit_recovery_candidates') as response:
            self.click(page, self.button(page, self.t('التحقق من السجلات المحتملة', 'Investigate possible records')))
        data = response.value.json()
        assert response.value.status == 200 and data['candidate_count'] == 1 and data['candidates'][0]['profile_reference'] == self.candidate['profile_id']
        assert data['linking_enabled'] is False and data['proposal_enabled'] is False
        with self.wait_rpc(page, 'get_visit_recovery_candidate') as response:
            self.click(page, self.button(page, self.t('عرض تفاصيل هذا السجل للمراجعة', 'Review details of this record')).first)
        row = response.value.json()['candidate']
        assert row['profile_reference'] == self.candidate['profile_id'] and row['candidate_is_identity_proof'] is False
        assert row['real_receipt_available'] and not row['receipt_ever_linked'] and not row['active_profile_link']
        self.owner_masks += [str(row['name']), self.candidate['plate']] + [str(c['phone']) for c in row['contacts']]

    def prepare_proposal(self, page):
        self.stage('owner_explicit_independent_proposal')
        self.click(page, self.button(page, self.t('اقتراح هذا السجل للتحقق المستقل', 'Propose this record for independent verification')))
        self.pick(page, self.t('نوع الدليل المستقل الفعلي', 'Actual independent evidence type'), self.t('شهادة مستقلة باستمرارية الهوية بحضور العميل', 'Independent continuity witness in person'), identifier='owner-proposal-evidence')
        Acceptance.type_into(page, self.t('سبب خاص مبني على الدليل (١٠ أحرف على الأقل)', 'Private evidence-based reason (at least 10 characters)'), self.tag + ' actual independent physical evidence')
        check = page.get_by_role('checkbox', name=self.t('تحققت حضورياً من دليل مستقل فعلي؛ لم أعتمد الهاتف أو رقم الإيصال وحده', 'I checked actual independent evidence in person; phone or receipt reference alone was insufficient'), exact=True)
        assert not check.is_checked()
        self.click(page, check)
        with self.wait_rpc(page, 'prepare_visit_recovery_proposal') as response:
            self.click(page, self.button(page, self.t('حفظ الاقتراح وطلب موافقة العميل', 'Save proposal and request customer consent')))
        data = response.value.json()
        assert response.value.status == 200 and data['state'] == 'open' and data['link_created'] is False
        assert data['case_id'] == self.state['case_id'] and data['profile_reference'] == self.candidate['profile_id']
        self.proof['checks']['owner_actual_independent_proposal_prepared'] = True
        self.shot(page, 'owner-actual-proposal-open-awaiting-consent')

    def accept_proposal(self, page):
        self.stage('customer_two_explicit_opaque_consents')
        with self.wait_rpc(page, 'get_my_visit_recovery_proposal') as response:
            self.click(page, self.button(page, self.t('تحديث الاقتراح والنتيجة', 'Refresh proposal and outcome')))
        data = response.value.json()
        assert response.value.status == 200 and data['state'] == 'open'
        assert data['proposal']['proposal_id'] in self.state['owner_proposals']
        for ar, en in [('أوافق على مراجعة اقتراح المالك', 'I agree to review the owner proposal'), ('أوافق على طلب التحقق المستقل', 'I agree to request independent verification')]:
            check = page.get_by_role('checkbox', name=self.t(ar, en), exact=True)
            assert not check.is_checked()
            self.click(page, check)
        with self.wait_rpc(page, 'accept_my_visit_recovery_proposal') as response:
            self.click(page, self.button(page, self.t('إرسال موافقتي للمراجعة', 'Submit my consent for review')))
        data = response.value.json()
        assert response.value.status == 200 and data['state'] == 'accepted' and data['attached'] is True and data['link_created'] is False and data['approval_required'] is True
        self.assert_bound_claim()
        self.proof['checks']['customer_actual_dual_consent_canonical_pending_no_link'] = True
        self.shot(page, 'customer-actual-consent-pending-final-review')
        self.click(page, self.button(page, self.t('راجعت نتيجة الموافقة', 'I reviewed the consent outcome')))

    def assert_bound_claim(self):
        rid = self.state['acceptance']
        assert nonce(rid) and rid not in self.state['old_claim_ids']
        profile = self.candidate['profile_id']
        value = self.h.sql("select exists(select 1 from private.visit_recovery_proposal_acceptances a join private.visit_recovery_owner_proposals p on p.proposal_id=a.proposal_id join private.offline_claim_requests c on c.request_id=a.claim_id join private.offline_customer_enrollment_receipts e on e.receipt_id=p.receipt_id and e.receipt_id=c.receipt_key join private.visit_recovery_case_claims m on m.claim_id=c.request_id where a.request_id='" + rid + "' and a.actor_id='" + self.actor + "' and p.case_id='" + self.state['case_id'] + "' and p.profile_id='" + profile + "' and c.profile_id=p.profile_id and c.actor_id=a.actor_id and m.case_id=p.case_id and e.profile_id=p.profile_id and e.request_id='" + self.state['controlled_registration'] + "')")
        assert value == 't'

    def back(self, page):
        self.click(page, page.get_by_role('button', name=re.compile(r'^(Back|رجوع)$')).first, fixed=True)

    def canonical_review(self, page, fixture_setup=False):
        self.stage('owner_actual_final_canonical_exception_review')
        if not fixture_setup:
            # EN full path still resolves its actual UI-created reference before
            # leaving. Root navigation replaces the unstable two-Back sequence.
            with self.wait_rpc(page, 'get_visit_recovery_proposal') as response:
                self.click(page, self.button(page, self.t('استعادة حالة الاقتراح', 'Recover proposal status')))
            assert response.value.json()['state'] == 'accepted'
            self.click(page, self.button(page, self.t('راجعت النتيجة النهائية', 'I reviewed the definitive outcome')))
        self.owner_root(page)
        self.owner_list(page)
        row = self.assert_first_case(self.latest[('owner', 'list_visit_recovery_requests')])
        assert row['canonical_claim_reference'] == self.state['claim_id']
        with self.wait_rpc(page, 'list_offline_customer_claim_reviews') as listed:
            self.click(page, self.button(page, self.t('فتح مراجعة الإثبات', 'Open canonical review')).first)
        rows = listed.value.json()
        assert rows and rows[0]['claim_id'] == self.state['claim_id'] and rows[0]['profile_reference'] == self.candidate['profile_id']
        assert rows[0]['mode'] == 'lost_secret_review' and rows[0]['status'] == 'pending_owner_review' and rows[0]['confirmed_account_current'] and rows[0]['contact_current']
        self.click(page, self.button(page, self.t('مراجعة الإثبات', 'Review evidence')).first)
        Acceptance.type_into(page, self.t('الإثبات الفعلي وسبب القرار', 'Actual review evidence and reason'), self.tag + ' final independent evidence review')
        self.pick(page, self.t('إثبات الاستمرارية الذي تم فحصه حضورياً', 'Continuity evidence checked in person'), self.t('شاهد مستقل لاستمرارية الهوية', 'Independent continuity witness'))
        self.click(page, page.get_by_role('checkbox', name=self.t('فحصت هذا الإثبات حضورياً. تطابق الهاتف وحده غير كافٍ.', 'I checked this evidence in person. A phone match alone is insufficient.'), exact=True))
        with self.wait_rpc(page, 'prepare_offline_claim_command') as prepared, self.wait_rpc(page, 'decide_offline_customer_claim') as decided:
            self.click(page, self.button(page, self.t('الموافقة على استثناء الاستمرارية الموثق', 'Approve the documented continuity exception')))
        data = decided.value.json()
        assert prepared.value.status == 200 and decided.value.status == 200 and data['decision'] == 'approve_exception' and data['status'] == 'approved_pending_reader_bridge'
        self.proof['checks']['owner_actual_canonical_exception_approved'] = True
        self.shot(page, 'owner-actual-canonical-exception-approved')
        self.click(page, self.button(page, self.t('تأكيد هذه النتيجة', 'Acknowledge this result')))

    def customer_status(self, page, status, template):
        self.customer_home(page)
        data = self.customer_panel(page)
        assert self.case_from(data)['case_id'] == self.state['case_id'] and self.case_from(data)['status'] == status
        assert data['link_current'] is (status == 'linked')
        assert data['record_access_requires_fresh_history_scope'] is True
        self.proof.setdefault('actual_customer_link_liveness', {})[status] = data['link_current']
        self.shot(page, 'customer-actual-request-' + status)
        self.customer_home(page)
        with self.wait_rpc(page, 'list_my_app_inbox') as listed:
            self.click(page, page.get_by_role('button', name=re.compile(self.t(r'^التنبيهات ·', r'^Inbox ·'))).first, fixed=True)
        matches = [row for row in listed.value.json()['items'] if row['case_reference'] == self.state['case_id'] and row['template_code'] == template]
        assert len(matches) == 1
        Acceptance.near(page, self.paragraph(page, matches[0]['title_' + self.args.language]))
        self.shot(page, 'customer-actual-' + template + '-notice')
        self.proof['checks'][status + '_actual_request_and_private_inbox_notice'] = True
        self.assert_no_history()

    def assert_no_history(self):
        data = self.rpc_as('customer', 'get_my_offline_history_context', {})
        assert data['state'] != 'available'
        flags = data.get('capabilities', {})
        assert all(flags.get(key) is False for key in ('wallet_access', 'guest_redemption'))
        assert self.h.sql('select not exists(select 1 from private.offline_history_runtime where enabled)') == 't'
        self.proof['checks']['history_reader_and_rewards_remain_disabled'] = True

    def revoke_ui(self, page):
        self.stage('owner_actual_exact_new_link_revocation')
        self.assert_bound_link(self.state['link_id'])
        with self.wait_rpc(page, 'list_offline_customer_claim_reviews') as listed:
            self.click(page, self.button(page, self.t('تحديث مراجعات الهوية', 'Refresh identity reviews')))
        rows = listed.value.json()
        assert rows[0]['claim_id'] == self.state['claim_id'] and rows[0]['link_id'] == self.state['link_id']
        reason = page.get_by_role('textbox', name=self.t('الإثبات الفعلي وسبب القرار', 'Actual review evidence and reason'), exact=True)
        if not reason.count():
            self.click(page, self.button(page, self.t('مراجعة الإثبات', 'Review evidence')).first)
        Acceptance.type_into(page, self.t('الإثبات الفعلي وسبب القرار', 'Actual review evidence and reason'), self.tag + ' revoke exact new QA approval')
        with self.wait_rpc(page, 'prepare_offline_claim_command') as prepared, self.wait_rpc(page, 'revoke_offline_customer_link') as revoked:
            self.click(page, self.button(page, self.t('إلغاء الموافقة على الهوية', 'Revoke identity approval')))
        assert prepared.value.status == 200 and revoked.value.status == 200 and revoked.value.json()['link_id'] == self.state['link_id'] and revoked.value.json()['status'] == 'revoked'
        self.shot(page, 'owner-actual-exact-link-revoked')
        self.click(page, self.button(page, self.t('تأكيد هذه النتيجة', 'Acknowledge this result')))
        self.proof['checks']['owner_actual_exact_link_revoked'] = True

    def cleanup(self):
        self.stage('cleanup_fence_and_only_new_claim_or_link')
        if self.state.get('acceptance'):
            self.rpc_as('customer', 'close_my_visit_recovery_acceptance', {'p_request': self.state['acceptance']})
        for proposal in self.state.get('owner_proposals', {}):
            self.rpc_as('owner', 'close_visit_recovery_proposal', {'p_proposal': proposal})
        for command in list(self.state.get('canonical_commands', {})):
            self.rpc_as('owner', 'close_offline_claim_command', {'p_request': command})
        rid = self.state.get('acceptance')
        if rid:
            claim = json.loads(self.h.sql("select coalesce((select json_build_object('claim_id',c.request_id,'profile',c.profile_id,'own',c.actor_id='" + self.actor + "','link_id',l.link_id,'revoked',l.revoked_at is not null,'rejected',exists(select 1 from private.offline_claim_decisions d where d.claim_id=c.request_id and d.decision='reject'))from private.offline_claim_requests c left join private.offline_customer_trusted_links l on l.claim_id=c.request_id where c.request_id='" + rid + "'),'{}'::json)"))
            if claim:
                assert rid not in self.state['old_claim_ids']
                assert self.h.sql("select exists(select 1 from private.visit_recovery_proposal_acceptances a join private.visit_recovery_owner_proposals p on p.proposal_id=a.proposal_id where a.request_id='" + rid + "' and a.claim_id='" + rid + "' and a.actor_id='" + self.actor + "' and p.profile_id='" + self.candidate['profile_id'] + "' and p.case_id='" + self.state['case_id'] + "')") == 't'
                assert claim['own'] and claim['profile'] == self.candidate['profile_id'] and claim['claim_id'] == rid
                self.state['claim_id'] = rid
                if claim['link_id'] and not claim['revoked']:
                    self.state['link_id'] = claim['link_id']
                    payload = {'p_link': claim['link_id'], 'p_reason': self.tag + ' exact new link cleanup'}
                    self.cleanup_command('revoke', payload)
                elif not claim['link_id'] and not claim['rejected']:
                    payload = {'p_claim': rid, 'p_decision': 'reject', 'p_reason': self.tag + ' exact new canonical claim cleanup', 'p_evidence_type': None}
                    self.cleanup_command('decide', payload)
        cid = self.state.get('case_id')
        if not cid and self.state.get('submission'):
            receipt = self.rpc_as('customer', 'close_my_visit_recovery_submission', {'p_request': self.state['submission']})
            if receipt['state'] == 'accepted':
                cid = self.case_from(receipt['result'])['case_id']
                self.state['case_id'] = cid
            else:
                assert receipt['state'] == 'closed'
        if cid:
            assert nonce(cid) and cid not in self.state['old_case_ids']
            row = json.loads(self.h.sql("select json_build_object('own',requester_id='" + self.actor + "','status',status,'mapped',exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id))from private.visit_recovery_customer_requests c where case_id='" + cid + "'"))
            assert row['own']
            if row['status'] in ('awaiting_matching', 'more_info'):
                assert not row['mapped']
                request = str(uuid.uuid4())
                self.state['reviews'][request] = {'p_request': request, 'p_case': cid}
                self.save()
                self.rpc_as('owner', 'prepare_visit_recovery_review', {'p_request': request, 'p_case': cid, 'p_expected_status': row['status'], 'p_action': 'reject', 'p_reason': self.tag + ' exact new unmapped case cleanup'})
                self.rpc_as('owner', 'apply_visit_recovery_review', {'p_request': request})
            else:
                assert row['status'] in ('rejected', 'revoked')
        assert self.h.sql("select not exists(select 1 from private.offline_customer_trusted_links where profile_id='" + self.candidate['profile_id'] + "' and revoked_at is null)") == 't'
        self.state['cleanup_complete'] = self.proof['cleanup_complete'] = True
        self.save()

    def cleanup_command(self, kind, payload):
        if kind == 'revoke':
            self.assert_bound_link(payload['p_link'])
        request = str(uuid.uuid4())
        self.state['canonical_commands'][request] = {'kind': kind, 'claim_id': self.state['claim_id'], 'link_id': self.state['link_id']}
        self.save()
        self.rpc_as('owner', 'prepare_offline_claim_command', {'p_request': request, 'p_kind': kind, 'p_payload': payload})
        endpoint = 'revoke_offline_customer_link' if kind == 'revoke' else 'decide_offline_customer_claim'
        self.rpc_as('owner', endpoint, {'p_request': request, **payload})
        self.rpc_as('owner', 'close_offline_claim_command', {'p_request': request})

    def execute(self):
        if self.args.remaining_canonical_only:
            assert self.args.accepted_scope_proof and self.args.language == 'ar'
            self.accepted_scopes()
        self.preflight()
        if self.args.remaining_canonical_only:
            self.proof['proof_scope'] = 'remaining_ar_final_canonical_owner_ui_linked_inbox_then_revoke_only'
        from playwright.sync_api import sync_playwright, expect
        pages = {}
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless=True)
                try:
                    for role in ('owner', 'customer'):
                        page = browser.new_page(viewport={'width': 390 if self.ar else 1440, 'height': 1100})
                        page.set_default_timeout(30000)
                        self.page_roles[page] = role
                        page.route('**/*', lambda route, request, role=role: self.guard(route, role))
                        page.route_web_socket('**/*', self.guard_socket)
                        page.on('response', lambda response, role=role: self.observe(response, role))
                        page.on('pageerror', lambda _: self.proof['render_errors'].append('javascript_error'))
                        page.on('console', lambda msg: self.proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                        pages[role] = page
                    owner, customer = pages['owner'], pages['customer']
                    self.login(owner, 'owner')
                    self.login(customer, 'customer')
                    if self.args.remaining_canonical_only:
                        self.setup_canonical_pending()
                    else:
                        data = self.customer_panel(customer)
                        assert data['new_request_allowed'] is True
                        check = customer.get_by_role('checkbox', name=self.t('أوافق على طلب المراجعة بهذا النطاق', 'I agree to this review request scope'), exact=True)
                        expect(check).not_to_be_checked()
                        self.click(customer, check)
                        with self.wait_rpc(customer, 'submit_visit_recovery_request') as submitted:
                            self.click(customer, self.button(customer, self.t('إرسال طلب جديد للمراجعة', 'Send a new request for review')))
                        assert submitted.value.status == 200
                        self.click(customer, self.button(customer, self.t('راجعت النتيجة', 'I reviewed the result')))
                        self.owner_list(owner)
                        self.select_controlled(owner)
                        self.prepare_proposal(owner)
                        self.accept_proposal(customer)
                    self.canonical_review(owner, fixture_setup=self.args.remaining_canonical_only)
                    self.customer_status(customer, 'linked', 'recovery_approved')
                    self.revoke_ui(owner)
                    self.customer_status(customer, 'revoked', 'recovery_access_ended')
                    assert not self.proof['blocked_requests'] and not self.proof['render_errors']
                    self.proof['all_passed'] = True
                except Exception as error:
                    self.proof['failure_type'] = type(error).__name__
                    if 'owner' in pages:
                        try:
                            self.fixed_diagnostic(pages['owner'])
                        except Exception:
                            self.proof['fixed_selector_diagnostic_unavailable'] = True
                    for role, page in pages.items():
                        try:
                            self.shot(page, role + '-proposal-failure-private')
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
            after = Intake.snapshot(self.h)
            self.proof['preexisting_public_private_rows_unchanged'] = all(not (rows - after.get(table, Counter())) for table, rows in self.before.items())
            self.proof['financial_credit_auth_and_profile_counts_unchanged'] = self.fact_counts() == self.state['before_fact_counts']
            self.proof['document_counters_unchanged'] = Intake.counters(self.h) == self.counters
            self.proof['auth_users_unchanged_except_signin_metadata'] = self.auth_hash() == self.auth_before
            self.save()
        assert self.proof['all_passed'] and self.state['cleanup_complete'] and self.proof['preexisting_public_private_rows_unchanged'] and self.proof['document_counters_unchanged'] and self.proof['auth_users_unchanged_except_signin_metadata'] and self.proof['financial_credit_auth_and_profile_counts_unchanged']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'proof', 'screenshots', 'build-proof'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--language', choices=('ar', 'en'), required=True)
    parser.add_argument('--app-url', default='http://127.0.0.1:8080')
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--remaining-canonical-only', action='store_true')
    parser.add_argument('--accepted-scope-proof', type=Path)
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({'plan_only': True, 'locale': args.language, 'mode': 'remaining_canonical_only' if args.remaining_canonical_only else 'full_new_locale', 'accepted_ui_scopes_reused': bool(args.remaining_canonical_only), 'new_case': 1, 'new_profiles_auth_phones_finance': False, 'journey': ['necessary_new_own_case', 'exact_controlled_profile_investigation', 'owner_explicit_independent_proposal', 'customer_two_opaque_consents', 'existing_canonical_owner_exception_review', 'actual_linked_status_and_approved_inbox', 'existing_owner_revoke', 'actual_revoked_status_no_old_access'], 'cleanup': 'same-nonce fences, reject/revoke only exact new claim/link/case; retain audit'}))
        return
    assert args.language == 'en' or args.remaining_canonical_only, 'Accepted Arabic proposal/consent UI must not be repeated; use remaining canonical mode'
    ProposalJourney(args).execute()


if __name__ == '__main__':
    main()
