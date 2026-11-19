"""Read-only existing cancelled reward invoice PDF/QR through actual Flutter UI."""
import argparse,json,re,subprocess,sys,urllib.parse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from owner_redemption_rules_browser import Harness
from service_booking_acceptance import Acceptance


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True);p.add_argument('--screenshots',type=Path,required=True);p.add_argument('--app-url',default='http://127.0.0.1:8080');a=p.parse_args();h=Harness(a)
    old=json.loads((a.runtime/'customer-reward-checkout-browser-state-attempt6-9357ad6cd6.json').read_text());receipt=old['receipts'][0]
    proof={'local_only':True,'fixture_writes':False,'status_expected':'cancelled_with_cancelled_reward_coverage','qr_followed':False,'blocked_mutations':[],'external_requests_blocked':[]};a.screenshots.mkdir(parents=True,exist_ok=True)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b=p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True);page=b.new_page(viewport={'width':390,'height':1100},accept_downloads=True);page.set_default_timeout(15000)
        def guard(route):
            q=route.request;url=urllib.parse.urlsplit(q.url);path=url.path
            if url.scheme in ('http','https') and url.hostname!='127.0.0.1' and not (q.method in ('GET','HEAD') and url.hostname in ('www.gstatic.com','fonts.gstatic.com')):proof['external_requests_blocked'].append(url.hostname);route.abort();return
            if q.method in ('GET','HEAD','OPTIONS') or (q.method=='POST' and (path=='/auth/v1/token' or re.match(r'^/rest/v1/rpc/(get_|list_|available_|resolve_)',path))):route.continue_()
            else:proof['blocked_mutations'].append(path);route.abort()
        page.route('**/*',guard)
        def click(loc):Acceptance.near(page,loc).click();page.wait_for_timeout(200)
        def button(name):return page.get_by_role('button',name=name,exact=True)
        try:
            page.goto(a.app_url);page.wait_for_selector('flutter-view',timeout=60000);sem=page.locator('flt-semantics-placeholder')
            if sem.count():sem.evaluate('(e)=>e.click()')
            button('احجز الآن').first.wait_for(timeout=30000);click(button('احجز الآن').first)
            for label,key in [('البريد الإلكتروني','email'),('كلمة المرور','password')]:Acceptance.type_into(page,label,h.accounts['users']['customer'][key])
            page.get_by_role('textbox',name='كلمة المرور',exact=True).press('Tab')
            with page.expect_response(lambda r:'/auth/v1/token?' in r.url) as auth:click(button('تسجيل الدخول'))
            assert auth.value.status==200;button('إرسال طلب الحجز').wait_for()
            nav=page.get_by_role('button',name=re.compile(r'^حجوزاتي(?:\s|$)')).last;nav.wait_for(state='visible');nav.click();page.wait_for_timeout(400)
            search=page.get_by_role('textbox').first;search.wait_for();search.click();page.wait_for_timeout(100);search.press('ControlOrMeta+A');search.press_sequentially(receipt['booking_number'],delay=20);page.wait_for_timeout(400)
            click(button('التفاصيل والفاتورة').first)
            with page.expect_response(lambda r:'/rpc/resolve_invoice_document' in r.url) as opened:click(button('عرض الفاتورة'))
            doc=opened.value.json();assert doc['invoice_id']==receipt['invoice_id'] and doc['payment_status']=='cancelled' and doc['reward_coverage']['state']=='cancelled_reward'
            assert float(doc['snapshot']['total'])==0 and float(doc['snapshot']['discount'])==137.45
            parsed=urllib.parse.urlsplit(doc['portal_origin']);assert parsed.scheme in ('http','https') and parsed.hostname and not parsed.username and not parsed.password
            pdfbutton=page.get_by_role('button',name=re.compile('Download PDF with QR'));Acceptance.near(page,pdfbutton)
            image=a.screenshots/'existing-cancelled-reward-ar390.png';page.screenshot(path=str(image))
            with page.expect_download(timeout=30000) as dl:pdfbutton.click()
            file=a.screenshots/'existing-cancelled-reward-ar390.pdf';dl.value.save_as(str(file))
            from pypdf import PdfReader
            import pypdfium2 as pdfium
            assert file.read_bytes().startswith(b'%PDF-');text=''.join(x.extract_text() for x in PdfReader(file).pages);assert '137.45' in text
            pdf=pdfium.PdfDocument(str(file));first=pdf[0];bitmap=first.render(scale=3);render=file.with_name(file.stem+'-pdf-render.png');bitmap.to_pil().save(render);bitmap.close();first.close();pdf.close()
            qr=subprocess.run([str(a.runtime/'read_qr'),str(render)],capture_output=True,text=True,check=True)
            values=[v for line in qr.stdout.splitlines() for v in json.loads(line).get('qr_values',[])]
            expected=doc['portal_origin'].rstrip('/')+'/?invoice='+doc['document_token'];assert expected in values
            proof.update(invoice_id=doc['invoice_id'],payment_status=doc['payment_status'],reward_coverage_state=doc['reward_coverage']['state'],actual_total=doc['snapshot']['total'],actual_discount=doc['snapshot']['discount'],actual_origin_preserved=doc['portal_origin'],qr_matches_actual_document=True,pdf=str(file),screenshot=str(image),passed=True)
        except Exception as e:proof['error']=str(e);page.screenshot(path=str(a.screenshots/'existing-cancelled-reward-diagnostic.png'));raise
        finally:
            b.close();a.proof.write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n');a.proof.chmod(0o600)
    print('PASS existing cancelled reward AR390 actual invoice/PDF/QR; no writes or QR navigation')


if __name__=='__main__':main()
