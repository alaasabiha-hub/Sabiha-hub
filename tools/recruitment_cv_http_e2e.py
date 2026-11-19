"""Synthetic private CV flow on loopback only; retain hidden QA records for audit."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import secrets
import urllib.error
import urllib.parse
import urllib.request
import uuid
from hr_payroll_e2e import sql

R=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime')
settings=json.loads((R/'local-status.json').read_text())
accounts=json.loads((R/'test-accounts-final.json').read_text())
base=accounts['url'].rstrip('/')
assert urllib.parse.urlsplit(base).hostname in ('127.0.0.1','localhost'), 'Loopback only'
anon=settings['ANON_KEY']

def call(path,body=None,token=None,mime='application/json',raw=None,extra=None,allowed=(200,201,204)):
    headers={'apikey':anon,'Authorization':'Bearer '+(token or anon),'Content-Type':mime,**(extra or {})}
    request=urllib.request.Request(base+path,data=raw if raw is not None else json.dumps(body).encode() if body is not None else None,headers=headers)
    try:
        with urllib.request.urlopen(request,timeout=45) as response:
            code=response.status;content=response.read();response_headers=response.headers
    except urllib.error.HTTPError as error:
        code=error.code;content=error.read();response_headers=error.headers
    assert code in allowed, f'Local CV request failed ({code}) at {path.split("?")[0]}'
    return json.loads(content) if 'json' in response_headers.get('Content-Type','') and content else content

def snapshot():
    out,_=sql("""CREATE TEMP TABLE qa_cv_hashes(t text,h text);DO $$ DECLARE t record;v text;BEGIN FOR t IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('public','private') LOOP EXECUTE format('SELECT coalesce(string_agg(md5(row_to_json(r)::text),%L),%L) FROM %I.%I r',',','',t.schemaname,t.tablename) INTO v;INSERT INTO qa_cv_hashes VALUES(t.schemaname||'.'||t.tablename,v);END LOOP;END $$;SELECT t||'|'||h FROM qa_cv_hashes ORDER BY t;""")
    return {line.split('|',1)[0]:Counter(filter(None,line.split('|',1)[1].split(','))) for line in out.splitlines() if '|' in line}

if __name__=='__main__':
    before=snapshot()
    owner=accounts['users']['owner']
    session=call('/auth/v1/token?grant_type=password',{'email':owner['email'],'password':owner['password']})
    jwt=session['access_token']
    def rpc(action,data):return call('/rest/v1/rpc/recruitment_action',{'p_action':action,'p_data':data},token=jwt)
    branch=rpc('owner_read',{})['branches'][0]['id']
    run=secrets.token_hex(6)
    job_data={'request_id':str(uuid.uuid4()),'branch_id':branch,'title_ar':'اختبار مرفق خاص','title_en':'Synthetic private CV QA '+run,'details_ar':'اختبار محلي فقط','details_en':'Local fixture only; no real applicant','published':True}
    job=rpc('save_job',job_data)['job_id']
    try:
        capability=secrets.token_hex(32)
        receipt=call('/rest/v1/rpc/recruitment_action',{'p_action':'submit','p_data':{'request_id':str(uuid.uuid4()),'job_id':job,'name':'Synthetic CV QA '+run,'email':f'cv-{run}@example.invalid','message':'No real personal data','cv_capability_hash':hashlib.sha256(capability.encode()).hexdigest()}})
        app=receipt['application_id']
        pdf=b'%PDF-1.4\n% Synthetic local CV, no personal data\n1 0 obj << /Type /Catalog >> endobj\ntrailer <<>>\n%%EOF\n'
        headers={'x-application-id':app,'x-upload-token':capability}
        call('/functions/v1/recruitment-cv',raw=pdf,mime='image/png',extra=headers,allowed=(415,))
        call('/functions/v1/recruitment-cv',raw=pdf,mime='application/pdf',extra={**headers,'x-upload-token':'f'*64},allowed=(400,))
        result=call('/functions/v1/recruitment-cv',raw=pdf,mime='application/pdf',extra=headers)
        assert result['state']=='quarantined_unscanned' and result['sha256']==hashlib.sha256(pdf).hexdigest()
        assert call('/functions/v1/recruitment-cv',raw=pdf,mime='application/pdf',extra=headers)==result
        object_path=app+'/'+hashlib.sha256(pdf).hexdigest()+'.pdf'
        assert call('/storage/v1/object/list/recruitment-cv-quarantine',{'prefix':app})==[]
        call('/storage/v1/object/public/recruitment-cv-quarantine/'+object_path,allowed=(400,401,403,404))
        call('/functions/v1/recruitment-cv',{'action':'download','application_id':app},allowed=(400,))
        signed=call('/functions/v1/recruitment-cv',{'action':'download','application_id':app},token=jwt)
        assert signed['state']=='quarantined_unscanned' and signed['expires_in']==60
        path=signed['signed_path'];assert path.startswith('/object/sign/recruitment-cv-quarantine/'+app+'/') and 'download=CV-unscanned.pdf' in path
        with urllib.request.urlopen(base+'/storage/v1'+path,timeout=30) as response:
            downloaded=response.read();assert 'attachment' in response.headers.get('Content-Disposition','').lower()
        assert downloaded==pdf
        print('PASS actual local Edge/storage upload + immutable retry + no anonymous read/list + owner 60s attachment download byte equality; unscanned quarantine retained')
    finally:
        rpc('save_job',{**job_data,'id':job,'published':False,'request_id':str(uuid.uuid4())})
    after=snapshot()
    additions={'private.recruitment_jobs','private.recruitment_applications','private.recruitment_requests','private.recruitment_cv'}
    for table,old in before.items():
        assert not(old-after[table]),'Preexisting application row changed in '+table
        if table not in additions:assert old==after[table],'Unexpected application table change '+table
    print('PASS all preexisting public/private rows unchanged; only tagged hidden recruitment QA fixtures added; no real applicant or hosted service')
