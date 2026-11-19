"""Encrypted LOCAL Supabase DB/Storage backup and isolated restore drill.
Never accepts a hosted endpoint or restores over an existing database.
"""
import argparse,base64,hashlib,io,json,os,secrets,subprocess,tarfile,time,urllib.request,urllib.parse
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

TABLES=['customers','vehicles','staff_profiles','bookings','business_orders','business_invoices','business_catalog_items','business_branches','customer_complaints','employee_service_reviews','business_cashier_shifts','business_payment_events','vehicle_inspections','vehicle_inspection_media','business_printers','business_print_jobs','business_print_attempts','completed_service_reviews']
def seal(data,key):
    nonce=secrets.token_bytes(12)
    return b'SABIHA-BACKUP-1\n'+nonce+AESGCM(key).encrypt(nonce,data,b'Sabiha Hub local backup v1')
def unseal(data,key):
    magic=b'SABIHA-BACKUP-1\n'
    if not data.startswith(magic):raise ValueError('Unsupported backup format')
    nonce=data[len(magic):len(magic)+12]
    return AESGCM(key).decrypt(nonce,data[len(magic)+12:],b'Sabiha Hub local backup v1')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--status',type=Path,required=True);p.add_argument('--backup-dir',type=Path,required=True);p.add_argument('--key-file',type=Path,required=True);p.add_argument('--docker',required=True);p.add_argument('--restore-test',action='store_true');a=p.parse_args()
    status=json.loads(a.status.read_text());base=status['API_URL'];service=status['SERVICE_ROLE_KEY']
    if urllib.parse.urlsplit(base).hostname!='127.0.0.1' or not os.environ.get('DOCKER_HOST','').startswith('unix://'):raise SystemExit('Only the isolated local stack is supported')
    container='supabase_db_supabase-local'
    a.backup_dir.mkdir(parents=True,exist_ok=True);os.chmod(a.backup_dir,0o700)
    if a.key_file.resolve().is_relative_to(a.backup_dir.resolve()):raise SystemExit('Keep the key outside the backup directory')
    a.key_file.parent.mkdir(parents=True,exist_ok=True)
    if not a.key_file.exists():
        fd=os.open(a.key_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as f:f.write(secrets.token_bytes(32))
    if a.key_file.stat().st_mode&0o077:raise SystemExit('Encryption key must have private 0600 permissions')
    key=a.key_file.read_bytes()
    if len(key)!=32:raise SystemExit('Invalid encryption key')
    def docker(args,data=None):
        result=subprocess.run([a.docker,'exec','-i',container,*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
        if result.returncode:raise RuntimeError('Local container command failed: '+result.stderr.decode(errors='replace')[-1500:])
        return result.stdout
    def http(path,payload=None,raw_response=False):
        request=urllib.request.Request(base+'/storage/v1/'+path,data=json.dumps(payload).encode() if payload is not None else None,headers={'apikey':service,'Authorization':'Bearer '+service,'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=30) as response:
            raw=response.read();return raw if raw_response else json.loads(raw) if 'json' in response.headers.get('Content-Type','') else raw
    start=time.monotonic();dump=docker(['pg_dump','-U','postgres','-Fc','-n','public','-n','private','-n','auth','-n','storage','postgres'])
    manifest={'format':1,'created_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'database_sha256':hashlib.sha256(dump).hexdigest(),'storage':[],'buckets':http('bucket')}
    buffer=io.BytesIO()
    def add(archive,name,data):
        info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o600;archive.addfile(info,io.BytesIO(data))
    total=len(dump)
    with tarfile.open(fileobj=buffer,mode='w:gz') as archive:
        add(archive,'database.dump',dump)
        def collect(bucket,prefix=''):
            nonlocal total
            offset=0
            while True:
                entries=http('object/list/'+urllib.parse.quote(bucket,safe=''),{'prefix':prefix,'limit':100,'offset':offset,'sortBy':{'column':'name','order':'asc'}})
                for entry in entries:
                    name=prefix+('/' if prefix else '')+entry['name']
                    if not entry.get('id'):collect(bucket,name);continue
                    content=http('object/authenticated/'+urllib.parse.quote(bucket,safe='')+'/'+urllib.parse.quote(name,safe='/'),raw_response=True)
                    total+=len(content)
                    if total>512*1024*1024:raise RuntimeError('Local backup exceeds the 512MB memory limit')
                    item={'bucket':bucket,'name':name,'sha256':hashlib.sha256(content).hexdigest(),'size':len(content),'archive':'objects/'+str(len(manifest['storage']))}
                    manifest['storage'].append(item);add(archive,item['archive'],content)
                if len(entries)<100:break
                offset+=100
        for bucket in manifest['buckets']:collect(bucket['id'])
        add(archive,'manifest.json',json.dumps(manifest,ensure_ascii=False).encode())
    encrypted=seal(buffer.getvalue(),key);output=a.backup_dir/('sabiha-local-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+secrets.token_hex(3)+'.enc')
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as f:f.write(encrypted)
    report={'encrypted_file':output.name,'encrypted_bytes':len(encrypted),'storage_objects':len(manifest['storage']),'backup_seconds':round(time.monotonic()-start,2),'restore_verified':False}
    # Check authentication as well as confidentiality before considering the archive valid.
    corrupted=bytearray(encrypted);corrupted[-1]^=1
    try:unseal(bytes(corrupted),key);raise AssertionError('Tamper check failed')
    except __import__('cryptography.exceptions',fromlist=['InvalidTag']).InvalidTag:pass
    restore_error=None
    try:
        if a.restore_test:
            restore_start=time.monotonic();restored=unseal(output.read_bytes(),key)
            with tarfile.open(fileobj=io.BytesIO(restored),mode='r:gz') as archive:
                saved=json.load(archive.extractfile('manifest.json'));db=archive.extractfile('database.dump').read()
                assert hashlib.sha256(db).hexdigest()==saved['database_sha256']
                for item in saved['storage']:assert hashlib.sha256(archive.extractfile(item['archive']).read()).hexdigest()==item['sha256']
            target='restore_sabiha_'+secrets.token_hex(6)
            # createdb fails if the database exists; there is no overwrite/drop path.
            docker(['createdb','-U','supabase_admin','-T','template0',target])
            docker(['psql','-U','supabase_admin','-d',target,'-v','ON_ERROR_STOP=1','-c','drop schema public;'])
            docker(['pg_restore','-U','supabase_admin','--exit-on-error','-d',target],db)
            counts={}
            for table in TABLES:
                counts[table]=int(docker(['psql','-U','supabase_admin','-d',target,'-Atc','select count(*) from public.'+table]).decode().strip())
            metadata=json.loads(docker(['psql','-U','supabase_admin','-d',target,'-Atc',"select coalesce(json_agg(json_build_object('bucket',bucket_id,'name',name)),'[]') from storage.objects"]).decode())
            assert {(i['bucket'],i['name']) for i in saved['storage']}=={(i['bucket'],i['name']) for i in metadata},'DB/Storage snapshot mismatch'
            report.update({'restore_verified':True,'restore_database':target,'restore_seconds':round(time.monotonic()-restore_start,2),'row_counts':counts,'storage_checksums_verified':True,'tamper_rejected':True})
    except Exception as exc:
        restore_error=exc
        report.update({'restore_verified':False,'restore_error_type':type(exc).__name__})
    result=a.backup_dir/(output.stem+'.report.json');result.write_text(json.dumps(report,indent=2));os.chmod(result,0o600)
    print(json.dumps(report))
    if restore_error:raise SystemExit('Restore verification failed; backup retained and failure report written.')
if __name__=='__main__':main()
