"""PLAN default. Root-only future local WebSocket acceptance, NEVER production.
Existing QA owner + existing private bridge customer; no Auth creation or edits.
One real customer submission/exact replay; generic private hints; scoped cleanup.
No client publishing. No raw tokens, credentials, frames or HTTP bodies persisted.
"""
import argparse
import asyncio
from collections import Counter
import base64
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def uid(): return str(uuid.uuid4())
def ident(value):
    try:return isinstance(value,str) and str(uuid.UUID(value))==value
    except (ValueError,TypeError,AttributeError):return False
def lit(value): return "'"+str(value).replace("'","''")+"'"
class SafeFailure(RuntimeError):
    def __init__(self,code,diagnostic=None):
        super().__init__(code);self.diagnostic=diagnostic

def handshake_diagnostic(response):
    # Never serialize response headers, URLs, request objects or arbitrary bodies.
    # Retain only a bounded protocol-message field, with credential-shaped data removed.
    result={'http_status':int(response.status_code)}
    def clean(value):
        value=str(value)[:2048]
        value=re.sub(r'https?://[^\s<>"\']+|wss?://[^\s<>"\']+','[url]',value)
        value=re.sub(r'(?i)(authorization|apikey|access_token|token|password|secret)\s*[:=]\s*[^\s,;]+',r'\1=[redacted]',value)
        value=re.sub(r'[A-Za-z0-9_-]{18,}(?:\.[A-Za-z0-9_-]+)*','[redacted]',value)
        value=re.sub(r'[\w.+-]+@[\w.-]+','[redacted]',value)
        return ''.join(c if c.isprintable() else ' ' for c in value)[:240]
    result['reason']=clean(response.reason_phrase)
    raw=response.body
    if isinstance(raw,(bytes,bytearray)):
        try:
            parsed=json.loads(bytes(raw[:4096]).decode('utf-8'))
            if isinstance(parsed,dict):
                message=next((parsed[k]for k in ('message','error_description','error','reason')if isinstance(parsed.get(k),str)),None)
                if message is not None:result['protocol_message']=clean(message)
            else:result['body_format']='non_object_json_omitted'
        except (ValueError,UnicodeError):result['body_format']='non_json_omitted'
    return result
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): raise SafeFailure('redirect_denied')


def write_private(path,value):
    temporary=path.with_name(path.name+'.tmp')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w')as handle:
        json.dump(value,handle,indent=2);handle.write('\n');handle.flush();os.fsync(handle.fileno())
    os.replace(temporary,path);path.chmod(0o600)


