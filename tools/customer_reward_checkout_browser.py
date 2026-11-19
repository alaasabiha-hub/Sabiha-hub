"""Local-only real Flutter normal/reward checkout browser acceptance.

PLAN (default; no network or DB): require root approval/current web build; atomically
assert default branch has NO prior loyalty policy or redemption activation before
creating a tagged public QA service there. Never change default branch/config.
Create isolated offer, enabled policy, earning activation, four explicit rules and
redemption activation using actual owner JWT. Create two canonical source bookings,
complete/pay them on a dedicated QA owner shift, drain actual earning events.
AR390 and EN1440 each exercise Flutter normal prepare/place/receipt/ack, explicit
reward options/quote/consent/prepare/place/receipt/ack, wallet refresh and actual
reward invoice PDF/QR. Browser requests are the evidence; no direct placement fallback.
Finally cancel QA pending normal/reward bookings, refund only QA source cash, drain,
close/approve QA shift, append disabled policy, hide QA service/offer. Retain audit
rows, no deletes. Compare hashes of ALL preexisting public/private rows excluding
sequence counters; assert exact BKG/INV deltas match canonical QA bookings created.
--execute is only for a separately root-approved run; --restore-only retries cleanup.
"""
import argparse
from collections import Counter
import datetime as dt
import json
from pathlib import Path
import re
import sys
import uuid
import urllib.request
import urllib.error
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from owner_redemption_rules_browser import Harness as OwnerHarness
from service_booking_acceptance import Acceptance
from checkout_retry_lock_concurrency import PsqlSession


def uid(): return str(uuid.uuid4())


