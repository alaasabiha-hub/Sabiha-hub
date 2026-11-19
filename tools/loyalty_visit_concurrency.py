"""Root-run local-only loyalty concurrency/cron acceptance.

Requires both prepared migrations plus a recent REAL successful cron run.
Retains tagged synthetic QA records, fully refunded and deactivated; never deletes
or resets history/counters. Each worker RPC is its own READ COMMITTED transaction.
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
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--observe-cron',action='store_true',help='Also wait for actual scheduled posting, without manually draining that case')
    args=parser.parse_args();runtime=args.runtime.resolve()
    accounts=json.loads((runtime/'test-accounts-final.json').read_text())
    assert urllib.parse.urlsplit(accounts['url']).hostname=='127.0.0.1','Loopback retained QA configuration only'
    owner=str(uuid.UUID(accounts['users']['owner']['id']));customer=str(uuid.UUID(accounts['users']['customer']['id']))
    socket=runtime/'instances/sabiha-local/sock/docker.sock';docker=runtime/'docker-cli/docker/docker'
    assert socket.is_socket() and docker.is_file(),'Existing local Docker runtime required'
    env={**os.environ,'DOCKER_HOST':'unix://'+str(socket),'DOCKER_CONFIG':str(runtime/'docker-config')}
    command=[str(docker),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
    def sql(source,timeout=40):
        p=subprocess.run(command,input=source,env=env,text=True,capture_output=True,timeout=timeout)
        if p.returncode:raise RuntimeError(p.stdout+p.stderr)
        return p.stdout.strip()
    def value(source):
        lines=sql(source).splitlines()
        return json.loads(next(line for line in reversed(lines) if line.startswith('{')))
    def owner_sql(body):return "select set_config('request.jwt.claim.sub','"+owner+"',true);set local role authenticated;"+body
    def owner_call(body):return value('begin;'+owner_sql(body)+'commit;')
    def uuid4():return str(uuid.uuid4())
    def snapshots():
        result=sql("""create temp table qa_old_rows(t text,h text);do $$declare t record;h text;begin for t in select schemaname,tablename from pg_tables where schemaname in ('public','private') and not(schemaname='private' and tablename='document_number_counters') loop execute format('select coalesce(string_agg(md5(row_to_json(r)::text),%L),%L) from %I.%I r',',','',t.schemaname,t.tablename) into h;insert into qa_old_rows values(t.schemaname||'.'||t.tablename,h);end loop;end $$;select t||'|'||h from qa_old_rows order by t;""")
        return {line.split('|',1)[0]:Counter(filter(None,line.split('|',1)[1].split(','))) for line in result.splitlines() if '|' in line}
    def counters():return value("select json_object_agg(kind,last_value) from private.document_number_counters;")
    def counts(case):return value("select json_build_object('earned',count(*)filter(where kind='earn'),'reversed',count(*)filter(where kind='refund'),'net',coalesce(sum(visits),0)) from private.canonical_loyalty_visits where order_id='"+case['order']+"';")
    def drain_all():
        for _ in range(200):
            result=value('begin;set local role service_role;select public.drain_loyalty_visit_event();commit;')
            if result.get('retry'):raise RuntimeError('Unexpected retry during isolated acceptance: '+json.dumps(result))
            if not result.get('processed'):return
        raise RuntimeError('Unexpected queue volume; stop without claiming isolation')
    def complete(case):
        b=case['booking'];o=case['order']
        return ("update public.bookings set status='confirmed' where id='"+b+"' and status='pending';"
                "update public.bookings set status='in_progress' where id='"+b+"' and status='confirmed';"
                "update public.bookings set status='completed' where id='"+b+"' and status='in_progress';"
                "update public.business_orders set status='in_progress' where order_id='"+o+"' and status='received';"
                "update public.business_orders set status='quality_check' where order_id='"+o+"' and status='in_progress';"
                "update public.business_orders set status='completed' where order_id='"+o+"' and status='quality_check';")
    def payment(case,event='sale',request=None):
        return "select public.record_shift_payment('"+(request or uuid4())+"','"+shift+"','"+case['invoice']+"','"+event+"','cash');"
    def wait_lock(waiter,blocker,advisory=False):
        until=time.monotonic()+16
        while time.monotonic()<until:
            extra=" and wait_event='advisory'" if advisory else ''
            if sql('select exists(select 1 from pg_stat_activity where pid='+str(waiter.pid)+" and wait_event_type='Lock'"+extra+' and '+str(blocker.pid)+'=any(pg_blocking_pids(pid)));')=='t':return
            if waiter.proc.poll() is not None:raise RuntimeError('Concurrent session exited before lock observation')
            time.sleep(.05)
        raise RuntimeError('Expected actual PostgreSQL wait was not observed')
    def session(name):
        s=PsqlSession(command,env,'qa_loyalty_'+name+'_'+tag);sessions.append(s);return s
    def new_case(label):
        case={'label':label,'booking':uuid4(),'order':uuid4(),'invoice':'QA-LOYALTY-'+tag+'-'+label}
        slot=str(10+len(cases)).zfill(2)+':00';cases.append(case)
        sql("begin;insert into public.bookings(id,customer_id,service_name,booking_date,booking_time,catalog_item_id,branch_id) values('"+case['booking']+"','"+customer+"','Synthetic local loyalty QA',current_date+21,'"+slot+"','"+service+"','"+branch+"');"
            "insert into public.business_orders(order_id,order_number,customer_id,booking_id,branch_id,service_name,order_type,status) values('"+case['order']+"','QA-LOYALTY-"+case['order']+"','"+customer+"','"+case['booking']+"','"+branch+"','Synthetic local loyalty QA','service','received');"
            "insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total,discount,commission_total,sale_type) values('"+case['invoice']+"','"+case['order']+"','"+branch+"','Synthetic local loyalty QA',80,20,10,'service');commit;")
        return case

    tag=uuid.uuid4().hex[:12];branch=uuid4();service=uuid4();shift=uuid4();offer=None;policy=None
    sessions=[];cases=[];guard=None;guard_held=False;fixture=False;shift_open=False
    proof={'local_only':True,'production_touched':False,'gateway_called':False,'tag':tag,'branch_id':branch,'test_passed':False,'actual_cron_posting_verified':False}
    before=None;before_counters=None
    try:
        assert sql("select private.loyalty_visit_scheduler_ready() and coalesce(private.loyalty_visit_cron_last_success()>=clock_timestamp()-interval '5 minutes',false);")=='t','Apply scheduler registration and observe a real successful cron run first'
        guard=session('cron_guard');guard.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));");guard_held=True
        assert sql('select count(*) from private.loyalty_visit_outbox where processed_at is null;')=='0','Drain/review prior real pending events before isolated acceptance'
        before=snapshots();before_counters=counters()
        fixture=True
        sql("begin;insert into public.business_branches(branch_id,name_ar,name_en) values('"+branch+"','اختبار ولاء محلي','Synthetic loyalty QA "+tag+"');insert into public.business_catalog_items(item_id,branch_id,item_type,name,category,price,is_active,is_public) values('"+service+"','"+branch+"','service','Synthetic loyalty QA "+tag+"','QA',100,true,true);commit;")
        offer=owner_call("select public.save_visit_reward_offer('"+uuid4()+"','"+branch+"','Synthetic QA owner terms "+tag+"',7,true,'"+service+"');")['offer_id']
        policy=owner_call("select public.save_loyalty_policy('"+uuid4()+"','"+branch+"','"+offer+"',array['"+service+"'::uuid],true);")['version_id']
        activation=owner_call("select public.activate_loyalty_visits('"+uuid4()+"','"+policy+"');")
        sql('begin;'+owner_sql("select public.open_cashier_shift('"+shift+"','"+branch+"',0);")+'commit;');shift_open=True
        proof['activation_id']=activation['activation_id']
        # Actual overlapping writers, completion commits before an uncommitted payment.
        case=new_case('completion_first');a=session('payment_pending');b=session('completion_commit')
        a.run('begin;'+owner_sql(payment(case)));b.run('begin;'+owner_sql(complete(case)));b.run('commit;')
        drain_all();assert counts(case)['earned']==0,'Uncommitted payment awarded'
        a.run('commit;');drain_all();assert counts(case)=={'earned':1,'reversed':0,'net':1}
        proof['overlap_completion_commits_first']=True
        # Opposite real commit order, with completion still uncommitted.
        case=new_case('payment_first');a=session('completion_pending');b=session('payment_commit')
        a.run('begin;'+owner_sql(complete(case)));b.run('begin;'+owner_sql(payment(case)));b.run('commit;')
        drain_all();assert counts(case)['earned']==0,'Uncommitted completion awarded'
        a.run('commit;');drain_all();assert counts(case)=={'earned':1,'reversed':0,'net':1}
        proof['overlap_payment_commits_first']=True
        # Two workers select distinct source events for the same canonical order.
        case=new_case('two_workers');sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;')
        a=session('worker_A');b=session('worker_B');a.run('begin;set local role service_role;select public.drain_loyalty_visit_event();')
        marker='QA_WORKER_B_'+tag;b.send('begin;set local role service_role;select public.drain_loyalty_visit_event();\n\\echo '+marker)
        wait_lock(b,a,True);a.run('commit;');b.wait(marker);b.run('commit;');drain_all()
        assert counts(case)=={'earned':1,'reversed':0,'net':1};proof['two_workers_real_advisory_wait_one_award']=True
        # A worker crash/rollback leaves its source event and award uncommitted.
        case=new_case('worker_retry');sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;')
        a=session('worker_rollback');a.run('begin;set local role service_role;select public.drain_loyalty_visit_event();');a.run('rollback;')
        assert counts(case)['earned']==0;drain_all();assert counts(case)=={'earned':1,'reversed':0,'net':1};proof['worker_rollback_retry_exactly_once']=True
        # Refund races an uncommitted award: real FK wait, no cross-lock deadlock.
        case=new_case('refund_race');sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;')
        a=session('award_pending');b=session('refund_pending');a.run('begin;set local role service_role;select public.drain_loyalty_visit_event();')
        marker='QA_REFUND_'+tag;b.send('begin;'+owner_sql(payment(case,'refund'))+'\n\\echo '+marker)
        wait_lock(b,a);a.run('commit;');b.wait(marker);b.run('commit;');drain_all()
        assert counts(case)=={'earned':1,'reversed':1,'net':0};proof['concurrent_refund_reversed_once']=True
        # The converse refund race: refund is uncommitted when the worker starts.
        case=new_case('refund_before_insert');sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;')
        a=session('refund_first');b=session('award_waits_refund');a.run('begin;'+owner_sql(payment(case,'refund')))
        marker='QA_AWARD_WAIT_'+tag;b.send('begin;set local role service_role;select public.drain_loyalty_visit_event();\n\\echo '+marker)
        wait_lock(b,a);a.run('commit;');b.wait(marker);b.run('commit;');drain_all()
        assert counts(case)['net']==0 and counts(case)['earned']<=1;proof['refund_commit_during_award_net_zero']=True
        if args.observe_cron:
            case=new_case('real_cron');sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;')
            started=sql('select clock_timestamp()::text;')
            guard.run("select pg_advisory_unlock(hashtextextended('canonical-loyalty-cron',0));");guard_held=False
            until=time.monotonic()+180
            while time.monotonic()<until:
                actual=sql("select exists(select 1 from cron.job j join cron.job_run_details r using(jobid) where j.jobname='canonical-loyalty-visits' and r.command='select private.run_loyalty_visit_cron();' and r.status='succeeded' and r.start_time>='"+started+"'::timestamptz);")=='t'
                if actual and counts(case)['earned']==1:break
                time.sleep(1)
            else:raise RuntimeError('No real scheduled visit posting observed within three minutes')
            proof['actual_cron_posting_verified']=True
            guard.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));");guard_held=True
            drain_all()
        proof['test_passed']=True
    except Exception as error:
        proof['error']=str(error)
    finally:
        for s in sessions:
            if s is not guard:s.rollback_close()
        errors=[]
        if guard and not guard_held:
            try:guard.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));");guard_held=True
            except Exception as error:errors.append('cron guard: '+str(error))
        if shift_open:
            for case in cases:
                try:
                    if sql("select exists(select 1 from public.business_payment_events where invoice_id='"+case['invoice']+"' and event_type='sale');")=='t':sql('begin;'+owner_sql(payment(case,'refund'))+'commit;')
                except Exception as error:errors.append('refund '+case['label']+': '+str(error))
            try:
                drain_all()
                assert all(counts(case)['net']==0 for case in cases),'QA visits not neutralized'
                sql('begin;'+owner_sql("select public.close_cashier_shift('"+shift+"',0,'Synthetic QA fully refunded');select public.approve_cashier_shift('"+shift+"');")+'commit;')
                proof['qa_cash_and_visits_neutralized']=True
            except Exception as error:errors.append('neutralize/close: '+str(error))
        if fixture:
            try:
                if offer:owner_call("select public.save_visit_reward_offer('"+uuid4()+"','"+branch+"','Synthetic QA owner terms "+tag+"',7,false,'"+service+"',null,'"+offer+"');")
                if policy and offer:owner_call("select public.save_loyalty_policy('"+uuid4()+"','"+branch+"','"+offer+"',array['"+service+"'::uuid],false);")
                sql("begin;update public.business_catalog_items set is_active=false,is_public=false where item_id='"+service+"';update public.business_branches set is_active=false where branch_id='"+branch+"';commit;")
                proof['qa_branch_service_offer_inactive']=True
            except Exception as error:errors.append('deactivate: '+str(error))
        if before is not None:
            try:
                after=snapshots()
                for table,old in before.items():assert not(old-after[table]),'Preexisting row changed: '+table
                now=counters();expected=len(cases)
                assert now['BKG']-before_counters['BKG']==expected and now['INV']-before_counters['INV']==expected,'Unexpected document-number consumption'
                proof['preexisting_business_rows_unchanged']=True
                proof['document_counters_expected_delta']={'BKG':expected,'INV':expected}
            except Exception as error:errors.append('preservation: '+str(error))
        if guard:guard.rollback_close()
        if errors:proof['cleanup_errors']=errors;proof['test_passed']=False
        args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(proof,indent=2)+'\n');args.proof.chmod(0o600)
    if not proof['test_passed']:raise SystemExit('FAIL; inspect private proof: '+str(args.proof))
    print('PASS actual overlapping commit orders, two workers, rollback retry and refund races; tagged QA retained refunded/inactive; production untouched')
    if args.observe_cron:print('PASS actual scheduled posting observed without manual drain of that visit')

if __name__=='__main__':main()
