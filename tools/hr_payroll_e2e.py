"""Local-only rollback acceptance test, never calls hosted Supabase."""
import hashlib
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime')
DOCKER = str(RUNTIME / 'docker-cli/docker/docker')
ENV = {**os.environ, 'DOCKER_HOST': f'unix://{RUNTIME}/instances/sabiha-local/sock/docker.sock', 'DOCKER_CONFIG': str(RUNTIME / 'docker-config')}

def sql(source):
    p = subprocess.run([DOCKER, 'exec', '-i', 'supabase_db_supabase-local', 'psql', '-X', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At'], input=source, text=True, capture_output=True, env=ENV, timeout=60)
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return p.stdout, p.stderr

def fingerprint():
    # Stable rows in every public/private application table, including legacy payroll if present.
    result, _ = sql("""
CREATE TEMP TABLE hr_fingerprints(name text, fingerprint text);
DO $$ DECLARE t record;v text;BEGIN
 FOR t IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('public','private') ORDER BY schemaname,tablename LOOP
 EXECUTE format('SELECT count(*)::text||%L||md5(coalesce(string_agg(row_data,CHR(10) ORDER BY row_data),%L)) FROM (SELECT row_to_json(r)::text row_data FROM %I.%I r) x', ':', '',t.schemaname,t.tablename) INTO v;
 INSERT INTO hr_fingerprints VALUES(t.schemaname||'.'||t.tablename,v);
 END LOOP;
END $$;
SELECT name||':'||fingerprint FROM hr_fingerprints ORDER BY name;
""")
    return hashlib.sha256(result.encode()).hexdigest()


if __name__ == '__main__':
    before = fingerprint()
    output, notices = sql((ROOT / 'supabase/tests/hr_payroll.sql').read_text())
    after = fingerprint()
    assert before == after, 'Existing application data changed'
    print(output + notices)
    print('PASS public/private table counts and contents unchanged:', after)
