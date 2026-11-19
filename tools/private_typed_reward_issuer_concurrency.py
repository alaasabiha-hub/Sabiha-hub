"""PLAN by default; executable PRIVATE SQL acceptance on an explicit QA CLONE.
No migration/gate/Auth/HR/phone/clock edits, HTTP, credentials or raw SQL logs.
Consumes root's committed real fixture; each race gets fresh actual customer
assent. New received jobs are canonically cancelled, original seed retained.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid
from checkout_retry_lock_concurrency import PsqlSession

INITIAL_CASES=('exact_retry','withdraw_first','issue_first_withdraw','close_first')
CASES=INITIAL_CASES+('competing_last_credit','source_refund_first','issuer_first_source_refund')
def uid():return str(uuid.uuid4())
def lit(v):return "'"+str(v).replace("'","''")+"'"
class SafeFailure(RuntimeError):pass

def save(path,value):
    temporary=path.with_name(path.name+'.tmp')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w')as h:json.dump(value,h,indent=2);h.write('\n');h.flush();os.fsync(h.fileno())
    os.replace(temporary,path);path.chmod(0o600)

def obj(lines):
    if isinstance(lines,str):lines=lines.splitlines()
    return json.loads(next(v for v in reversed(lines)if v.startswith('{')))

class Run:
    def __init__(self,args):
        self.a=args;self.r=args.runtime.resolve();raw=json.loads(args.fixture.read_text())
        assert raw.get('stage')=='committed','Root fixture must be committed'
        f=raw['fixture'];self.db=f['database'];assert re.fullmatch(r'qa_typed_reward_[a-z0-9_]{1,40}',self.db)
        assert args.database==self.db,'Explicit database must exactly match root fixture'
        aliases={'owner_id':'owner','owner_session_id':'owner_session','customer_id':'customer','customer_session_id':'customer_session','branch_id':'branch','service_id':'service','profile_id':'profile','car_ref_id':'car','channel_version_id':'channel','registration_request_id':'registration','cash_shift_id':'shift','link_id':'link','rules_version_id':'rules','source_order_id':'source_order','source_earning_id':'source_earning'}
        self.f={key:str(uuid.UUID(f.get(key,f.get(alias))))for key,alias in aliases.items()}
        self.f['worker_ids']=[str(uuid.UUID(v))for v in f.get('worker_ids',f.get('workers',[]))];assert self.f['worker_ids']
        sock=self.r/'instances/sabiha-local/sock/docker.sock';assert sock.is_socket()
        self.env={**os.environ,'DOCKER_HOST':'unix://'+str(sock),'DOCKER_CONFIG':str(self.r/'docker-config')}
        self.command=[str(self.r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d',self.db,'-v','ON_ERROR_STOP=1']
        self.sessions=[];self.before=None;self.counters=None;self.processed=[]
        self.state={'local_only':True,'database':self.db,'fixture_sha256':hashlib.sha256(args.fixture.read_bytes()).hexdigest(),'cases':[],'stage':'preflight','cleanup_complete':False}
        self.proof={'local_only':True,'database':self.db,'production_touched':False,'actual_private_sql_component':True,'public_http_acceptance':False,'auth_accounts_created':0,'gate_schema_hr_phone_clock_edits':False,'all_passed':False,'cases':[]}
        self.checkpoint()
    def checkpoint(self):save(self.a.state,self.state);save(self.a.proof,self.proof)
    def sql(self,source):
        p=subprocess.run(self.command,input="set statement_timeout='25s';set lock_timeout='20s';"+source,env=self.env,capture_output=True,text=True,timeout=35)
        if p.returncode:raise SafeFailure('local_sql_failed_output_redacted')
        return p.stdout.strip()
    def context(self,role):
        actor=self.f['owner_id'if role=='owner'else'customer_id'];session=self.f['owner_session_id'if role=='owner'else'customer_session_id']
        value="select set_config('request.jwt.claim.sub',"+lit(actor)+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':actor,'session_id':session}))+",true);"
        if role=='customer':value+='set local role authenticated;'
        return value
    def tx(self,role,body):return 'begin;'+self.context(role)+body
    def call(self,role,expression):return obj(self.sql(self.tx(role,'select '+expression+';commit;')))
    def rows(self):
        raw=self.sql("""begin read only;do $$declare t record;v jsonb;all_rows jsonb:='{}';begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private','auth')and not(schemaname='private'and tablename='document_number_counters')order by schemaname,tablename loop
        execute format('select coalesce(jsonb_object_agg(h,n),''{}''::jsonb)from(select md5(to_jsonb(r)::text)h,count(*)n from %I.%I r group by 1)x',t.schemaname,t.tablename)into v;
        all_rows:=all_rows||jsonb_build_object(t.schemaname||'.'||t.tablename,v);end loop;perform set_config('qa.issuer_rows',all_rows::text,true);end$$;select current_setting('qa.issuer_rows');commit;""")
        return {table:Counter(hashes)for table,hashes in json.loads(raw).items()}
    def preflight(self):
        assert self.sql('select current_database();')==self.db
        assert self.sql("select kernel_installed and not public_enabled from private.offline_reward_issuer_runtime where singleton;")=='t'
        assert self.sql("select not earning_enabled and exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%')from private.offline_service_visit_runtime where singleton;")=='t'
        assert self.sql('select not read_enabled from private.offline_visit_wallet_runtime where singleton;')=='t'
        assert self.sql('select exists(select 1 from private.loyalty_redemption_rule_versions where rules_version_id='+lit(self.f['rules_version_id'])+" and rules->>'cancellation'='restore_visits');")=='t','Canonical cleanup requires explicitly saved restore_visits'
        assert self.sql('select exists(select 1 from private.offline_customer_trusted_links where link_id='+lit(self.f['link_id'])+' and auth_user_id='+lit(self.f['customer_id'])+' and profile_id='+lit(self.f['profile_id'])+' and revoked_at is null);')=='t'
        self.call('customer','public.get_my_offline_reward_financial_proposal(null)') # actual grant/session/link boundary
        assert self.sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id=(select actor_id from private.offline_customer_registration_requests where request_id='+lit(self.f['registration_request_id'])+")and acknowledged_at is null and state in('prepared','succeeded'));")=='t','Acknowledge retained fixture command before racing new attempts'
        assert self.sql('select exists(select 1 from private.canonical_loyalty_visits where id='+lit(self.f['source_earning_id'])+' and order_id='+lit(self.f['source_order_id'])+' and offline_profile_id='+lit(self.f['profile_id'])+" and source_channel='offline_walk_in'and kind='earn'and private.reward_credit_refund(id)is null);")=='t'
        self.gross=self.sql('select price::text from public.business_catalog_items where item_id='+lit(self.f['service_id'])+' and branch_id='+lit(self.f['branch_id'])+' and is_active and is_public;')
        assert re.fullmatch(r'[0-9]+(?:\.[0-9]+)?',self.gross)and float(self.gross)>0
        self.before=self.rows();self.counters=obj(self.sql("select jsonb_object_agg(kind,last_value)from private.document_number_counters;"))
        self.base_payments=int(self.sql('select count(*)from public.business_payment_events;'))
        self.base_sales=int(self.sql("select count(*)from public.business_payment_events where event_type='sale';"))
        self.source_baseline=obj(self.sql("select jsonb_build_object('invoice_id',invoice.invoice_id,'row_hash',md5(to_jsonb(invoice)::text),'non_status_hash',md5((to_jsonb(invoice)-'status')::text),'status',invoice.status,'sale_amount',payment.amount)from private.canonical_loyalty_visits earning join public.business_invoices invoice on invoice.invoice_id=earning.invoice_id join public.business_payment_events payment on payment.payment_id=earning.sale_payment_id where earning.id="+lit(self.f['source_earning_id'])+' and earning.order_id='+lit(self.f['source_order_id'])+" and payment.event_type='sale'and payment.method='cash';"))
        if any(name in self.a.cases for name in ['competing_last_credit','source_refund_first','issuer_first_source_refund']):
            plan=self.call('owner',"private.plan_reward_owner_candidates('offline_profile',"+lit(self.f['profile_id'])+','+lit(self.f['rules_version_id'])+','+lit(self.f['channel_version_id'])+')')
            assert plan['threshold_met']is True and plan['required_visits']==1 and plan['candidate_ids']==[self.f['source_earning_id']],'Exactly one actual unclaimed fixture credit required'
            assert self.sql("select count(*)from private.reward_owner_candidate_lots('offline_profile',"+lit(self.f['profile_id'])+','+lit(self.f['rules_version_id'])+','+lit(self.f['channel_version_id'])+');')=='1','Full unbounded candidate set must contain exactly one actual credit'
        if any(name in self.a.cases for name in ['source_refund_first','issuer_first_source_refund']):
            assert self.source_baseline['status']=='active'and self.source_baseline['sale_amount']>0
            assert self.sql('select exists(select 1 from public.business_cashier_shifts where shift_id='+lit(self.f['cash_shift_id'])+' and branch_id='+lit(self.f['branch_id'])+" and status='open');")=='t'
        self.base_earns=int(self.sql("select count(*)from private.canonical_loyalty_visits where kind='earn';"))
        self.scheduler_hash=self.sql("select md5(prosrc)from pg_proc where oid='private.loyalty_visit_scheduler_ready()'::regprocedure;")
        self.state['baseline_rows']={key:dict(value)for key,value in self.before.items()};self.state['baseline_counters']=self.counters;self.checkpoint()
    def fresh(self,name):
        case={'name':name,'hold_id':uid(),'preparation_id':uid(),'proposal_id':uid(),'consent_id':uid(),'issue_id':uid(),'withdraw_id':uid(),'cancel_id':uid(),'refund_id':uid(),'stage':'producer_not_sent'}
        self.state['cases'].append(case);self.checkpoint() # every UUID BEFORE send
        case['stage']='hold_dispatch';self.checkpoint()
        reserve='private.reserve_offline_reward_candidates('+','.join(map(lit,[case['hold_id'],self.f['profile_id'],self.f['car_ref_id'],self.f['channel_version_id']]))+','+self.gross+')'
        held=self.call('owner',reserve);assert held['state']=='active'
        self.call('owner','private.prepare_offline_reward_consumption('+lit(case['preparation_id'])+','+lit(case['hold_id'])+','+lit(held['fingerprint'])+')')
        self.call('owner','private.propose_offline_reward_financial_consent('+lit(case['proposal_id'])+','+lit(case['preparation_id'])+')')
        view=self.call('customer','public.get_my_offline_reward_financial_proposal('+lit(case['proposal_id'])+')');assert view['state']=='proposal'
        consent={'accepted':True,'version':'offline-reward-financial-v1','language':'en','text':view['consent']['notice_en']}
        accepted=self.call('customer','public.accept_my_offline_reward_financial_consent('+','.join(map(lit,[case['consent_id'],case['proposal_id'],view['fingerprint']]))+','+lit(json.dumps(consent))+'::jsonb)');assert accepted['state']=='consent_recorded'
        staff='array['+','.join(map(lit,self.f['worker_ids']))+']::uuid[]'
        prepared=self.call('owner','private.prepare_offline_reward_issue('+','.join(map(lit,[case['issue_id'],case['preparation_id'],case['consent_id'],self.f['registration_request_id']]))+','+staff+')');assert prepared['state']=='prepared'
        case['stage']='prepared';self.checkpoint();return case
    def pair(self,name):
        values=[PsqlSession(self.command,self.env,'qa_typed_issuer_'+name+'_'+str(n))for n in [1,2]];self.sessions.extend(values);return values
    def wait_lock(self,second,first):
        until=time.monotonic()+8
        while time.monotonic()<until:
            if self.sql('select exists(select 1 from pg_stat_activity where pid='+str(second.pid)+" and wait_event_type='Lock'and "+str(first.pid)+'=any(pg_blocking_pids(pid)));')=='t':return
            if second.proc.poll()is not None:raise SafeFailure('waiter_exited')
            time.sleep(.05)
        raise SafeFailure('actual_lock_wait_not_observed')
    def start(self,session,role,body):
        marker='QA_TYPED_'+uuid.uuid4().hex;session.send(self.tx(role,body)+'\n\\echo '+marker);return marker
    def race(self,name):
        if name=='competing_last_credit':return self.competing_last_credit()
        c=self.fresh(name);a,b=self.pair(name);place='private.place_offline_reward_issue('+lit(c['issue_id'])+')';withdraw='public.revoke_my_offline_reward_financial_consent('+lit(c['withdraw_id'])+','+lit(c['consent_id'])+')'
        c['stage']='race_dispatch';self.checkpoint()
        if name=='exact_retry':
            first=obj(a.run(self.tx('owner','select '+place+';')));marker=self.start(b,'owner','select '+place+';')
            self.wait_lock(b,a);a.run('commit;');second=obj(b.wait(marker));b.run('commit;')
            assert first['state']=='issued'and second['state']=='issued'and first['result']['invoice_id']==second['result']['invoice_id']
        elif name=='withdraw_first':
            first=obj(a.run(self.tx('customer','select '+withdraw+';')));assert first['state']=='revoked'
            rejection="do $$declare denied boolean:=false;begin begin perform "+place+";exception when sqlstate '55000'then denied:=true;end;assert denied,'Expected withdrawn actual consent';end$$;select jsonb_build_object('rejected',true);"
            marker=self.start(b,'owner',rejection);self.wait_lock(b,a);a.run('commit;');assert obj(b.wait(marker))['rejected']is True;b.run('commit;')
        elif name=='issue_first_withdraw':
            first=obj(a.run(self.tx('owner','select '+place+';')));assert first['state']=='issued';marker=self.start(b,'customer','select '+withdraw+';')
            self.wait_lock(b,a);a.run('commit;');second=obj(b.wait(marker));b.run('commit;')
            assert second['state']=='already_issued'and second['withdrawal_applied']is False
            assert self.call('customer',withdraw)==second
        elif name=='source_refund_first':
            assert self.sql('select exists(select 1 from private.service_reward_quotes quote where quote.reserve_request_id='+lit(c['hold_id'])+' and quote.earning_ids=array['+lit(self.f['source_earning_id'])+']::uuid[]);')=='t'
            c['refund_dispatch']=True;self.checkpoint() # refund UUID already journaled
            refund="set local role authenticated;select jsonb_build_object('refund_payment_id',public.record_shift_payment("+','.join(map(lit,[c['refund_id'],self.f['cash_shift_id'],self.source_baseline['invoice_id']]))+",'refund','cash'));"
            first=obj(a.run(self.tx('owner',refund)));assert first['refund_payment_id']==c['refund_id']
            rejection="do $$declare denied boolean:=false;begin begin perform "+place+";exception when sqlstate '55000'then denied:=true;end;assert denied,'Actual committed source refund must block issue';end$$;select jsonb_build_object('rejected',true);"
            marker=self.start(b,'owner',rejection);self.wait_lock(b,a);a.run('commit;');assert obj(b.wait(marker))['rejected']is True;b.run('commit;')
            assert self.sql('select exists(select 1 from public.business_payment_events where payment_id='+lit(c['refund_id'])+' and invoice_id='+lit(self.source_baseline['invoice_id'])+" and event_type='refund'and method='cash');")=='t'
        elif name=='issuer_first_source_refund':
            assert self.sql('select exists(select 1 from private.service_reward_quotes quote where quote.reserve_request_id='+lit(c['hold_id'])+' and quote.earning_ids=array['+lit(self.f['source_earning_id'])+']::uuid[]);')=='t'
            first=obj(a.run(self.tx('owner','select '+place+';')));assert first['state']=='issued'
            c['redemption_id']=str(uuid.UUID(first['result']['redemption_id']));c['order_id']=str(uuid.UUID(first['result']['order_id']));c['refund_dispatch']=True;self.checkpoint()
            refund="set local role authenticated;select jsonb_build_object('refund_payment_id',public.record_shift_payment("+','.join(map(lit,[c['refund_id'],self.f['cash_shift_id'],self.source_baseline['invoice_id']]))+",'refund','cash'));"
            marker=self.start(b,'owner',refund);self.wait_lock(b,a);a.run('commit;');second=obj(b.wait(marker));b.run('commit;');assert second['refund_payment_id']==c['refund_id']
            self.sql(self.tx('owner','select private.sync_offline_profile_rewards('+lit(self.f['profile_id'])+');commit;'))
            reviews=obj(self.sql("select jsonb_build_object('count',count(*),'review_id',min(review.review_id::text),'bound',coalesce(bool_and(review.earning_id="+lit(self.f['source_earning_id'])+' and review.refund_payment_id='+lit(c['refund_id'])+" and review.owner_kind='offline_profile'and review.customer_id is null and review.offline_profile_id="+lit(self.f['profile_id'])+" and review.closed_at is null and review.mode=quote.terms_snapshot#>>'{rules,refunded_contribution}'and claim.redemption_id=receipt.redemption_id and claim.earning_id=review.earning_id and claim.kind='reward'and claim.released_at is null),false))from private.reward_refund_reviews review join private.service_reward_redemptions receipt on receipt.redemption_id=review.redemption_id join private.service_reward_quotes quote on quote.quote_id=receipt.quote_id join private.reward_credit_claims claim on claim.claim_id=review.original_claim_id where receipt.offline_issue_id="+lit(c['issue_id'])+';'))
            assert reviews['count']==1 and reviews['bound']is True;c['review_id']=str(uuid.UUID(reviews['review_id']));self.checkpoint()
            self.sql(self.tx('owner','select private.sync_offline_profile_rewards('+lit(self.f['profile_id'])+');commit;'))
            assert self.sql('select count(*)from private.reward_refund_reviews where redemption_id='+lit(c['redemption_id'])+' and refund_payment_id='+lit(c['refund_id'])+';')=='1'
            assert self.sql("select count(*)from private.offline_reward_issue_events where event_key='review:'||(select original_claim_id::text from private.reward_refund_reviews where review_id="+lit(c['review_id'])+")||':'||"+lit(c['refund_id'])+' and redemption_id='+lit(c['redemption_id'])+" and action='refund_review';")=='1'
            assert self.sql('select not exists(select 1 from private.reward_credit_claims where debt_id='+lit(c['review_id'])+');')=='t','No invented future credit or debt waiver'
            current=self.call('owner','private.get_offline_reward_issue('+lit(c['issue_id'])+')')
            assert current['state']=='issued'and current['result']['payment_status']=='covered_by_reward'and current['result']['amount_due']==0 and current['result']['collectible']is False
            assert self.sql('select not exists(select 1 from public.business_payment_events where invoice_id='+lit(first['result']['invoice_id'])+');')=='t','No retrospective cash charge on issued benefit'
            assert self.sql('select not private.offline_reward_debt_clear('+lit(self.f['profile_id'])+','+lit(self.f['rules_version_id'])+');')=='t'
            c['issued_benefit_honored']=True;c['review_exactly_once']=True;self.checkpoint()
        elif name=='close_first':
            first=obj(a.run(self.tx('owner','select private.close_offline_reward_issue('+lit(c['issue_id'])+');')));assert first['state']=='closed'
            marker=self.start(b,'owner','select '+place+';');self.wait_lock(b,a);a.run('commit;');second=obj(b.wait(marker));b.run('commit;');assert second['state']=='closed'
        for session in[a,b]:session.rollback_close();self.sessions.remove(session)
        current=self.call('owner','private.get_offline_reward_issue('+lit(c['issue_id'])+')')
        count=int(self.sql('select count(*)from private.service_reward_redemptions where offline_issue_id='+lit(c['issue_id'])+';'))
        assert count==(1 if name in('exact_retry','issue_first_withdraw','issuer_first_source_refund')else 0)
        c['stage']='race_verified';self.proof['cases'].append({'case':name,'actual_pg_blocking_pids_wait':True,'passed':True,'redemption_count':count,'committed_source_refund_blocks_invoice':name=='source_refund_first','issued_benefit_honored_after_source_refund':c.get('issued_benefit_honored',False),'refund_review_exactly_once':c.get('review_exactly_once',False)});self.checkpoint()
        self.cleanup_case(c)
    def competing_last_credit(self):
        c={'name':'competing_last_credit','hold_id':uid(),'loser_hold_id':uid(),'issue_id':uid(),'stage':'producer_not_sent'}
        self.state['cases'].append(c);self.checkpoint()
        a,b=self.pair(c['name'])
        def reserve(request):return 'private.reserve_offline_reward_candidates('+','.join(map(lit,[request,self.f['profile_id'],self.f['car_ref_id'],self.f['channel_version_id']]))+','+self.gross+')'
        c['stage']='race_dispatch';self.checkpoint()
        first=obj(a.run(self.tx('owner','select '+reserve(c['hold_id'])+';')));assert first['state']=='active'
        rejection="do $$declare denied boolean:=false;begin begin perform "+reserve(c['loser_hold_id'])+";exception when sqlstate '55000'then denied:=true;end;assert denied,'Last actual credit cannot be reserved twice';end$$;select jsonb_build_object('rejected',true);"
        marker=self.start(b,'owner',rejection);self.wait_lock(b,a);a.run('commit;');assert obj(b.wait(marker))['rejected']is True;b.run('commit;')
        for session in[a,b]:session.rollback_close();self.sessions.remove(session)
        assert self.sql('select exists(select 1 from private.service_reward_quotes where reserve_request_id='+lit(c['hold_id'])+' and earning_ids=array['+lit(self.f['source_earning_id'])+']::uuid[]);')=='t'
        assert self.sql('select count(*)from private.reward_credit_claims where earning_id='+lit(self.f['source_earning_id'])+' and released_at is null;')=='1'
        assert self.sql('select not exists(select 1 from private.offline_reward_reservation_commands where request_id='+lit(c['loser_hold_id'])+')and not exists(select 1 from private.service_reward_quotes where reserve_request_id='+lit(c['loser_hold_id'])+')and not exists(select 1 from private.reward_credit_claims where reserve_request_id='+lit(c['loser_hold_id'])+');')=='t'
        c['stage']='race_verified';self.proof['cases'].append({'case':c['name'],'actual_pg_blocking_pids_wait':True,'one_actual_active_claim':True,'different_nonce_loser_no_quote_or_claim':True,'passed':True,'redemption_count':0});self.checkpoint();self.cleanup_case(c)
    def cleanup_case(self,c):
        if c['name']=='competing_last_credit':
            for request in[c['hold_id'],c['loser_hold_id']]:
                if self.sql('select exists(select 1 from private.offline_reward_reservation_commands where request_id='+lit(request)+' and offline_profile_id='+lit(self.f['profile_id'])+' and requested_by='+lit(self.f['owner_id'])+');')=='t':
                    self.call('owner','private.release_offline_reward_reservation('+lit(request)+",'Release only exact competing clone QA hold')")
            assert self.sql('select not exists(select 1 from private.reward_credit_claims where reserve_request_id in('+lit(c['hold_id'])+','+lit(c['loser_hold_id'])+')and released_at is null);')=='t'
            c['stage']='canonically_cleaned';self.checkpoint();return
        current=self.call('owner','private.get_offline_reward_issue('+lit(c['issue_id'])+')')
        if current['state']=='issued':
            order=str(uuid.UUID(current['result']['order_id']))
            assert self.sql('select exists(select 1 from private.offline_walk_in_subjects subject where subject.order_id='+lit(order)+' and subject.reward_issue_id='+lit(c['issue_id'])+' and subject.profile_id='+lit(self.f['profile_id'])+' and subject.branch_id='+lit(self.f['branch_id'])+');')=='t'
            c['order_id']=order;self.checkpoint()
            if current['result']['work_status']=='received':
                self.call('owner','private.cancel_offline_reward_issue('+lit(c['cancel_id'])+','+lit(c['issue_id'])+",'Clone-only exact newly created received QA reward cleanup')")
            else:
                assert current['result']['work_status']=='cancelled'and current['result']['invoice_status']=='void'
                assert self.sql('select coalesce(private.reward_invoice_coverage(invoice_id)->>'+lit('state')+"='cancelled_reward',false)from private.offline_walk_in_subjects where order_id="+lit(order)+';')=='t'
        else:self.call('owner','private.close_offline_reward_issue('+lit(c['issue_id'])+')')
        self.call('owner','private.ack_offline_reward_issue('+lit(c['issue_id'])+')')
        self.call('owner','private.close_offline_reward_consumption('+lit(c['preparation_id'])+",'Close only exact journaled unconsumed clone QA hold')")
        exists=self.sql('select exists(select 1 from private.offline_reward_reservation_commands where request_id='+lit(c['hold_id'])+' and offline_profile_id='+lit(self.f['profile_id'])+' and requested_by='+lit(self.f['owner_id'])+');')
        if exists=='t':self.call('owner','private.release_offline_reward_reservation('+lit(c['hold_id'])+",'Release only exact journaled unconsumed clone QA hold')")
        assert self.sql('select not exists(select 1 from private.reward_credit_claims where released_at is null and(reserve_request_id='+lit(c['hold_id'])+' or redemption_id in(select redemption_id from private.service_reward_redemptions where offline_issue_id='+lit(c['issue_id'])+')));')=='t'
        c['stage']='canonically_cleaned';self.checkpoint()
    def preservation(self):
        after=self.rows();expected_refunds=[]
        for case in self.state['cases']:
            if case['name']in('source_refund_first','issuer_first_source_refund')and case.get('refund_dispatch'):
                exists=self.sql('select exists(select 1 from public.business_payment_events where payment_id='+lit(case['refund_id'])+' and invoice_id='+lit(self.source_baseline['invoice_id'])+" and event_type='refund'and method='cash'and actor_id="+lit(self.f['owner_id'])+' and shift_id='+lit(self.f['cash_shift_id'])+' and amount='+str(self.source_baseline['sale_amount'])+');')=='t'
                if exists:expected_refunds.append(case['refund_id'])
        assert len(expected_refunds)<=1
        protected={table:Counter(rows)for table,rows in self.before.items()}
        if expected_refunds:
            assert self.sql('select status='+lit('refunded')+" and md5((to_jsonb(invoice)-'status')::text)="+lit(self.source_baseline['non_status_hash'])+' from public.business_invoices invoice where invoice_id='+lit(self.source_baseline['invoice_id'])+';')=='t','Only exact source invoice status may change'
            protected['public.business_invoices'][self.source_baseline['row_hash']]-=1
            if not protected['public.business_invoices'][self.source_baseline['row_hash']]:del protected['public.business_invoices'][self.source_baseline['row_hash']]
        self.proof['authorized_source_invoice_status_change_only']=bool(expected_refunds)
        self.proof['all_other_preexisting_clone_rows_unchanged']=all(not(rows-after.get(table,Counter()))for table,rows in protected.items())
        self.proof['all_preexisting_clone_rows_unchanged']=not expected_refunds and self.proof['all_other_preexisting_clone_rows_unchanged']
        self.proof['expected_scoped_refund_count']=len(expected_refunds)

        allowed={'private.offline_reward_issue_commands','private.offline_reward_issue_events','private.offline_reward_post_issue_withdrawals','private.offline_reward_financial_proposals','private.offline_reward_financial_consents','private.offline_reward_financial_revocations','private.offline_reward_consumption_preparations','private.offline_reward_consumption_closures','private.offline_reward_reservation_commands','private.offline_reward_reservation_events','private.service_reward_quotes','private.reward_credit_claims','private.service_reward_redemptions','private.reward_ledger_events','private.offline_walk_in_commands','private.offline_walk_in_subjects','private.offline_walk_in_commissions','private.offline_walk_in_reception','private.offline_walk_in_events','private.offline_service_visit_order_snapshots','private.loyalty_visit_outbox','public.business_orders','public.business_order_items','public.business_invoices','public.business_audit_log'}
        scoped_after={table:Counter(rows)for table,rows in after.items()}
        # Never permit the payment table wholesale: remove ONLY the one verified
        # newly appended journaled refund hash, then apply the old strict allowlist.
        for refund in expected_refunds:
            row_hash=self.sql('select md5(to_jsonb(payment)::text)from public.business_payment_events payment where payment_id='+lit(refund)+' and invoice_id='+lit(self.source_baseline['invoice_id'])+" and event_type='refund'and method='cash';")
            assert(scoped_after.get('public.business_payment_events',Counter())-self.before.get('public.business_payment_events',Counter()))[row_hash]==1
            scoped_after['public.business_payment_events'][row_hash]-=1
            if not scoped_after['public.business_payment_events'][row_hash]:del scoped_after['public.business_payment_events'][row_hash]
        scoped_reviews=0
        for case in self.state['cases']:
            if case['name']=='issuer_first_source_refund'and case.get('refund_id')in expected_refunds:
                data=obj(self.sql("select jsonb_build_object('count',count(*),'hash',min(md5(to_jsonb(review)::text)),'closed',coalesce(bool_and(review.closed_at is not null and review.owner_kind='offline_profile'and review.customer_id is null and review.offline_profile_id="+lit(self.f['profile_id'])+' and review.earning_id='+lit(self.f['source_earning_id'])+' and review.refund_payment_id='+lit(case['refund_id'])+' and claim.redemption_id=receipt.redemption_id and claim.earning_id=review.earning_id and claim.released_at is not null and receipt.state='+lit('restored')+"),false))from private.reward_refund_reviews review join private.service_reward_redemptions receipt on receipt.redemption_id=review.redemption_id join private.reward_credit_claims claim on claim.claim_id=review.original_claim_id where receipt.offline_issue_id="+lit(case['issue_id'])+';'))
                assert data['count']==1 and data['closed']is True,'Only exact new restored receipt/refund review may be retained'
                row_hash=data['hash'];assert(scoped_after.get('private.reward_refund_reviews',Counter())-self.before.get('private.reward_refund_reviews',Counter()))[row_hash]==1
                scoped_after['private.reward_refund_reviews'][row_hash]-=1
                if not scoped_after['private.reward_refund_reviews'][row_hash]:del scoped_after['private.reward_refund_reviews'][row_hash]
                scoped_reviews+=1
        self.proof['exact_new_scoped_refund_reviews_closed']=scoped_reviews
        self.proof['refund_review_table_not_generally_allowlisted']='private.reward_refund_reviews'not in allowed
        if 'issuer_first_source_refund'in self.a.cases:
            allowed.discard('private.reward_credit_claims')
            case=next(v for v in self.state['cases']if v['name']=='issuer_first_source_refund')
            data=obj(self.sql("select jsonb_build_object('count',count(*),'hashes',coalesce(jsonb_agg(md5(to_jsonb(claim)::text)),'[]'::jsonb))from private.reward_credit_claims claim where(claim.reserve_request_id="+lit(case['hold_id'])+' or claim.redemption_id=(select redemption_id from private.service_reward_redemptions where offline_issue_id='+lit(case['issue_id'])+'))and claim.earning_id='+lit(self.f['source_earning_id'])+' and claim.offline_profile_id='+lit(self.f['profile_id'])+" and claim.owner_kind='offline_profile'and claim.customer_id is null and claim.kind in('reserve','reward')and claim.released_at is not null;"))
            assert data['count']==2,'Only exact released reserve and consumed/restored reward claims allowed'
            for row_hash in data['hashes']:
                assert(scoped_after.get('private.reward_credit_claims',Counter())-self.before.get('private.reward_credit_claims',Counter()))[row_hash]==1
                scoped_after['private.reward_credit_claims'][row_hash]-=1
                if not scoped_after['private.reward_credit_claims'][row_hash]:del scoped_after['private.reward_credit_claims'][row_hash]
            self.proof['claim_table_not_generally_allowlisted']=True
        self.proof['only_expected_new_rows']={table for table,rows in scoped_after.items()if rows-self.before.get(table,Counter())}<=allowed
        self.proof['payment_table_not_generally_allowlisted']='public.business_payment_events'not in allowed

        counters=obj(self.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));ids=','.join(lit(v['issue_id'])for v in self.state['cases']);issued=int(self.sql("select count(*)from private.offline_reward_issue_commands where state='issued'and request_id in("+ids+');'))if ids else 0
        self.proof['exact_document_counter_delta']=counters['BKG']==self.counters['BKG']and counters['INV']==self.counters['INV']+issued
        payment_delta=int(self.sql('select count(*)from public.business_payment_events;'))-self.base_payments
        self.proof['new_payment_events_zero']=payment_delta==0
        self.proof['payment_delta_matches_only_scoped_refund']=payment_delta==len(expected_refunds)
        self.proof['no_new_cash_sale']=int(self.sql("select count(*)from public.business_payment_events where event_type='sale';"))==self.base_sales
        self.proof['new_positive_credits_zero']=int(self.sql("select count(*)from private.canonical_loyalty_visits where kind='earn';"))==self.base_earns
        self.proof['scheduler_body_unchanged']=self.sql("select md5(prosrc)from pg_proc where oid='private.loyalty_visit_scheduler_ready()'::regprocedure;")==self.scheduler_hash
        self.proof['false_gates_and_original_check_preserved']=self.sql("select not public_enabled and not(select earning_enabled from private.offline_service_visit_runtime where singleton)and not(select read_enabled from private.offline_visit_wallet_runtime where singleton)and exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%')from private.offline_reward_issuer_runtime where singleton;")=='t'
        self.proof['fixture_seed_retained_for_other_acceptance']=True
    def run(self):
        try:
            self.preflight()
            for name in self.a.cases:self.race(name)
        except Exception as failure:
            self.proof['failure_class']=type(failure).__name__;frames=[];frame=failure.__traceback__
            while frame:
                if Path(frame.tb_frame.f_code.co_filename).resolve()==Path(__file__).resolve():frames.append({'function':frame.tb_frame.f_code.co_name,'line':frame.tb_lineno})
                frame=frame.tb_next
            self.proof['failure_locations']=frames
        finally:
            for session in self.sessions:session.rollback_close()
            self.sessions=[];cleanup=True
            for case in self.state['cases']:
                if case['stage']!='canonically_cleaned':
                    try:self.cleanup_case(case)
                    except Exception:cleanup=False
            self.state['cleanup_complete']=cleanup;self.proof['canonical_cleanup_complete']=cleanup
            if self.before is not None:
                try:self.preservation()
                except Exception:self.proof['preservation_check_failed']=True
            checks=['all_other_preexisting_clone_rows_unchanged','only_expected_new_rows','exact_document_counter_delta','payment_delta_matches_only_scoped_refund','payment_table_not_generally_allowlisted','refund_review_table_not_generally_allowlisted','no_new_cash_sale','new_positive_credits_zero','scheduler_body_unchanged','false_gates_and_original_check_preserved','canonical_cleanup_complete']
            self.proof['all_passed']=len(self.proof['cases'])==len(self.a.cases)and all(self.proof.get(k)is True for k in checks)and'failure_class'not in self.proof
            self.state['stage']='complete'if self.proof['all_passed']else'stopped_review_required';self.checkpoint()
        return self.proof['all_passed']

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--execute',action='store_true');p.add_argument('--runtime',type=Path,default=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime'));p.add_argument('--database');p.add_argument('--fixture',type=Path);p.add_argument('--state',type=Path);p.add_argument('--proof',type=Path);p.add_argument('--cases',nargs='+',choices=CASES,default=list(INITIAL_CASES));a=p.parse_args()
    if not a.execute:print('PLAN ONLY: selected real clone SQL races; original four default, NEW allocator/refund cases require explicit --cases; issuer_first_source_refund runs ALONE on its fresh genuine-credit fixture. Refund runs last and intentionally changes only exact QA source invoice status/payment ledger; no DB/Auth/network/file reads.');return 0
    if not all([a.database,a.fixture,a.state,a.proof]):p.error('Explicit clone database, committed root fixture and fresh state/proof required')
    if len(set(a.cases))!=len(a.cases):p.error('No duplicate cases')
    destructive=[name for name in a.cases if name in('source_refund_first','issuer_first_source_refund')]
    if len(destructive)>1:p.error('One authorized source refund per explicit genuine-credit fixture')
    if 'issuer_first_source_refund'in a.cases and len(a.cases)!=1:p.error('Run this NEW case alone against its explicit fresh genuine-credit fixture')
    if 'issuer_first_source_refund'in a.cases and a.cases[-1]!='issuer_first_source_refund':p.error('Source refund must run LAST')
    if 'source_refund_first'in a.cases and a.cases[-1]!='source_refund_first':p.error('Destructive source refund case must run LAST')
    if 'competing_last_credit'in a.cases and 'source_refund_first'in a.cases and a.cases.index('competing_last_credit')>a.cases.index('source_refund_first'):p.error('Competing last credit must run before refund')
    if a.state.resolve()==a.proof.resolve():p.error('Distinct state/proof required')
    for path in[a.fixture,a.state,a.proof]:path.resolve().relative_to(a.runtime.resolve())
    for path in[a.state,a.proof]:
        if path.exists():p.error('Archive/review previous artifacts; no automatic rerun')
        path.parent.mkdir(parents=True,exist_ok=True)
    try:passed=Run(a).run()
    except Exception:print('FAIL initialization; details redacted; no automatic retry');return 1
    print('PASS clone private issuer concurrency and canonical cleanup'if passed else'FAIL stopped; sanitized proof and UUID journal require review');return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
