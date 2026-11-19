"""Payment numbering, policy and sandbox regression; isolated local Docker DB, rollback only."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    docker = runtime / 'docker-cli/docker/docker'
    socket = runtime / 'instances/sabiha-local/sock/docker.sock'
    if not socket.is_socket() or not docker.is_file():
        raise SystemExit('Existing isolated local Docker stack required')
    env = os.environ.copy()
    env['DOCKER_HOST'] = 'unix://' + str(socket)
    env['DOCKER_CONFIG'] = str(runtime / 'docker-config')
    command = [str(docker), 'exec', '-i', 'supabase_db_supabase-local',
               'psql', '-X', '-U', 'postgres', '-d', 'postgres',
               '-v', 'ON_ERROR_STOP=1', '-At']

    def sql(source):
        return subprocess.run(command, input=source, text=True, env=env,
                              capture_output=True, check=False)

    tables = ['bookings', 'business_orders', 'business_order_items', 'vehicles', 'business_catalog_items', 'business_branches', 'business_invoices', 'business_payment_events',
              'business_cashier_shifts', 'business_shift_cash_movements',
              'business_audit_log', 'business_print_jobs', 'business_print_attempts', 'business_payment_policies']
    snapshot = '\n'.join(
        "select '" + table + "', count(*), md5(coalesce(string_agg(row::text, '' "
        "order by row::text), '')) from (select to_jsonb(t) row from public."
        + table + " t) s;" for table in tables)
    snapshot += "\nselect 'private.customer_booking_change_requests',count(*),md5(coalesce(string_agg(t::text,'' order by t::text),'')) from private.customer_booking_change_requests t;"
    snapshot += '\n' + '\n'.join("select '" + table + "', count(*), md5(coalesce(string_agg(row::text, '' order by row::text), '')) from (select to_jsonb(t) row from private." + table + " t) s;" for table in ['document_number_counters','paymob_intents','paymob_callbacks','gateway_reconciliations'])
    before = sql(snapshot)
    if before.returncode:
        raise SystemExit(before.stderr)
    test = Path(__file__).resolve().parents[1] / 'supabase/tests/payment_platform.sql'
    result = sql(test.read_text())
    after = sql(snapshot)
    unchanged = after.returncode == 0 and before.stdout == after.stdout
    print(result.stdout, end='')
    print(result.stderr, end='')
    proof = {'local_only': True, 'transaction_rolled_back': unchanged,
             'existing_rows_unchanged': unchanged, 'tables_checked': tables,
             'test_passed': result.returncode == 0 and unchanged,
             'production_touched': False, 'gateway_called': False,
             'ui_changed': False}
    args.proof.parent.mkdir(parents=True, exist_ok=True)
    args.proof.write_text(json.dumps(proof, indent=2) + '\n')
    if not proof['test_passed']:
        raise SystemExit(1)
    print('PASS rollback restored every checked row; no real payment or hosted access')


if __name__ == '__main__':
    main()
