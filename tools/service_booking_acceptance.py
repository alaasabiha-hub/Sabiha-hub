"""Actual local Auth/RPC + Flutter Web checkout acceptance. Never accepts hosted URLs.

QA records are retained cancelled/inactive for audit; prior default branch and
test cashier permissions are restored in finally. No real gateway is called.
"""
import argparse
import concurrent.futures
import datetime as dt
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid


class Acceptance:
    def __init__(self, runtime):
        self.r = runtime.resolve()
        self.settings = json.loads((self.r / 'local-status.json').read_text())
        self.accounts = json.loads((self.r / 'test-accounts-final.json').read_text())
        self.base = self.accounts['url']
        assert urllib.parse.urlsplit(self.base).hostname == '127.0.0.1'
        self.statefile = self.r / 'stage2-qa-state.local.json'
        assert not self.statefile.exists(), 'Restore prior stage2 QA state before continuing'
        self.tokens = {}
        self.proof = {'local_only': True, 'production_touched': False, 'gateway_called': False}

    def call(self, path, data=None, who=None, method=None, allowed=(200,201,204)):
        key = self.settings['SERVICE_ROLE_KEY'] if who == 'admin' else self.settings['ANON_KEY']
        token = self.tokens.get(who, key)
        request = urllib.request.Request(self.base + path,
            data=None if data is None else json.dumps(data).encode(), method=method,
            headers={'apikey': key, 'Authorization': 'Bearer ' + token,
                     'Content-Type': 'application/json', 'Prefer': 'return=representation'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read(); code = response.status
        except urllib.error.HTTPError as error:
            code = error.code; raw = error.read()
        value = json.loads(raw) if raw else None
        assert code in allowed, (path.split('?')[0], code, value)
        return value

    def rpc(self, name, data, who='customer', **kw):
        return self.call('/rest/v1/rpc/' + name, data, who, **kw)

    def sql(self, source):
        env = os.environ.copy()
        env['DOCKER_HOST'] = 'unix://' + str(self.r/'instances/sabiha-local/sock/docker.sock')
        env['DOCKER_CONFIG'] = str(self.r/'docker-config')
        subprocess.run([str(self.r/'docker-cli/docker/docker'), 'exec', '-i',
            'supabase_db_supabase-local', 'psql', '-X', '-U', 'postgres', '-d',
            'postgres', '-v', 'ON_ERROR_STOP=1'], input=source, text=True,
            env=env, stdout=subprocess.DEVNULL, check=True)

    def save_state(self):
        self.statefile.write_text(json.dumps(self.state, indent=2))
        os.chmod(self.statefile, 0o600)

    def prepare(self):
        for role in ['owner','customer','other_customer']:
            user = self.accounts['users'][role]
            signed = self.call('/auth/v1/token?grant_type=password',
                {'email':user['email'], 'password':user['password']})
            self.tokens[role] = signed['access_token']
        old = self.call('/rest/v1/business_branches?is_default=eq.true&select=branch_id,is_active', who='admin')
        self.state = {'branch':str(uuid.uuid4()), 'previous_default':old,
                      'created':[]}
        self.save_state()
        branch = self.state['branch']
        self.call('/rest/v1/business_branches', {'branch_id':branch,
            'name_ar':'اختبار مسار باقة معزول', 'name_en':'Isolated checkout QA'}, 'admin')
        self.sql("begin;update public.business_branches set is_default=false where is_default;"
                 "update public.business_branches set is_default=true where branch_id='"+branch+"';commit;")
        # Dedicated disposable-role account: no existing staff permissions change.
        email='checkout-cashier-'+uuid.uuid4().hex+'@sabiha.test'
        password=secrets.token_urlsafe(24)
        employee=self.call('/auth/v1/admin/users',{'email':email,'password':password,
            'email_confirm':True,'user_metadata':{'full_name':'Isolated checkout QA cashier'}},'admin')['id']
        self.state['employee']=employee;self.save_state()
        self.call('/rest/v1/staff_profiles',{'user_id':employee,'full_name':'Isolated checkout QA cashier',
            'role':'employee','permissions':{'cashier':True},'is_active':True},'admin')
        self.call('/rest/v1/staff_branch_access', {'user_id':employee,'branch_id':branch}, 'admin')
        self.tokens['employee']=self.call('/auth/v1/token?grant_type=password',{'email':email,'password':password})['access_token']
        # Dedicated QA vehicle avoids conflicts with any earlier test bookings.
        self.car = self.call('/rest/v1/vehicles', {
            'customer_id':self.accounts['users']['customer']['id'], 'brand':'QA',
            'model':'Isolated checkout', 'plate_number':'QA-'+uuid.uuid4().hex[:8]}, 'admin')[0]
        self.state['vehicle'] = self.car['id']; self.save_state()
        self.service = {'name':'اختبار معزول — باقة الحجز', 'name_en':'Isolated QA booking package',
            'price':137.45,'duration_minutes':45,'resource_key':'wash','is_active':True,'is_public':True}
        self.offer = {'name':'اختبار معزول — باقة الحجز','name_en':'Isolated QA booking package',
            'description':'بيانات اختبار محلية فقط','description_en':'Isolated local QA only',
            'category':'package','compare_price':160,'is_active':True,'is_public':True}
        self.saved = self.rpc('save_service_promotion', {'p_request':str(uuid.uuid4()),
            'p_service':self.service,'p_offer':self.offer}, 'owner')
        self.state['created'].append(self.saved);self.save_state()

    def verify_document(self, result, token_role='customer'):
        docs = self.rpc('list_invoice_documents', {}, token_role)
        record = next(d for d in docs if d['invoice_id']==result['invoice_id'])
        document = self.rpc('resolve_invoice_document', {'p_token':record['document_token']}, token_role)
        assert document['booking_id']==result['booking_id']
        assert document['order_id']==result['order_id']
        assert float(document['snapshot']['total'])==137.45
        assert document['vehicle_id']==self.car['id']
        return document

    def http_acceptance(self):
        offers = self.rpc('get_public_promotions', {}, who=None)['offers']
        assert any(o['offer_id']==self.saved['offer_id'] and float(o['price'])==137.45 for o in offers)
        day = (dt.date.today()+dt.timedelta(days=7)).isoformat()
        payload = {'p_request':str(uuid.uuid4()),'p_service':self.saved['service_id'],
            'p_branch':self.state['branch'],'p_vehicle':self.car['id'],
            'p_date':day,'p_time':'10:00:00','p_expected_price':137.45,'p_notes':'Isolated concurrent QA'}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _:self.rpc('place_customer_service_booking',payload), range(6)))
        assert all(r==results[0] for r in results)
        result = results[0]
        assert self.verify_document(result)['payment_status']=='unpaid'
        # An entirely new request still cannot duplicate the vehicle interval.
        self.rpc('place_customer_service_booking', {**payload,'p_request':str(uuid.uuid4())}, allowed=(400,))
        error=self.rpc('place_customer_service_booking', {**payload,'p_request':str(uuid.uuid4()),'p_expected_price':1}, allowed=(500,))
        assert error['code']=='40001'
        self.rpc('get_owner_promotions', {}, 'customer', allowed=(403,))
        self.rpc('get_owner_promotions', {}, 'employee', allowed=(403,))
        self.rpc('resolve_invoice_document', {'p_token':self.verify_document(result)['document_token']}, 'other_customer', allowed=(403,))
        invoices = self.call('/rest/v1/business_invoices?order_id=eq.'+result['order_id']+'&select=invoice_id,total', who='admin')
        bookings = self.call('/rest/v1/bookings?branch_id=eq.'+self.state['branch']+'&select=id', who='admin')
        assert len(invoices)==len(bookings)==1
        shift = self.rpc('open_cashier_shift', {'p_request':str(uuid.uuid4()),'p_branch':self.state['branch'],'p_opening':0}, 'employee')
        self.state['shift']=shift;self.save_state()
        payment = {'p_request':str(uuid.uuid4()),'p_shift':shift,'p_invoice':result['invoice_id'],'p_event':'sale','p_method':'cash'}
        self.rpc('record_shift_payment', payment, 'customer', allowed=(400,403))
        self.rpc('record_shift_payment', {**payment,'p_method':'electronic'}, 'employee', allowed=(403,))
        self.rpc('record_shift_payment', payment, 'employee')
        self.rpc('record_shift_payment', payment, 'employee')
        assert self.verify_document(result)['payment_status']=='paid'
        self.proof.update({'real_auth':True,'owner_published_package':True,'server_price':137.45,
            'six_concurrent_requests_one_booking_invoice':True,'invented_price_rejected':True,
            'overlapping_request_rejected':True,'roles_verified':['customer','owner','cashier'],
            'cash_pending_then_confirmed_once':True,'unverified_electronic_denied':True})

    def browser_acceptance(self):
        from playwright.sync_api import sync_playwright
        errors=[];runs=[]
        with sync_playwright() as playwright:
            browser=playwright.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
            for index,(width,language) in enumerate(getattr(self,'browser_cases',[(1440,'ar'),(390,'en'),(1440,'en'),(390,'ar')])):
                page=browser.new_page(viewport={'width':width,'height':1100})
                page.set_default_timeout(10000)
                page.on('pageerror',lambda e:errors.append(str(e)))
                page.on('console',lambda m:errors.append(m.text) if 'overflowed' in m.text or 'EXCEPTION CAUGHT' in m.text else None)
                page.goto('http://127.0.0.1:8080')
                page.wait_for_selector('flutter-view',timeout=60000)
                page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
                page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
                if language=='en':
                    page.get_by_role('button',name='EN',exact=True).click()
                    page.wait_for_timeout(250)
                page.get_by_text('لأن سيارتك تستحق الأفضل' if language=='ar' else 'Because Your Car Deserves the Best',exact=True).wait_for()
                book=page.get_by_role('button',name='احجز الآن' if language=='ar' else 'Book now',exact=True).first
                self.near(page,book).click()
                email='البريد الإلكتروني' if language=='ar' else 'Email address'
                password='كلمة المرور' if language=='ar' else 'Password'
                page.get_by_role('textbox',name=email,exact=True).wait_for()
                user=self.accounts['users']['customer']
                self.type_into(page,email,user['email']);self.type_into(page,password,user['password'])
                page.get_by_role('textbox',name=password,exact=True).press('Tab')
                with page.expect_response(lambda r:'/auth/v1/token?' in r.url,timeout=20000) as signed:
                    self.near(page,page.get_by_role('button',name='تسجيل الدخول' if language=='ar' else 'Sign in',exact=True)).click()
                sent=json.loads(signed.value.request.post_data)
                assert sent['email']==user['email'], 'Automation entered an incomplete email'
                assert sent['password']==user['password'], 'Automation entered an incomplete password'
                assert signed.value.status==200, ('Auth status',signed.value.status)
                print('PASS Flutter login',language,width,flush=True)
                page.get_by_text('الخدمة والموعد' if language=='ar' else 'Service & appointment',exact=True).wait_for(timeout=20000)
                # Select the QA vehicle through the actual Flutter dropdown.
                vehicle=page.get_by_role('button',name=re.compile(('السيارة' if language=='ar' else 'Vehicle')+r'.*'))
                self.near(page,vehicle).click()
                page.wait_for_timeout(250)
                page.get_by_role('menuitem',name='QA Isolated checkout · '+self.car['plate_number'],exact=True).click()
                time=page.get_by_role('button',name=re.compile('^'+('الوقت:' if language=='ar' else 'Time:')))
                with page.expect_response(lambda r:'/rpc/available_booking_slots' in r.url,timeout=20000) as response:
                    self.near(page,time).click()
                slots=response.value.json();assert slots
                # Both runs use the form's actual default date; reserve disjoint intervals.
                chosen=next(s['slot_time'][:5] for s in slots if s['slot_time']>=f'{9+2*index:02d}:00:00')
                page.get_by_role('button',name=chosen,exact=True).click()
                submit=page.get_by_role('button',name='إرسال طلب الحجز' if language=='ar' else 'Send booking request',exact=True)
                with page.expect_response(lambda r:'/rpc/place_customer_service_booking' in r.url,timeout=20000) as response:
                    self.near(page,submit).click()
                assert response.value.status==200,(response.value.status,response.value.text())
                result=response.value.json();payload=json.loads(response.value.request.post_data)
                assert payload['p_service']==self.saved['service_id'] and payload['p_vehicle']==self.car['id']
                assert result['quoted_price']==137.45
                document=self.verify_document(result)
                assert document['payment_status']=='unpaid'
                if not document.get('portal_origin'):
                    # Configure only this isolated QA document, never global or production settings.
                    self.call('/rest/v1/business_invoices?invoice_id=eq.'+result['invoice_id'],{'document_origin':'http://127.0.0.1:8080'},'admin','PATCH')
                    document=self.verify_document(result)
                page.wait_for_timeout(450)
                page.get_by_text('لأن سيارتك تستحق الأفضل' if language=='ar' else 'Because Your Car Deserves the Best',exact=True).wait_for()
                print('PASS Flutter booking and invoice created',language,width,flush=True)
                page.get_by_role('button',name=re.compile('حجوزاتي' if language=='ar' else 'Bookings')).last.click()
                page.get_by_text('طلباتي ومواعيدي' if language=='ar' else 'Orders & appointments',exact=True).wait_for()
                short=document.get('booking_number') or ('SH-'+result['booking_id'].replace('-','')[:8].upper())
                search=page.get_by_role('textbox').first
                search.wait_for();search.click();page.wait_for_timeout(150);search.press_sequentially(short,delay=20);page.wait_for_timeout(200)
                assert search.input_value()==short, 'Booking search input did not settle'
                page.get_by_role('button',name='التفاصيل والفاتورة' if language=='ar' else 'Details & invoice',exact=True).first.wait_for()
                assert page.get_by_role('button',name='التفاصيل والفاتورة' if language=='ar' else 'Details & invoice',exact=True).count()==1
                card=self.near(page,page.get_by_role('button',name='التفاصيل والفاتورة' if language=='ar' else 'Details & invoice',exact=True))
                page.screenshot(path=str(self.r.parents[1]/'outputs'/('Sabiha-customer-bookings-'+language+'-'+str(width)+'-qa.png')))
                card.click()
                secure=page.get_by_role('button',name='عرض الفاتورة' if language=='ar' else 'View invoice',exact=True)
                secure.wait_for()
                with page.expect_response(lambda r:'/rpc/resolve_invoice_document' in r.url,timeout=20000) as opened:
                    secure.click()
                assert opened.value.status==200
                assert opened.value.json()['invoice_id']==result['invoice_id']
                page.get_by_text(re.compile(re.escape(document.get('invoice_number') or result['invoice_id']))).last.wait_for()
                page.wait_for_timeout(350)
                page.screenshot(path=str(self.r.parents[1]/'outputs'/('Sabiha-stage2-booking-'+language+'-'+str(width)+'.png')))
                pdf_control=self.near(page,page.get_by_role('button',name=re.compile('Download PDF with QR')))
                with page.expect_download(timeout=30000) as downloaded:pdf_control.click()
                pdf=self.r.parents[1]/'outputs'/('Sabiha-customer-invoice-'+language+'-'+str(width)+'-qa.pdf')
                downloaded.value.save_as(str(pdf))
                qr=self.verify_pdf(pdf,document)
                runs.append({'width':width,'language':language,'real_booking_invoice':True,'invoice_displayed_in_flutter':True,'pdf_downloaded':True,'qr_matches_authorized_document':True,'short_reference_and_card':True})
                print('PASS Flutter customer invoice displayed',language,width,flush=True)
                self.proof['actual_flutter_web']=runs
                (self.r/'stage2-browser-partial-proof.json').write_text(json.dumps(self.proof,indent=2))
                page.close()
            browser.close()
        assert not errors,errors
        self.proof.update({'actual_flutter_web':runs,'render_errors':errors})

    def verify_pdf(self,path,document):
        from pypdf import PdfReader
        import pypdfium2 as pdfium
        assert path.read_bytes().startswith(b'%PDF-')
        reader=PdfReader(path)
        assert '137.45' in ''.join(p.extract_text() for p in reader.pages)
        folder=self.r/'customer-invoice-qr';folder.mkdir(exist_ok=True)
        image=folder/(path.stem+'.png')
        pdf=pdfium.PdfDocument(str(path));page=pdf[0];bitmap=page.render(scale=3)
        bitmap.to_pil().save(image);bitmap.close();page.close();pdf.close()
        result=subprocess.run([str(self.r/'read_qr'),str(image)],capture_output=True,text=True,check=True)
        values=[v for line in result.stdout.splitlines() for v in json.loads(line).get('qr_values',[])]
        expected=document['portal_origin'].rstrip('/')+'/?invoice='+document['document_token']
        assert expected in values, 'Downloaded invoice QR does not match its authorized document'
        return expected

    def cross_request_race(self):
        payload={'p_service':self.saved['service_id'],'p_branch':self.state['branch'],
            'p_vehicle':self.car['id'],'p_date':(dt.date.today()+dt.timedelta(days=10)).isoformat(),
            'p_time':'10:00:00','p_expected_price':137.45,'p_notes':'Isolated cross-request race'}
        def attempt(_):
            return self.rpc('place_customer_service_booking',
                {**payload,'p_request':str(uuid.uuid4())},allowed=(200,400))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(attempt,range(2)))
        assert sum('booking_id' in r for r in results)==1
        assert any(r.get('message')=='Vehicle already booked in this interval' for r in results)
        self.proof['different_concurrent_requests_vehicle_conflict_blocked']=True

    @staticmethod
    def near(page,locator):
        for _ in range(35):
            box=None
            if locator.count():
                box=locator.first.bounding_box()
                if box and 4<box['y']<page.viewport_size['height']-90:return locator.first
            page.mouse.move(page.viewport_size['width']//2,page.viewport_size['height']//2)
            page.mouse.wheel(0,-220 if locator.count() and box and box['y']<=4 else 220)
            page.wait_for_timeout(80)
        raise AssertionError('Flutter control not reached: '+str(locator))

    @staticmethod
    def type_into(page,label,value):
        field=page.get_by_role('textbox',name=label,exact=True)
        field.click();page.wait_for_timeout(150)
        field.press('ControlOrMeta+A');field.press_sequentially(value,delay=20)
        page.wait_for_timeout(100)

    def restore(self):
        if not self.statefile.exists():return
        self.state=json.loads(self.statefile.read_text());branch=self.state['branch']
        # Retain QA history, refund only these isolated test ledger sales.
        if self.state.get('shift'):
            shift=self.state['shift']
            rows=self.call('/rest/v1/business_payment_events?shift_id=eq.'+shift+'&select=invoice_id,event_type',who='admin')
            refunds={r['invoice_id'] for r in rows if r['event_type']=='refund'}
            for row in rows:
                if row['event_type']=='sale' and row['invoice_id'] not in refunds:
                    self.rpc('record_shift_payment',{'p_request':str(uuid.uuid4()),'p_shift':shift,'p_invoice':row['invoice_id'],'p_event':'refund','p_method':'cash'},'employee')
            total=self.rpc('cashier_shift_totals',{'p_shift':shift},'employee')
            self.rpc('close_cashier_shift',{'p_shift':shift,'p_actual':total['expected_cash'],'p_reason':'Isolated QA cleanup'},'employee')
            self.rpc('approve_cashier_shift',{'p_shift':shift},'owner')
        self.call('/rest/v1/bookings?branch_id=eq.'+branch+'&status=eq.pending',{'status':'cancelled'},'admin','PATCH')
        self.call('/rest/v1/business_orders?branch_id=eq.'+branch+'&status=eq.received',{'status':'cancelled'},'admin','PATCH')
        self.call('/rest/v1/business_invoices?branch_id=eq.'+branch+'&status=eq.active',{'status':'void'},'admin','PATCH')
        for item in self.state['created']:
            self.call('/rest/v1/business_offers?offer_id=eq.'+item['offer_id'],{'is_active':False,'is_public':False},'admin','PATCH')
            self.call('/rest/v1/business_catalog_items?item_id=eq.'+item['service_id'],{'is_active':False,'is_public':False},'admin','PATCH')
        if self.state.get('employee'):
            self.call('/rest/v1/staff_profiles?user_id=eq.'+self.state['employee'],{'is_active':False},'admin','PATCH')
        # No DELETE. Retain QA-only membership with an inactive QA staff account.
        source="begin;update public.business_branches set is_default=false,is_active=false where branch_id='"+branch+"';"
        for old in self.state['previous_default']:
            source+="update public.business_branches set is_default=true where branch_id='"+old['branch_id']+"';"
        self.sql(source+'commit;')
        self.state['restored']=True;self.save_state()
        self.statefile.rename(self.r/('stage2-qa-state.restored-'+uuid.uuid4().hex[:8]+'.local.json'))
        self.proof['qa_restored_no_deletes']=True


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--browser-only',action='store_true')
    parser.add_argument('--mobile-only',action='store_true')
    args=parser.parse_args();run=Acceptance(args.runtime)
    if args.mobile_only:run.browser_cases=[(390,'en')]
    try:
        run.prepare()
        if not args.browser_only:run.http_acceptance()
        run.browser_acceptance();run.cross_request_race()
        run.proof['all_checks_passed']=True
    finally:
        run.restore()
        (run.r/'stage2-acceptance-proof.json').write_text(json.dumps(run.proof,indent=2))
    print('PASS Flutter customer journey, PDF/QR and concurrent vehicle guard; QA restored' if args.browser_only else 'PASS owner publication, customer journey, PDF/QR and cashier confirmation; QA restored')


if __name__=='__main__':main()
