"""Root-owned LOCAL fixtures for real work UI. No I/O without explicit action.
Creates separate tagged NONdefault branches with explicit QA hours, never edits
old branch/HR/Auth records. Cleanup fences browser UUIDs then uses real work graph.
"""
import argparse,json,uuid,hashlib
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from service_work_kernel_concurrency import WorkQA,lit

def save(path,data):
 path.write_text(json.dumps(data,indent=2)+'\n');path.chmod(0o600)
def newqa(r,language):
 return WorkQA(SimpleNamespace(runtime=r,state=r/('service-work-ui-'+language+'-state.json'),proof=r/('service-work-ui-'+language+'-cleanup.json')))
def signin(q):
 for role in ['owner','manager']:
  u=q.accounts['users'][role];v=q.http('/auth/v1/token?grant_type=password',{'email':u['email'],'password':u['password']},role=None)
  assert v['user']['id']==q.actors[role];q.tokens[role]=v['access_token']
def authhash(q):
 return q.sql("select md5(coalesce(string_agg((to_jsonb(u)-array['last_sign_in_at','updated_at'])::text,''order by id),''))from auth.users u;")
def prepare(r):
 assert not(r/'service-work-ui-root-state.json').exists(),'Existing UI fixture checkpoint must be resolved first'
 accepted=json.loads((r/'service-work-concurrency-proof-attempt2.json').read_text());assert accepted['all_passed']and accepted['cleanup_complete']
 beforeqa=newqa(r,'ar');signin(beforeqa)
 # A new QA branch will explicitly close at23:59. Require a full30-minute service
 # plus10minutes test budget; do not bypass any actual source's business hours.
 assert beforeqa.sql("select (clock_timestamp()at time zone'Africa/Cairo')+interval'40 minutes'<(clock_timestamp()at time zone'Africa/Cairo')::date+time'23:59';")=='t'
 journal=json.loads((r/'walkin-financial-concurrency-state.json').read_text());expected=journal['borrowed_contract_hashes']
 assert set(expected)==set(beforeqa.staff)
 ids=','.join(map(lit,beforeqa.staff));assert json.loads(beforeqa.sql('select jsonb_object_agg(staff_id,md5(to_jsonb(e)::text))from private.hr_employment e where staff_id in('+ids+');'))==expected
 assert beforeqa.sql('select count(*)=2 from private.hr_employment where staff_id in('+ids+")and currency='EGP'and starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date;")=='t'
 assert beforeqa.sql('select not exists(select 1 from private.service_work_commands where actor_id='+lit(beforeqa.actors['manager'])+'and acknowledged_at is null);')=='t'
 assert beforeqa.sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'
 root={'local_only':True,'production_touched':False,'before_rows':dict(beforeqa.rows()),'before_auth':authhash(beforeqa),'before_counters':json.loads(beforeqa.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;')),'borrowed_hashes':expected,'languages':[],'setup_complete':False}
 save(r/'service-work-ui-root-state.json',root)
 for language in ['ar','en']:
  q=beforeqa if language=='ar'else newqa(r,language)
  if language!='ar':signin(q)
  q.borrowed_hashes=expected;q.checkpoint();root['languages'].append(language);save(r/'service-work-ui-root-state.json',root)
  q.setup();oid=q.walk_in();item=next(x for x in q.orders if x['order_id']==oid)
  fixture={'local_only':True,'root_approved':True,'fresh_qa':True,'source_kind':'walk_in','initial_status':'received','order_id':oid,'branch_id':q.branch,'service_id':q.service,'invoice_id':item['invoice_id'],'service_name':q.tag,'gross_amount':120,'tag':q.tag,'actor_role':'manager','allowed_transitions':['in_progress','quality_check','completed','delivered']}
  save(r/('service-work-ui-'+language+'-fixture.json'),fixture)
 root['setup_complete']=True;save(r/'service-work-ui-root-state.json',root)
 print('Two isolated real received/unpaid UI fixtures ready; no payment/Auth creation/HR edits.')
def cleanup(r):
 root=json.loads((r/'service-work-ui-root-state.json').read_text());assert root['local_only']and not root['production_touched']
 reports=[];last=None;finance={};branches=[]
 for language in root['languages']:
  q=newqa(r,language);state=json.loads(q.args.state.read_text());assert state['local_only']
  q.tag=state['tag'];q.branch=state['branch_id'];q.service=state['service_id'];q.branch_created=state['branch_created'];q.service_created=state['service_created'];q.borrowed_hashes=state['borrowed_contract_hashes'];q.orders=state['orders'];q.bookings=state['bookings'];q.financial_commands=state['financial_commands'];q.work_commands=state['work_commands'];q.booking_attempts=state['booking_attempts'];q.financial_hashes=state['invoice_snapshot_hashes'];signin(q)
  for browser in sorted(r.glob('service-work-browser-'+language+'-proof*-state.json')):
   b=json.loads(browser.read_text());assert b['tag']==q.tag and b['order_id']in{v['order_id']for v in q.orders}
   if b.get('request_id') and not any(v['request_id']==b['request_id'] for v in q.work_commands):
    uuid.UUID(b['request_id']);q.work_commands.append({'request_id':b['request_id'],'role':'manager','order_id':b['order_id']})
  q.cleanup();save(q.args.proof,q.proof);reports.append(q.proof['cleanup_complete']);finance.update(q.financial_hashes);branches.append(q.branch);last=q
 assert last is not None
 before=Counter(root['before_rows']);after=last.rows();counters=json.loads(last.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'))
 actual=int(last.sql('select count(*)from public.business_invoices where branch_id in('+','.join(map(lit,branches))+');'))
 result={'local_only':True,'production_touched':False,'fixture_cleanup_complete':all(reports),'old_public_private_rows_unchanged':not bool(before-after),'auth_users_unchanged':root['before_auth']==authhash(last),'invoice_money_documents_unchanged':all(last.finance_hash(k)==v for k,v in finance.items()),'exact_invoice_allocations':counters['INV']-root['before_counters']['INV']==actual,'booking_counter_unchanged':counters['BKG']==root['before_counters']['BKG'],'no_new_open_span':last.sql('select not exists(select 1 from private.service_resource_spans where branch_id in('+','.join(map(lit,branches))+')and ended_at is null);')=='t','no_pending_loyalty':last.sql('select count(*)=0 from private.loyalty_visit_outbox where processed_at is null;')=='t'}
 result['all_passed']=all(v for k,v in result.items()if k not in['production_touched'])
 save(r/'service-work-ui-root-cleanup-proof.json',result);print(json.dumps(result))
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--action',choices=['prepare','cleanup']);a=p.parse_args()
 if not a.action:print(__doc__);return
 (prepare if a.action=='prepare'else cleanup)(a.runtime.resolve())
if __name__=='__main__':main()
