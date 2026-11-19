"""Local-only recruitment acceptance; every fixture is rolled back."""
from pathlib import Path
from hr_payroll_e2e import fingerprint, sql
if __name__ == '__main__':
    before = fingerprint()
    output, notices = sql((Path(__file__).resolve().parents[1] / 'supabase/tests/recruitment.sql').read_text())
    after = fingerprint()
    assert before == after, 'Existing application data changed'
    print(output + notices)
    print('PASS public/private counts and contents unchanged:', after)
