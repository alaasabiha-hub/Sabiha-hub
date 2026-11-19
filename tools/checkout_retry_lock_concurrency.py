"""Real two-session checkout lock regression against the existing isolated Docker DB.

Run only after all prepared checkout migrations have been applied locally. No
hosted HTTP, gateway, new dependencies, deletes or application changes. A tagged
QA product remains inactive and its draft remains rejected for audit. Placement
and replay effects are rolled back in both concurrent psql sessions.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import urllib.parse
import uuid


class PsqlSession:
    def __init__(self, command, env, name):
        self.name = name
        self.proc = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1)
        self.lines = queue.Queue()
        self.transcript = []

        def read():
            for line in self.proc.stdout:
                self.lines.put(line.rstrip())
            self.lines.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.send("set application_name='" + name + "';set statement_timeout='25s';set lock_timeout='20s';")
        ready = self.run('select pg_backend_pid();')
        self.pid = int(next(line for line in ready if line.isdecimal()))

    def send(self, sql):
        if self.proc.poll() is not None:
            raise RuntimeError(self.name + ' exited: ' + '\n'.join(self.transcript[-20:]))
        self.proc.stdin.write(sql + '\n')
        self.proc.stdin.flush()

    def wait(self, marker, timeout=35):
        observed = []
        until = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.01, until-time.monotonic()))
            except queue.Empty:
                raise TimeoutError(self.name + ' did not reach ' + marker)
            if line is None:
                self.proc.wait(timeout=5)
                raise RuntimeError(self.name + ' SQL failed: ' + '\n'.join(self.transcript[-25:]))
            self.transcript.append(line)
            if line == marker:
                return observed
            observed.append(line)

    def run(self, sql, timeout=35):
        marker = 'QA_DONE_' + uuid.uuid4().hex
        self.send(sql + '\n\\echo ' + marker)
        return self.wait(marker, timeout)

    def rollback_close(self):
        if self.proc.poll() is None:
            try:
                self.send('rollback;\n\\q')
                self.proc.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    socket = runtime/'instances/sabiha-local/sock/docker.sock'
    docker = runtime/'docker-cli/docker/docker'
    if not socket.is_socket() or not docker.is_file():
        raise SystemExit('Existing isolated local Docker socket and CLI required')
    accounts = json.loads((runtime/'test-accounts-final.json').read_text())
    if urllib.parse.urlsplit(accounts['url']).hostname != '127.0.0.1':
        raise SystemExit('Only the retained local QA account configuration is accepted')
    env = {**os.environ, 'DOCKER_HOST': 'unix://'+str(socket),
           'DOCKER_CONFIG': str(runtime/'docker-config')}
    command = [str(docker), 'exec', '-i', 'supabase_db_supabase-local', 'psql',
               '-X', '-q', '-At', '-U', 'postgres', '-d', 'postgres',
               '-v', 'ON_ERROR_STOP=1']

    def sql(source, timeout=35):
        result = subprocess.run(command, input=source, env=env, text=True,
                                capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout.strip()

    def authenticated(customer, body):
        return ("select set_config('request.jwt.claim.sub','"+customer+"',true);"
                "set local role authenticated;"+body)

    tag = uuid.uuid4().hex[:12]
    product = str(uuid.uuid4())
    request = str(uuid.uuid4())
    customer = None
    sessions = []
    fixture_attempted = False
    draft_attempted = False
    proof = {'local_only': True, 'production_touched': False, 'gateway_called': False,
             'tag': tag, 'request_id': request, 'product_id': product,
             'concurrent_wait_observed': False, 'test_passed': False}
    try:
        definition = sql("select pg_get_functiondef('private.prepare_checkout_retry(uuid,jsonb)'::regprocedure);")
        if 'for no key update' not in definition.lower():
            raise RuntimeError('Apply the prepared FOR NO KEY UPDATE hardening before running this regression')
        for role in ['customer', 'other_customer']:
            candidate = str(uuid.UUID(accounts['users'][role]['id']))
            available = sql("select exists(select 1 from public.customers c where c.id='"+candidate+"' "
                            "and not exists(select 1 from public.staff_profiles s where s.user_id=c.id) "
                            "and not exists(select 1 from private.customer_checkout_retries r where r.customer_id=c.id "
                            "and (r.state='open' or (r.state='succeeded' and r.acknowledged_at is null))));")
            if available == 't':
                customer = candidate
                break
        if customer is None:
            raise RuntimeError('Resolve retained QA customer checkout drafts before this isolated regression')
        branch = str(uuid.UUID(sql("select branch_id from public.business_branches where is_default and is_active and not temporarily_closed;")))
        payload = {'p_items': [{'item_id': product, 'quantity': 2}],
                   'p_request_id': request, 'p_method': 'pickup', 'p_zone': None,
                   'p_address': None, 'p_phone': None, 'p_note': 'QA concurrent lock '+tag,
                   'p_coupon': '', 'p_expected_total': 26}
        # UUIDs and generated ASCII tags only; the payload contains no address or phone.
        encoded = json.dumps(payload, separators=(',', ':'))
        prepare = "select public.prepare_checkout_retry('"+request+"',$qa$"+encoded+"$qa$::jsonb);"
        place = ("select public.place_product_fulfillment($qa$"+json.dumps(payload['p_items'])+
                 "$qa$::jsonb,'"+request+"','pickup',null,null,null,'"+payload['p_note']+"','',26);")
        fixture_attempted = True
        sql("begin;insert into public.business_catalog_items(item_id,branch_id,item_type,name,price,stock_quantity,is_active,is_public) "
            "values('"+product+"','"+branch+"','product','QA concurrent checkout "+tag+"',13,4,true,true);commit;")
        draft_attempted = True
        sql('begin;'+authenticated(customer, prepare)+'commit;')
        a = PsqlSession(command, env, 'qa_checkout_A_'+tag)
        sessions.append(a)
        b = PsqlSession(command, env, 'qa_checkout_B_'+tag)
        sessions.append(b)
        a.run('begin;'+authenticated(customer,
              "select pg_advisory_xact_lock(hashtextextended('"+customer+request+"',0));"))
        b_marker = 'QA_PREPARE_RETURNED_'+tag
        b.send('begin;'+authenticated(customer, prepare)+'\n\\echo '+b_marker)
        # Observe the real database wait, not a fixed sleep or mirrored algorithm.
        until = time.monotonic()+18
        while time.monotonic() < until:
            waiting = sql("select exists(select 1 from pg_stat_activity where pid="+str(b.pid)+
                          " and wait_event_type='Lock' and wait_event='advisory' and "+
                          str(a.pid)+"=any(pg_blocking_pids(pid)));")
            if waiting == 't':
                proof['concurrent_wait_observed'] = True
                break
            if b.proc.poll() is not None:
                raise RuntimeError('Session B exited before the expected advisory wait')
            time.sleep(0.05)
        if not proof['concurrent_wait_observed']:
            raise RuntimeError('Did not observe B waiting behind A on the real request advisory lock')
        # B now holds the customer row lock. A must still acquire FK KEY SHARE.
        a.run(place)
        a.run(place)  # Exact replay: no second order or second reservation.
        a.run("reset role;do $$begin "
              "assert (select count(*) from public.business_orders where customer_id='"+customer+
              "' and customer_request_id='"+request+"')=1,'Duplicate order';"
              "assert (select stock_quantity from public.business_catalog_items where item_id='"+product+
              "')=2,'Duplicate stock reservation';end $$;")
        proof['single_order_and_reservation_inside_A'] = True
        proof['deadlock_free'] = True
        a.run('rollback;')
        b.wait(b_marker)
        b.run('rollback;')
        baseline = sql("select json_build_object('orders',(select count(*) from public.business_orders where "
                       "customer_id='"+customer+"' and customer_request_id='"+request+"'),"
                       "'stock',(select stock_quantity from public.business_catalog_items where item_id='"+product+"'));")
        state = json.loads(baseline)
        if state != {'orders': 0, 'stock': 4}:
            raise AssertionError('Concurrent rollback did not restore the exact fixture stock/order state')
        proof['both_transactions_rolled_back'] = True
        proof['no_committed_order_or_stock_double_effect'] = True
        proof['test_passed'] = True
    except Exception as error:
        proof['error'] = str(error)
    finally:
        # Release A first so B can finish its blocked statement before rollback.
        for session in sessions:
            session.rollback_close()
        cleanup_errors = []
        if draft_attempted:
            try:
                current = sql('begin;'+authenticated(customer,
                              "select public.get_checkout_retry('"+request+"');")+'rollback;')
                if '"state": "absent"' in current or '"state":"absent"' in current:
                    proof['retained_draft_absent'] = True
                else:
                    closed = sql('begin;'+authenticated(customer,
                                 "select public.reject_checkout_retry('"+request+"');")+'commit;')
                    if '"state": "rejected"' not in closed and '"state":"rejected"' not in closed:
                        raise RuntimeError('QA retry did not close as rejected')
                    proof['retained_draft_rejected'] = True
            except Exception as error:
                cleanup_errors.append(str(error))
        if fixture_attempted:
            try:
                sql("update public.business_catalog_items set is_active=false,is_public=false where item_id='"+product+"';")
                proof['retained_product_deactivated'] = True
            except Exception as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            proof['cleanup_errors'] = cleanup_errors
            proof['test_passed'] = False
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, indent=2)+'\n')
    if not proof['test_passed']:
        raise SystemExit('FAIL: '+str(proof.get('error', proof.get('cleanup_errors'))))
    print('PASS real concurrent prepare/place wait: no deadlock, one reservation, both rollbacks; QA fixture retained inactive/rejected')


if __name__ == '__main__':
    main()
