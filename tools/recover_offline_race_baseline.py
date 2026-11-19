"""Recover the LOST test-hash baseline from a named encrypted pre-test backup.
Creates a NEW unserved local restore database; never overwrites/deletes a DB.
Plaintext stays in memory; no application tests or old races are rerun.
"""
from pathlib import Path
from types import SimpleNamespace
import io,json,hashlib,subprocess,tarfile,uuid
from local_backup import unseal
from service_work_kernel_concurrency import WorkQA

def main():
 r=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime');q=WorkQA(SimpleNamespace(runtime=r,state=r/'unused',proof=r/'unused'))
 backup=r.parent/'backups/before-offline-loyalty-races-20261115/sabiha-local-20261114T224149Z-7b45a6.enc';keyfile=r/'keys/backup-key.local.bin';assert keyfile.stat().st_mode&0o777==0o600
 raw=unseal(backup.read_bytes(),keyfile.read_bytes())
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz')as archive:
  m=json.load(archive.extractfile('manifest.json'));dump=archive.extractfile('database.dump').read();assert hashlib.sha256(dump).hexdigest()==m['database_sha256']
  assert all(hashlib.sha256(archive.extractfile(x['archive']).read()).hexdigest()==x['sha256']for x in m['storage'])
 journal=r/'offline-loyalty-restored-baseline.json';assert not journal.exists(),'Resolve existing restore journal; never duplicate a restore silently'
 target='qa_offline_baseline_'+uuid.uuid4().hex[:12];journal.write_text(json.dumps({'local_only':True,'restore_database':target,'source_backup':backup.name,'stage':'before_create'})+'\n');journal.chmod(0o600)
 docker=[str(r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local']
 def run(args,data=None):
  out=subprocess.run(docker+args,env=q.env,input=data,capture_output=True)
  if out.returncode:raise RuntimeError('Fresh isolated restore step failed; private restore journal retained')
  return out.stdout
 run(['createdb','-U','supabase_admin','-T','template0',target]);run(['psql','-X','-U','supabase_admin','-d',target,'-v','ON_ERROR_STOP=1','-c','drop schema public;']);run(['pg_restore','-U','supabase_admin','--exit-on-error','-d',target],dump)
 old_command=q.command.copy();q.command[q.command.index('-d')+1]=target
 baseline=q.rows();counters=json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));auth=q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
 q.command=old_command;missing=baseline-q.rows();current_counters=json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
 proof={'local_only':True,'production_touched':False,'restore_database':target,'source_backup':backup.name,'stage':'baseline_recovered','restore_verified_for_database_hash_comparison':True,'archived_storage_checksums_verified':len(m['storage']),'restored_storage_service_tested':False,'before_rows':dict(baseline),'before_counters':counters,'before_auth':auth,'old_rows_unchanged':not bool(missing),'auth_users_unchanged':auth==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;"),'exact_invoice_numbers':current_counters['INV']==counters['INV']+3 and current_counters['BKG']==counters['BKG']}
 journal.write_text(json.dumps(proof,indent=2)+'\n');assert proof['old_rows_unchanged']and proof['auth_users_unchanged']and proof['exact_invoice_numbers']
 print(json.dumps({k:v for k,v in proof.items()if k not in ['before_rows','before_counters','before_auth']}))
if __name__=='__main__':main()
