"""SOURCE PLAN ONLY. No DB/Auth/network/credential access; NOT an execution harness.
The reviewed issuer A/B remain unapplied. Root must first prepare an isolated
qa_typed_reward_* clone with actual committed QA credits/link/intake/current
sessions and restored false production gates. This file prints exact bounded
session ordering for the next harness, never executes the plan.
"""
import argparse
import json

CASES = [
    {'case':'exact_retry','first':'BEGIN; owner context; place_offline_reward_issue(R)', 'second':'same owner/request R; observe pg_blocking_pids(second) contains first', 'release':'COMMIT first; COMMIT second', 'assert':'same canonical invoice/order; one redemption; cancel received reward through private API'},
    {'case':'withdraw_first','first':'BEGIN; actual customer context; public revoke financial consent C', 'second':'BEGIN; owner place prepared R; observe identity/consent lock wait', 'release':'COMMIT customer first', 'assert':'owner placement SQLSTATE55000; no invoice; close+ack exact R'},
    {'case':'issue_first_withdraw','first':'BEGIN; owner place R', 'second':'BEGIN; actual customer revoke C; observe identity lock wait', 'release':'COMMIT issuer first', 'assert':'withdraw already_issued, withdrawal_applied=false; exact nonce replay stable; canonical received cancel'},
    {'case':'close_first','first':'BEGIN; owner close prepared R', 'second':'BEGIN; owner place same R; observe exact request lock wait', 'release':'COMMIT close first', 'assert':'placement closed; no order/invoice; no late producer; ack exact R'},
]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    if args.execute:parser.error('Execution deliberately unavailable: source plan only; root must review the fixture/cleanup adapter first')
    print(json.dumps({'source_plan_only':True,'actual_concurrency_coverage':False,'cases':CASES,'prerequisites':['A/B installed ONLY on explicit QA clone','same actual owner/customer sessions and genuine approved link','real eligible credits; no ledger injection or gate bypass','fresh hold/proposal/actual customer assent per case, TTL respected','restore_visits rule for received-only cleanup','0600 UUID journal BEFORE producer','preserve original stack/clone baseline; expected INV increment/BKG unchanged','no new Auth/HR/phones/quotas; no service-role HTTP or token forging']},indent=2))
if __name__=='__main__':main()
