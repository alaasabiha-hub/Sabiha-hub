"""PLAN by default. Local received-only walk-in HTTP/real transaction QA.
Creates only tagged QA config/HR/intake/work; refunds every QA cash sale, seals
its shift, ends only newly created QA employment, disables its branch/service.
No new Auth accounts, booking, loyalty award, hosted service or real payment.
Root must approve the plan and release the serial database slot before --execute.
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


def uid(): return str(uuid.uuid4())
def lit(value): return "'" + str(value).replace("'", "''") + "'"


class RedactedFailure(RuntimeError): pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--state', type=Path, help='Private UUID-only QA recovery journal; defaults beside proof')
    parser.add_argument('--reuse-contract-state', type=Path)
    parser.add_argument('--reuse-contract-proof', type=Path)
    parser.add_argument('--worker-roles', nargs=2, choices=['employee', 'other_employee', 'manager'], default=['employee', 'other_employee'])
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print(__doc__)
        return
    r = args.runtime.resolve()
    accounts = json.loads((r / 'test-accounts-final.json').read_text())
    target = urllib.parse.urlsplit(accounts['url'])
    assert target.scheme == 'http' and target.hostname == '127.0.0.1'
    base = accounts['url'].rstrip('/')
    sock = r / 'instances/sabiha-local/sock/docker.sock'
    assert sock.is_socket()
    env = {**os.environ, 'DOCKER_HOST': 'unix://' + str(sock), 'DOCKER_CONFIG': str(r / 'docker-config')}
    command = [str(r / 'docker-cli/docker/docker'), 'exec', '-i', 'supabase_db_supabase-local',
               'psql', '-X', '-q', '-At', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
    actors = {role: str(uuid.UUID(accounts['users'][role]['id']))
              for role in ['owner', 'manager', 'employee', 'other_employee']}
    tokens = {}
    tag = 'walkin-financeqa-' + uuid.uuid4().hex[:10]
    branch, service, shift = uid(), uid(), uid()
    assert len(set(args.worker_roles)) == 2
    staff = sorted(actors[role] for role in args.worker_roles)
    rates = {actors[role]: rate for role, rate in zip(args.worker_roles, [15, 25])}
    created_contracts, commands_created, orders, sessions = [], [], [], []
    branch_created = service_created = shift_opened = False
    registration = None
    before = auth_before = counters_before = None
    borrowed_contracts = []
    borrowed_hashes = None
    assert bool(args.reuse_contract_state) == bool(args.reuse_contract_proof)
    state_path = args.state or args.proof.with_name(args.proof.stem + '-state.json')

    def checkpoint():
        state = {'local_only': True, 'tag': tag, 'actor_ids': actors, 'branch_id': branch,
                 'service_id': service, 'shift_id': shift, 'borrowed_contract_staff_ids': borrowed_contracts, 'borrowed_contract_hashes': borrowed_hashes, 'worker_roles': args.worker_roles, 'selected_worker_ids': staff, 'new_contract_staff_ids': created_contracts,
                 'registration_request_id': registration, 'command_ids': commands_created, 'order_ids': orders, 'branch_created': branch_created,
                 'service_created': service_created, 'shift_opened': shift_opened}
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(state, indent=2) + '\n')
        state_path.chmod(0o600)
    proof = {'local_only': True, 'production_touched': False, 'auth_accounts_created': 0,
             'real_payments': 0, 'tag': tag, 'all_passed': False}

    def sql(text):
        result = subprocess.run(command, input=text, env=env, capture_output=True, text=True, timeout=35)
        if result.returncode: raise RedactedFailure('Local SQL failed; details redacted')
        return result.stdout.strip()

    def call(path, data=None, role='owner', method='POST', prefer='return=representation'):
        headers = {'apikey': accounts['anon_key'], 'Content-Type': 'application/json', 'Prefer': prefer}
        if role in tokens: headers['Authorization'] = 'Bearer ' + tokens[role]
        request = urllib.request.Request(base + path, data=None if data is None else json.dumps(data).encode(),
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw.strip() else None
        except urllib.error.HTTPError as error:
            proof['failed_http_status'] = error.code
            proof['failed_http_endpoint'] = urllib.parse.urlsplit(path).path
            try:
                proof['failed_http_code'] = json.loads(error.read()).get('code')
            except (ValueError, TypeError):
                pass
            raise RedactedFailure('Local HTTP operation failed; body/arguments redacted') from None

    def rpc(name, data, role='owner'): return call('/rest/v1/rpc/' + name, data, role)
    def rows():
        value = sql("""create temp table qa_walkin_hash(t text,h text);do $$declare t record;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop
        execute format('insert into qa_walkin_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;
        select t||'|'||h from qa_walkin_hash order by t,h;""")
        return Counter(value.splitlines())

    def employment(worker, end=None):
        rate = rates[worker]
        return rpc('hr_action', {'p_action': 'employment', 'p_data': {
            'request_id': uid(), 'staff_id': worker, 'salary': 0, 'commission_percent': rate,
            'currency': 'EGP', 'starts_on': today, 'ends_on': end}})

    def auth_tx(body):
        return 'begin;select set_config(\'request.jwt.claim.sub\',' + lit(actors['manager']) + ',true);set local role authenticated;' + body

    def parsed_result(lines): return json.loads(next(line for line in reversed(lines) if line.startswith('{')))
    def prepare():
        request_id = uid()
        commands_created.append(request_id)
        checkpoint()
        rpc('prepare_offline_walk_in', {'p_request': request_id, 'p_registration': registration,
            'p_service': service, 'p_expected_price': 120, 'p_cashier': actors['manager'],
            'p_staff_ids': staff, 'p_notes': tag})
        return request_id

    def place(request_id):
        result = rpc('place_offline_walk_in', {'p_request': request_id}, 'manager')
        orders.append(result['result']['order_id'])
        checkpoint()
        return result['result']

    def ack(request_id): rpc('ack_offline_walk_in_command', {'p_request': request_id}, 'manager')
    def pair():
        first = PsqlSession(command, env, 'qa_walkin_finance_first')
        second = PsqlSession(command, env, 'qa_walkin_finance_second')
        sessions.extend([first, second])
        return first, second

    def blocked_by(second, first):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if sql('select exists(select 1 from pg_stat_activity where pid=' + str(second.pid) +
                   " and wait_event_type='Lock'and " + str(first.pid) + '=any(pg_blocking_pids(pid)));') == 't': return True
            time.sleep(.05)
        return False

    def expected_second(second, expression, code):
        marker = 'QA_WALKIN_' + uuid.uuid4().hex
        second.send(auth_tx('do $$begin perform ' + expression +
                    ";raise exception 'Unexpected concurrent operation success'using errcode='PZ009';exception when sqlstate '" + code +
                    "'then raise notice 'QA_EXPECTED_" + code + "';end$$;commit;") + '\n\\echo ' + marker)
        return marker

    try:
        for role in ['owner', 'manager']:
            login = call('/auth/v1/token?grant_type=password', {'email': accounts['users'][role]['email'],
                         'password': accounts['users'][role]['password']}, role=None)
            assert login['user']['id'] == actors[role]
            tokens[role] = login['access_token']
        today = sql("select(clock_timestamp()at time zone'Africa/Cairo')::date;")
        assert sql("select(clock_timestamp()at time zone'Africa/Cairo')::time between '00:01'and '23:50';") == 't'
        ids = ','.join(map(lit, staff))
        assert sql('select count(*)=2 from public.staff_profiles where user_id in(' + ids + ")and is_active and role in('employee','manager');") == 't'
        assert sql('select not exists(select 1 from public.business_orders where assigned_staff_ids&&array[' + ids + ']::uuid[])and not exists(select 1 from public.bookings where assigned_staff_ids&&array[' + ids + ']::uuid[]);') == 't'
        if args.reuse_contract_state:
            args.reuse_contract_state.resolve().relative_to(r)
            args.reuse_contract_proof.resolve().relative_to(r)
            prior = json.loads(args.reuse_contract_state.read_text())
            prior_proof = json.loads(args.reuse_contract_proof.read_text())
            assert prior['local_only'] and prior_proof['local_only'] and prior['tag'] == prior_proof['tag']
            assert set(prior['new_contract_staff_ids']) == set(staff)
            assert prior['worker_roles'] == args.worker_roles and prior['actor_ids']['owner'] == actors['owner']
            assert not prior['order_ids'] and not prior['command_ids'] and not prior['registration_request_id']
            assert not prior['service_created'] and not prior['shift_opened'] and prior['branch_created']
            assert all(prior_proof.get(key) is True for key in ['new_qa_contracts_ended_on_today',
                'qa_refund_shift_contract_branch_cleanup_complete', 'only_new_invoice_counter_allocations',
                'preexisting_rows_unchanged_except_new_invoice_counter', 'auth_identities_unchanged'])
            assert sql('select exists(select 1 from public.business_branches where branch_id=' + lit(str(uuid.UUID(prior['branch_id']))) + ' and not is_active and temporarily_closed);') == 't'
            for worker in staff:
                assert sql('select exists(select 1 from private.hr_employment where staff_id=' + lit(worker) +
                    ' and salary=0 and commission_percent=' + str(rates[worker]) + " and currency='EGP'and starts_on=" + lit(today) + '::date and ends_on=' + lit(today) + '::date);') == 't'
                assert sql('select exists(select 1 from private.hr_requests where actor=' + lit(actors['owner']) +
                    " and action='employment'and payload->>'staff_id'=" + lit(worker) +
                    " and(payload->>'salary')::numeric=0 and(payload->>'commission_percent')::numeric=" + str(rates[worker]) +
                    " and payload->>'currency'='EGP'and payload->>'starts_on'=" + lit(today) + " and payload->>'ends_on'=" + lit(today) + ');') == 't'
            borrowed_contracts = staff[:]
            borrowed_hashes = json.loads(sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in(' + ids + ');'))
            proof['only_explicit_journal_proven_qa_contracts_reused'] = True
        else:
            assert sql('select not exists(select 1 from private.hr_employment where staff_id in(' + ids + '));') == 't'
        assert sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id=' + lit(actors['manager']) + ' and acknowledged_at is null);') == 't'
        assert sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;') == 't'
        proof['canonical_outbox_initially_empty'] = True
        auth_before = sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
        before = rows()
        counters_before = json.loads(sql("select jsonb_object_agg(kind,last_value)from private.document_number_counters;"))
        checkpoint()
        for worker in ([] if borrowed_contracts else staff):
            created_contracts.append(worker)
            checkpoint()
            employment(worker)
        call('/rest/v1/business_branches', {'branch_id': branch, 'name_ar': tag, 'name_en': tag, 'is_default': False})
        branch_created = True
        checkpoint()
        call('/rest/v1/business_branch_hours?branch_id=eq.' + branch,
             {'opens_at': '00:00', 'closes_at': '23:59'}, method='PATCH')
        call('/rest/v1/staff_branch_access', [{'user_id': actor, 'branch_id': branch}
                                            for actor in sorted(set([actors['manager'], *staff]))])
        call('/rest/v1/business_catalog_items', {'item_id': service, 'branch_id': branch,
             'item_type': 'service', 'name': tag, 'vehicle_type': 'sedan', 'price': 120,
             'duration_minutes': 5, 'resource_key': 'wash', 'is_active': True, 'is_public': True}, prefer='return=minimal')
        service_created = True
        checkpoint()
        phone = '010' + str(uuid.uuid4().int % 100000000).zfill(8)
        assert sql("select not exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key(" + lit(phone) + ",'EG'))and not exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key(" + lit(phone) + ",'EG'));") == 't'
        registration = uid()
        checkpoint()
        intake = rpc('register_offline_customer', {'p_request': registration, 'p_branch': branch,
            'p_name': tag, 'p_phone': phone, 'p_country': 'EG', 'p_car': {'plate_number': tag},
            'p_consent': {'accepted': True, 'version': 'offline-registration-v1', 'language': 'en',
                          'text': sql("select private.offline_registration_notice('en');")}}, 'manager')
        assert intake['status'] == 'created_unverified'
        # Drop enrollment secret immediately; it is not needed for this operation.
        intake.pop('enrollment_secret', None)
        request_id = prepare()
        first, second = pair()
        one = parsed_result(first.run(auth_tx('select public.place_offline_walk_in(' + lit(request_id) + ');')))
        orders.append(one['result']['order_id'])
        checkpoint()
        marker = 'QA_PLACE_' + uuid.uuid4().hex
        second.send(auth_tx('select public.place_offline_walk_in(' + lit(request_id) + ');commit;') + '\n\\echo ' + marker)
        assert blocked_by(second, first)
        first.run('commit;')
        two = parsed_result(second.wait(marker))
        assert one['result']['order_id'] == two['result']['order_id'] and one['result']['invoice_id'] == two['result']['invoice_id']
        proof['same_request_actual_lock_one_order_invoice'] = True
        ack(request_id)
        # Close-first fences actual delayed place; place-first close preserves success.
        request_id = prepare()
        first, second = pair()
        first.run(auth_tx('select public.close_offline_walk_in_command(' + lit(request_id) + ');'))
        marker = expected_second(second, 'public.place_offline_walk_in(' + lit(request_id) + ')', '55000')
        assert blocked_by(second, first)
        first.run('commit;')
        assert any('QA_EXPECTED_55000' in line for line in second.wait(marker))
        ack(request_id)
        proof['close_first_blocks_delayed_place'] = True
        request_id = prepare()
        work = place(request_id)
        assert rpc('close_offline_walk_in_command', {'p_request': request_id}, 'manager')['result']['order_id'] == work['order_id']
        ack(request_id)
        proof['place_first_close_preserves_success'] = True
        rpc('open_cashier_shift', {'p_request': shift, 'p_branch': branch, 'p_opening': 0}, 'manager')
        shift_opened = True
        checkpoint()
        # Cancel owns order/invoice and commits before an attempted sale.
        first, second = pair()
        first.run(auth_tx('select public.cancel_offline_walk_in(' + ','.join(map(lit, [uid(), work['order_id'], tag + ' cancel-first no collection'])) + ');'))
        marker = expected_second(second, 'public.record_shift_payment(' + ','.join(map(lit, [uid(), shift, work['invoice_id'], 'sale', 'cash'])) + ')', 'P0001')
        assert blocked_by(second, first)
        first.run('commit;')
        assert any('QA_EXPECTED_P0001' in line for line in second.wait(marker))
        proof['cancel_first_blocks_sale'] = True
        # Sale owns shift/invoice; cancel must block then fail without automatic refund.
        request_id = prepare()
        work = place(request_id)
        ack(request_id)
        first, second = pair()
        payment_id = uid()
        first.run(auth_tx('select public.record_shift_payment(' + ','.join(map(lit, [payment_id, shift, work['invoice_id'], 'sale', 'cash'])) + ');'))
        marker = expected_second(second, 'public.cancel_offline_walk_in(' + ','.join(map(lit, [uid(), work['order_id'], tag + ' sale-first requires management'])) + ')', '55000')
        assert blocked_by(second, first)
        first.run('commit;')
        assert any('QA_EXPECTED_55000' in line for line in second.wait(marker))
        current = rpc('get_offline_walk_in_command', {'p_request': request_id}, 'manager')
        assert current['result']['payment_status'] == 'paid' and current['result']['collectible_amount'] == 0
        proof['sale_first_blocks_cancel_and_recovery_paid'] = True
    except Exception:
        proof['failure'] = 'Validation failed; sensitive arguments/HTTP/SQL contexts redacted'
    finally:
        for session in sessions: session.rollback_close()
        cleanup = True
        # Independent cleanup steps: one uncertain API result must not skip fencing
        # other owned commands or hiding new QA config. UUID journal supports review.
        for request_id in commands_created:
            try:
                current = rpc('get_offline_walk_in_command', {'p_request': request_id}, 'manager')
                if current['status'] in ('prepared', 'absent'):
                    current = rpc('close_offline_walk_in_command', {'p_request': request_id}, 'manager')
                if current['status'] == 'succeeded':
                    work = current['result']
                    if work['order_id'] not in orders: orders.append(work['order_id'])
                    paid = sql('select exists(select 1 from public.business_payment_events where invoice_id=' + lit(work['invoice_id']) + " and event_type='sale')and not exists(select 1 from public.business_payment_events where invoice_id=" + lit(work['invoice_id']) + " and event_type='refund');") == 't'
                    if paid:
                        rpc('record_shift_payment', {'p_request': uid(), 'p_shift': shift, 'p_invoice': work['invoice_id'], 'p_event': 'refund', 'p_method': 'cash'}, 'manager')
                    elif work['invoice_status'] == 'active':
                        rpc('cancel_offline_walk_in', {'p_request': uid(), 'p_order': work['order_id'], 'p_reason': tag + ' QA finished without work or collection'}, 'manager')
                rpc('ack_offline_walk_in_command', {'p_request': request_id}, 'manager')
            except Exception:
                cleanup = False
        if shift_opened:
            try:
                totals = rpc('cashier_shift_totals', {'p_shift': shift}, 'manager')
                assert totals['expected_cash'] == 0 and totals['cash_payments_net'] == 0
                rpc('close_cashier_shift', {'p_shift': shift, 'p_actual': 0, 'p_reason': tag + ' all QA sales fully refunded; no actual cash'}, 'manager')
                rpc('approve_cashier_shift', {'p_shift': shift})
            except Exception:
                cleanup = False
        for worker in created_contracts:
            try:
                if sql('select exists(select 1 from private.hr_employment where staff_id=' + lit(worker) + ');') == 't': employment(worker, today)
            except Exception:
                cleanup = False
        proof['new_qa_contracts_ended_on_today'] = cleanup
        if borrowed_contracts:
            try:
                proof['borrowed_contracts_untouched'] = borrowed_hashes == json.loads(sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in(' + ','.join(map(lit, borrowed_contracts)) + ');'))
                proof['new_qa_contracts_ended_on_today'] = proof['borrowed_contracts_untouched']
            except Exception:
                proof['borrowed_contracts_untouched'] = False
                cleanup = False
        proof['contracts_may_remain_eligible_until_end_of_today'] = True
        for created, path, payload in [
                (service_created, '/rest/v1/business_catalog_items?item_id=eq.' + service, {'is_active': False, 'is_public': False}),
                (branch_created, '/rest/v1/business_branches?branch_id=eq.' + branch, {'is_active': False, 'temporarily_closed': True})]:
            if created:
                try:
                    call(path, payload, method='PATCH', prefer='return=minimal' if '/business_catalog_items?' in path else 'return=representation')
                except Exception:
                    cleanup = False
        try:
            known_orders = ','.join(map(lit, orders)) or 'null'
            unknown_pending = sql('select exists(select 1 from private.loyalty_visit_outbox q left join public.business_invoices i on i.invoice_id=q.invoice_id where q.processed_at is null and(coalesce(q.order_id,i.order_id)is null or coalesce(q.order_id,i.order_id)not in(' + known_orders + ')));')
            assert unknown_pending == 'f', 'Non-QA pending outbox found; do not drain unrelated jobs'
            drained = 0
            while int(sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')):
                assert drained < 100
                result = json.loads(sql('select public.drain_loyalty_visit_event();'))
                assert result.get('processed') is True and result.get('result') not in ('earned', 'refunded')
                drained += 1
            proof['qa_only_outbox_jobs_drained'] = drained
            proof['canonical_outbox_finally_empty'] = True
        except Exception:
            proof['canonical_outbox_finally_empty'] = False
            cleanup = False
        proof['qa_refund_shift_contract_branch_cleanup_complete'] = cleanup
        try:
            if before is not None:
                after = rows()
                counters_after = json.loads(sql("select jsonb_object_agg(kind,last_value)from private.document_number_counters;"))
                qa_count = int(sql('select count(*)from private.offline_walk_in_subjects where branch_id=' + lit(branch) + ';'))
                proof['only_new_invoice_counter_allocations'] = counters_after['BKG'] == counters_before['BKG'] and counters_after['INV'] - counters_before['INV'] == qa_count
                permitted = {'public.business_branches', 'public.business_branch_hours', 'public.business_branch_resources',
                    'public.staff_branch_access', 'public.business_catalog_items', 'public.business_audit_log',
                    'public.business_orders', 'public.business_order_items', 'public.business_invoices',
                    'public.business_cashier_shifts', 'public.business_payment_events', 'private.hr_employment',
                    'private.hr_requests', 'private.offline_customer_profiles', 'private.offline_customer_contacts',
                    'private.offline_customer_car_refs', 'private.offline_customer_registration_requests',
                    'private.offline_customer_enrollment_receipts', 'private.offline_walk_in_commands',
                    'private.offline_walk_in_subjects', 'private.offline_walk_in_commissions',
                    'private.offline_walk_in_reception', 'private.offline_walk_in_events', 'private.loyalty_visit_outbox'}
                # Existing numbering counter legitimately advances for NEW issued documents only.
                missing = before - after
                proof['preexisting_rows_unchanged_except_new_invoice_counter'] = all(row.startswith('private.document_number_counters|') for row in missing)
                proof['only_expected_addition_tables'] = {row.split('|', 1)[0] for row in after - before} <= (permitted | {'private.document_number_counters'})
                proof['auth_identities_unchanged'] = auth_before == sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
                if orders:
                    proof['qa_work_refunded_or_void_no_forced_paid_cancellation'] = sql('select not exists(select 1 from private.offline_walk_in_subjects ws join public.business_invoices i on i.invoice_id=ws.invoice_id where ws.branch_id=' + lit(branch) + " and i.status not in('void','refunded'));") == 't'
                    ids = ','.join(map(lit, orders))
                    proof['no_booking_auth_customer_or_loyalty_bridge'] = sql('select not exists(select 1 from public.business_orders where order_id in(' + ids + ')and(customer_id is not null or booking_id is not null))and not exists(select 1 from private.canonical_loyalty_visits where order_id in(' + ids + '))and not exists(select 1 from public.business_loyalty_transactions where order_id in(' + ids + '));') == 't'
            keys = ['same_request_actual_lock_one_order_invoice', 'close_first_blocks_delayed_place',
                'place_first_close_preserves_success', 'cancel_first_blocks_sale', 'sale_first_blocks_cancel_and_recovery_paid',
                'qa_refund_shift_contract_branch_cleanup_complete', 'preexisting_rows_unchanged_except_new_invoice_counter',
                'only_expected_addition_tables', 'auth_identities_unchanged', 'no_booking_auth_customer_or_loyalty_bridge',
                'only_new_invoice_counter_allocations', 'new_qa_contracts_ended_on_today', 'qa_work_refunded_or_void_no_forced_paid_cancellation',
                'canonical_outbox_initially_empty', 'canonical_outbox_finally_empty']
            if borrowed_contracts: keys.extend(['borrowed_contracts_untouched', 'only_explicit_journal_proven_qa_contracts_reused'])
            proof['all_passed'] = all(proof.get(key) is True for key in keys)
        except Exception:
            proof['all_passed'] = False
        checkpoint()
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, indent=2) + '\n')
        args.proof.chmod(0o600)
    print('PASS local financial walk-in QA' if proof['all_passed'] else 'FAIL local financial walk-in QA; sanitized proof saved')
    if not proof['all_passed']: raise SystemExit(1)


if __name__ == '__main__': main()
