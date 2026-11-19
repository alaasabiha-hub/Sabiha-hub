"""Root-run local-only canonical reward checkout concurrency acceptance.

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
    # No scheduler modifications: real installed consumer readiness is a prerequisite.
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
    def owner_execute(body):return sql('begin;'+owner_sql(body)+'commit;')
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


    def customer_sql(body):return "select set_config('request.jwt.claim.sub','"+customer+"',true);set local role authenticated;"+body
    def customer_call(body):return value('begin;'+customer_sql(body)+'commit;')
    def as_json(lines):return json.loads(next(line for line in reversed(lines)if line.startswith('{')))
    def expect_failure(body,code):return "do $qa$declare rejected boolean:=false;begin begin "+body+" exception when "+' or '.join("sqlstate '"+x+"'"for x in code.split('|'))+" then rejected:=true;end;assert rejected,'Expected fail-closed SQLSTATE "+code+"';end $qa$;"
    def normal(request,day=46):return "select public.place_customer_service_booking('"+request+"','"+service+"','"+branch+"','"+car+"',current_date+"+str(day)+",'10:00',100,null);"
    def quote_case(label):
        case=new_case(label);sql('begin;'+owner_sql(complete(case)+payment(case))+'commit;');drain_all()
        q=customer_call("select public.quote_service_reward('"+uuid4()+"','"+service+"','"+branch+"','"+car+"',current_date+45,'10:00','"+policy+"','"+rules+"',null);")
        assert q['eligible'],q
        request=uuid4();payload={'p_quote':q['quote_id'],'p_fingerprint':q['fingerprint'],'p_accept_terms':True,'p_adopt_existing_visits':False}
        customer_call("select public.prepare_service_booking_attempt('"+request+"','reward','"+json.dumps(payload,separators=(',',':'))+"'::jsonb);")
        return case,request,q
    def place(request,q):return "select public.place_customer_reward_booking('"+request+"','"+q['quote_id']+"','"+q['fingerprint']+"',true,false);"
    def acknowledge(request):customer_call("select public.acknowledge_service_booking_attempt('"+request+"');")
    def cancel_booking(booking):return customer_call("select public.change_customer_booking('"+uuid4()+"','"+booking+"','cancel');")

    tag=uuid.uuid4().hex[:12];branch=uuid4();service=uuid4();shift=uuid4();car=uuid4();rules=uuid4();offer=None;policy=None
    sessions=[];cases=[];rewards=[];normal_receipts=[];guard=None;fixture=False;shift_open=False;before=None;before_counters=None
    proof={'local_only':True,'production_touched':False,'gateway_called':False,'tag':tag,'branch_id':branch,'test_passed':False}
    try:
        assert sql("select private.loyalty_visit_scheduler_ready() and coalesce(private.loyalty_visit_cron_last_success()>=clock_timestamp()-interval '5 minutes',false);")=='t','Observe a real successful scheduled run first'
        assert sql('select booking_installed and readers_integrated from private.reward_runtime where singleton;')=='t','All reward readers/backend must be installed'
        guard=session('cron_guard');guard.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));")
        assert sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0','Review existing ready work before isolated QA'
        before=snapshots();before_counters=counters();fixture=True
        sql("begin;insert into public.business_branches(branch_id,name_ar,name_en)values('"+branch+"','اختبار استبدال محلي','Synthetic reward QA "+tag+"');insert into public.business_catalog_items(item_id,branch_id,item_type,name,price,is_active,is_public,duration_minutes)values('"+service+"','"+branch+"','service','Synthetic reward QA "+tag+"',100,true,true,30);insert into public.vehicles(id,customer_id,brand,model,plate_number)values('"+car+"','"+customer+"','QA','Reward','QA-"+tag+"');commit;")
        offer=owner_call("select public.save_visit_reward_offer('"+uuid4()+"','"+branch+"','Synthetic reward QA "+tag+"',1,true,'"+service+"');")['offer_id']
        policy=owner_call("select public.save_loyalty_policy('"+uuid4()+"','"+branch+"','"+offer+"',array['"+service+"'::uuid],true);")['version_id']
        owner_call("select public.activate_loyalty_visits('"+uuid4()+"','"+policy+"');")
        explicit={'pooling':'policy_version','expiry':'no_expiry','cancellation':'restore_visits','refunded_contribution':'offset_future_visits'}
        owner_call("select public.save_loyalty_redemption_rules('"+rules+"','"+policy+"',null,'"+json.dumps(explicit,separators=(',',':'))+"'::jsonb);")
        owner_call("select public.activate_loyalty_redemption('"+uuid4()+"','"+rules+"');")
        owner_execute("select public.open_cashier_shift('"+shift+"','"+branch+"',0);");shift_open=True
        # Real overlapping exact reward retries serialize on the same actor/request lock.
        case,request,q=quote_case('exact_retry');a=session('reward_first');b=session('reward_retry')
        receipt=as_json(a.run('begin;'+customer_sql(place(request,q))));rewards.append(receipt)
        marker='QA_REWARD_RETRY_'+tag;b.send('begin;'+customer_sql(place(request,q))+'\n\\echo '+marker)
        wait_lock(b,a,True);a.run('commit;');second=as_json(b.wait(marker));b.run('commit;')
        assert second['invoice_id']==receipt['invoice_id'];acknowledge(request)
        assert sql("select count(*)from private.service_reward_redemptions where customer_id='"+customer+"'and request_id='"+request+"';")=='1'
        proof['two_concurrent_exact_retries_one_receipt']=True
        cancel_booking(receipt['booking_id'])
        # Release restored source eligibility deliberately by refunding that source.
        owner_execute(payment(case,'refund'));drain_all()
        # Refund commits while placement waits: fresh post-lock facts reject the stale quote.
        case,request,q=quote_case('refund_before_claim');a=session('refund_first');b=session('claim_waits_refund')
        a.run('begin;'+owner_sql(payment(case,'refund')))
        marker='QA_REFUND_BEFORE_'+tag;b.send('begin;'+customer_sql(expect_failure(place(request,q),'40001'))+'\n\\echo '+marker)
        wait_lock(b,a);a.run('commit;');b.wait(marker);b.run('commit;')
        assert customer_call("select public.close_service_booking_attempt('"+request+"');")['state']=='closed'
        assert sql("select count(*)from private.service_reward_redemptions where customer_id='"+customer+"'and request_id='"+request+"';")=='0'
        proof['refund_commits_before_claim_rejected']=True;drain_all()
        # Placement commits while refund waits: issued coverage stays fixed and wallet records debt.
        case,request,q=quote_case('claim_before_refund');a=session('claim_first');b=session('refund_waits_claim')
        receipt=as_json(a.run('begin;'+customer_sql(place(request,q))));rewards.append(receipt)
        marker='QA_REFUND_AFTER_'+tag;b.send('begin;'+owner_sql(payment(case,'refund'))+'\n\\echo '+marker)
        wait_lock(b,a);a.run('commit;');b.wait(marker);b.run('commit;');acknowledge(request)
        wallet=customer_call('select public.get_my_reward_wallet();')
        program=next(p for p in wallet['programs']if p['rules_version_id']==rules)
        assert program['blockers']['outstanding_refund_debt']==1 and not program['blockers']['eligible']
        assert sql("select private.reward_invoice_coverage('"+receipt['invoice_id']+"')->>'state';")=='covered_by_reward'
        proof['claim_commits_before_refund_fixed_invoice_and_debt']=True
        # Offset-credit refund, not merely a quoted earning refund: debt must reopen
        # before a new benefit can be issued, even when its own quoted lot is sound.
        offset_case=new_case('offset_future');sql('begin;'+owner_sql(complete(offset_case)+payment(offset_case))+'commit;');drain_all()
        wallet=customer_call('select public.get_my_reward_wallet();')
        assert next(p for p in wallet['programs']if p['rules_version_id']==rules)['blockers']['outstanding_refund_debt']==0
        fresh_case,fresh_request,fresh_q=quote_case('offset_followup')
        a=session('offset_refund_first');b=session('new_claim_waits_offset_refund')
        a.run('begin;'+owner_sql(payment(offset_case,'refund')))
        marker='QA_OFFSET_REFUND_'+tag;b.send('begin;'+customer_sql(expect_failure(place(fresh_request,fresh_q),'55000|40001'))+'\n\\echo '+marker)
        wait_lock(b,a);a.run('commit;');b.wait(marker);b.run('commit;')
        assert customer_call("select public.close_service_booking_attempt('"+fresh_request+"');")['state']=='closed'
        assert sql("select count(*)from private.service_reward_redemptions where customer_id='"+customer+"'and request_id='"+fresh_request+"';")=='0'
        proof['concurrent_refund_of_offset_credit_reopens_debt_before_new_claim']=True
        cancel_booking(receipt['booking_id']);drain_all()
        # Close-first permanently fences a delayed legacy-compatible normal creator.
        request=uuid4();a=session('close_first');b=session('late_normal')
        a.run('begin;'+customer_sql("select public.close_service_booking_attempt('"+request+"');"))
        marker='QA_CLOSE_FIRST_'+tag;b.send('begin;'+customer_sql(expect_failure(normal(request),'55000'))+'\n\\echo '+marker)
        wait_lock(b,a,True);a.run('commit;');b.wait(marker);b.run('commit;')
        assert customer_call("select public.get_service_booking_attempt('"+request+"');")['state']=='closed'
        proof['tombstone_fences_delayed_normal_creator']=True
        # Create-first means close returns the real successful receipt, never false absence.
        request=uuid4();a=session('normal_first');b=session('close_waits_normal')
        receipt=as_json(a.run('begin;'+customer_sql(normal(request))));normal_receipts.append(receipt)
        marker='QA_CREATE_FIRST_'+tag;b.send('begin;'+customer_sql("select public.close_service_booking_attempt('"+request+"');")+'\n\\echo '+marker)
        wait_lock(b,a,True);a.run('commit;');closed=as_json(b.wait(marker));b.run('commit;')
        assert closed['state']=='succeeded'and closed['result']['invoice_id']==receipt['invoice_id'];acknowledge(request)
        cancel_booking(receipt['booking_id']);proof['creation_wins_close_returns_success']=True
        proof['test_passed']=True
    except Exception as error:proof['error']=str(error)
    finally:
        for s in sessions:
            if s is not guard:s.rollback_close()
        errors=[]
        for receipt in rewards+normal_receipts:
            try:
                if sql("select status from public.bookings where id='"+receipt['booking_id']+"';")=='pending':cancel_booking(receipt['booking_id'])
            except Exception as error:errors.append('cancel QA: '+str(error))
        if shift_open:
            for case in cases:
                try:owner_execute(payment(case,'refund'))
                except Exception as error:errors.append('refund QA '+case['label']+': '+str(error))
            try:
                drain_all();customer_call('select public.get_my_reward_wallet();')
                assert all(counts(case)['net']==0 for case in cases)
                owner_execute("select public.close_cashier_shift('"+shift+"',0,'Synthetic reward QA fully refunded');select public.approve_cashier_shift('"+shift+"');")
                proof['qa_cash_and_visits_neutralized']=True
            except Exception as error:errors.append('neutralize: '+str(error))
        if fixture:
            try:
                if offer:owner_call("select public.save_visit_reward_offer('"+uuid4()+"','"+branch+"','Synthetic reward QA "+tag+"',1,false,'"+service+"',null,'"+offer+"');")
                if policy:owner_call("select public.save_loyalty_policy('"+uuid4()+"','"+branch+"','"+offer+"',array['"+service+"'::uuid],false);")
                sql("begin;update public.business_catalog_items set is_active=false,is_public=false where item_id='"+service+"';update public.business_branches set is_active=false where branch_id='"+branch+"';commit;")
                proof['qa_program_inactive']=True
            except Exception as error:errors.append('deactivate: '+str(error))
        if before is not None:
            try:
                after=snapshots()
                for table,rows in before.items():assert not(rows-after[table]),'Preexisting row changed: '+table
                now=counters();expected=len(cases)+len(rewards)+len(normal_receipts)
                assert now['BKG']-before_counters['BKG']==expected and now['INV']-before_counters['INV']==expected
                proof['preexisting_rows_unchanged']=True;proof['document_counter_expected_delta']=expected
            except Exception as error:errors.append('preservation: '+str(error))
        if guard:guard.rollback_close()
        if errors:proof['cleanup_errors']=errors;proof['test_passed']=False
        args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(proof,indent=2)+'\n');args.proof.chmod(0o600)
    if not proof['test_passed']:raise SystemExit('FAIL; inspect private proof: '+str(args.proof))
    print('PASS actual reward retry/refund/tombstone commit orders; local QA retained refunded/inactive; production untouched')

if __name__=='__main__':main()