class PrivateChannel:
    """Explicit installed-SDK supported Phoenix1.0.0 JSON object text framing.
    The only outbound events are phx_join, heartbeat and phx_leave.
    """
    def __init__(self,url,token,actor,target=None):
        self.url=url;self.token=token;self.actor=actor;self.target=target or actor
        self.topic='realtime:app-inbox:'+self.target;self.ws=None;self.tasks=[]
        self.join_ref='1';self.next_ref=1;self.waiters={};self.hints=[];self.fault=None;self.joined=False
        self.changed=asyncio.Event();self.sent_types=set();self.expected_close=False
    async def push(self,event,payload,topic=None,ref=None,join_ref=None):
        if event not in {'phx_join','heartbeat','phx_leave'}:raise SafeFailure('client_publish_forbidden')
        if ref is None:self.next_ref+=1;ref=str(self.next_ref)
        await self.ws.send(json.dumps({'topic':topic or self.topic,'event':event,'payload':payload,'ref':ref,'join_ref':join_ref}))
        self.sent_types.add(event);return ref
    async def read(self):
        try:
            async for raw in self.ws:
                if not isinstance(raw,str):raise SafeFailure('unexpected_binary_on_v1')
                value=json.loads(raw)
                if not isinstance(value,dict):raise SafeFailure('invalid_protocol_frame')
                event=value.get('event');payload=value.get('payload')
                if event=='phx_reply':
                    future=self.waiters.get(value.get('ref'))
                    if future is not None and not future.done():future.set_result(payload)
                elif event=='broadcast':
                    if value.get('topic')!=self.topic or not isinstance(payload,dict)or payload.get('event')!='inbox_changed'or payload.get('type')!='broadcast':raise SafeFailure('unexpected_broadcast_envelope')
                    data=payload.get('payload')
                    if not isinstance(data,dict)or set(data)!={'kind','id'}or data['kind']!='inbox_changed'or not ident(data['id']):raise SafeFailure('unsafe_hint_payload')
                    self.hints.append({'id':data['id'],'received_monotonic':time.monotonic()})
                    if len(self.hints)>32:raise SafeFailure('unexpected_hint_volume')
                    self.changed.set()
                elif event in {'phx_error','phx_close'} or event=='system'and isinstance(payload,dict)and payload.get('status')=='error':
                    if not self.expected_close:self.fault='channel_closed_or_system_error';self.changed.set()
        except asyncio.CancelledError:pass
        except Exception:self.fault='websocket_frame_or_connection_failure';self.changed.set()
        finally:
            if not self.expected_close and self.joined:self.fault=self.fault or'unexpected_socket_close';self.changed.set()
    async def heartbeat(self):
        try:
            while True:
                await asyncio.sleep(15)
                await self.push('heartbeat',{},topic='phoenix',join_ref=None)
        except asyncio.CancelledError:pass
        except Exception:
            if not self.expected_close:self.fault='heartbeat_failed';self.changed.set()
    async def connect(self):
        import websockets
        from websockets.exceptions import InvalidStatus
        logger=logging.getLogger('qa.private-inbox.websocket');logger.disabled=True
        # Never use a system proxy or an automatic reconnect/retry iterator.
        try:
            self.ws=await websockets.connect(self.url,proxy=None,open_timeout=15,close_timeout=5,ping_interval=None,max_size=65536,logger=logger)
        except InvalidStatus as failure:
            raise SafeFailure('websocket_handshake_http_rejected',handshake_diagnostic(failure.response))from None
        future=asyncio.get_running_loop().create_future();self.waiters[self.join_ref]=future
        self.tasks=[asyncio.create_task(self.read()),asyncio.create_task(self.heartbeat())]
        await self.push('phx_join',{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':'','enabled':False},'postgres_changes':[],'private':True},'access_token':self.token},ref=self.join_ref,join_ref=self.join_ref)
        reply=await asyncio.wait_for(future,15)
        if not isinstance(reply,dict)or reply.get('status')not in {'ok','error'}:raise SafeFailure('invalid_join_reply')
        self.joined=reply['status']=='ok'
        return reply
    async def expect_hints(self,count,timeout=12):
        deadline=time.monotonic()+timeout
        while len(self.hints)<count:
            if self.fault:raise SafeFailure('channel_fault')
            self.changed.clear()
            await asyncio.wait_for(self.changed.wait(),max(.01,deadline-time.monotonic()))
        if self.fault:raise SafeFailure('channel_fault')
    async def close(self):
        self.expected_close=True
        if self.ws is not None:
            try:
                if self.joined:await self.push('phx_leave',{},join_ref=self.join_ref)
            except Exception:pass
            try:await self.ws.close()
            except Exception:pass
        for task in self.tasks:task.cancel()
        if self.tasks:await asyncio.gather(*self.tasks,return_exceptions=True)
        self.token=None


class Acceptance:
    def __init__(self,args):
        self.args=args;self.r=args.runtime.resolve()
        accounts=json.loads((self.r/'test-accounts-final.json').read_text())
        fixture=json.loads((self.r/'recovery-bridge-fixture.private.json').read_text())
        assert fixture['local_only']and fixture['canonical_bridge_fixture']and len(fixture['customers'])==2
        self.base=accounts['url'];parsed=urllib.parse.urlsplit(self.base)
        assert parsed.scheme=='http'and parsed.hostname=='127.0.0.1'and parsed.port==54321 and parsed.path in {'','/'}
        self.base=self.base.rstrip('/');self.anon=accounts['anon_key'];self.customer=fixture['customers'][args.customer_index];self.owner=accounts['users']['owner']
        self.actors={'customer':self.customer['user_id'],'owner':self.owner['id']};assert all(ident(v)for v in self.actors.values())and self.actors['owner']==fixture['owner_id']
        self.api_key_type='legacy_jwt'if self.anon.startswith('eyJ')else'publishable'if self.anon.startswith('sb_publishable_')else'unsupported'
        assert self.api_key_type in {'legacy_jwt','publishable'}
        self.tokens={};self.session_ids={};self.sockets={};self.all_sockets=[];self.before=None;self.auth_before=None;self.counters=None;self.before_wire=None
        socket=self.r/'instances/sabiha-local/sock/docker.sock';assert socket.is_socket()
        self.env={**os.environ,'DOCKER_HOST':'unix://'+str(socket),'DOCKER_CONFIG':str(self.r/'docker-config')}
        self.command=[str(self.r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local','psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
        self.state={'local_only':True,'actor_ids':self.actors,'submission':uid(),'review':uid(),'case_id':None,'old_case_ids':[],'producer_dispatched':False,'review_expected':None,'cleanup_complete':False}
        self.proof={'local_only':True,'production_touched':False,'actual_auth_accounts_created':0,'phone_role_quota_contract_edits':False,'client_publish_attempted':False,'protocol':'Phoenix1.0.0','api_key_type':self.api_key_type,'join_configuration':{'private':True,'broadcast':{'ack':False,'self':False},'presence_enabled':False,'postgres_changes':[]},'actual_jwt_tokens_only':True,'all_passed':False,'stage':'preflight'}
        self.save()
    def save(self):write_private(self.args.state,self.state);write_private(self.args.proof,self.proof)
    def stage(self,name):self.proof['stage']=name;self.save()
    def sql_sync(self,source):
        p=subprocess.run(self.command,input='begin read only;'+source+'commit;',env=self.env,text=True,capture_output=True,timeout=35)
        if p.returncode:raise SafeFailure('readonly_database_check_failed')
        return p.stdout.strip()
    async def sql(self,source):return await asyncio.to_thread(self.sql_sync,source)
    def http_sync(self,path,data=None,role=None):
        assert path.startswith('/auth/v1/token?')or path.startswith('/rest/v1/rpc/')
        headers={'apikey':self.anon,'Content-Type':'application/json'}
        if role is not None:headers['Authorization']='Bearer '+self.tokens[role]
        req=urllib.request.Request(self.base+path,data=json.dumps(data).encode(),headers=headers,method='POST')
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect).open(req,timeout=25)as response:return json.load(response)
        except urllib.error.HTTPError as failure:
            self.proof['failed_http_status']=failure.code;self.proof['failed_endpoint']=urllib.parse.urlsplit(path).path
            raise SafeFailure('local_http_rejected')from None
    async def rpc(self,role,name,body):return await asyncio.to_thread(self.http_sync,'/rest/v1/rpc/'+name,body,role)
    async def rows(self):
        # Read-only transaction; no temporary/persistent table writes. Hashing
        # stays inside Postgres; no Auth/PII rows are returned to the process.
        value=await self.sql("""do $$declare t record;v jsonb;all_rows jsonb:='{}';begin
        for t in select schemaname,tablename from pg_tables where schemaname in('public','private','auth')order by schemaname,tablename loop
        execute format('select coalesce(jsonb_object_agg(h,n),''{}''::jsonb)from(select md5(to_jsonb(r)::text)h,count(*)n from %I.%I r group by 1)x',t.schemaname,t.tablename)into v;
        all_rows:=all_rows||jsonb_build_object(t.schemaname||'.'||t.tablename,v);end loop;
        perform set_config('qa.inbox_snapshot',all_rows::text,true);end$$;select current_setting('qa.inbox_snapshot');""")
        return {table:Counter(hashes)for table,hashes in json.loads(value).items()}
    async def login(self):
        for role,user in [('owner',self.owner),('customer',self.customer)]:
            value=await asyncio.to_thread(self.http_sync,'/auth/v1/token?grant_type=password',{'email':user['email'],'password':user['password']})
            assert value['user']['id']==self.actors[role]
            token=value['access_token'];claims=json.loads(base64.urlsafe_b64decode(token.split('.')[1]+'==='))
            assert claims['sub']==self.actors[role]and claims['role']=='authenticated'and ident(claims['session_id'])and claims['exp']>time.time()+180
            self.tokens[role]=token;self.session_ids[role]=claims['session_id']
        self.proof['real_auth_logins_before_baseline']=True
    async def preflight(self):
        await self.login()
        assert await self.sql("select to_regclass('private.app_inbox_hint_targets')is not null and to_regprocedure('public.close_my_visit_recovery_submission(uuid)')is not null;")=='t'
        for role in self.actors:
            assert await self.sql('select exists(select 1 from auth.sessions where id='+lit(self.session_ids[role])+' and user_id='+lit(self.actors[role])+" and(not_after is null or not_after>clock_timestamp()));")=='t'
        actor=self.actors['customer']
        checked=json.loads(await self.sql("select jsonb_build_object('valid',u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and private.offline_phone_key(c.phone,'EG')is not null,'old_cases',coalesce((select jsonb_agg(case_id)from private.visit_recovery_customer_requests where requester_id=c.id),'[]'),'blocked',exists(select 1 from private.visit_recovery_customer_requests where requester_id=c.id and status in('awaiting_matching','more_info','linked')))from public.customers c join auth.users u on u.id=c.id where c.id="+lit(actor)+';'))
        assert checked['valid']is True and checked['blocked']is False
        assert await self.sql("select exists(select 1 from public.staff_profiles where user_id="+lit(self.actors['owner'])+" and role='owner'and is_active);")=='t'
        self.state['old_case_ids']=checked['old_cases'];self.save()
        context=await self.rpc('customer','get_my_visit_recovery_request',{'p_case':None})
        assert context['state']=='unavailable'or(context.get('new_request_allowed')is True and context['case']['status']in {'rejected','revoked'})
        notice=context['consent'];assert notice['version']=='visit-recovery-v1'and isinstance(notice['notice_en'],str)and notice['notice_en']
        self.consent={'accepted':True,'version':notice['version'],'language':'en','text':notice['notice_en']}
        self.ws_url=self.base.replace('http://','ws://',1)+'/realtime/v1/websocket?'+urllib.parse.urlencode({'apikey':self.anon,'vsn':'1.0.0'})
    async def channels(self):
        self.stage('private_channel_joins')
        for role in ['owner','customer']:
            channel=PrivateChannel(self.ws_url,self.tokens[role],self.actors[role]);self.all_sockets.append(channel)
            reply=await channel.connect();assert reply['status']=='ok'
            self.sockets[role]=channel
        self.proof['actual_owner_and_customer_private_join_ok']=True
        foreign=PrivateChannel(self.ws_url,self.tokens['customer'],self.actors['customer'],self.actors['owner']);self.all_sockets.append(foreign)
        denied=await foreign.connect();assert denied['status']=='error'
        # Reject infrastructure/JWT-expiry errors as false authorization proof.
        reason=denied.get('response',{}).get('reason','')
        assert isinstance(reason,str)and any(word in reason.lower()for word in ['permission','unauthorized','forbidden','authoriz'])
        assert not foreign.hints;await foreign.close()
        assert all(not channel.fault for channel in self.sockets.values())
        self.proof['customer_foreign_owner_topic_denied']=True
    async def baseline(self):
        self.stage('baseline_after_logins_and_joins')
        self.before=await self.rows()
        self.auth_before=await self.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
        self.counters=json.loads(await self.sql('select coalesce(jsonb_object_agg(kind,last_value),\'{}\')from private.document_number_counters;'))
        self.before_wire=set(json.loads(await self.sql("select coalesce(jsonb_agg(id),'[]')from realtime.messages where topic like'app-inbox:%';")))
        self.inbox_before={role:await self.rpc(role,'list_my_app_inbox',{'p_limit':25})for role in self.actors}
        assert all(not ch.hints for ch in self.sockets.values())
        self.state['before_rows']={table:dict(rows)for table,rows in self.before.items()};self.state['before_auth_hash']=self.auth_before;self.state['before_counters']=self.counters;self.state['before_managed_hint_ids']=sorted(self.before_wire);self.save()
    async def test(self):
        await self.preflight();await self.channels();await self.baseline()
        self.stage('actual_customer_producer')
        self.state['producer_dispatched']=True;self.save()  # durable nonce BEFORE send
        started=time.monotonic();body={'p_request':self.state['submission'],'p_consent':self.consent}
        result=await self.rpc('customer','submit_visit_recovery_request',body)
        assert result['state']=='available'and result['case']['status']=='awaiting_matching'and result['case']['identity_current']is True
        cid=result['case']['case_id'];assert ident(cid)and cid not in self.state['old_case_ids'];self.state['case_id']=cid;self.save()
        await asyncio.gather(*(channel.expect_hints(1)for channel in self.sockets.values()))
        assert all(len(channel.hints)==1 for channel in self.sockets.values())
        self.proof['committed_producer_private_hint_received_both_roles']=True
        self.proof['observed_hint_delay_seconds']={role:round(ch.hints[0]['received_monotonic']-started,3)for role,ch in self.sockets.items()}
        for role,template in [('owner','recovery_submitted'),('customer','recovery_received')]:
            current=await self.rpc(role,'list_my_app_inbox',{'p_limit':25})
            rows=[item for item in current['items']if item['case_reference']==cid and item['template_code']==template]
            assert len(rows)==1 and current['unread_count']==self.inbox_before[role]['unread_count']+1
        own=await self.rpc('customer','get_my_visit_recovery_request',{'p_case':cid});assert own['case']['case_id']==cid
        self.proof['hint_only_triggers_authorized_rpc_data_confirmed']=True
        event_count=await self.sql('select count(*)from private.app_inbox_events where source_case_id='+lit(cid)+';');assert event_count=='2'
        target_count=await self.sql('select count(*)from private.app_inbox_hint_targets t join private.app_inbox_events e on e.event_id=t.inbox_event_id where e.source_case_id='+lit(cid)+';')
        self.stage('exact_producer_replay')
        replay=await self.rpc('customer','submit_visit_recovery_request',body);assert replay==result
        await asyncio.sleep(2)
        assert all(len(ch.hints)==1 and not ch.fault for ch in self.sockets.values())
        assert await self.sql('select count(*)from private.app_inbox_events where source_case_id='+lit(cid)+';')==event_count
        assert await self.sql('select count(*)from private.app_inbox_hint_targets t join private.app_inbox_events e on e.event_id=t.inbox_event_id where e.source_case_id='+lit(cid)+';')==target_count
        self.proof['exact_replay_no_duplicate_event_target_or_hint']=True
    async def cleanup(self):
        self.stage('cleanup_exact_new_case')
        errors=[]
        try:
            if self.state['producer_dispatched']:
                receipt=await self.rpc('customer','close_my_visit_recovery_submission',{'p_request':self.state['submission']})
                if receipt['state']=='accepted':
                    cid=receipt['result']['case']['case_id'];assert ident(cid)and cid not in self.state['old_case_ids']and self.state['case_id']in {None,cid};self.state['case_id']=cid;self.save()
                    row=json.loads(await self.sql("select jsonb_build_object('own',requester_id="+lit(self.actors['customer'])+",'status',status,'mapped',exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id))from private.visit_recovery_customer_requests c where case_id="+lit(cid)+';'))
                    assert row['own']is True and row['mapped']is False
                    if row['status']in {'awaiting_matching','more_info'}:
                        command=await self.rpc('owner','get_visit_recovery_review',{'p_request':self.state['review']})
                        if command['state']=='absent':
                            self.state['review_expected']=row['status'];self.save()
                            command=await self.rpc('owner','prepare_visit_recovery_review',{'p_request':self.state['review'],'p_case':cid,'p_expected_status':self.state['review_expected'],'p_action':'reject','p_reason':'Local realtime QA exact new unmapped case cleanup'})
                        if command['state']=='open':
                            expected=command.get('payload',{})
                            assert expected.get('case_id')==cid and expected.get('action')=='reject'and expected.get('expected_status')==self.state['review_expected']and expected.get('private_reason')=='Local realtime QA exact new unmapped case cleanup'
                            command=await self.rpc('owner','apply_visit_recovery_review',{'p_request':self.state['review']})
                        assert command['state']=='succeeded'and command['result']['case_id']==cid and command['result']['case_status']=='rejected'
                    else:assert row['status']=='rejected'
                    final=await self.rpc('customer','get_my_visit_recovery_request',{'p_case':cid});assert final['case']['status']=='rejected'
                else:assert receipt['state']=='closed'and receipt['definitive_failure']is True
            self.state['cleanup_complete']=True
        except Exception:errors.append('exact_case_cleanup_requires_review')
        finally:
            for channel in self.all_sockets:
                try:await channel.close()
                except Exception:errors.append('websocket_close')
        self.proof['cleanup_errors']=errors;self.proof['cleanup_complete']=not errors and self.state['cleanup_complete'];self.save()
    async def preservation(self):
        if self.before is None:return
        after=await self.rows();missing={table:sum((rows-after.get(table,Counter())).values())for table,rows in self.before.items()if rows-after.get(table,Counter())}
        additions={table for table,rows in after.items()if rows-self.before.get(table,Counter())}
        allowed={'private.visit_recovery_customer_requests','private.visit_recovery_submission_requests','private.visit_recovery_submission_closures','private.visit_recovery_review_commands','private.visit_recovery_owner_decisions','private.app_inbox_events','private.app_inbox_hint_targets'}
        self.proof['all_original_public_private_auth_rows_unchanged']=not missing
        self.proof['only_expected_new_private_workflow_rows']=additions<=allowed
        self.proof['auth_users_full_hash_unchanged_after_initial_logins']=self.auth_before==await self.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;")
        self.proof['document_counters_unchanged']=self.counters==json.loads(await self.sql('select coalesce(jsonb_object_agg(kind,last_value),\'{}\')from private.document_number_counters;'))
        all_ids=set(json.loads(await self.sql("select coalesce(jsonb_agg(id),'[]')from realtime.messages where topic like'app-inbox:%';")))
        added=all_ids-self.before_wire
        if added:
            ids=','.join(map(lit,added));cid=self.state['case_id']
            assert cid is not None
            safe=await self.sql("select not exists(select 1 from realtime.messages m where m.id in("+ids+")and(m.event<>'inbox_changed'or m.private is distinct from true or m.payload is distinct from jsonb_build_object('kind','inbox_changed','id',m.id::text)or not exists(select 1 from private.app_inbox_hint_targets t join private.app_inbox_events e on e.event_id=t.inbox_event_id where e.source_case_id="+lit(cid)+" and m.topic='app-inbox:'||t.recipient_actor_id::text)or exists(select 1 from private.app_inbox_events e where m.id=e.event_id or m.id=e.source_case_id or m.id=e.source_event_id)or exists(select 1 from auth.users u where u.id=m.id)));" )
            self.proof['all_new_managed_hints_fixed_and_only_new_case_targets']=safe=='t'
        else:self.proof['all_new_managed_hints_fixed_and_only_new_case_targets']=not self.state['producer_dispatched']
        forbidden={*self.actors.values(),self.state['submission'],self.state['review'],*self.state['old_case_ids']}
        if self.state['case_id']:forbidden.add(self.state['case_id'])
        hints=[hint['id']for channel in self.all_sockets for hint in channel.hints]
        self.proof['received_hint_ids_only_managed_transport_ids']=all(v in added and v not in forbidden for v in hints)
        self.proof['client_sent_only_join_heartbeat_leave']=all(ch.sent_types<= {'phx_join','heartbeat','phx_leave'}for ch in self.all_sockets)
        self.proof['all_owned_websockets_closed']=all(ch.ws is None or ch.ws.close_code is not None for ch in self.all_sockets)
        self.proof['new_managed_hint_count']=len(added);self.save()
    async def run(self):
        try:await self.test()
        except Exception as failure:
            self.proof['failure_class']=type(failure).__name__
            if isinstance(failure,SafeFailure)and failure.diagnostic is not None:self.proof['handshake_diagnostic']=failure.diagnostic
            frames=[];frame=failure.__traceback__
            while frame:
                if Path(frame.tb_frame.f_code.co_filename).resolve()==Path(__file__).resolve():frames.append({'function':frame.tb_frame.f_code.co_name,'line':frame.tb_lineno})
                frame=frame.tb_next
            self.proof['failure_locations']=frames
        finally:
            await self.cleanup()
            try:await self.preservation()
            except Exception:self.proof['preservation_check_failed']=True
            self.tokens.clear();self.session_ids.clear()
        keys=['actual_owner_and_customer_private_join_ok','customer_foreign_owner_topic_denied','committed_producer_private_hint_received_both_roles','hint_only_triggers_authorized_rpc_data_confirmed','exact_replay_no_duplicate_event_target_or_hint','cleanup_complete','all_original_public_private_auth_rows_unchanged','only_expected_new_private_workflow_rows','auth_users_full_hash_unchanged_after_initial_logins','document_counters_unchanged','all_new_managed_hints_fixed_and_only_new_case_targets','received_hint_ids_only_managed_transport_ids','client_sent_only_join_heartbeat_leave','all_owned_websockets_closed']
        self.proof['all_passed']=all(self.proof.get(key)is True for key in keys)and'failure_class'not in self.proof;self.save();return self.proof['all_passed']


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--execute',action='store_true');p.add_argument('--runtime',type=Path,default=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime'));p.add_argument('--customer-index',type=int,choices=[0,1],default=0);p.add_argument('--state',type=Path);p.add_argument('--proof',type=Path);args=p.parse_args()
    if not args.execute:print('PLAN ONLY: local private owner/customer joins, foreign-topic denial, one exact producer/replay, current RPC read, scoped owner rejection; no files/credentials/network/DB accessed.');return 0
    if not args.state or not args.proof:p.error('Explicit fresh --state and --proof paths required')
    if args.state.resolve()==args.proof.resolve():p.error('State and proof must be distinct files')
    for path in [args.state,args.proof]:
        path.resolve().relative_to(args.runtime.resolve())
        if path.exists():p.error('Archive prior artifacts first; no automatic rerun or identity rotation')
        path.parent.mkdir(parents=True,exist_ok=True)
    try:passed=asyncio.run(Acceptance(args).run())
    except Exception:print('FAIL: initialization; context redacted');return 1
    print('PASS local private WebSocket inbox acceptance; original rows preserved'if passed else'FAIL stopped; review sanitized proof and UUID journal before any retry')
    return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
