"""Isolated real-Auth concurrent numbering acceptance; no hosted URLs or gateway."""
import argparse
import concurrent.futures
import datetime as dt
import json
from pathlib import Path
import re
import uuid
from service_booking_acceptance import Acceptance


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime',type=Path,required=True)
    p.add_argument('--browser',action='store_true')
    args=p.parse_args();run=Acceptance(args.runtime)
    proof={'local_only':True,'production_touched':False,'gateway_called':False}
    try:
        run.prepare()
        def create(index):
            day=(dt.date.today()+dt.timedelta(days=9+index)).isoformat()
            return run.rpc('place_customer_service_booking',{'p_request':str(uuid.uuid4()),'p_service':run.saved['service_id'],'p_branch':run.state['branch'],'p_vehicle':run.car['id'],'p_date':day,'p_time':'10:00','p_expected_price':137.45,'p_notes':'Isolated concurrent numbering QA'})
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            created=list(pool.map(create,range(6)))
        docs=[run.verify_document(row) for row in created]
        invoices=[d['invoice_number'] for d in docs];bookings=[d['booking_number'] for d in docs]
        assert all(re.fullmatch('SH-INV-[0-9]{6,}',n) for n in invoices)
        assert all(re.fullmatch('SH-BKG-[0-9]{6,}',n) for n in bookings)
        assert len(set(invoices))==len(set(bookings))==6
        assert len({r['invoice_id'] for r in created})==len({r['booking_id'] for r in created})==6
        for values in [invoices,bookings]:
            sequence=sorted(int(v.rsplit('-',1)[1]) for v in values)
            assert sequence==list(range(sequence[0],sequence[0]+6)),sequence
        proof.update({'six_parallel_distinct_bookings':True,'unique_consecutive_invoice_numbers':True,'unique_consecutive_booking_numbers':True,'uuid_preserved':True})
        print('PASS six concurrent distinct bookings/invoices: unique consecutive display numbers, internal IDs preserved',flush=True)
        if args.browser:
            run.browser_cases=[(390,'ar'),(1440,'en')]
            run.browser_acceptance()
            proof['actual_flutter_web']=run.proof['actual_flutter_web']
        proof['all_checks_passed']=True
    finally:
        run.restore()
        proof['qa_restored_no_deletes']=run.proof.get('qa_restored_no_deletes',False)
        (args.runtime/'document-numbers-acceptance-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    print('PASS isolated QA disabled/cancelled; original default restored; no deletion',flush=True)

if __name__=='__main__':main()
