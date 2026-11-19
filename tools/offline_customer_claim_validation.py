"""PLAN by default: retained local-only HTTP proof/rate and two-session claim QA.
No new Auth users, finance writes, raw secrets, credentials or HTTP bodies in proof.
Run only after root releases the serial DB slot. QA intake/claim audit is retained;
any approved QA link is revoked. Existing identity/financial rows must not change.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def uid():
    return str(uuid.uuid4())


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class SafeFailure(RuntimeError):
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(__doc__)
        return
    runtime = args.runtime.resolve()
    accounts = json.loads((runtime / 'test-accounts-final.json').read_text())
    parsed = urllib.parse.urlsplit(accounts['url'])
    assert parsed.hostname == '127.0.0.1' and parsed.scheme == 'http'
    base = accounts['url'].rstrip('/')
    sock = runtime / 'instances/sabiha-local/sock/docker.sock'
    assert sock.is_socket()
    env = {**os.environ, 'DOCKER_HOST': 'unix://' + str(sock),
           'DOCKER_CONFIG': str(runtime / 'docker-config')}
    command = [str(runtime / 'docker-cli/docker/docker'), 'exec', '-i',
               'supabase_db_supabase-local', 'psql', '-X', '-q', '-At',
               '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
    tokens = {}
    actors = {key: str(uuid.UUID(accounts['users'][key]['id']))
              for key in ['owner', 'manager', 'customer', 'other_customer']}
    tag = 'claimqa-' + uuid.uuid4().hex[:12]
    proof = {'local_only': True, 'production_touched': False,
             'auth_accounts_created': 0, 'financial_writes': 0,
             'tag': tag, 'all_passed': False}
    qa_claims = []
    sessions = []

    def sql(source):
        result = subprocess.run(command, input=source, text=True, capture_output=True,
                                env=env, timeout=35)
        if result.returncode:
            # Never persist stderr: SQL context could contain in-memory arguments.
            raise SafeFailure('Local SQL assertion/query failed; output redacted')
        return result.stdout.strip()

    def http(path, data, role=None):
        headers = {'apikey': accounts['anon_key'], 'Content-Type': 'application/json'}
        if role:
            headers['Authorization'] = 'Bearer ' + tokens[role]
        request = urllib.request.Request(base + path, data=json.dumps(data).encode(),
                                         method='POST', headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            try:
                body = json.loads(error.read())
                code = body.get('code')
            except (ValueError, TypeError):
                code = None
            return error.code, {'code': code}

    def rpc(name, payload, role='owner', expect=200):
        status, result = http('/rest/v1/rpc/' + name, payload, role)
        if status != expect:
            raise SafeFailure('RPC status assertion failed for ' + name + '; body redacted')
        return result

    def snapshot():
        rows = sql("""create temp table qa_claim_hash(t text,h text);do $$declare t record;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop
        execute format('insert into qa_claim_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;
        select t||'|'||h from qa_claim_hash order by t,h;""")
        return Counter(rows.splitlines())

    def rate(actor=None, receipt=None):
        predicate = 'actor_id=' + literal(actor) if actor else 'receipt_key=' + literal(receipt)
        return int(sql("select count(*)from private.offline_claim_requests where " + predicate +
                       " and created_at>clock_timestamp()-interval '1 hour';"))

    def request(receipt, secret, role, mode='original_receipt'):
        request_id = uid()
        result = rpc('request_offline_customer_claim', {
            'p_request': request_id, 'p_receipt': receipt, 'p_secret': secret,
            'p_mode': mode, 'p_consent': consent}, role)
        assert result['capabilities'] == disabled
        return request_id, result

    before = None
    try:
        for role in actors:
            status, login = http('/auth/v1/token?grant_type=password', {
                'email': accounts['users'][role]['email'],
                'password': accounts['users'][role]['password']})
            assert status == 200 and login['user']['id'] == actors[role]
            tokens[role] = login['access_token']
        auth_identity_before = sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
        for role in ['customer', 'other_customer']:
            assert sql("select exists(select 1 from auth.users u join public.customers c on c.id=u.id where u.id=" +
                       literal(actors[role]) + " and u.email_confirmed_at is not null and u.deleted_at is null);") == 't'
            assert rate(actor=actors[role]) <= 2, 'Existing rate evidence leaves insufficient QA budget; wait, never reset counters'
        branch = sql("begin;select set_config('request.jwt.claim.sub'," + literal(actors['manager']) + ",true);select branch_id from public.business_branches where is_active and private.can_cashier_branch(branch_id)order by is_default desc limit 1;rollback;").splitlines()[-1]
        uuid.UUID(branch)
        consent = {'accepted': True, 'version': 'offline-claim-v1', 'language': 'en',
                   'text': sql("select private.offline_claim_notice('en');")}
        reg_consent = {'accepted': True, 'version': 'offline-registration-v1', 'language': 'en',
                       'text': sql("select private.offline_registration_notice('en');")}
        disabled = {'history_visible': False, 'wallet_access': False,
                    'guest_redemption': False, 'reader_bridge_implemented': False}
        before = snapshot()
        receipts = []
        for index in range(2):
            phone = '010' + str(uuid.uuid4().int % 100000000).zfill(8)
            assert sql("select not exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key(" + literal(phone) + ",'EG'))and not exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key(" + literal(phone) + ",'EG'));") == 't'
            intake = rpc('register_offline_customer', {
                'p_request': uid(), 'p_branch': branch, 'p_name': tag + '-' + str(index),
                'p_phone': phone, 'p_country': 'EG',
                'p_car': {'plate_number': tag + '-' + str(index)}, 'p_consent': reg_consent}, 'manager')
            assert intake['status'] == 'created_unverified' and len(intake['enrollment_secret']) == 64
            receipts.append((intake['enrollment_receipt_id'], intake['enrollment_secret']))
        for role in ['customer', 'other_customer']:
            claim_id, result = request(*receipts[0], role)
            assert result['status'] == 'pending_owner_review'
            qa_claims.append(claim_id)
        decision = {'p_request': uid(), 'p_claim': qa_claims[0],
                    'p_decision': 'approve_with_secret',
                    'p_reason': 'QA owner independently checked receipt and explicit customer consent'}
        for role in ['customer', 'manager']:
            result = rpc('decide_offline_customer_claim', decision, role, expect=403)
            assert result['code'] == '42501'
        proof['actual_http_customer_manager_approval_denied'] = True
        # Actual HTTP calls each commit their own rejected proof receipts.
        bad_id, wrong = request(receipts[1][0], '0' * 64, 'customer')
        unknown_id, unknown = request(uid(), '0' * 64, 'customer')
        assert wrong['status'] == unknown['status'] == 'verification_failed'
        assert (wrong.keys() == unknown.keys()) and not any(k in wrong for k in ['profile_id', 'email', 'secret_hash'])
        assert sql("select count(*)=2 from private.offline_claim_requests where request_id in(" + literal(bad_id) + ',' + literal(unknown_id) + ")and outcome='verification_failed';") == 't'
        proof['actual_http_generic_failure_receipts_committed'] = True
        while rate(actor=actors['customer']) < 5:
            request(receipts[1][0], '0' * 64, 'customer')
        _, capped = request(*receipts[1], 'customer')
        assert capped['status'] == 'verification_failed'
        while rate(receipt=receipts[1][0]) < 5:
            request(receipts[1][0], '0' * 64, 'customer')
        assert rate(actor=actors['other_customer']) < 5
        _, cross_capped = request(*receipts[1], 'other_customer')
        assert cross_capped['status'] == 'verification_failed'
        proof['http_actor_and_cross_account_receipt_caps'] = True
        # Same active owner, two independent approval transactions (single-owner business).
        def owner_tx(body):
            return "begin;select set_config('request.jwt.claim.sub'," + literal(actors['owner']) + ",true);set local role authenticated;" + body
        def decision_sql(claim):
            return 'public.decide_offline_customer_claim(' + ','.join([
                literal(uid()), literal(claim), "'approve_with_secret'",
                literal('QA original receipt and customer consent independently reviewed')]) + ')'
        first = PsqlSession(command, env, 'qa_offline_claim_approval_first')
        second = PsqlSession(command, env, 'qa_offline_claim_approval_second')
        sessions.extend([first, second])
        lines = first.run(owner_tx('select ' + decision_sql(qa_claims[0]) + ';'))
        first_result = json.loads(next(line for line in reversed(lines) if line.startswith('{')))
        assert first_result['status'] == 'approved_pending_reader_bridge'
        marker = 'QA_CLAIM_SECOND_' + uuid.uuid4().hex
        # Catch expected denial inside second TX so the bounded client reaches its marker.
        second.send(owner_tx("do $$begin perform " + decision_sql(qa_claims[1]) +
                    ";raise exception 'Unexpected second approval';exception when sqlstate '55000'then raise notice 'QA_SECOND_APPROVAL_BLOCKED_55000';end$$;commit;") + '\n\\echo ' + marker)
        blocked = False
        until = time.monotonic() + 10
        while time.monotonic() < until:
            blocked = sql('select exists(select 1 from pg_stat_activity where pid=' + str(second.pid) +
                          " and wait_event_type='Lock'and wait_event='advisory'and " + str(first.pid) + '=any(pg_blocking_pids(pid)));') == 't'
            if blocked:
                break
            time.sleep(.05)
        assert blocked, 'Actual approval advisory contention not observed'
        first.run('commit;')
        second_lines = second.wait(marker)
        assert any('QA_SECOND_APPROVAL_BLOCKED_55000' in line for line in second_lines)
        assert sql('select count(*)=1 from private.offline_customer_trusted_links where claim_id in(' + ','.join(map(literal, qa_claims)) + ');') == 't'
        proof.update(actual_two_session_advisory_wait=True, exactly_one_approved_link=True,
                     second_account_approval_denied=True)
    except Exception:
        # Suppress request/SQL contexts, credentials and raw response objects.
        proof['failure'] = 'Validation failed; sensitive context intentionally redacted'
    finally:
        for session in sessions:
            session.rollback_close()
        if tokens.get('owner') and qa_claims:
            try:
                links = sql('select link_id from private.offline_customer_trusted_links where claim_id in(' + ','.join(map(literal, qa_claims)) + ')and revoked_at is null;')
                for link in filter(None, links.splitlines()):
                    uuid.UUID(link)
                    revoked = rpc('revoke_offline_customer_link', {'p_request': uid(), 'p_link': link,
                                  'p_reason': 'QA verification complete; reviewed evidence link revoked'}, 'owner')
                    assert revoked['status'] == 'revoked'
                proof['qa_links_revoked'] = True
            except Exception:
                proof['qa_links_revoked'] = False
        try:
            if before is not None:
                after = snapshot()
                proof['preexisting_public_private_rows_unchanged'] = not bool(before - after)
                allowed_additions = {'public.business_audit_log', *('private.' + name for name in [
                    'offline_customer_profiles', 'offline_customer_contacts', 'offline_customer_car_refs',
                    'offline_customer_registration_requests', 'offline_customer_enrollment_receipts',
                    'offline_claim_requests', 'offline_claim_decisions', 'offline_customer_trusted_links',
                    'offline_claim_revocations'])}
                added_tables = {row.split('|', 1)[0] for row in (after - before)}
                proof['retained_tagged_qa_only'] = added_tables <= allowed_additions
                proof['no_other_business_or_financial_row_additions'] = added_tables <= allowed_additions
                auth_after = sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
                proof['existing_auth_identity_rows_unchanged'] = auth_after == auth_identity_before
            proof['all_passed'] = all(proof.get(key) is True for key in [
                'actual_http_customer_manager_approval_denied',
                'actual_http_generic_failure_receipts_committed',
                'http_actor_and_cross_account_receipt_caps', 'actual_two_session_advisory_wait',
                'exactly_one_approved_link', 'second_account_approval_denied', 'qa_links_revoked',
                'preexisting_public_private_rows_unchanged', 'existing_auth_identity_rows_unchanged',
                'retained_tagged_qa_only', 'no_other_business_or_financial_row_additions'])
        except Exception:
            proof['all_passed'] = False
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, indent=2) + '\n')
        args.proof.chmod(0o600)
    print('PASS local claim HTTP/approval validation' if proof['all_passed'] else 'FAIL local claim validation; sanitized proof saved')
    if not proof['all_passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