class Harness(OwnerHarness):
    def __init__(self, args):
        super().__init__(args)
        self.state_file = self.r / 'customer-reward-checkout-browser-state.json'
        self.proof = {'local_only': True, 'production_touched': False,
                      'gateway_called': False, 'screens': [], 'journeys': [], 'render_errors': []}
        prior_checkpoint=json.loads((self.r/'customer-reward-checkout-browser-proof-attempt5-e124963d14.json').read_text())
        verified=next(x for x in prior_checkpoint['journeys'] if x['language']=='ar' and x['mode']=='normal')
        assert verified['qa_fixture_verified'] and verified['actual_quoted_price']==137.45 and verified['receipt_acknowledged']
        self.proof['previous_ar_normal_checkpoint']={'proof_file':str(self.r/'customer-reward-checkout-browser-proof-attempt5-e124963d14.json'),'journey':verified}
        reward_checkpoint=self.r/'customer-reward-checkout-browser-proof-attempt6-9357ad6cd6.json'
        reward_proof=json.loads(reward_checkpoint.read_text());ar_reward=reward_proof['journeys'][0]
        assert ar_reward['language']=='ar' and ar_reward['mode']=='reward' and ar_reward['receipt_acknowledged'] and ar_reward['actual_amount_due']==0 and ar_reward['qa_fixture_verified']
        self.proof['previous_ar_reward_checkpoint']={'proof_file':str(reward_checkpoint),'journey':ar_reward}
        readonly_pdf=self.r/'customer-reward-cancelled-invoice-proof.json'
        assert json.loads(readonly_pdf.read_text())['passed']
        self.proof['previous_cancelled_ar_pdf_proof']=str(readonly_pdf)
        self.proof['remaining_cases_only']=['en_normal','en_reward']
        self.tokens = {}
        self.cashier_role=args.cashier_role
        self.prior_state=args.prior_cleanup_state
        self.prior_proof=args.prior_cleanup_proof

    def call(self, path, data=None):
        request=urllib.request.Request(self.base+path,data=None if data is None else json.dumps(data).encode(),method='GET' if data is None else 'POST',
          headers={'apikey':self.settings['ANON_KEY'],'Authorization':'Bearer '+(self.token or self.settings['ANON_KEY']),'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=30) as response:
                raw=response.read()
                return json.loads(raw) if raw.strip() else None
        except urllib.error.HTTPError as error:
            raw=error.read()
            try:
                payload=json.loads(raw);detail={k:payload.get(k) for k in ['code','message'] if k in payload}
            except (ValueError,TypeError):detail={'message':'Non-JSON error response'}
            raise RuntimeError(path+' HTTP '+str(error.code)+' '+json.dumps(detail)) from error

    def sign_in(self):
        for role in ['owner', 'customer', self.cashier_role]:
            u = self.accounts['users'][role]
            self.tokens[role] = self.call('/auth/v1/token?grant_type=password',
                {'email': u['email'], 'password': u['password']})['access_token']
        self.token = self.tokens['owner']

    def rpc_as(self, name, data, role='owner'):
        self.token = self.tokens[role]
        try: return self.rpc(name, data)
        finally: self.token = self.tokens['owner']

    def snapshot(self):
        rows = self.sql("""create temp table qa_hashes(t text,h text);do $$declare t record;h text;begin
        for t in select schemaname,tablename from pg_tables where schemaname in ('public','private')
        and not(schemaname='private' and tablename='document_number_counters') loop
        execute format('select coalesce(string_agg(md5(row_to_json(r)::text),%L),%L) from %I.%I r',',','',t.schemaname,t.tablename) into h;
        insert into qa_hashes values(t.schemaname||'.'||t.tablename,h);end loop;end $$;
        select t||'|'||h from qa_hashes order by t;""")
        return {line.split('|',1)[0]: Counter(filter(None,line.split('|',1)[1].split(',')))
                for line in rows.splitlines() if '|' in line}

    def counters(self):
        return json.loads(self.sql('select json_object_agg(kind,last_value) from private.document_number_counters;'))

    def drain(self):
        for _ in range(100):
            value = json.loads(self.sql('begin;set local role service_role;select public.drain_loyalty_visit_event();commit;'))
            assert not value.get('retry'), value
            if not value.get('processed'): return
        raise AssertionError('Unexpected queue volume')

    def prepare(self):
        if self.state_file.exists():
            old = json.loads(self.state_file.read_text())
            assert old.get('cleanup_complete'), 'Run --restore-only for previous QA first'
            self.state_file.rename(self.r / ('customer-reward-checkout-state-' + old['tag'] + '.json'))
        cashier=str(uuid.UUID(self.accounts['users'][self.cashier_role]['id']))
        assert self.sql("select count(*) from public.business_cashier_shifts where cashier_id='"+cashier+"' and status='open';")=='0', 'Never close or reuse an existing shift'
        branch = self.sql('select branch_id from public.business_branches where is_default and is_active;')
        uuid.UUID(branch)
        permission=self.sql("begin;select set_config('request.jwt.claim.sub','"+cashier+"',true);set local role authenticated;select private.can_cashier_branch('"+branch+"');rollback;").splitlines()[-1]
        assert permission=='t', 'Actual can_cashier_branch must permit existing QA manager; no profile changes'
        self.state = {'tag': uuid.uuid4().hex[:10], 'branch': branch, 'service': uid(),
                      'vehicle': uid(), 'shift': uid(), 'sources': [], 'receipts': [], 'attempt_ids': [],
                      'offer': None, 'policy': None, 'rules': None, 'shift_open': False,
                      'cleanup_complete': False, 'fixture': False}
        self.save_state()
        assert self.rpc_as('get_service_booking_attempt', {}, 'customer')['state']=='absent', 'Resolve prior customer attempt before isolated QA'
        s = self.state; c = self.accounts['users']['customer']['id']; tag = s['tag']
        # Revised root-approved retry permits ONLY the exact retained inactive QA
        # program from the archived failed run, never another default-branch policy.
        if self.prior_state:
            assert len(self.prior_state)==len(self.prior_proof)==6, 'Exactly six audited previous QA programs required'
            pairs=[]
            for state_path,proof_path,expected in zip(self.prior_state,self.prior_proof,[0,2,2,3,3,3]):
                prior=json.loads(state_path.read_text());proof=json.loads(proof_path.read_text())
                assert prior['cleanup_complete'] and prior['branch']==branch
                assert proof['qa_cleanup_complete'] and proof['preexisting_rows_unchanged']
                assert proof['document_counters_exact'] and proof['document_counter_deltas']=={'BKG':expected,'INV':expected}
                assert len(prior['receipts'])==max(0,expected-2)
                pairs.append((str(uuid.UUID(prior['offer'])),str(uuid.UUID(prior['service']))))
            assert len(set(pairs))==6
            allowed=' or '.join("(offer_id='"+o+"' and eligible_service_ids=array['"+v+"'::uuid])" for o,v in pairs)
            allowed_p=allowed.replace('offer_id=','p.offer_id=').replace('eligible_service_ids=','p.eligible_service_ids=')
            offers=','.join("'"+o+"'::uuid" for o,_ in pairs)
            guard=("assert (select count(distinct offer_id) from private.loyalty_policy_versions where branch_id='"+branch+"')=6,'Exactly recorded QA programs required';"
              "assert not exists(select 1 from private.loyalty_policy_versions where branch_id='"+branch+"' and not ("+allowed+")),'Unapproved prior policy';"
              "assert not (select enabled from private.loyalty_policy_versions where branch_id='"+branch+"' order by version_no desc limit 1),'Prior QA latest policy must be disabled';"
              "assert not exists(select 1 from private.loyalty_redemption_rule_versions r where r.branch_id='"+branch+"' and (r.offer_id not in ("+offers+") or not exists(select 1 from private.loyalty_policy_versions p where p.version_id=r.policy_version_id and p.offer_id=r.offer_id and ("+allowed_p+")))),'Unapproved prior rules';"
              "assert not exists(select 1 from private.reward_rule_activations a join private.loyalty_redemption_rule_versions r using(rules_version_id) where r.branch_id='"+branch+"' and r.offer_id not in ("+offers+")),'Unapproved prior redemption activation';"
              "assert not exists(select 1 from private.loyalty_visit_activations a join private.loyalty_policy_versions p on p.version_id=a.policy_version_id where p.branch_id='"+branch+"' and p.offer_id not in ("+offers+")),'Unapproved prior earning activation';")
            for po,ps in pairs:
                guard+=("assert exists(select 1 from public.business_catalog_items where item_id='"+ps+"' and not is_active and not is_public),'Prior QA service must be hidden';"
                  "assert exists(select 1 from public.business_offers where offer_id='"+po+"' and not is_active and not is_public),'Prior QA offer must be hidden';")
        else:
            guard=("assert not exists(select 1 from private.loyalty_policy_versions where branch_id='"+branch+"'),'Default branch already has a policy';"
              "assert not exists(select 1 from private.reward_rule_activations a join private.loyalty_redemption_rule_versions r using(rules_version_id) where r.branch_id='"+branch+"'),'Default branch already has activation';")
        self.sql("begin;select branch_id from public.business_branches where branch_id='"+branch+"' and is_default and is_active for update;"
          "do $$begin "+guard+"end $$;"
          "insert into public.business_catalog_items(item_id,branch_id,item_type,name,name_en,price,is_active,is_public,duration_minutes) values('"+s['service']+"','"+branch+"','service','اختبار مكافأة محلي "+tag+"','Local reward QA "+tag+"',137.45,true,true,30);"
          "insert into public.vehicles(id,customer_id,brand,model,plate_number) values('"+s['vehicle']+"','"+c+"','QA','Reward browser','QAR-"+tag+"');commit;")
        s['fixture'] = True; self.save_state()
        s['offer'] = self.rpc_as('save_visit_reward_offer', {'p_request':uid(), 'p_branch':branch,
          'p_name':'Local reward QA '+tag,'p_name_en':'Local reward QA '+tag,'p_visits':1,
          'p_publish':True,'p_reward_service':s['service'],'p_offer':None})['offer_id']; self.save_state()
        s['policy'] = self.rpc_as('save_loyalty_policy', {'p_request':uid(),'p_branch':branch,
          'p_offer':s['offer'],'p_services':[s['service']],'p_enabled':True})['version_id']; self.save_state()
        self.rpc_as('activate_loyalty_visits', {'p_request':uid(),'p_policy_version':s['policy']})
        rules = {'pooling':'policy_version','expiry':'no_expiry','cancellation':'restore_visits','refunded_contribution':'offset_future_visits'}
        saved = self.rpc_as('save_loyalty_redemption_rules', {'p_request':uid(),'p_policy_version':s['policy'],
          'p_expected_rules_version':None,'p_rules':rules})
        s['rules'] = saved['current']['rules_version_id']; self.save_state()
        self.rpc_as('activate_loyalty_redemption', {'p_request':uid(),'p_rules_version':s['rules']})
        shift = self.rpc_as('open_cashier_shift', {'p_request':s['shift'],'p_branch':branch,'p_opening':0}, self.cashier_role)
        s['shift'] = shift; s['shift_open'] = True; self.save_state()
        for i in range(1):
            receipt = self.rpc_as('place_customer_service_booking', {
              'p_request':uid(),'p_service':s['service'],'p_branch':branch,'p_vehicle':s['vehicle'],
              'p_date':(dt.date.today()+dt.timedelta(days=21+i)).isoformat(),'p_time':'10:00',
              'p_expected_price':137.45,'p_notes':'Local reward browser earning source '+tag}, 'customer')
            receipt['qa_sale_request']=uid();receipt['qa_refund_request']=uid();s['sources'].append(receipt); self.save_state()
            b,o=receipt['booking_id'],receipt['order_id']
            self.sql("begin;update public.bookings set status='confirmed' where id='"+b+"' and status='pending';update public.bookings set status='in_progress' where id='"+b+"' and status='confirmed';update public.bookings set status='completed' where id='"+b+"' and status='in_progress';update public.business_orders set status='in_progress' where order_id='"+o+"' and status='received';update public.business_orders set status='quality_check' where order_id='"+o+"' and status='in_progress';update public.business_orders set status='completed' where order_id='"+o+"' and status='quality_check';commit;")
            self.rpc_as('record_shift_payment', {'p_request':receipt['qa_sale_request'],'p_shift':s['shift'],'p_invoice':receipt['invoice_id'],'p_event':'sale','p_method':'cash'}, self.cashier_role)
        self.drain()
        wallet=self.rpc_as('get_my_reward_wallet', {}, 'customer')
        p=next(p for p in wallet['programs'] if p['rules_version_id']==s['rules'])
        assert p['unused_valid_visits']==1 and wallet['global_spendable_balance'] is None
        self.proof['source_earning_visits']=1

    def restore(self):
        s=self.state
        if not s or s.get('cleanup_complete'): return
        errors=[]
        # Recover any browser receipt even when a selector failed after placement.
        if s.get('fixture'):
            result=self.rpc_as('get_service_booking_attempt', {}, 'customer')
            if result.get('state') in ('succeeded','open'):
                assert result.get('request_id') in s['attempt_ids'], 'Never touch a non-harness customer attempt'
            if result.get('state')=='succeeded':
                receipt=result['result']
                if receipt.get('booking_id') not in [r['booking_id'] for r in s['receipts']]:
                    s['receipts'].append(receipt); self.save_state()
                self.rpc_as('acknowledge_service_booking_attempt', {'p_request':result['request_id']}, 'customer')
            elif result.get('state')=='open':
                self.rpc_as('close_service_booking_attempt', {'p_request':result['request_id']}, 'customer')
        for receipt in s['receipts']:
            try:
                status=self.sql("select status from public.bookings where id='"+receipt['booking_id']+"';")
                if status=='pending': self.rpc_as('change_customer_booking', {'p_request':uid(),'p_booking':receipt['booking_id'],'p_action':'cancel'}, 'customer')
            except Exception as e: errors.append('cancel: '+str(e))
        if s['shift_open']:
            for receipt in s['sources']:
                try: self.rpc_as('record_shift_payment', {'p_request':receipt['qa_refund_request'],'p_shift':s['shift'],'p_invoice':receipt['invoice_id'],'p_event':'refund','p_method':'cash'}, self.cashier_role)
                except Exception as e: errors.append('refund: '+str(e))
            try:
                self.drain(); self.rpc_as('get_my_reward_wallet', {}, 'customer')
                total=self.rpc_as('cashier_shift_totals', {'p_shift':s['shift']}, self.cashier_role)
                assert float(total['expected_cash'])==0
                self.rpc_as('close_cashier_shift', {'p_shift':s['shift'],'p_actual':0,'p_reason':'Local reward browser QA fully refunded'}, self.cashier_role)
                self.rpc_as('approve_cashier_shift', {'p_shift':s['shift']})
                s['shift_open']=False; self.save_state()
            except Exception as e: errors.append('close shift: '+str(e))
        if s.get('policy'):
            try: self.rpc_as('save_loyalty_policy', {'p_request':uid(),'p_branch':s['branch'],'p_offer':s['offer'],'p_services':[s['service']],'p_enabled':False})
            except Exception as e: errors.append('disable policy: '+str(e))
        if s.get('offer'):
            try: self.rpc_as('save_visit_reward_offer', {'p_request':uid(),'p_branch':s['branch'],'p_name':'Local reward QA '+s['tag'],'p_name_en':'Local reward QA '+s['tag'],'p_visits':1,'p_publish':False,'p_reward_service':s['service'],'p_offer':s['offer']})
            except Exception as e: errors.append('hide offer: '+str(e))
        if s.get('fixture'): self.sql("update public.business_catalog_items set is_active=false,is_public=false where item_id='"+s['service']+"';")
        s['cleanup_complete']=not errors; self.save_state()
        self.proof['qa_cleanup_complete']=not errors
        if errors: raise RuntimeError('; '.join(errors))

    def browser(self):
        from playwright.sync_api import sync_playwright, expect
        self.out.mkdir(parents=True,exist_ok=True)
        with sync_playwright() as p:
            browser=p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
            try:
                for index,(lang,width) in enumerate([('en',1440)]):
                    page=browser.new_page(viewport={'width':width,'height':1100},accept_downloads=True)
                    page.set_default_timeout(25000)
                    def track_attempt(request):
                        if '/rpc/prepare_service_booking_attempt' in request.url:
                            body=json.loads(request.post_data);rid=body['p_request']
                            if rid not in self.state['attempt_ids']:
                                self.state['attempt_ids'].append(rid);self.save_state()
                    page.on('request',track_attempt)
                    validated_quotes={}
                    def quote_response(response):
                        if '/rpc/quote_service_reward' in response.url and response.status==200:
                            q=response.json()
                            if q.get('eligible'):
                                assert float(q['gross_amount'])==137.45 and q['amount_due']==0
                                validated_quotes[q['quote_id']]=q['fingerprint']
                    page.on('response',quote_response)
                    def fixture_request_guard(route):
                        req=route.request;body=json.loads(req.post_data or '{}');valid=True
                        if '/rpc/prepare_service_booking_attempt' in req.url:
                            payload=body['p_payload']
                            if body['p_mode']=='reward':
                                valid=validated_quotes.get(payload.get('p_quote'))==payload.get('p_fingerprint') and payload.get('p_quote') in validated_quotes
                                payload=None
                        elif '/rpc/place_customer_service_booking' in req.url:payload=body
                        elif '/rpc/quote_service_reward' in req.url:
                            payload=body
                            valid=body.get('p_policy_version')==self.state['policy'] and body.get('p_rules_version')==self.state['rules']
                        elif '/rpc/place_customer_reward_booking' in req.url:
                            payload=None;valid=body.get('p_quote') in validated_quotes and validated_quotes.get(body.get('p_quote'))==body.get('p_fingerprint')
                        else:route.continue_();return
                        if payload is not None:
                            valid=valid and payload.get('p_service')==self.state['service'] and payload.get('p_vehicle')==self.state['vehicle'] and payload.get('p_branch')==self.state['branch']
                            if 'p_expected_price' in payload:valid=valid and float(payload['p_expected_price'])==137.45
                        if not valid:self.proof['blocked_wrong_fixture_request']=True;route.abort()
                        else:route.continue_()
                    page.route('**/rest/v1/rpc/*',fixture_request_guard)
                    t=lambda a,e:a if lang=='ar' else e
                    page.on('pageerror',lambda e:self.proof['render_errors'].append(str(e)))
                    page.on('console',lambda m:self.proof['render_errors'].append(m.text) if 'overflowed' in m.text or 'EXCEPTION CAUGHT' in m.text else None)
                    def click(loc): Acceptance.near(page,loc).click();page.wait_for_timeout(150)
                    def fixed_click(loc):
                        loc.wait_for(state='visible');assert loc.is_enabled();loc.click();page.wait_for_timeout(250)
                    def button(a,e): return page.get_by_role('button',name=t(a,e),exact=True)
                    def shot(stage):
                        file=self.out/f'reward-{self.state["tag"]}-{lang}-{width}-{stage}.png';page.screenshot(path=str(file))
                        self.proof['screens'].append({'language':lang,'width':width,'stage':stage,'file':str(file)})
                        self.proof_file.write_text(json.dumps(self.proof,indent=2,ensure_ascii=False)+'\n')
                    def choose(label,rows,target):
                        # Verified by read-only AR390/EN1440 smoke: click the actual
                        # menuitem, then check the displayed selection. Never infer a
                        # Flutter keyboard focus offset from catalog/vehicle ordering.
                        loc=page.get_by_role('button',name=re.compile('^'+re.escape(label)+r'\s')).or_(page.get_by_role('combobox',name=re.compile('^'+re.escape(label)+r'\s'))).last
                        if label==t('الخدمة','Service'):
                            row=next(x for x in rows if x['item_id']==target)
                            display=row['name']+' · '+format(float(row['price']),'.15g')+' ج.م'
                        else:
                            row=next(x for x in rows if x['id']==target)
                            display=row['brand']+' '+row['model']+' · '+row['plate_number']
                        click(loc)
                        option=page.get_by_role('menuitem',name=display,exact=True).or_(page.get_by_role('option',name=display,exact=True))
                        option.wait_for(state='visible',timeout=15000)
                        assert option.count()==1, 'Actual target menuitem must exist before selection'
                        option.click();page.wait_for_timeout(250)
                        assert display in (loc.get_attribute('aria-label') or loc.inner_text()), 'Actual selection must display target value'
                    def booking_form(mode, initial=False):
                        if initial:
                            self.token=self.tokens['customer']
                            try: services=self.call('/rest/v1/business_catalog_items?select=item_id,name,name_en,description,price,vehicle_type&branch_id=eq.'+self.state['branch']+'&item_type=eq.service&is_active=eq.true&is_public=eq.true&order=name')
                            finally:self.token=self.tokens['owner']
                        else:
                            with page.expect_response(lambda r:'/business_catalog_items?' in r.url and 'vehicle_type' in r.url) as catalog:
                                click(button('احجز الآن','Book now').first)
                            services=catalog.value.json()
                        services=[x for x in services if not re.search(r'ceramic|سيراميك|paint\s*protect|حماية\s*الطلاء|\bppf\b',str(x.get('name',''))+' '+str(x.get('name_en','')),re.I)]
                        ids=[x['item_id'] for x in services]
                        choose(t('الخدمة','Service'),services,self.state['service'])
                        # Actual dropdown order equals the existing own vehicles API order.
                        self.token=self.tokens['customer']
                        try: vehicles=self.call('/rest/v1/vehicles?select=id,brand,model,year,plate_number&customer_id=eq.'+self.accounts['users']['customer']['id']+'&order=created_at')
                        finally:self.token=self.tokens['owner']
                        carids=[x['id'] for x in vehicles]
                        choose(t('السيارة','Vehicle'),vehicles,self.state['vehicle'])
                        time=page.get_by_role('button',name=re.compile('^'+t('الوقت:','Time:')))
                        with page.expect_response(lambda r:'/rpc/available_booking_slots' in r.url) as got:click(time)
                        slots=got.value.json();assert slots
                        assert json.loads(got.value.request.post_data)['p_service']==self.state['service'], 'No placement after a wrong actual selected service'
                        start=9+index*3+(1 if mode=='reward' else 0)
                        chosen=next(x['slot_time'][:5] for x in slots if x['slot_time']>=f'{start:02d}:00:00')
                        click(page.get_by_role('button',name=chosen,exact=True))
                    try:
                        page.goto(self.app);page.wait_for_selector('flutter-view',timeout=60000)
                        semantics=page.locator('flt-semantics-placeholder')
                        if semantics.count():semantics.evaluate('(e)=>e.click()')
                        page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
                        if lang=='en':click(page.get_by_role('button',name='EN',exact=True))
                        click(button('احجز الآن','Book now').first)
                        for a,e,k in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:
                            Acceptance.type_into(page,t(a,e),self.accounts['users']['customer'][k])
                        page.get_by_role('textbox',name=t('كلمة المرور','Password'),exact=True).press('Tab')
                        with page.expect_response(lambda r:'/auth/v1/token?' in r.url) as auth:click(button('تسجيل الدخول','Sign in'))
                        assert auth.value.status==200
                        # Login already opens the first normal form.
                        modes=['reward'] if lang=='ar' else ['normal','reward']
                        for mode in modes:
                            booking_form(mode,initial=mode==modes[0])
                            if mode=='normal':
                                with page.expect_response(lambda r:'/rpc/place_customer_service_booking' in r.url) as placed:click(button('إرسال طلب الحجز','Send booking request'))
                                payload=json.loads(placed.value.request.post_data)
                                assert payload['p_service']==self.state['service'] and payload['p_vehicle']==self.state['vehicle'] and float(payload['p_expected_price'])==137.45
                                assert set(payload)=={'p_request','p_service','p_branch','p_vehicle','p_date','p_time','p_expected_price','p_notes'}
                            else:
                                with page.expect_response(lambda r:'/rpc/get_service_reward_options' in r.url) as options:click(button('التحقق من مكافأة زيارات · اختياري','Check visit reward · optional'))
                                actual=options.value.json();programs=actual['programs']; assert actual['redemption_enabled']
                                program=next(x for x in programs if x['rules_version_id']==self.state['rules'])
                                assert program['eligible']
                                loc=page.get_by_role('button',name=re.compile(t('اختر برنامجاً فعلياً صراحةً','Explicitly select an actual program'))).or_(page.get_by_role('combobox',name=re.compile(t('اختر برنامجاً فعلياً صراحةً','Explicitly select an actual program')))).last
                                click(loc)
                                snap=program['terms_snapshot']
                                display=str(snap.get('offer_name') or snap.get('offer',{}).get('name') or t('برنامج زيارات','Visit program'))+' · '+str(program['available_visits'])+' / '+str(program['threshold_visits'])
                                actualoption=page.get_by_role('menuitem',name=display,exact=True).or_(page.get_by_role('option',name=display,exact=True))
                                actualoption.wait_for(state='visible',timeout=15000)
                                assert actualoption.count()==1;actualoption.click();page.wait_for_timeout(250)
                                assert display in (loc.get_attribute('aria-label') or loc.inner_text())
                                with page.expect_response(lambda r:'/rpc/quote_service_reward' in r.url) as quoted:click(button('تحميل عرض المكافأة الفعلي','Load actual reward quote'))
                                q=quoted.value.json();assert q['eligible'] and q['amount_due']==0 and float(q['gross_amount'])==137.45
                                assert len(q['terms_snapshot']['rules'])==4
                                confirm=button('تأكيد حجز المكافأة المعروض','Confirm this quoted reward booking')
                                Acceptance.near(page,confirm);expect(confirm).to_be_disabled();shot('quote-explicit-consent-required')
                                checkbox=page.get_by_role('checkbox',name=re.compile(t('أوافق صراحةً','I explicitly accept')))
                                click(checkbox)
                                if q['adoption_required']:click(page.get_by_role('checkbox',name=re.compile(t('أتبنى الزيارات','I explicitly adopt'))))
                                expect(confirm).to_be_enabled()
                                with page.expect_response(lambda r:'/rpc/place_customer_reward_booking' in r.url) as placed:click(confirm)
                                payload=json.loads(placed.value.request.post_data)
                                assert payload['p_quote']==q['quote_id'] and payload['p_fingerprint']==q['fingerprint'] and payload['p_accept_terms']
                            assert placed.value.status==200,(placed.value.status,placed.value.text())
                            receipt=placed.value.json();assert float(receipt.get('quoted_price',receipt.get('gross_amount',-1)))==137.45;self.state['receipts'].append(receipt);self.save_state()
                            if mode=='reward':assert receipt['payment_status']=='covered_by_reward' and receipt['amount_due']==0
                            ack=button('راجعت الحجز والفاتورة · متابعة','I reviewed the booking and invoice · Continue')
                            Acceptance.near(page,ack);shot(mode+'-receipt')
                            with page.expect_response(lambda r:'/rpc/acknowledge_service_booking_attempt' in r.url) as acknowledged:click(ack)
                            assert acknowledged.value.json()['state']=='acknowledged'
                            self.proof['journeys'].append({'language':lang,'width':width,'mode':mode,'booking_id':receipt['booking_id'],'invoice_id':receipt['invoice_id'],'receipt_acknowledged':True,'request_keys':sorted(payload)})
                            self.proof_file.write_text(json.dumps(self.proof,indent=2,ensure_ascii=False)+'\n')
                            if mode=='reward':self.invoice_pdf(page,receipt,lang,width,click,button,shot)
                        # Wallet is a true app read, separate counts, never a client sum.
                        fixed_click(page.get_by_role('button',name=re.compile('^'+t('الرئيسية','Home')+r'(?:\s|$)')).last)
                        with page.expect_response(lambda r:'/rpc/get_my_reward_wallet' in r.url) as wallet:click(button('عروضي ونقاطي','Offers & loyalty').last)
                        w=wallet.value.json();assert w['global_spendable_balance'] is None and w['pools_overlap']
                        program=next(x for x in w['programs'] if x['rules_version_id']==self.state['rules'])
                        assert program['unused_valid_visits']==0
                        Acceptance.near(page,button('تحديث رصيد البرامج','Refresh program balances'));shot('wallet-after-debit')
                    except Exception:
                        shot('diagnostic');(self.out/f'semantics-{lang}.txt').write_text(page.locator('body').inner_text());raise
                    finally:page.close()
            finally:browser.close()
        assert not self.proof['render_errors'],self.proof['render_errors']
        assert len(self.proof['journeys'])==2
        self.proof['aggregate_journeys']=[self.proof['previous_ar_normal_checkpoint']['journey'],self.proof['previous_ar_reward_checkpoint']['journey']]+self.proof['journeys']

    def invoice_pdf(self,page,receipt,lang,width,click,button,shot):
        page.get_by_role('button',name=re.compile('^'+('حجوزاتي' if lang=='ar' else 'Bookings')+r'(?:\s|$)')).last.click()
        search=page.get_by_role('textbox').first;search.wait_for();search.click();page.wait_for_timeout(100);search.press('ControlOrMeta+A');search.press_sequentially(receipt['booking_number'],delay=20);page.wait_for_timeout(250)
        origin=self.sql("select coalesce(document_origin,'') from public.business_invoices where invoice_id='"+receipt['invoice_id']+"';")
        parsed_origin=urllib.parse.urlsplit(origin)
        assert not origin or (parsed_origin.scheme in ('http','https') and parsed_origin.hostname and not parsed_origin.username and not parsed_origin.password), 'Preserve a syntactically safe actual origin; never follow QR'
        if not origin:
            assert any(r['invoice_id']==receipt['invoice_id'] for r in self.state['receipts'])
            iid=receipt['invoice_id'];bid=receipt['booking_id'];cid=self.accounts['users']['customer']['id']
            self.sql("begin;do $$begin assert exists(select 1 from public.business_invoices i join public.business_orders o using(order_id) join public.bookings b on b.id=o.booking_id join public.business_catalog_items s on s.item_id=b.catalog_item_id where i.invoice_id='"+iid+"' and b.id='"+bid+"' and b.customer_id='"+cid+"' and s.item_id='"+self.state['service']+"' and s.name like '%"+self.state['tag']+"%' and coalesce(i.document_origin,'')=''),'Only exact tagged QA invoice with empty origin';end $$;update public.business_invoices set document_origin='http://127.0.0.1:8080' where invoice_id='"+iid+"' and coalesce(document_origin,'')='';commit;")
            self.proof['qa_invoice_only_origin_preparation']=True
        click(button('التفاصيل والفاتورة','Details & invoice').first)
        with page.expect_response(lambda r:'/rpc/resolve_invoice_document' in r.url) as resolved:click(button('عرض الفاتورة','View invoice'))
        doc=resolved.value.json();assert doc['invoice_id']==receipt['invoice_id'] and doc['payment_status']=='covered_by_reward'
        assert float(doc['snapshot']['total'])==0 and float(doc['snapshot']['discount'])==137.45
        actual_origin=urllib.parse.urlsplit(doc['portal_origin'])
        assert actual_origin.scheme in ('http','https') and actual_origin.hostname and not actual_origin.username and not actual_origin.password
        self.proof['actual_invoice_origin_preserved']=doc['portal_origin']
        shot('covered-invoice')
        pdf_control=page.get_by_role('button',name=re.compile('Download PDF with QR'))
        with page.expect_download(timeout=30000) as downloaded:click(pdf_control)
        file=self.out/f'reward-invoice-{self.state["tag"]}-{lang}-{width}.pdf';downloaded.value.save_as(str(file))
        from pypdf import PdfReader
        import pypdfium2 as pdfium
        assert file.read_bytes().startswith(b'%PDF-')
        text=''.join(p.extract_text() for p in PdfReader(file).pages);assert '137.45' in text
        import subprocess
        pdf=pdfium.PdfDocument(str(file));p=pdf[0];bitmap=p.render(scale=3);image=file.with_name(file.stem+'-pdf-render.png');bitmap.to_pil().save(image);bitmap.close();p.close();pdf.close()
        result=subprocess.run([str(self.r/'read_qr'),str(image)],capture_output=True,text=True,check=True)
        values=[v for line in result.stdout.splitlines() for v in json.loads(line).get('qr_values',[])]
        assert doc.get('portal_origin'), 'Actual local document origin required for QR; no global config rewrite'
        assert doc['portal_origin'].rstrip('/')+'/?invoice='+doc['document_token'] in values
        self.proof['journeys'][-1]['pdf_qr_verified']=True
        self.proof_file.write_text(json.dumps(self.proof,indent=2,ensure_ascii=False)+'\n')
        # Route back using UI controls, never invoke a private Flutter action.
        page.keyboard.press('Escape');page.wait_for_timeout(200)
        backs=page.get_by_role('button',name=re.compile('Back|رجوع'))
        if backs.count():backs.first.click();page.wait_for_timeout(200)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime',type=Path,required=True);p.add_argument('--proof',type=Path,required=True)
    p.add_argument('--screenshots',type=Path,required=True);p.add_argument('--app-url',default='http://127.0.0.1:8080')
    p.add_argument('--cashier-role',choices=['manager'])
    p.add_argument('--prior-cleanup-state',type=Path,action='append');p.add_argument('--prior-cleanup-proof',type=Path,action='append')
    p.add_argument('--execute',action='store_true');p.add_argument('--restore-only',action='store_true')
    args=p.parse_args()
    if not args.execute:print(__doc__);return
    assert args.cashier_role and bool(args.prior_cleanup_state)==bool(args.prior_cleanup_proof), 'Explicit existing QA cashier and matching prior state/proof required'
    h=Harness(args);before=None;counter=None;guard=None
    try:
        h.sign_in()
        if args.restore_only:h.state=json.loads(h.state_file.read_text());h.restore();return
        assert h.sql("select private.loyalty_visit_scheduler_ready() and coalesce(private.loyalty_visit_cron_last_success()>=clock_timestamp()-interval '5 minutes',false);")=='t', 'Actual recent cron run required'
        guard=PsqlSession(h.command,h.env,'qa_reward_browser_cron_guard')
        guard.run("select pg_advisory_lock(hashtextextended('canonical-loyalty-cron',0));")
        assert h.sql('select count(*) from private.loyalty_visit_outbox where processed_at is null;')=='0', 'Do not process prior pending work'
        before=h.snapshot();counter=h.counters();h.prepare();h.browser();h.proof['browser_checks_passed']=True
    except Exception as e:h.proof['error']=str(e);raise
    finally:
        if not args.restore_only:
            try:h.restore()
            except Exception as e:h.proof['cleanup_error']=str(e)
        if before is not None:
            after=h.snapshot();missing={t:sum((rows-after[t]).values()) for t,rows in before.items() if rows-after[t]}
            h.proof['preexisting_rows_unchanged']=not missing;h.proof['changed_preexisting_tables']=missing
            now=h.counters();expected=len((h.state or {}).get('sources',[]))+len((h.state or {}).get('receipts',[]))
            h.proof['expected_document_counter_delta']=expected
            h.proof['document_counter_deltas']={k:now[k]-counter.get(k,0) for k in now}
            h.proof['document_counters_exact']=all(now[k]-counter.get(k,0)==expected for k in ['BKG','INV']) and all(now[k]==counter.get(k,0) for k in now if k not in ['BKG','INV'])
        if guard:guard.rollback_close()
        h.proof['all_passed']=all(h.proof.get(k) for k in ['browser_checks_passed','preexisting_rows_unchanged','document_counters_exact','qa_cleanup_complete'])
        args.proof.parent.mkdir(parents=True,exist_ok=True);args.proof.write_text(json.dumps(h.proof,indent=2,ensure_ascii=False)+'\n');args.proof.chmod(0o600)
    assert h.proof['all_passed'], 'Inspect local proof'
    print('PASS Flutter normal/reward AR390 EN1440, acknowledged receipts, wallet debit and actual invoice PDF QR; QA neutralized')


if __name__=='__main__':main()
