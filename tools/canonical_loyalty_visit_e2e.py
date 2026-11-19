"""Root-run local rollback acceptance for canonical service visits."""
from pathlib import Path
from hr_payroll_e2e import fingerprint, sql
if __name__ == '__main__':
    before=fingerprint()
    source=(Path(__file__).resolve().parents[1]/'supabase/tests/canonical_loyalty_visits.sql').read_text()
    output,notices=sql(source)
    after=fingerprint()
    assert before==after,'Existing application data changed'
    print(output+notices)
    print('PASS all public/private table counts and contents unchanged:',after)
