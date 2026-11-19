"""Local-only two-session offline intake race; no Auth or financial fixture writes.
Retains private tagged QA intake/audit rows. Never prints/stores enrollment secrets.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--proof', type=Path, required=True)
    p.add_argument('--execute', action='store_true')
    args = p.parse_args()
    if not args.execute:
        print(__doc__)
        return
    r = args.runtime.resolve()
    accounts = json.loads((r/'test-accounts-final.json').read_text())
    assert urllib.parse.urlsplit(accounts['url']).hostname == '127.0.0.1'
    owner = str(uuid.UUID(accounts['users']['owner']['id']))
    socket = r/'instances/sabiha-local/sock/docker.sock'
    assert socket.is_socket()
    env = {**os.environ, 'DOCKER_HOST': 'unix://'+str(socket),
           'DOCKER_CONFIG': str(r/'docker-config')}
    command = [str(r/'docker-cli/docker/docker'), 'exec', '-i',
               'supabase_db_supabase-local', 'psql', '-X', '-q', '-At',
               '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']

    def sql(source):
        value = subprocess.run(command, input=source, text=True, capture_output=True,
                               env=env, timeout=35)
        if value.returncode:
            raise RuntimeError('Local intake SQL failed: '+value.stderr[-1500:])
        return value.stdout.strip()

    def snapshot():
        value = sql("""create temp table qa_hash(t text,h text);do $$declare t record;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private') loop
        execute format('insert into qa_hash select %L,md5(row_to_json(r)::text) from %I.%I r',
        t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end $$;
        select t||'|'||h from qa_hash order by t,h;""")
        return Counter(value.splitlines())

    def auth(body):
        return ("begin;select set_config('request.jwt.claim.sub','"+owner+
                "',true);set local role authenticated;"+body)

    def literal(value):
        return "'"+value.replace("'", "''")+"'"

    tag = uuid.uuid4().hex[:10]
    branch = sql('select branch_id from public.business_branches where is_active and is_default;')
    uuid.UUID(branch)
    phone = '010'+str(uuid.uuid4().int % 100000000).zfill(8)
    assert sql("select exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key('"+phone+"','EG')) or exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key('"+phone+"','EG'));") == 'f'
    car = {'plate_number': 'QA-'+tag, 'brand': 'QA', 'model': 'Intake race'}
    consent = {'accepted': True, 'version': 'offline-registration-v1', 'language': 'en',
               'text': sql("select private.offline_registration_notice('en');")}
    requests = [str(uuid.uuid4()) for _ in range(2)]

    def register(request):
        rpc = ("public.register_offline_customer('"+request+"','"+branch+"',"+
               literal('QA intake '+tag)+','+literal(phone)+",'EG',"+
               literal(json.dumps(car))+"::jsonb,"+literal(json.dumps(consent))+"::jsonb)")
        # Project the secret to a boolean inside PostgreSQL; raw secret never leaves this query.
        return ("select (v-'enrollment_secret')||jsonb_build_object('secret_returned',"
                "coalesce(length(v->>'enrollment_secret')=64,false)) from(select "+rpc+" v) receipt;")

    def result(lines):
        return json.loads(next(line for line in reversed(lines) if line.startswith('{')))

    proof = {'local_only': True, 'production_touched': False, 'auth_accounts_created': 0,
             'financial_writes': 0, 'tag': tag, 'all_passed': False}
    before = snapshot()
    first = second = None
    try:
        first = PsqlSession(command, env, 'qa_offline_intake_first')
        second = PsqlSession(command, env, 'qa_offline_intake_second')
        one = result(first.run(auth(register(requests[0]))))
        assert one['status'] == 'created_unverified' and one['secret_returned']
        marker = 'QA_SECOND_'+uuid.uuid4().hex
        second.send(auth(register(requests[1]))+'commit;\n\\echo '+marker)
        deadline = time.monotonic()+10
        blocked = False
        while time.monotonic() < deadline:
            blocked = sql('select exists(select 1 from pg_stat_activity where pid='+str(second.pid)+
                          " and wait_event_type='Lock' and wait_event='advisory' and "+
                          str(first.pid)+'=any(pg_blocking_pids(pid)));') == 't'
            if blocked:
                break
            time.sleep(.05)
        assert blocked, 'Did not observe actual phone-key lock contention'
        first.run('commit;')
        two = result(second.wait(marker))
        assert two['status'] == 'reused_unverified' and not two['secret_returned']
        assert one['offline_profile_id'] == two['offline_profile_id']
        assert one['car_ref_id'] == two['car_ref_id']
        replay = result(first.run(auth(register(requests[0]))+'commit;'))
        assert not replay['secret_returned'] and replay['offline_profile_id'] == one['offline_profile_id']
        count = sql("select count(*) from private.offline_customer_profiles where profile_id='"+one['offline_profile_id']+"';")
        assert count == '1'
        assert not before-snapshot(), 'A preexisting business row changed'
        proof.update(actual_advisory_wait_observed=True, one_profile_for_concurrent_intake=True,
                     no_second_enrollment_secret=True, exact_retry_no_secret_reissue=True,
                     preexisting_rows_unchanged=True, all_passed=True)
    finally:
        if first:
            first.rollback_close()
        if second:
            second.rollback_close()
        args.proof.parent.mkdir(parents=True, exist_ok=True)
        args.proof.write_text(json.dumps(proof, indent=2)+'\n')
        args.proof.chmod(0o600)
    print('PASS local simultaneous intake: one private profile; no repeated secret or financial writes')


if __name__ == '__main__':
    main()
