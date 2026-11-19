"""PLAN by default. Root-reviewed LOCAL owner catalogue concurrency only.
No Auth/HR/customer/contact/finance/ETA/gate edits. New tagged master data only.
Journal BEFORE dispatch; retain archived audit, no DELETE or producer reissue.
"""
import argparse,json,time,uuid
from pathlib import Path
from collections import Counter
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def uid():return str(uuid.uuid4())
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n');p.chmod(0o600)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--action',choices=['plan','run','cleanup'],default='plan');a=p.parse_args()
 if a.action=='plan':print('PLAN 7 actual mutex waits: same-command replay; party and vehicle expected-version one-winner edits; parent archive/new vehicle both orders; unknown-close/prepare both orders. Only new QA entities, API archive cleanup, full old-row/Auth/counter preservation.');return
 r=a.runtime.resolve();state=r/'fleet-catalogue-concurrency-state.json';proof_path=r/'fleet-catalogue-concurrency-proof.json'
 q=WorkQA(SimpleNamespace(runtime=r,state=state,proof=proof_path));d=None;sessions=[]
 def sql(body):return q.sql("set statement_timeout='25s';set lock_timeout='20s';"+body)
 def rows():
  raw=sql("""create temp table qa_fleet_hash(t text,h text);do $$declare rel record;begin for rel in select schemaname,tablename from pg_tables where schemaname in('public','private','auth')and not(schemaname='private'and tablename='document_number_counters')loop execute format('insert into qa_fleet_hash select %L,md5(row_to_json(x)::text)from %I.%I x',rel.schemaname||'.'||rel.tablename,rel.schemaname,rel.tablename);end loop;end$$;select t||'|'||h from qa_fleet_hash order by t,h;""");return Counter(raw.splitlines())
 def financial():return json.loads(sql("select jsonb_build_object('orders',(select count(*)from public.business_orders),'invoices',(select count(*)from public.business_invoices),'payments',(select count(*)from public.business_payment_events),'bookings',(select count(*)from public.bookings),'credits',(select count(*)from private.canonical_loyalty_visits),'auth_users',(select count(*)from auth.users));"))
 def actor():return "select set_config('request.jwt.claim.sub',"+lit(d['owner_id'])+",true);select set_config('request.jwt.claims',"+lit(json.dumps({'sub':d['owner_id'],'session_id':d['session_id'],'role':'authenticated'}))+",true);set local role authenticated;"
 def result(lines):return json.loads(next(x for x in reversed(lines)if x.startswith('{')))
 def rpc(expression):return result(sql('begin;'+actor()+'select '+expression+';commit;').splitlines())
 def prepare(key,kind,entity,party,version,data):
  return rpc('public.prepare_fleet_catalog_command('+','.join([lit(d['commands'][key]),lit(kind),lit(entity),lit(party),'null'if version is None else str(version),lit(json.dumps(data))+'::jsonb',lit(d['tag']+' actual isolated master-data review')])+')')
 def apply(key):return 'select public.apply_fleet_catalog_command('+lit(d['commands'][key])+');'
 def actual_apply(key):return rpc('public.apply_fleet_catalog_command('+lit(d['commands'][key])+')')
 def close(key):return rpc('public.close_fleet_catalog_command('+lit(d['commands'][key])+')')
 def session(name):s=PsqlSession(q.command,q.env,'qa-fleet-'+name);sessions.append(s);return s
 def launch(s,body):marker='FLEET_'+uuid.uuid4().hex;s.send(body+'\n\\echo '+marker);return marker
 def blocked(second,first):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if sql('select '+str(first.pid)+'=any(pg_blocking_pids('+str(second.pid)+'));')=='t':return
   time.sleep(.05)
  raise RuntimeError('Expected actual owner catalogue lock wait absent')
 def remember(check):d['checks'].append(check);save(state,d)
 def fenced_apply(key,condition,marker):
  return "do $$begin perform public.apply_fleet_catalog_command("+lit(d['commands'][key])+");raise exception 'Unexpected catalogue apply success'using errcode='PZ001';exception when "+condition+" then raise notice '"+marker+"';end$$;"
 def cleanup():
  # Fence every producer nonce first; never close planned cleanup nonces yet.
  for key in d['commands']:
   if not key.startswith('cleanup_'):close(key)
  created=sql('select exists(select 1 from private.fleet_parties p join private.fleet_catalog_versions e on e.request_id='+lit(d['commands']['create_party'])+' and e.entity_kind=\'party\'and e.entity_id=p.party_id where p.party_id='+lit(d['party'])+' and p.created_by='+lit(d['owner_id'])+' and e.actor_id=p.created_by and p.terms->>\'legal_name\'like '+lit(d['tag']+'%')+');')=='t'
  if created:
   for entity,key,producer in [(d['car_blocked'],'cleanup_car_blocked','create_blocked_car'),(d['car'],'cleanup_car','create_car')]:
    exists=sql('select exists(select 1 from private.fleet_vehicles v join private.fleet_catalog_versions e on e.request_id='+lit(d['commands'][producer])+' and e.entity_kind=\'vehicle\'and e.entity_id=v.vehicle_id where v.vehicle_id='+lit(entity)+' and v.party_id='+lit(d['party'])+' and v.created_by='+lit(d['owner_id'])+');')=='t'
    if exists:
     current=rpc('public.get_fleet_vehicle('+lit(d['party'])+','+lit(entity)+')')
     if not current['archived']:prepare(key,'vehicle_archive',entity,d['party'],current['version'],{});actual_apply(key)
   current=rpc('public.get_fleet_party('+lit(d['party'])+')')
   if not current['archived']:prepare('cleanup_party','party_archive',d['party'],d['party'],current['version'],{});actual_apply('cleanup_party')
  for key in d['commands']:
   if key.startswith('cleanup_'):close(key)
  d['cleanup_complete']=True;save(state,d)
 try:
  if a.action=='run':
   assert not state.exists(),'Existing journal: cleanup only, never repeat accepted races'
   owner=q.actors['owner'];sid=sql('select id from auth.sessions where user_id='+lit(owner)+' and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;');uuid.UUID(sid)
   keys=['create_party','party_left','party_right','archive_first','create_blocked_car','reenable','create_car','archive_after','reenable_for_edits','vehicle_left','vehicle_right','close_first','prepare_first','cleanup_car_blocked','cleanup_car','cleanup_party']
   d={'local_only':True,'tag':'QA-fleet-race-'+uuid.uuid4().hex[:10],'owner_id':owner,'session_id':sid,'party':uid(),'car':uid(),'car_blocked':uid(),'never_party1':uid(),'never_party2':uid(),'commands':{key:uid()for key in keys},'checks':[],'before_rows':dict(rows()),'before_counters':json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;')),'before_financial_auth':financial()}
   assert sql('select not exists(select 1 from private.fleet_catalog_commands where request_id in('+','.join(lit(x)for x in d['commands'].values())+'));')=='t'
   assert sql('select not exists(select 1 from private.fleet_parties where party_id in('+','.join(lit(d[k])for k in ['party','never_party1','never_party2'])+'))and not exists(select 1 from private.fleet_vehicles where vehicle_id in('+lit(d['car'])+','+lit(d['car_blocked'])+'));')=='t'
   assert rpc('public.get_fleet_catalogue_context()')['manage_allowed']is True
   save(state,d) # IDs and full baseline hashes BEFORE first prepare/mutation.
   terms={'legal_name':d['tag'],'trading_name':None,'registration_country':None,'tax':None,'address':None,'contacts':[],'representative':None}
   vehicle={'plate_country':None,'plate_number':'QA'+uuid.uuid4().hex[:16],'make':'QA recorded maker','model':'QA recorded model','year':1960,'color':None,'fleet_reference':d['tag']}
   d['vehicle_terms']=vehicle;d['blocked_vehicle_terms']={**vehicle,'plate_number':'QB'+uuid.uuid4().hex[:16]};save(state,d)
   prepare('create_party','party_create',d['party'],d['party'],None,terms)
   first=session('first');second=session('second')
   original=result(first.run('begin;'+actor()+apply('create_party')))
   marker=launch(second,'begin;'+actor()+apply('create_party')+'commit;');blocked(second,first);first.run('commit;');replayed=result(second.wait(marker));assert original==replayed
   assert sql('select count(*)from private.fleet_catalog_versions where request_id='+lit(d['commands']['create_party'])+';')=='1';remember('same_command_actual_wait_one_version')
   prepare('party_left','party_edit',d['party'],d['party'],1,{**terms,'trading_name':'QA left selected'})
   prepare('party_right','party_edit',d['party'],d['party'],1,{**terms,'trading_name':'QA stale right'})
   first.run('begin;'+actor()+apply('party_left'));marker=launch(second,'begin;'+actor()+fenced_apply('party_right','serialization_failure','QA_STALE_PARTY')+'commit;');blocked(second,first);first.run('commit;');assert any('QA_STALE_PARTY'in x for x in second.wait(marker));remember('different_expected_party_edits_one_winner_stale')
   prepare('archive_first','party_archive',d['party'],d['party'],2,{})
   prepare('create_blocked_car','vehicle_create',d['car_blocked'],d['party'],None,d['blocked_vehicle_terms'])
   first.run('begin;'+actor()+apply('archive_first'));marker=launch(second,'begin;'+actor()+fenced_apply('create_blocked_car','object_not_in_prerequisite_state','QA_PARENT_ARCHIVED')+'commit;');blocked(second,first);first.run('commit;');assert any('QA_PARENT_ARCHIVED'in x for x in second.wait(marker));assert sql('select count(*)from private.fleet_vehicles where vehicle_id='+lit(d['car_blocked'])+';')=='0';remember('parent_archive_commits_waiting_car_rejected')
   prepare('reenable','party_reenable',d['party'],d['party'],3,{});actual_apply('reenable')
   prepare('create_car','vehicle_create',d['car'],d['party'],None,vehicle)
   prepare('archive_after','party_archive',d['party'],d['party'],4,{})
   first.run('begin;'+actor()+apply('create_car'));marker=launch(second,'begin;'+actor()+apply('archive_after')+'commit;');blocked(second,first);first.run('commit;');second.wait(marker)
   assert rpc('public.get_fleet_vehicle('+lit(d['party'])+','+lit(d['car'])+')')['effective_active']is False;remember('car_commits_before_waiting_parent_archive_retained_inactive')
   prepare('reenable_for_edits','party_reenable',d['party'],d['party'],5,{});actual_apply('reenable_for_edits')
   prepare('vehicle_left','vehicle_edit',d['car'],d['party'],1,{**vehicle,'model':'QA actual left edit'})
   prepare('vehicle_right','vehicle_edit',d['car'],d['party'],1,{**vehicle,'model':'QA stale right edit'})
   first.run('begin;'+actor()+apply('vehicle_left'));marker=launch(second,'begin;'+actor()+fenced_apply('vehicle_right','serialization_failure','QA_STALE_VEHICLE')+'commit;');blocked(second,first);first.run('commit;');assert any('QA_STALE_VEHICLE'in x for x in second.wait(marker));remember('different_expected_vehicle_edits_one_winner_stale')
   # Unknown close is durable even when the delayed prepare arrives afterward.
   first.run('begin;'+actor()+'select public.close_fleet_catalog_command('+lit(d['commands']['close_first'])+');')
   body='select public.prepare_fleet_catalog_command('+','.join([lit(d['commands']['close_first']),"'party_create'",lit(d['never_party1']),lit(d['never_party1']),'null',lit(json.dumps({**terms,'legal_name':d['tag']+' never1'}))+'::jsonb',lit(d['tag']+' actual isolated master-data review')])+');'
   marker=launch(second,'begin;'+actor()+body+'commit;');blocked(second,first);first.run('commit;');assert result(second.wait(marker))['state']=='closed';remember('unknown_close_commits_before_waiting_prepare_fenced')
   # Prepare can win first, but a waiting close seals it before any apply.
   body='select public.prepare_fleet_catalog_command('+','.join([lit(d['commands']['prepare_first']),"'party_create'",lit(d['never_party2']),lit(d['never_party2']),'null',lit(json.dumps({**terms,'legal_name':d['tag']+' never2'}))+'::jsonb',lit(d['tag']+' actual isolated master-data review')])+');'
   first.run('begin;'+actor()+body);marker=launch(second,'begin;'+actor()+'select public.close_fleet_catalog_command('+lit(d['commands']['prepare_first'])+');commit;');blocked(second,first);first.run('commit;');assert result(second.wait(marker))['state']=='closed'
   assert actual_apply('prepare_first')['state']=='closed'and actual_apply('close_first')['state']=='closed';remember('prepare_commits_before_waiting_close_no_entity')
   d['races_passed']=len(d['checks'])==7;save(state,d)
  else:d=json.loads(state.read_text());assert d['local_only']
 except Exception as error:
  if d is not None:d['error_type']=type(error).__name__;save(state,d)
 finally:
  for s in sessions:s.rollback_close()
  if d is not None:
   try:
    cleanup();after=rows()
    proof={'local_only':True,'checks':d['checks'],'races_passed':d.get('races_passed',False),'old_public_private_auth_hr_rows_unchanged':not bool(Counter(d['before_rows'])-after),'financial_auth_counts_unchanged':financial()==d['before_financial_auth'],'document_counters_unchanged':json.loads(sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))==d['before_counters'],'only_known_party_created':sql('select count(*)from private.fleet_parties where party_id in('+lit(d['party'])+','+lit(d['never_party1'])+','+lit(d['never_party2'])+');')=='1','qa_party_archived':sql('select archived from private.fleet_parties where party_id='+lit(d['party'])+';')=='t','no_active_qa_vehicle':sql('select not exists(select 1 from private.fleet_vehicles where party_id='+lit(d['party'])+' and not archived);')=='t','cleanup_complete':d['cleanup_complete'],'production_touched':False}
    proof['all_passed']=all(proof[k]is True for k in ['races_passed','old_public_private_auth_hr_rows_unchanged','financial_auth_counts_unchanged','document_counters_unchanged','only_known_party_created','qa_party_archived','no_active_qa_vehicle','cleanup_complete']);save(proof_path,proof);d['all_passed']=proof['all_passed'];save(state,d)
   except Exception as error:d['cleanup_error_type']=type(error).__name__;save(state,d)
 if d.get('all_passed'):print('PASS local owner catalogue races and retained archived QA')
 else:raise SystemExit('INCOMPLETE sanitized exact-ID journal retained; cleanup/root review only, no repeated producer')
if __name__=='__main__':main()
