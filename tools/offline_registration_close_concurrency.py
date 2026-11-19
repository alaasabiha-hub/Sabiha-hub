"""SOURCE-PREPARED local-only close-vs-registration race; explicit --execute required.

Run only after root reviews/applies 20261114165824. Uses existing owner/branch,
no Auth/profile changes or financial fixtures. Retains ONE tagged private intake,
one permanent closed UUID and their audit rows; never deletes or exposes secrets.
Tests actual nonce waits in both commit orders, including close lost-response retry.
"""
import argparse
from collections import Counter
import json,os,subprocess,time,urllib.parse,uuid
from pathlib import Path
from checkout_retry_lock_concurrency import PsqlSession


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
    if not a.execute:print(__doc__);return
    r=a.runtime.resolve();accounts=json.loads((r/'test-accounts-final.json').read_text());assert urllib.parse.urlsplit(accounts['url']).hostname=='127.0.0.1'
    actor=str(uuid.UUID(accounts['users']['owner']['id']));socket=r/'instances/sabiha-local/sock/docker.sock';assert socket.is_socket()
    env={**os.environ,'DOCKER_HOST':'unix://'+str(socket),'DOCKER_CONFIG':str(r/'docker-config')}
    command=[str(r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
    def sql(text):
        out=subprocess.run(command,input=text,text=True,env=env,capture_output=True,timeout=35)
        if out.returncode:raise RuntimeError('Local fence SQL failed: '+out.stderr[-1000:])
        return out.stdout.strip()
    def snapshot():
        out=sql("""create temp table qa_hash(t text,h text);do $$declare t record;begin for t in
        select schemaname,tablename from pg_tables where schemaname in('public','private') or (schemaname='auth' and tablename='users') loop
        execute format('insert into qa_hash select %L,md5(row_to_json(r)::text) from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end $$;
        select t||'|'||h from qa_hash order by t,h;""")
        return Counter(out.splitlines())
    def protected():
        return sql("""select (select count(*) from auth.users)||'|'||(select count(*) from public.customers)||'|'||
        (select count(*) from public.vehicles)||'|'||(select count(*) from public.bookings)||'|'||
        (select count(*) from public.business_orders)||'|'||(select count(*) from public.business_invoices)||'|'||
        (select count(*) from public.business_payment_events)||'|'||(select count(*) from private.canonical_loyalty_visits);""")
    def literal(v):return "'"+v.replace("'","''")+"'"
    def auth(body):return "begin;select set_config('request.jwt.claim.sub','"+actor+"',true);set local role authenticated;"+body
    def result(lines):return json.loads(next(x for x in reversed(lines) if x.startswith('{')))
    def wait(waiter,blocker):
        until=time.monotonic()+10
        while time.monotonic()<until:
            found=sql('select exists(select 1 from pg_stat_activity where pid='+str(waiter.pid)+" and wait_event_type='Lock' and wait_event='advisory' and "+str(blocker.pid)+'=any(pg_blocking_pids(pid)));')
            if found=='t':return
            if waiter.proc.poll() is not None:raise RuntimeError('Waiter exited before actual nonce wait')
            time.sleep(.05)
        raise AssertionError('Expected SAME registration nonce advisory wait was not observed')
    tag=uuid.uuid4().hex[:10];branch=sql('select branch_id from public.business_branches where is_active and is_default;');uuid.UUID(branch)
    phone='010'+str(uuid.uuid4().int%100000000).zfill(8)
    assert sql("select exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key('"+phone+"','EG')) or exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key('"+phone+"','EG'));")=='f'
    car={'plate_number':'QA-CLOSE-'+tag,'brand':'QA','model':'Nonce fence'};consent={'accepted':True,'version':'offline-registration-v1','language':'en','text':sql("select private.offline_registration_notice('en');")}
    closed=str(uuid.uuid4());created=str(uuid.uuid4())
    def register_expr(req):
        return "public.register_offline_customer('"+req+"','"+branch+"',"+literal('QA close '+tag)+','+literal(phone)+",'EG',"+literal(json.dumps(car))+"::jsonb,"+literal(json.dumps(consent))+"::jsonb)"
    def register(req):
        expr=register_expr(req)
        return "select (v-'enrollment_secret')||jsonb_build_object('secret_returned',coalesce(length(v->>'enrollment_secret')=64,false)) from(select "+expr+" v)q;"
    def close(req):return "select public.close_offline_customer_registration('"+req+"','"+branch+"');"
    proof={'local_only':True,'production_touched':False,'auth_accounts_created':0,'financial_writes':0,'tag':tag,'all_passed':False}
    before=snapshot();counts=protected();one=two=None
    try:
        one=PsqlSession(command,env,'qa_offline_close_first_'+tag);two=PsqlSession(command,env,'qa_offline_late_create_'+tag)
        c=result(one.run(auth(close(closed))));assert c['state']=='closed'
        marker='QA_CLOSE_WIN_'+tag
        catch="do $$declare rejected boolean:=false;begin begin perform "+register_expr(closed)+";exception when sqlstate '55000' then rejected:=true;end;assert rejected,'Closed nonce created intake';end $$;select '{\"late_create_rejected\":true}'::jsonb;"
        two.send(auth(catch)+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');assert result(two.wait(marker))['late_create_rejected']
        replay=result(one.run(auth(close(closed))+'commit;'));assert replay==c,'Lost close retry must stay permanently closed'
        recovered=result(one.run(auth("select public.get_offline_customer_registration('"+closed+"');")+'commit;'));assert recovered['status']=='closed' and not recovered['may_retry_same_request']
        assert sql("select count(*) from private.offline_customer_registration_requests where request_id='"+closed+"';")=='0'
        proof['close_commits_first_late_create_rejected']=True;proof['close_actual_nonce_wait_observed']=True;proof['lost_close_retry_stays_closed']=True
        # Creation holds the exact same nonce. Close must wait, then reveal the
        # original stored receipt without cancelling intake or reissuing a secret.
        receipt=result(one.run(auth(register(created))));assert receipt['status']=='created_unverified' and receipt['secret_returned']
        marker='QA_CREATE_WIN_'+tag;two.send(auth(close(created))+'commit;\n\\echo '+marker);wait(two,one);one.run('commit;');won=result(two.wait(marker))
        assert won['state']=='succeeded' and won['result']['offline_profile_id']==receipt['offline_profile_id'] and won['result']['enrollment_secret'] is None
        again=result(one.run(auth(register(created))+'commit;'));assert not again['secret_returned'] and again['offline_profile_id']==receipt['offline_profile_id']
        assert sql("select count(*) from private.offline_registration_closed_requests where request_id='"+created+"';")=='0'
        assert sql("select count(*) from private.offline_customer_profiles where profile_id='"+receipt['offline_profile_id']+"';")=='1'
        assert not before-snapshot(),'Preexisting row changed'
        assert counts==protected(),'Intake changed Auth/customer/car/booking/payment/loyalty counts'
        proof.update(creation_actual_nonce_wait_observed=True,creation_commits_first_close_returns_actual_receipt=True,no_secret_reissue=True,no_false_tombstone_for_created_receipt=True,preexisting_rows_unchanged=True,protected_counts_unchanged=True,all_passed=True)
    except Exception as e:proof['error']=str(e);raise
    finally:
        if one:one.rollback_close()
        if two:two.rollback_close()
        a.proof.parent.mkdir(parents=True,exist_ok=True);a.proof.write_text(json.dumps(proof,indent=2)+'\n');a.proof.chmod(0o600)
    print('PASS real close/create commit orders; permanent same-nonce fence, actual receipt, no secret reissue or financial effects')


if __name__=='__main__':main()
