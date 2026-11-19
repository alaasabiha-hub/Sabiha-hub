"""PLAN default; SOURCE-ONLY until root reviews/releases one --execute run.
Local QA only: real two-session work/request/resource locks, customer booking vs
walk-in final slot, stale dispatch and atomic paired completion. No Auth creation,
HR edits, collections/refunds, fabricated stops or manual physical/loyalty updates.
Requires current eligible journal-proven QA employment; expired contracts STOP.
Retains tagged completed unpaid QA invoices (amount/document snapshots unchanged),
closes actual QA spans through reviewed work graph, cancels only eligible pending
unpaid work and hides NEW QA config. Incomplete cleanup is reported, never forced.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from checkout_retry_lock_concurrency import PsqlSession


def uid(): return str(uuid.uuid4())
def lit(value): return 'null' if value is None else "'" + str(value).replace("'", "''") + "'"
class SafeFailure(RuntimeError): pass


class WorkQA:
    def __init__(self, args):
        self.args = args
        self.r = args.runtime.resolve()
        self.accounts = json.loads((self.r/'test-accounts-final.json').read_text())
        parsed = urllib.parse.urlsplit(self.accounts['url'])
        assert parsed.scheme == 'http' and parsed.hostname == '127.0.0.1'
        self.base = self.accounts['url'].rstrip('/')
        sock = self.r/'instances/sabiha-local/sock/docker.sock'
        assert sock.is_socket()
        self.env = {**os.environ, 'DOCKER_HOST': 'unix://'+str(sock), 'DOCKER_CONFIG': str(self.r/'docker-config')}
        self.command = [str(self.r/'docker-cli/docker/docker'), 'exec','-i','supabase_db_supabase-local',
                        'psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
        self.actors = {role: str(uuid.UUID(self.accounts['users'][role]['id']))
                       for role in ['owner','manager','other_employee','employee','customer']}
        self.tokens, self.sessions = {}, []
        self.tag = 'workkernelqa-'+uuid.uuid4().hex[:10]
        self.branch, self.service = uid(), uid()
        self.staff = sorted([self.actors['manager'], self.actors['other_employee']])
        self.orders, self.bookings, self.financial_commands, self.work_commands, self.booking_attempts = [], [], [], [], []
        self.financial_hashes = {}
        self.prepared_book_payloads = {}
        self.branch_created = self.service_created = False
        self.borrowed_hashes = None
        self.before = self.counters_before = self.auth_before = None
        self.proof = {'source_local_only': True, 'production_touched': False,
                      'auth_accounts_created': 0, 'hr_contract_edits': 0, 'payment_rpcs_called': 0,
                      'physical_service_performed': False, 'tag': self.tag, 'all_passed': False,
                      'stage': 'preflight'}

    def checkpoint(self):
        data = {'local_only':True,'tag':self.tag,'actor_ids':self.actors,
                'branch_id':self.branch,'service_id':self.service,
                'branch_created':self.branch_created,'service_created':self.service_created,
                'borrowed_contract_hashes':self.borrowed_hashes,
                'orders':self.orders,'bookings':self.bookings,'financial_commands':self.financial_commands,
                'work_commands':self.work_commands,'booking_attempts':self.booking_attempts,
                'invoice_snapshot_hashes':self.financial_hashes}
        self.args.state.parent.mkdir(parents=True,exist_ok=True)
        self.args.state.write_text(json.dumps(data,indent=2)+'\n');self.args.state.chmod(0o600)

    def sql(self, source):
        p = subprocess.run(self.command,input=source,env=self.env,text=True,capture_output=True,timeout=35)
        if p.returncode: raise SafeFailure('SQL failed; context redacted')
        return p.stdout.strip()

    def http(self,path,data=None,role='owner',method='POST',error=None):
        headers={'apikey':self.accounts['anon_key'],'Content-Type':'application/json','Prefer':'return=minimal'}
        if role in self.tokens: headers['Authorization']='Bearer '+self.tokens[role]
        request=urllib.request.Request(self.base+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
        try:
            with urllib.request.urlopen(request,timeout=35)as response:
                body=response.read()
                if error: raise SafeFailure('Expected rejection unexpectedly succeeded')
                return json.loads(body)if body.strip()else None
        except urllib.error.HTTPError as failure:
            try: code=json.loads(failure.read()).get('code')
            except(ValueError,TypeError): code=None
            if code==error and error is not None:return {'rejected_code':code}
            self.proof['failed_endpoint']=urllib.parse.urlsplit(path).path
            self.proof['failed_http_status']=failure.code;self.proof['failed_http_code']=code
            raise SafeFailure('HTTP failed; body and inputs redacted')from None

    def rpc(self,name,data,role='owner',error=None):return self.http('/rest/v1/rpc/'+name,data,role,error=error)
    def patch(self,table,key,value,data):return self.http('/rest/v1/'+table+'?'+key+'=eq.'+value,data,method='PATCH')
    def stage(self,name):self.proof['stage']=name;self.checkpoint()
    def rows(self):
        raw=self.sql("""create temp table qa_work_hash(t text,h text);do $$declare t record;begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private')and tablename<>'document_number_counters'loop
        execute format('insert into qa_work_hash select %L,md5(row_to_json(r)::text)from %I.%I r',t.schemaname||'.'||t.tablename,t.schemaname,t.tablename);end loop;end$$;
        select t||'|'||h from qa_work_hash order by t,h;""")
        return Counter(raw.splitlines())
    def finance_hash(self,invoice):
        return self.sql("select md5(jsonb_build_object('id',invoice_id,'order',order_id,'branch',branch_id,'total',total,'discount',discount,'commission_model',commission_model,'commission_total',commission_total,'commission_share',commission_share,'workers',workers,'token',document_token,'number',display_number,'document',document_snapshot,'policy',payment_policy_snapshot,'reward',reward_snapshot)::text)from public.business_invoices where invoice_id="+lit(invoice)+';')
    def remember_order(self,result,kind):
        oid=str(uuid.UUID(result['order_id']));invoice=result['invoice_id']
        if not any(v['order_id']==oid for v in self.orders):
            self.orders.append({'order_id':oid,'invoice_id':invoice,'kind':kind})
            self.financial_hashes[invoice]=self.finance_hash(invoice)
        if result.get('booking_id')and result['booking_id']not in self.bookings:self.bookings.append(result['booking_id'])
        self.checkpoint();return oid

    def preflight(self):
        for role in self.actors:
            user=self.accounts['users'][role]
            value=self.http('/auth/v1/token?grant_type=password',{'email':user['email'],'password':user['password']},role=None)
            assert value['user']['id']==self.actors[role];self.tokens[role]=value['access_token']
        assert self.sql("select to_regprocedure('private.service_work_source_snapshot(uuid)')is not null and to_regprocedure('public.list_service_work_queue(uuid)')is not null;")=='t'
        assert self.sql("select(clock_timestamp()at time zone'Africa/Cairo')::time between '00:01'and '22:50';")=='t'
        assert self.sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'
        for role in ['manager','other_employee']:
            assert self.sql('select not exists(select 1 from private.service_work_commands where actor_id='+lit(self.actors[role])+" and state in('prepared','succeeded')and acknowledged_at is null);")=='t'
        assert self.sql('select not exists(select 1 from private.offline_walk_in_commands where actor_id='+lit(self.actors['manager'])+'and acknowledged_at is null);')=='t'
        assert self.sql('select not exists(select 1 from private.service_booking_attempts where customer_id='+lit(self.actors['customer'])+" and(state='open'or(state='succeeded'and acknowledged_at is null)));")=='t'
        self.args.contract_state.resolve().relative_to(self.r);self.args.contract_proof.resolve().relative_to(self.r)
        prior=json.loads(self.args.contract_state.read_text());priorproof=json.loads(self.args.contract_proof.read_text())
        assert prior['tag']==priorproof['tag']and priorproof['all_passed']is True and priorproof['borrowed_contracts_untouched']is True
        expected=prior['borrowed_contract_hashes'];assert set(expected)==set(self.staff)
        ids=','.join(map(lit,self.staff))
        current=json.loads(self.sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+ids+');'))
        assert current==expected,'QA employment changed: root fixture review required, never reset'
        assert self.sql('select count(*)=2 from private.hr_employment where staff_id in('+ids+")and currency='EGP'and starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and(ends_on is null or ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date);")=='t','QA contracts expired: no HR extension authorized'
        self.borrowed_hashes=current
        self.vehicle=self.sql('select v.id from public.vehicles v where v.customer_id='+lit(self.actors['customer'])+" and not exists(select 1 from public.bookings b where b.vehicle_id=v.id and b.status not in('cancelled','completed')and(b.booking_date+b.booking_time)between(clock_timestamp()at time zone'Africa/Cairo')-interval'1 hour'and(clock_timestamp()at time zone'Africa/Cairo')+interval'2 hours')order by v.id limit 1;")
        uuid.UUID(self.vehicle)
        self.before=self.rows();self.counters_before=json.loads(self.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
        self.auth_before=self.sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
        self.payment_before=self.sql('select md5(coalesce(string_agg(to_jsonb(p)::text,\'\'order by payment_id),\'\'))from public.business_payment_events p;')
        self.loyalty_before=self.sql("select md5(coalesce(string_agg(x::text,''order by x::text),''))from(select to_jsonb(t)x from private.canonical_loyalty_visits t union all select to_jsonb(t)from public.business_loyalty_transactions t)x;")
        self.checkpoint()

    def setup(self):
        self.stage('new_qa_config')
        self.branch_created=True;self.checkpoint()  # journal attempted ID before dispatch; response may be lost
        self.http('/rest/v1/business_branches',{'branch_id':self.branch,'name_ar':self.tag,'name_en':self.tag,'is_default':False})
        self.patch('business_branch_hours','branch_id',self.branch,{'opens_at':'00:00','closes_at':'23:59'})
        self.patch('business_branch_resources','branch_id',self.branch,{'capacity':1})
        self.http('/rest/v1/staff_branch_access',[{'user_id':v,'branch_id':self.branch}for v in sorted(set([*self.staff,self.actors['employee']]))])
        self.service_created=True;self.checkpoint()  # attempted ID, not proof of commit
        self.http('/rest/v1/business_catalog_items',{'item_id':self.service,'branch_id':self.branch,'item_type':'service','name':self.tag,'vehicle_type':'sedan','price':120,'duration_minutes':30,'resource_key':'wash','is_active':True,'is_public':True})
        self.checkpoint()

    def walk_in(self):
        registration,financial=uid(),uid()
        self.financial_commands.append(financial);self.checkpoint()
        phone='010'+str(uuid.uuid4().int%100000000).zfill(8)
        assert self.sql("select not exists(select 1 from private.offline_customer_contacts where phone_e164=private.offline_phone_key("+lit(phone)+",'EG'))and not exists(select 1 from public.customers where private.offline_phone_key(phone,'EG')=private.offline_phone_key("+lit(phone)+",'EG'));")=='t'
        receipt=self.rpc('register_offline_customer',{'p_request':registration,'p_branch':self.branch,'p_name':self.tag,'p_phone':phone,'p_country':'EG','p_car':{'plate_number':'QA-'+uuid.uuid4().hex[:10]},'p_consent':{'accepted':True,'version':'offline-registration-v1','language':'en','text':self.sql("select private.offline_registration_notice('en');")}},'manager')
        assert receipt['status']=='created_unverified';receipt.pop('enrollment_secret',None)
        self.rpc('prepare_offline_walk_in',{'p_request':financial,'p_registration':registration,'p_service':self.service,'p_expected_price':120,'p_cashier':self.actors['manager'],'p_staff_ids':self.staff,'p_notes':self.tag})
        placed=self.rpc('place_offline_walk_in',{'p_request':financial},'manager')
        oid=self.remember_order(placed['result'],'walk_in')
        self.rpc('ack_offline_walk_in_command',{'p_request':financial},'manager');return oid

    def prepare_work(self,order,expected,next_status,role='manager'):
        request=uid();self.work_commands.append({'request_id':request,'role':role,'order_id':order});self.checkpoint()
        self.rpc('prepare_service_work',{'p_request':request,'p_order':order,'p_expected_status':expected,'p_next_status':next_status,'p_reason':self.tag+' protocol QA'},role)
        return request
    def ack_work(self,request,role='manager'):self.rpc('ack_service_work_command',{'p_request':request},role)
    def step(self,order,expected,next_status,role='manager'):
        request=self.prepare_work(order,expected,next_status,role)
        value=self.rpc('place_service_work',{'p_request':request},role);self.ack_work(request,role);return value
    def close_work(self,request,role='manager'):
        value=self.rpc('close_service_work_command',{'p_request':request},role)
        assert value['status']in('closed','succeeded');self.ack_work(request,role)

    def prepare_booking(self):
        request=uid();self.booking_attempts.append(request);self.checkpoint()
        # Actual service guard accepts this explicit future QA time. The public
        # slot-list is 15-minute suggestions, not permission to bypass admission.
        times=json.loads(self.sql("select jsonb_build_object('day',((clock_timestamp()at time zone'Africa/Cairo')+interval'3 minutes')::date,'time',date_trunc('minute',(clock_timestamp()at time zone'Africa/Cairo')+interval'3 minutes')::time);"))
        payload={'p_service':self.service,'p_branch':self.branch,'p_vehicle':self.vehicle,'p_date':times['day'],'p_time':times['time'],'p_expected_price':120,'p_notes':self.tag}
        view=self.rpc('prepare_service_booking_attempt',{'p_request':request,'p_mode':'normal','p_payload':payload},'customer')
        self.prepared_book_payloads[request]=view['payload'];return request
    def booking_expression(self,request):
        p=self.prepared_book_payloads[request]
        values=[lit(request)+'::uuid',lit(p['p_service'])+'::uuid',lit(p['p_branch'])+'::uuid',lit(p['p_vehicle'])+'::uuid',lit(p['p_date'])+'::date',lit(p['p_time'])+'::time',lit(p['p_expected_price'])+'::numeric',lit(p['p_notes'])]
        return 'public.place_customer_service_booking('+','.join(values)+')'
    def create_booking(self):
        request=self.prepare_booking()
        result=self.rpc('place_customer_service_booking',{'p_request':request,**self.prepared_book_payloads[request]},'customer')
        self.remember_order(result,'booking');self.rpc('acknowledge_service_booking_attempt',{'p_request':request},'customer');return result
    def cancel_pending_booking(self,booking):
        self.rpc('change_customer_booking',{'p_request':uid(),'p_booking':booking,'p_action':'cancel'},'customer')
    def dispatch_booked(self,booking):
        self.patch('bookings','id',booking,{'status':'confirmed','assigned_staff_ids':[self.actors['other_employee']]})

    def pair(self):
        a=PsqlSession(self.command,self.env,'qa_work_kernel_first');b=PsqlSession(self.command,self.env,'qa_work_kernel_second');self.sessions.extend([a,b]);return a,b
    def tx(self,body,role='manager'):
        return 'begin;select set_config(\'request.jwt.claim.sub\','+lit(self.actors[role])+',true);set local role authenticated;'+body
    @staticmethod
    def result(lines):return json.loads(next(v for v in reversed(lines)if v.startswith('{')))
    def wait_block(self,second,first):
        end=time.monotonic()+10
        while time.monotonic()<end:
            if self.sql('select exists(select 1 from pg_stat_activity where pid='+str(second.pid)+" and wait_event_type='Lock'and "+str(first.pid)+'=any(pg_blocking_pids(pid)));')=='t':return
            time.sleep(.05)
        raise SafeFailure('Expected actual lock wait not observed')
    def send_expected(self,session,expression,code,role='manager'):
        marker='QA_EXPECTED_'+uid().replace('-','')
        session.send(self.tx("do $$begin perform "+expression+";raise exception 'Unexpected concurrent success'using errcode='PZ999';exception when sqlstate '"+code+"'then raise notice 'QA_REJECTED_"+code+"';end$$;commit;",role)+'\n\\echo '+marker)
        return marker

    def tests(self):
        self.stage('same_nonce_start')
        first_order=self.walk_in();second_order=self.walk_in()
        request=self.prepare_work(first_order,'received','in_progress')
        a,b=self.pair();one=self.result(a.run(self.tx('select public.place_service_work('+lit(request)+');')))
        marker='QA_REPLAY_'+uid().replace('-','');b.send(self.tx('select public.place_service_work('+lit(request)+');commit;')+'\n\\echo '+marker)
        self.wait_block(b,a);a.run('commit;');two=self.result(b.wait(marker))
        assert one['result']['work_event_id']==two['result']['work_event_id']
        assert self.sql('select count(*)=1 from private.service_resource_spans where walk_in_order_id='+lit(first_order)+';')=='t'
        self.ack_work(request);self.step(first_order,'in_progress','quality_check');self.step(first_order,'quality_check','completed')
        self.proof['same_nonce_actual_wait_one_start_span']=True

        self.stage('booking_wins_last_slot')
        booking_request=self.prepare_booking();request=self.prepare_work(second_order,'received','in_progress')
        a,b=self.pair();placed=self.result(a.run(self.tx('select '+self.booking_expression(booking_request)+';','customer')))
        marker=self.send_expected(b,'public.place_service_work('+lit(request)+')','55000')
        self.wait_block(b,a);a.run('commit;');assert any('QA_REJECTED_55000'in x for x in b.wait(marker))
        self.remember_order(placed,'booking');self.rpc('acknowledge_service_booking_attempt',{'p_request':booking_request},'customer');self.close_work(request)
        self.cancel_pending_booking(placed['booking_id'])
        self.proof['booking_first_blocks_walk_in_start']=True

        self.stage('walk_in_wins_last_slot')
        booking_request=self.prepare_booking();request=self.prepare_work(second_order,'received','in_progress')
        a,b=self.pair();a.run(self.tx('select public.place_service_work('+lit(request)+');'))
        marker=self.send_expected(b,self.booking_expression(booking_request),'P0001','customer')
        self.wait_block(b,a);a.run('commit;');assert any('QA_REJECTED_P0001'in x for x in b.wait(marker))
        self.ack_work(request);closed=self.rpc('close_service_booking_attempt',{'p_request':booking_request},'customer');assert closed['state']=='closed'
        self.step(second_order,'in_progress','quality_check');self.step(second_order,'quality_check','completed')
        self.proof['walk_in_first_blocks_booking_insert']=True

        self.stage('stale_source_and_permission')
        stale=self.create_booking();request=self.prepare_work(stale['order_id'],'received','in_progress')
        self.patch('bookings','id',stale['booking_id'],{'assigned_staff_ids':[self.actors['other_employee']]})
        self.rpc('place_service_work',{'p_request':request},error='40001',role='manager')
        assert self.sql('select not exists(select 1 from private.service_work_ledger where command_id='+lit(request)+');')=='t'
        self.close_work(request);self.patch('bookings','id',stale['booking_id'],{'assigned_staff_ids':[]});self.cancel_pending_booking(stale['booking_id'])
        self.rpc('prepare_service_work',{'p_request':uid(),'p_order':second_order,'p_expected_status':'completed','p_next_status':'delivered','p_reason':self.tag},'other_employee',error='42501')
        self.rpc('get_service_work_context',{'p_order':second_order},'employee',error='42501')
        self.proof['stale_dispatch_rejected_without_action']=True;self.proof['actual_http_unassigned_and_employee_delivery_denied']=True

        self.stage('atomic_paired_completion')
        paired=self.create_booking();self.dispatch_booked(paired['booking_id'])
        self.step(paired['order_id'],'received','in_progress','other_employee');self.step(paired['order_id'],'in_progress','quality_check','other_employee')
        self.http('/rest/v1/bookings?id=eq.'+paired['booking_id'],{'status':'completed'},'other_employee','PATCH',error='55000')
        self.http('/rest/v1/business_orders?order_id=eq.'+paired['order_id'],{'status':'completed'},'owner','PATCH',error='55000')
        request=self.prepare_work(paired['order_id'],'quality_check','completed','other_employee')
        a,b=self.pair();a.run(self.tx('select public.place_service_work('+lit(request)+');','other_employee'))
        assert self.sql('select b.status=\'in_progress\'and o.status=\'quality_check\'from public.bookings b join public.business_orders o on o.booking_id=b.id where b.id='+lit(paired['booking_id'])+';')=='t'
        marker='QA_PAIR_'+uid().replace('-','');b.send(self.tx('select public.place_service_work('+lit(request)+');commit;','other_employee')+'\n\\echo '+marker)
        self.wait_block(b,a);a.run('commit;');replay=self.result(b.wait(marker))
        assert replay['result']['current_work_status']=='completed'and replay['result']['current_booking_status']=='completed'
        assert self.sql('select count(*)=1 and bool_and(ended_at is not null)from private.service_resource_spans where booking_id='+lit(paired['booking_id'])+';')=='t'
        self.ack_work(request,'other_employee')
        self.proof['pair_invisible_until_atomic_commit']=True;self.proof['paired_completion_actual_wait_one_release']=True

    def cleanup(self):
        self.proof['test_stage_before_cleanup']=self.proof['stage'];self.stage('cleanup')
        failures=[]
        for session in self.sessions:
            try:session.rollback_close()
            except Exception:failures.append('owned_session_close')
        for item in list(self.work_commands):
            try:self.close_work(item['request_id'],item['role'])
            except Exception:failures.append('work_command_fence')
        for request in self.financial_commands:
            try:
                value=self.rpc('get_offline_walk_in_command',{'p_request':request},'manager')
                if value.get('status')=='succeeded':self.remember_order(value['result'],'walk_in')
                self.rpc('close_offline_walk_in_command',{'p_request':request},'manager')
                self.rpc('ack_offline_walk_in_command',{'p_request':request},'manager')
            except Exception:failures.append('financial_command_recovery')
        for request in self.booking_attempts:
            try:
                value=self.rpc('get_service_booking_attempt',{'p_request':request},'customer')
                if value.get('state')=='succeeded':
                    self.remember_order(value['result'],'booking')
                    self.rpc('acknowledge_service_booking_attempt',{'p_request':request},'customer')
                elif value.get('state')=='open':self.rpc('close_service_booking_attempt',{'p_request':request},'customer')
            except Exception:failures.append('booking_command_recovery')
        for item in list(self.orders):
            try:
                state=json.loads(self.sql("select jsonb_build_object('status',o.status,'booking',o.booking_id,'booking_status',b.status,'owned',o.branch_id="+lit(self.branch)+" and o.notes="+lit(self.tag)+")from public.business_orders o left join public.bookings b on b.id=o.booking_id where o.order_id="+lit(item['order_id'])+';'))
                assert state['owned']is True
                role='other_employee'if item['kind']=='booking'else'manager'
                if state['status']=='in_progress':self.step(item['order_id'],'in_progress','quality_check',role);state['status']='quality_check'
                if state['status']=='quality_check':self.step(item['order_id'],'quality_check','completed',role)
                elif state['status']=='received'and item['kind']=='walk_in':self.rpc('cancel_offline_walk_in',{'p_request':uid(),'p_order':item['order_id'],'p_reason':self.tag+' unpaid QA cleanup'})
                elif state['status']=='received'and state['booking_status']=='pending':self.cancel_pending_booking(state['booking'])
                elif state['status']=='received':failures.append('unstarted_booking_requires_review')
            except Exception:failures.append('new_qa_order_cleanup')
        if self.service_created:
            try:
                owned=self.sql('select not exists(select 1 from public.business_catalog_items where item_id='+lit(self.service)+')or exists(select 1 from public.business_catalog_items where item_id='+lit(self.service)+'and branch_id='+lit(self.branch)+'and name='+lit(self.tag)+');')
                assert owned=='t'
                self.patch('business_catalog_items','item_id',self.service,{'is_active':False,'is_public':False})
            except Exception:failures.append('hide_new_service')
        if self.branch_created:
            try:
                owned=self.sql('select not exists(select 1 from public.business_branches where branch_id='+lit(self.branch)+')or exists(select 1 from public.business_branches where branch_id='+lit(self.branch)+'and name_ar='+lit(self.tag)+'and name_en='+lit(self.tag)+');')
                assert owned=='t'
                self.patch('business_branches','branch_id',self.branch,{'is_active':False,'temporarily_closed':True})
            except Exception:failures.append('hide_new_branch')
        try:
            pending=json.loads(self.sql("select coalesce(jsonb_agg(order_id),'[]')from private.loyalty_visit_outbox where processed_at is null;"))
            assert set(pending)<={v['order_id']for v in self.orders}
            for _ in range(len(pending)+1):
                if self.sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t':break
                self.sql('select public.drain_loyalty_visit_event();')
            assert self.sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'
            self.proof['outbox_empty_after_actual_worker']=True
        except Exception:failures.append('outbox_review_required')
        if self.before is not None:
            try:
                self.proof['old_public_private_rows_unchanged']=not bool(self.before-self.rows())
                self.proof['auth_identities_unchanged']=self.auth_before==self.sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
                self.proof['payment_ledger_unchanged']=self.payment_before==self.sql("select md5(coalesce(string_agg(to_jsonb(p)::text,''order by payment_id),''))from public.business_payment_events p;")
                self.proof['loyalty_ledger_unchanged']=self.loyalty_before==self.sql("select md5(coalesce(string_agg(x::text,''order by x::text),''))from(select to_jsonb(t)x from private.canonical_loyalty_visits t union all select to_jsonb(t)from public.business_loyalty_transactions t)x;")
                self.proof['new_invoice_money_documents_unchanged']=all(self.finance_hash(k)==v for k,v in self.financial_hashes.items())
                counters=json.loads(self.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
                counts=json.loads(self.sql("select jsonb_build_object('INV',(select count(*)from public.business_invoices where branch_id="+lit(self.branch)+"),'BKG',(select count(*)from public.bookings where branch_id="+lit(self.branch)+'));'))
                self.proof['only_actual_qa_document_allocations']=all(counters.get(k,0)-self.counters_before.get(k,0)==counts.get(k,0)for k in set(counters)|set(self.counters_before))
                self.proof['no_open_new_qa_span']=self.sql('select not exists(select 1 from private.service_resource_spans where branch_id='+lit(self.branch)+'and ended_at is null);')=='t'
                self.proof['borrowed_contracts_untouched']=self.borrowed_hashes==json.loads(self.sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+','.join(map(lit,self.staff))+');'))
            except Exception:failures.append('preservation_verification')
        self.proof['cleanup_failures']=sorted(set(failures));self.proof['cleanup_complete']=not failures
        self.proof['retained_new_qa_orders']=[v['order_id']for v in self.orders]
        self.proof['completed_qa_invoices_retained_unpaid']=True
        self.checkpoint()

    def run(self):
        tested=False
        try:self.preflight();self.setup();self.tests();tested=True
        except Exception as failure:
            self.proof['failure_class']=type(failure).__name__
            # Only literal controlled reasons and our own function/line numbers.
            # Never serialize exception values, SQL, HTTP bodies or session traces.
            safe_reasons={'SQL failed; context redacted','Expected rejection unexpectedly succeeded','HTTP failed; body and inputs redacted','Expected actual lock wait not observed'}
            self.proof['failure_reason']=str(failure)if isinstance(failure,SafeFailure)and str(failure)in safe_reasons else'Check failed; values redacted'
            frames=[];frame=failure.__traceback__
            while frame is not None:
                if Path(frame.tb_frame.f_code.co_filename).resolve()==Path(__file__).resolve():frames.append({'function':frame.tb_frame.f_code.co_name,'line':frame.tb_lineno})
                frame=frame.tb_next
            self.proof['failure_locations']=frames
        finally:
            if self.before is not None:self.cleanup()
            else:
                for session in self.sessions:
                    try:session.rollback_close()
                    except Exception:pass
                self.checkpoint()
        checks=['same_nonce_actual_wait_one_start_span','booking_first_blocks_walk_in_start','walk_in_first_blocks_booking_insert','stale_dispatch_rejected_without_action','actual_http_unassigned_and_employee_delivery_denied','pair_invisible_until_atomic_commit','paired_completion_actual_wait_one_release','cleanup_complete','old_public_private_rows_unchanged','auth_identities_unchanged','payment_ledger_unchanged','loyalty_ledger_unchanged','new_invoice_money_documents_unchanged','only_actual_qa_document_allocations','no_open_new_qa_span','borrowed_contracts_untouched','outbox_empty_after_actual_worker']
        self.proof['all_passed']=tested and all(self.proof.get(k)is True for k in checks)
        self.args.proof.parent.mkdir(parents=True,exist_ok=True);self.args.proof.write_text(json.dumps(self.proof,indent=2)+'\n');self.args.proof.chmod(0o600)
        return self.proof['all_passed']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute',action='store_true')
    parser.add_argument('--runtime',type=Path,default=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime'))
    parser.add_argument('--contract-state',type=Path)
    parser.add_argument('--contract-proof',type=Path)
    parser.add_argument('--state',type=Path)
    parser.add_argument('--proof',type=Path)
    args=parser.parse_args()
    if not args.execute:
        print('PLAN ONLY: no credentials loaded, no database/API calls. Explicit root release required. See docs/SERVICE_WORK_KERNEL_CONCURRENCY_PLAN.md.');return 0
    if not all([args.contract_state,args.contract_proof,args.state,args.proof]):parser.error('--execute requires explicit contract-state, contract-proof, state and proof paths')
    if args.state.exists()or args.proof.exists():parser.error('Archive prior artifacts first; refusing overwrite')
    try:passed=WorkQA(args).run()
    except Exception:print('FAIL: initialization stopped; details suppressed');return 1
    print('PASS: local work concurrency and cleanup verified'if passed else'FAIL: stopped; sanitized proof/journal require review before retry')
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
