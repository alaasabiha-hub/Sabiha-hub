"""SOURCE-PREPARED: local owner-command nonce races; --execute only after root apply.
Retains ONE tagged intake/claim and recovery metadata; new QA evidence link is always
revoked in finally. No Auth/user/profile changes, finance, reader or wallet access.
No raw enrollment secret leaves PostgreSQL. No old acceptance cases are repeated.
"""
import argparse
from collections import Counter
import json,os,subprocess,time,urllib.parse,uuid
from pathlib import Path
from checkout_retry_lock_concurrency import PsqlSession


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--runtime',type=Path,required=True);ap.add_argument('--proof',type=Path,required=True);ap.add_argument('--customer-role',choices=['customer','other_customer'],default='customer');ap.add_argument('--execute',action='store_true');a=ap.parse_args()
    if not a.execute:print(__doc__);return
    r=a.runtime.resolve();accounts=json.loads((r/'test-accounts-final.json').read_text());assert urllib.parse.urlsplit(accounts['url']).hostname=='127.0.0.1'
    owner=str(uuid.UUID(accounts['users']['owner']['id']));customer=str(uuid.UUID(accounts['users'][a.customer_role]['id']));socket=r/'instances/sabiha-local/sock/docker.sock';assert socket.is_socket()
    env={**os.environ,'DOCKER_HOST':'unix://'+str(socket),'DOCKER_CONFIG':str(r/'docker-config')};cmd=[str(r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
    def uid():return str(uuid.uuid4())
    def lit(v):return "'"+str(v).replace("'","''")+"'"
    def sql(body):
        p=subprocess.run(cmd,input=body,text=True,capture_output=True,env=env,timeout=35)
        if p.returncode:raise RuntimeError('Local owner-command query/assertion failed; SQL details redacted')
        return p.stdout.strip()
    def value(text):return json.loads(next(x for x in reversed(text.splitlines()) if x.startswith('{')))
    def auth(body):return "begin;select set_config('request.jwt.claim.sub','"+owner+"',true);set local role authenticated;"+body
    def run(body):return value(sql(auth(body)+'commit;'))
    def snapshot():
        out=sql("""create temp table qa_hash(t text,h text);do $$declare t record;begin for t in select schemaname,tablename from pg_tables where schemaname in('public','private')or(schemaname='auth'and tablename='users')loop execute format('insert into qa_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;select t||'|'||h from qa_hash order by t,h;""")
        return Counter(out.splitlines())
    def protected():return sql("select json_build_object('auth',(select count(*)from auth.users),'customers',(select count(*)from public.customers),'vehicles',(select count(*)from public.vehicles),'bookings',(select count(*)from public.bookings),'orders',(select count(*)from public.business_orders),'invoices',(select count(*)from public.business_invoices),'payments',(select count(*)from public.business_payment_events),'visits',(select count(*)from private.canonical_loyalty_visits));")
    def wait(waiter,blocker):
        until=time.monotonic()+10
        while time.monotonic()<until:
            if sql('select exists(select 1 from pg_stat_activity where pid='+str(waiter.pid)+" and wait_event_type='Lock'and wait_event='advisory'and "+str(blocker.pid)+'=any(pg_blocking_pids(pid)));')=='t':return
            if waiter.proc.poll()is not None:raise AssertionError('Waiter exited before observed nonce contention')
            time.sleep(.05)
        raise AssertionError('Actual global owner nonce advisory wait not observed')
    def result(lines):return value('\n'.join(lines))
    def close(req):return 'select public.close_offline_claim_command('+lit(req)+');'
    def prepare(req,kind,payload):return 'select public.prepare_offline_claim_command('+lit(req)+','+lit(kind)+','+lit(json.dumps(payload))+"::jsonb);"
    def decide(req,reason):return 'select public.decide_offline_customer_claim('+lit(req)+','+lit(claim)+",'hold',"+lit(reason)+');'
    def revoke(req,reason):return 'select public.revoke_offline_customer_link('+lit(req)+','+lit(link)+','+lit(reason)+');'
    def rejected(body,code):return "do $$declare denied boolean:=false;begin begin perform "+body.removeprefix('select ').removesuffix(';')+";exception when sqlstate '"+code+"'then denied:=true;end;assert denied,'Expected owner command fence';end$$;select '{\"rejected\":true}'::jsonb;"
    tag=uid()[:8];branch=sql('select branch_id from public.business_branches where is_default and is_active;');uuid.UUID(branch)
    assert sql("select exists(select 1 from auth.users where id='"+customer+"'and email_confirmed_at is not null and deleted_at is null and(banned_until is null or banned_until<clock_timestamp()));")=='t'
    assert sql("select count(*)from private.offline_customer_trusted_links where auth_user_id='"+customer+"'and revoked_at is null;")=='0','Never alter an existing active evidence link'
    assert sql("select count(*)filter(where created_at>clock_timestamp()-interval '1 hour')<5 and count(*)<20 from private.offline_claim_requests where actor_id='"+customer+"'and created_at>clock_timestamp()-interval '1 day';")=='t','Wait for real claim budget; never reset it'
    phone='010'+str(uuid.uuid4().int%100000000).zfill(8)
    assert sql("select not exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key('"+phone+"','EG'))and not exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key('"+phone+"','EG'));")=='t'
    registration=uid();claim=uid();link=None;cleanup=uid();sessions=[];before=snapshot();protected_before=protected()
    proof={'local_only':True,'production_touched':False,'auth_accounts_created':0,'financial_writes':0,'tag':tag,'customer_role':a.customer_role,'all_passed':False}
    try:
        # Secret is used only in a PostgreSQL local variable, never projected/logged.
        sql("begin;do $$declare intake jsonb;claim_result jsonb;registration_consent jsonb:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));claim_consent jsonb:=jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en'));begin perform set_config('request.jwt.claim.sub','"+owner+"',true);execute 'set local role authenticated';intake:=public.register_offline_customer('"+registration+"','"+branch+"','QA owner command "+tag+"','"+phone+"','EG',jsonb_build_object('plate_number','QA-OWNCMD-"+tag+"'),registration_consent);assert intake->>'status'='created_unverified';perform set_config('request.jwt.claim.sub','"+customer+"',true);claim_result:=public.request_offline_customer_claim('"+claim+"',(intake->>'enrollment_receipt_id')::uuid,intake->>'enrollment_secret','original_receipt',claim_consent);assert claim_result->>'status'='pending_owner_review';end$$;commit;")
        one=PsqlSession(cmd,env,'qa_owner_command_first_'+tag);sessions.append(one);two=PsqlSession(cmd,env,'qa_owner_command_waiter_'+tag);sessions.append(two)
        # Close-first fences both a delayed prepare and an unprepared legacy actual call.
        req=uid();closed=result(one.run(auth(close(req))));marker='QA_OWNER_CLOSE_'+tag
        payload={'p_claim':claim,'p_decision':'hold','p_reason':'Delayed command must remain fenced','p_evidence_type':None}
        two.send(auth(prepare(req,'decide',payload)+rejected(decide(req,payload['p_reason']),'55000'))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');assert result(two.wait(marker))['rejected'];assert run(close(req))==closed
        proof['close_wins_prepare_and_actual_fenced']=True
        # Actual decide wins, and close returns that original business receipt.
        req=uid();reason='Actual prepared owner hold review';payload={'p_claim':claim,'p_decision':'hold','p_reason':reason,'p_evidence_type':None}
        receipt=result(one.run(auth(prepare(req,'decide',payload)+decide(req,reason))));marker='QA_OWNER_DECIDE_'+tag
        two.send(auth(close(req))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');view=result(two.wait(marker));assert view['state']=='succeeded'and view['result']==receipt
        proof['decide_wins_close_actual_receipt']=True
        approved=run('select public.decide_offline_customer_claim('+lit(uid())+','+lit(claim)+",'approve_with_secret','Reviewed QA original receipt proof');");link=approved['link_id'];assert link
        # Cross-kind contention observes the global mutex before revoke can act.
        cross=uid();payload={'p_claim':claim,'p_decision':'hold','p_reason':'Prepared cross kind witness reason','p_evidence_type':None}
        one.run(auth(prepare(cross,'decide',payload)));marker='QA_OWNER_CROSS_'+tag
        two.send(auth(rejected(revoke(cross,'Different revoke cannot reuse nonce'),'22023'))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');assert result(two.wait(marker))['rejected'];assert run(close(cross))['state']=='closed'
        proof['cross_kind_global_nonce_wait_and_rejection']=True
        # Close-first actual revoke remains fenced, leaving the newly approved link intact.
        req=uid();one.run(auth(close(req)));marker='QA_OWNER_REVOKE_FENCE_'+tag
        two.send(auth(rejected(revoke(req,'Late revoke must remain fenced'),'55000'))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');assert result(two.wait(marker))['rejected']
        assert sql('select revoked_at is null from private.offline_customer_trusted_links where link_id='+lit(link)+';')=='t'
        proof['close_wins_revoke_fenced']=True
        # Actual revoke wins; close returns the revocation receipt, never false closure.
        req=uid();reason='Reviewed QA evidence link revocation';payload={'p_link':link,'p_reason':reason}
        revoked=result(one.run(auth(prepare(req,'revoke',payload)+revoke(req,reason))));marker='QA_OWNER_REVOKED_'+tag
        two.send(auth(close(req))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');view=result(two.wait(marker));assert view['state']=='succeeded'and view['result']==revoked
        proof.update(revoke_wins_close_actual_receipt=True,actual_global_nonce_waits_observed=True)
    except Exception as e:proof['error']=str(e);raise
    finally:
        for session in sessions:session.rollback_close()
        try:
            # Never touch a non-fixture link, including on a lost approval response.
            qa_link=sql('select link_id from private.offline_customer_trusted_links where claim_id='+lit(claim)+'and revoked_at is null;')
            if qa_link:
                uuid.UUID(qa_link);link=qa_link
                run('select public.revoke_offline_customer_link('+lit(cleanup)+','+lit(link)+",'QA owner command verification complete');")
            proof['qa_link_revoked']=sql('select count(*)from private.offline_customer_trusted_links where claim_id='+lit(claim)+'and revoked_at is null;')=='0'
            proof['preexisting_rows_unchanged']=not(before-snapshot());proof['protected_counts_unchanged']=protected_before==protected()
        except Exception as e:proof['cleanup_error']=str(e)
        needed=['close_wins_prepare_and_actual_fenced','decide_wins_close_actual_receipt','cross_kind_global_nonce_wait_and_rejection','close_wins_revoke_fenced','revoke_wins_close_actual_receipt','qa_link_revoked','preexisting_rows_unchanged','protected_counts_unchanged']
        proof['all_passed']=all(proof.get(k)for k in needed)and not proof.get('error')and not proof.get('cleanup_error')
        a.proof.parent.mkdir(parents=True,exist_ok=True);a.proof.write_text(json.dumps(proof,indent=2)+'\n');a.proof.chmod(0o600)
    assert proof['all_passed'];print('PASS real owner command global nonce races; actual receipts, permanent fences, QA link revoked; no Auth/finance effects')


if __name__=='__main__':main()
