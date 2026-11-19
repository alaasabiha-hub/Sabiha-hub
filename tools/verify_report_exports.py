"""Read-only independent check of Flutter-generated PDF/XLSX against a local report.
Requires openpyxl and pypdf in the isolated QA Python environment.
"""
import argparse,json
from pathlib import Path
from openpyxl import load_workbook
from pypdf import PdfReader

def verify(fixture,folder):
    report=json.loads(fixture.read_text())
    book=load_workbook(folder/'flutter-sales-window.xlsx')
    metrics={r[0]:r[1] for r in book['Summary'].iter_rows(values_only=True)}
    assert metrics['Net active invoice value']==report['net_billed']
    assert metrics['Recorded taxes']==('Not recorded / incomplete' if report['taxes'] is None else report['taxes'])
    assert metrics['From (inclusive)']==report['from_local'] and metrics['To (exclusive)']==report['to_local']
    assert book['Hourly sales'].max_row==len(report['hourly'])+1
    assert book['Summary'].sheet_view.rightToLeft
    pdf=PdfReader(folder/'flutter-sales-window.pdf')
    text=' '.join(''.join(page.extract_text() for page in pdf.pages).split())
    for label in ['Sabiha Hub Sales Summary','Actual profit','Africa/Cairo',report['from_local'],report['to_local']]:assert label in text
    if report['taxes'] is None:assert 'Not recorded / incomplete' in text
    return {'xlsx_readable':True,'totals_match_supabase':True,'missing_tax_preserved':True,'rtl':True,'hourly_rows':len(report['hourly']),'pdf_readable':True,'pdf_pages':len(pdf.pages)}
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--fixture',required=True,type=Path);parser.add_argument('--artifacts',required=True,type=Path);parser.add_argument('--proof',required=True,type=Path);args=parser.parse_args()
    proof=verify(args.fixture,args.artifacts);args.proof.write_text(json.dumps(proof,indent=2));print('PASS independent PDF/Excel validation against the local Supabase report')
