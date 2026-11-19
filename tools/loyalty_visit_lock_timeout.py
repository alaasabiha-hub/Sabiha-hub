"""Root-run local-only 20-second worker lock acceptance; no business fixture.

Retains one processed synthetic outbox event. No tables, visits, payments,
bookings, document numbers or policy activations are created or changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    args=parser.parse_args();r=args.runtime.resolve()
    config=json.loads((r/'test-accounts-final.json').read_text())
    assert urllib.parse.urlsplit(config['url']).hostname=='127.0.0.1','Local-only retained runtime required'
    socket=r/'instances/sabiha-local/sock/docker.sock';docker=r/'docker-cli/docker/docker'
    assert socket.is_socket() and docker.is_file(),'Existing local Docker runtime required'
    env={**os.environ,'DOCKER_HOST':'unix://'+str(socket),'DOCKER_CONFIG':str(r/'docker-config')}
    command=[str(docker),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
    def sql(source):
        result=subprocess.run(command,input=source,text=True,capture_output=True,env=env,timeout=40)
        if result.returncode:raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()
    def value(source):return json.loads(sql(source).splitlines()[-1])
    event=str(uuid.uuid4());order=str(uuid.uuid4());controller=None;worker=None;inserted=False
    proof={'local_only':True,'production_touched':False,'business_fixtures_created':False,'event_id':event,'test_passed':False}
    try:
        sql((Path(__file__).resolve().parents[1]/'supabase/tests/loyalty_visit_worker_lock_timeout.sql').read_text())
        assert sql('select private.loyalty_visit_scheduler_ready();')=='t','Registered scheduler required for orphan-event cleanup'
        controller=PsqlSession(command,env,'qa_loyalty_timeout_guard')
        controller.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));select pg_advisory_lock(hashtextextended('canonical-visit:"+order+"',0));")
        assert sql('select count(*) from private.loyalty_visit_outbox where processed_at is null;')=='0','Review preexisting pending work first'
        baseline=sql('select count(*) from private.canonical_loyalty_visits;')
        sql("insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id) values('"+event+"','qa_lock_timeout','"+event+"','"+order+"');");inserted=True
        worker=PsqlSession(command,env,'qa_loyalty_timeout_worker')
        # Disable the session's normal lock bound: the function must supply it.
        worker.run("set lock_timeout='0';set statement_timeout='35s';")
        marker='QA_LOYALTY_BOUNDED_'+uuid.uuid4().hex
        started=time.monotonic();worker.send('begin;set local role service_role;select public.drain_loyalty_visit_event();\n\\echo '+marker)
        until=time.monotonic()+12;observed=False
        while time.monotonic()<until:
            if sql('select exists(select 1 from pg_stat_activity where pid='+str(worker.pid)+" and wait_event_type='Lock' and wait_event='advisory' and "+str(controller.pid)+'=any(pg_blocking_pids(pid)));')=='t':observed=True;break
            time.sleep(.05)
        assert observed,'No real worker advisory wait observed'
        lines=worker.wait(marker,timeout=32);elapsed=time.monotonic()-started
        result=json.loads(next(line for line in reversed(lines) if line.startswith('{')))
        assert result.get('retry') is True and result.get('error_code')=='55P03','Expected function lock timeout did not reach retry path'
        assert 18<=elapsed<35,'Unexpected lock-wait timing'
        worker.run('commit;')
        state=value("select json_build_object('pending',processed_at is null,'attempts',attempts,'error',last_error_code,'backoff_seconds',extract(epoch from(next_attempt_at-clock_timestamp()))) from private.loyalty_visit_outbox where event_id='"+event+"';")
        assert state['pending'] and state['attempts']==1 and state['error']=='55P03' and state['backoff_seconds']>100,'Failed lock event lost its bounded backoff'
        proof.update({'actual_advisory_wait_observed':True,'caller_lock_timeout_disabled':True,'elapsed_seconds':round(elapsed,3),'retry_sqlstate':'55P03','backoff_preserved':True})
        controller.run("select pg_advisory_unlock(hashtextextended('canonical-visit:"+order+"',0));")
        # Cleanup only this synthetic event: no waiting two minutes and no deletes.
        sql("update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp() where event_id='"+event+"';")
        done=value('begin;set local role service_role;select public.drain_loyalty_visit_event();commit;')
        assert done.get('processed') and done.get('result')=='canonical_service_order_required','Synthetic orphan event did not finish harmlessly'
        assert sql('select count(*) from private.canonical_loyalty_visits;')==baseline,'Timeout acceptance changed canonical visits'
        proof['synthetic_event_processed_without_business_effect']=True;proof['test_passed']=True
    except Exception as error:proof['error']=str(error)
    finally:
        if worker:worker.rollback_close()
        errors=[]
        if inserted and controller:
            try:
                controller.run("select pg_advisory_unlock(hashtextextended('canonical-visit:"+order+"',0));")
                sql("update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp() where event_id='"+event+"' and processed_at is null;")
                if sql("select processed_at is null from private.loyalty_visit_outbox where event_id='"+event+"';")=='t':sql('begin;set local role service_role;select public.drain_loyalty_visit_event();commit;')
            except Exception as error:errors.append(str(error))
        if controller:controller.rollback_close()
        if errors:proof['cleanup_errors']=errors;proof['test_passed']=False
        args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(proof,indent=2)+'\n');args.proof.chmod(0o600)
    if not proof['test_passed']:raise SystemExit('FAIL; inspect private proof: '+str(args.proof))
    print('PASS real worker lock waited then retried at its own 20s bound; backoff retained; no business records or visits changed')

if __name__=='__main__':main()
