"""Local rollback verification of policy foundation only; no earning/redemption."""
from pathlib import Path
from hr_payroll_e2e import fingerprint, sql
if __name__ == '__main__':
    before = fingerprint()
    root=Path(__file__).resolve().parents[1]
    source=(root/'supabase/tests/loyalty_policy.sql').read_text()+'\n'+(root/'supabase/tests/visit_reward_offer.sql').read_text()
    output, notices = sql(source)
    after = fingerprint()
    assert before == after, 'Existing application data changed'
    print(output + notices)
    print('PASS public/private table counts and contents unchanged:', after)
