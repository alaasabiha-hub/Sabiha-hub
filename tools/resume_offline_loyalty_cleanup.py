"""Resume ONLY cleanup verification; never rerun accepted races or payments."""
from pathlib import Path
from types import SimpleNamespace
from collections import Counter
import json,hashlib
from service_work_kernel_concurrency import WorkQA,lit
from checkout_retry_lock_concurrency import PsqlSession

def main():
 r=Path('/Users/user/Documents/Codex/2026-11-12/v/work/runtime');q=WorkQA(SimpleNamespace(runtime=r,state=r/'unused',proof=r/'unused'));d=json.loads((r/'offline-loyalty-concurrency-state.json').read_text());baseline=json.loads((r/'offline-loyalty-restored-baseline.json').read_text());p=r/'offline-loyalty-kernel-concurrency-proof.json';prior=json.loads(p.read_text());assert prior['all_passed']and len(prior['checks'])==3
 original=r/'offline-loyalty-kernel-concurrency-initial-proof.json'
 if not original.exists():original.write_text(p.read_text())
 guard=PsqlSession(q.command,q.env,'offline-loyalty-cleanup-resume');guard.run("begin;select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));")
 try:
  drained=0
  while q.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')!='0':
   assert drained<100
   result=json.loads(q.sql('select private.drain_loyalty_visit_event();'))
   assert result.get('processed')is True, 'No due event; retain natural retry time and resume later'
   drained+=1
  current=json.loads(q.sql('select jsonb_object_agg(kind,last_value)from private.document_number_counters;'));before=Counter(baseline['before_rows']);after=q.rows()
  checks={'old_rows_unchanged':not bool(before-after),'auth_users_unchanged':baseline['before_auth']==q.sql("select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u;"),'exact_invoice_numbers':current['INV']==baseline['before_counters']['INV']+3 and current['BKG']==baseline['before_counters']['BKG'],
  'runtime_disabled_with_check':q.sql("select not earning_enabled and exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and conname='offline_service_visit_runtime_earning_enabled_check')from private.offline_service_visit_runtime where singleton;")=='t',
  'qa_net_visits_zero':q.sql('select coalesce(sum(visits),0)from private.canonical_loyalty_visits where branch_id='+lit(d['branch'])+';')=='0',
  'pending_outbox_zero':q.sql('select count(*)from private.loyalty_visit_outbox where processed_at is null;')=='0',
  'qa_shift_closed_zero_difference':q.sql('select status=\'closed\'and actual_cash=0 and expected_cash=0 and difference=0 from public.business_cashier_shifts where shift_id='+lit(d['shift'])+';')=='t',
  'qa_branch_hidden':q.sql('select not is_active from public.business_branches where branch_id='+lit(d['branch'])+';')=='t',
  'no_qa_open_resource_span':q.sql('select count(*)from private.service_resource_spans where branch_id='+lit(d['branch'])+'and ended_at is null;')=='0'}
  proof={**prior,**checks,'cleanup_complete':all(checks.values()),'cleanup_error_type':None,'resumed_cleanup_without_repeating_races':True,'accepted_race_evidence':original.name,'new_terminal_refund_fix':'terminal-offline-refund-local-apply-proof.json','hash_baseline_recovered_from_encrypted_pre_test_backup':baseline['source_backup'],'drained_one_event_per_transaction':drained}
  p.write_text(json.dumps(proof,indent=2)+'\n');assert proof['cleanup_complete'];print(json.dumps(proof))
 finally:guard.rollback_close()
if __name__=='__main__':main()
