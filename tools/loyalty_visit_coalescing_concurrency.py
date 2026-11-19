"""PLAN by default. SOURCE ONLY until root releases local exclusive DB slot.
Real worker, existing isolated legacy service reference, new private QA outbox only.
No Auth, financial/loyalty source mutations, replacement reconciler or deletion.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def uid(): return str(uuid.uuid4())
def lit(v): return "'"+str(v).replace("'","''")+"'"


class QA:
    def __init__(self,args):
        self.args=args;self.r=args.runtime.resolve();self.sessions=[];self.events=[];self.before=None;self.controller=None
        sock=self.r/'instances/sabiha-local/sock/docker.sock';assert sock.is_socket()
        self.env={**os.environ,'DOCKER_HOST':'unix://'+str(sock),'DOCKER_CONFIG':str(self.r/'docker-config')}
        self.cmd=[str(self.r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
        self.proof={'local_only':True,'business_rows_created':False,'auth_created':False,'finance_mutated':False,'replacement_reconciler':False,'all_passed':False,'stage':'preflight'}
    def sql(self,q):
        p=subprocess.run(self.cmd,input=q,env=self.env,text=True,capture_output=True,timeout=35)
        if p.returncode:raise RuntimeError('SQL failed; context redacted')
        return p.stdout.strip()
    def session(self,name):
        s=PsqlSession(self.cmd,self.env,name);self.sessions.append(s);return s
    def checkpoint(self):
        self.args.state.write_text(json.dumps({'local_only':True,'order_id':getattr(self,'order',None),'event_ids':self.events},indent=2)+'\n');self.args.state.chmod(0o600)
    def rows(self):
        q="""create temp table qa_coalesce_hash(t text,h text);do $$declare t record;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private')loop
        execute format('insert into qa_coalesce_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;
        select t||'|'||h from qa_coalesce_hash order by t,h;"""
        return Counter(self.sql(q).splitlines())
    def add(self,n):
        new=[uid()for _ in range(n)];self.events.extend(new);self.checkpoint()
        self.sql('insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id)values'+','.join('('+lit(v)+",'business_orders',"+lit(v)+','+lit(self.order)+')'for v in new)+';')
        return new
    def state(self,ids):
        return json.loads(self.sql("select jsonb_build_object('pending',count(*)filter(where processed_at is null),'attempts',coalesce(sum(attempts),0),'count',count(*))from private.loyalty_visit_outbox where event_id in("+','.join(map(lit,ids))+');'))
    @staticmethod
    def result(lines):return json.loads(next(v for v in reversed(lines)if v.startswith('{')))
    @staticmethod
    def drain(s,commit=True):return QA.result(s.run('begin;set local role service_role;select public.drain_loyalty_visit_event();'+('commit;'if commit else'')))
    def waiting(self,a,b):
        end=time.monotonic()+10
        while time.monotonic()<end:
            if self.sql('select exists(select 1 from pg_stat_activity where pid='+str(a.pid)+" and wait_event_type='Lock' and wait_event='advisory' and "+str(b.pid)+'=any(pg_blocking_pids(pid)));')=='t':return
            time.sleep(.05)
        raise RuntimeError('Expected actual advisory wait absent')
    def send(self,s):
        marker='QA_COALESCING_'+uuid.uuid4().hex
        s.send('begin;set local role service_role;select public.drain_loyalty_visit_event();commit;\n\\echo '+marker)
        return marker
    def test(self):
        self.controller=self.session('qa_coalescing_controller')
        self.controller.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));")
        assert self.sql('select not exists(select 1 from private.loyalty_visit_outbox where processed_at is null);')=='t'
        assert self.sql('select private.loyalty_visit_scheduler_ready();')=='t'
        assert self.sql("select to_regprocedure('private.coalescible_loyalty_order(private.loyalty_visit_outbox)')is not null;")=='t'
        self.order=self.sql("select o.order_id from public.business_orders o where o.order_type='service'and o.status='received'and o.booking_id is null and not exists(select 1 from private.offline_walk_in_subjects s where s.order_id=o.order_id)and not exists(select 1 from private.canonical_loyalty_visits v where v.order_id=o.order_id)order by o.order_id limit 1;")
        uuid.UUID(self.order);self.before=self.rows();self.checkpoint()
        a=self.session('qa_coalescing_first');b=self.session('qa_coalescing_second')
        self.proof['stage']='two_worker_skip_locked'
        first,second=self.add(2)
        # A owns its anchor; B must skip it, then retain only B's own event lock.
        a.run('begin;select event_id from private.loyalty_visit_outbox where event_id='+lit(first)+' for update;')
        result=self.drain(b,False);assert result.get('processed')is True
        marker='QA_SKIP_'+uuid.uuid4().hex
        a.send('set local role service_role;select public.drain_loyalty_visit_event();commit;\n\\echo '+marker)
        self.waiting(a,b)  # A waits canonical, never B's outbox row; B can commit.
        b.run('commit;');assert self.result(a.wait(marker)).get('processed')is True
        assert self.state([first,second])=={'pending':0,'attempts':2,'count':2}
        self.proof['actual_two_workers_skip_locked_without_event_canonical_deadlock']=True
        self.proof['stage']='new_event_after_capture'
        old=self.add(2)
        self.controller.run("select pg_advisory_lock(hashtextextended('canonical-visit:"+self.order+"',0));")
        marker=self.send(a);self.waiting(a,self.controller)
        late=self.add(1)  # Independent committed connection while reconcile waits.
        self.controller.run("select pg_advisory_unlock(hashtextextended('canonical-visit:"+self.order+"',0));")
        assert self.result(a.wait(marker)).get('processed')is True
        assert self.state(old)=={'pending':0,'attempts':2,'count':2}
        assert self.state(late)=={'pending':1,'attempts':0,'count':1}
        assert self.drain(b).get('processed')is True and self.state(late)['pending']==0
        self.proof['actual_concurrent_after_capture_event_preserved_and_drained']=True
        self.proof['stage']='worker_transaction_rollback'
        retry=self.add(2);assert self.drain(a,False).get('processed')is True;a.run('rollback;')
        assert self.state(retry)=={'pending':2,'attempts':0,'count':2}
        assert self.drain(b).get('processed')is True
        assert self.state(retry)=={'pending':0,'attempts':2,'count':2}
        self.proof['actual_worker_rollback_preserves_replay']=True
    def cleanup(self):
        errors=[]
        for s in self.sessions:
            if s is self.controller:continue
            try:s.rollback_close()
            except Exception:errors.append('owned_session_close')
        try:
            if self.controller:
                if hasattr(self,'order'):self.controller.run("select pg_advisory_unlock(hashtextextended('canonical-visit:"+self.order+"',0));")
                pending=json.loads(self.sql("select coalesce(jsonb_agg(event_id),'[]')from private.loyalty_visit_outbox where processed_at is null;"))
                assert set(pending)<=set(self.events),'Unrelated pending work: do not drain'
                if pending:
                    for _ in range(len(pending)):
                        if self.state(self.events)['pending']==0:break
                        value=json.loads(self.sql('select public.drain_loyalty_visit_event();'));assert value.get('processed')is True
                if self.events:assert self.state(self.events)['pending']==0
        except Exception:errors.append('known_event_cleanup_requires_review')
        if self.before is not None:
            try:
                after=self.rows();self.proof['all_original_rows_unchanged']=not bool(self.before-after)
                self.proof['only_new_private_outbox_rows']={x.split('|')[0]for x in(after-self.before)}<= {'private.loyalty_visit_outbox'}
                self.proof['outbox_empty']=self.sql('select not exists(select 1 from private.loyalty_visit_outbox where processed_at is null);')=='t'
            except Exception:errors.append('preservation_check')
        if self.controller:
            try:self.controller.rollback_close()  # Releases only owned session advisory locks.
            except Exception:errors.append('controller_close')
        self.proof['cleanup_errors']=errors;self.proof['cleanup_complete']=not errors
    def run(self):
        try:self.test()
        except Exception as failure:self.proof['failure_class']=type(failure).__name__
        finally:self.cleanup();self.checkpoint()
        keys=['actual_two_workers_skip_locked_without_event_canonical_deadlock','actual_concurrent_after_capture_event_preserved_and_drained','actual_worker_rollback_preserves_replay','all_original_rows_unchanged','only_new_private_outbox_rows','outbox_empty','cleanup_complete']
        self.proof['all_passed']=all(self.proof.get(k)is True for k in keys)
        self.args.proof.write_text(json.dumps(self.proof,indent=2)+'\n');self.args.proof.chmod(0o600)
        return self.proof['all_passed']


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--execute',action='store_true');p.add_argument('--runtime',type=Path,default=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime'));p.add_argument('--state',type=Path);p.add_argument('--proof',type=Path);a=p.parse_args()
    if not a.execute:print('PLAN ONLY: no DB/API/credentials accessed; root review and exclusive release required');return 0
    if not a.state or not a.proof:p.error('Explicit --state and --proof required')
    if a.state.exists()or a.proof.exists():p.error('Archive existing artifacts before approved retry')
    a.state.parent.mkdir(parents=True,exist_ok=True);a.proof.parent.mkdir(parents=True,exist_ok=True)
    try:ok=QA(a).run()
    except Exception:print('FAIL: initialization; context redacted');return 1
    print('PASS local coalescing concurrency; originals unchanged'if ok else'FAIL stopped; review sanitized proof before retry');return 0 if ok else 1
if __name__=='__main__':raise SystemExit(main())
