"""Actual local Flutter owner rules get/save acceptance; explicit execution required.

Prepared spec:
* Validate existing local runtime/accounts and completed owner-rules web build.
* Fingerprint existing core business/loyalty rows (hashes only).
* Create ONE tagged NONDEFAULT QA branch and ONE actual QA reward service using
  local psql; use real owner Auth/JWT RPCs to create ONE published QA visit offer
  and ONE DISABLED eligibility policy. Freeze a real future offer end in policy.
* Actual browser owner login: AR390 then EN1440. Select the QA branch and all four
  terms explicitly. Save via Flutter RPC, inspect actual requests/responses and
  capture before/after screenshots. Save two immutable rule versions; no booking,
  payment, visit activation, quote or redemption request is allowed.
* Finally append a disabled QA policy version, hide QA offer/service/branch, retain
  all QA audit/history rows (NO deletes), and compare every pre-existing core row.

Default invocation prints this plan without opening a browser or database.
--execute requires root's explicit approval AFTER pending migrations/web build.
"""
import argparse
from collections import Counter
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from service_booking_acceptance import Acceptance

CORE = [
    ('public', name) for name in ['business_branches','business_catalog_items','business_offers',
      'bookings','business_orders','business_order_items','business_invoices',
      'business_payment_events','business_cashier_shifts','business_loyalty_transactions']
] + [('private', name) for name in ['loyalty_policy_versions','managed_visit_reward_offers',
    'loyalty_redemption_rule_versions','loyalty_redemption_rule_requests',
    'loyalty_visit_activations','booking_loyalty_policy_snapshots',
    'loyalty_earning_snapshot_bindings','canonical_loyalty_visits']]


class Harness:
    def __init__(self, args):
        self.r = args.runtime.resolve()
        self.proof_file = args.proof
        self.out = args.screenshots.resolve()
        self.state_file = self.r/'owner-redemption-rules-browser-state.json'
        self.settings = json.loads((self.r/'local-status.json').read_text())
        self.accounts = json.loads((self.r/'test-accounts-final.json').read_text())
        self.base = self.accounts['url'].rstrip('/')
        self.app = args.app_url.rstrip('/')
        for url in [self.base, self.app]:
            parsed = urllib.parse.urlsplit(url)
            assert parsed.scheme == 'http' and parsed.hostname == '127.0.0.1' and not parsed.username, 'Local URLs only'
        socket = self.r/'instances/sabiha-local/sock/docker.sock'
        assert socket.is_socket(), 'Existing isolated Docker instance required'
        self.env = {**os.environ, 'DOCKER_HOST':'unix://'+str(socket), 'DOCKER_CONFIG':str(self.r/'docker-config')}
        self.command = [str(self.r/'docker-cli/docker/docker'),'exec','-i','supabase_db_supabase-local',
            'psql','-X','-q','-At','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
        self.token = None
        self.state = None
        self.proof = {'local_only':True,'production_touched':False,'gateway_called':False,
            'redemption_executed':False,'screens':[],'save_requests':[],'render_errors':[]}

    def sql(self, source):
        result = subprocess.run(self.command,input=source,env=self.env,text=True,capture_output=True,timeout=45)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def call(self, path, data):
        request = urllib.request.Request(self.base+path,data=json.dumps(data).encode(),method='POST',
            headers={'apikey':self.settings['ANON_KEY'],'Authorization':'Bearer '+(self.token or self.settings['ANON_KEY']),
                'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(path+' failed HTTP '+str(error.code)) from error

    def rpc(self, name, data):
        return self.call('/rest/v1/rpc/'+name,data)

    def sign_in(self):
        owner = self.accounts['users']['owner']
        self.token = self.call('/auth/v1/token?grant_type=password',
            {'email':owner['email'],'password':owner['password']})['access_token']

    def snapshot(self):
        result = {}
        for schema, table in CORE:
            # No row data/PII is exported. UUIDs and all record fields stay inside MD5.
            hashes = self.sql('select md5(to_jsonb(t)::text) from '+schema+'.'+table+' t order by 1;')
            result[schema+'.'+table] = Counter(hashes.splitlines())
        return result

    def save_state(self):
        self.state_file.write_text(json.dumps(self.state,indent=2)+'\n')
        self.state_file.chmod(0o600)

    def prepare(self):
        if self.state_file.exists():
            prior = json.loads(self.state_file.read_text())
            assert prior.get('cleanup_complete'), 'Restore prior QA state with --restore-only first'
            (self.r/('owner-rules-state-'+prior['tag']+'.json')).write_text(json.dumps(prior,indent=2)+'\n')
        tag = uuid.uuid4().hex[:10]
        self.state = {'tag':tag,'branch':str(uuid.uuid4()),'service':str(uuid.uuid4()),
            'branch_ar':'اختبار شروط معزول '+tag,'branch_en':'Isolated QA rules '+tag,
            'offer':None,'policy':None,'cleanup_complete':False}
        self.save_state()  # Record cleanup identities before the first write.
        branch, service = self.state['branch'], self.state['service']
        self.sql("begin;insert into public.business_branches(branch_id,name_ar,name_en,is_default,is_active) values('"+branch+"','"+
            self.state['branch_ar']+"','"+self.state['branch_en']+"',false,true);"
            "insert into public.business_catalog_items(item_id,branch_id,item_type,name,name_en,price,is_active,is_public) values('"+service+"','"+
            branch+"','service','خدمة مكافأة اختبار "+tag+"','QA reward service "+tag+"',17.25,true,true);commit;")
        self.state['offer'] = self.rpc('save_visit_reward_offer',{
            'p_request':str(uuid.uuid4()),'p_branch':branch,'p_name':'عرض شروط اختبار '+tag,
            'p_name_en':'QA rules offer '+tag,'p_visits':7,'p_publish':True,
            'p_reward_service':service,'p_offer':None})['offer_id']
        self.save_state()
        end = (dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=14)).replace(microsecond=0).isoformat()
        self.sql("update public.business_offers set ends_at='"+end+"' where offer_id='"+self.state['offer']+"';")
        policy = self.rpc('save_loyalty_policy',{'p_request':str(uuid.uuid4()),'p_branch':branch,
            'p_offer':self.state['offer'],'p_services':[service],'p_enabled':False})
        self.state['policy'] = policy['version_id']
        self.save_state()
        context = self.rpc('get_loyalty_redemption_rules',{'p_policy_version':self.state['policy']})
        assert context['configuration_valid'] and not context['rules_saved']
        assert context['redemption_enabled'] is False and context['reward_service']['id']==service
        assert context['offer']['ends_at'] is not None and 'policy_not_enabled' in context['blockers']
        self.proof['fixture'] = {k:v for k,v in self.state.items() if k in ['tag','branch','service','offer','policy']}

    def restore(self):
        if self.state is None:
            return
        branch, service = self.state['branch'],self.state['service']
        if self.state.get('offer'):
            # Immutable future version, not an UPDATE to prior policy history.
            result = self.rpc('save_loyalty_policy',{'p_request':str(uuid.uuid4()),'p_branch':branch,
                'p_offer':self.state['offer'],'p_services':[service],'p_enabled':False})
            self.state['cleanup_policy'] = result['version_id']
            self.save_state()
        self.sql("begin;update public.business_offers set is_active=false,is_public=false where branch_id='"+branch+"';"
            "update public.business_catalog_items set is_active=false,is_public=false where item_id='"+service+"';"
            "update public.business_branches set is_active=false,is_default=false where branch_id='"+branch+"';commit;")
        result = json.loads(self.sql("select json_build_object('bookings',(select count(*) from public.bookings where branch_id='"+branch+
            "'),'orders',(select count(*) from public.business_orders where branch_id='"+branch+
            "'),'invoices',(select count(*) from public.business_invoices where branch_id='"+branch+
            "'),'payments',(select count(*) from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id='"+branch+
            "'),'activations',(select count(*) from private.loyalty_visit_activations a join private.loyalty_policy_versions v on v.version_id=a.policy_version_id where v.branch_id='"+branch+"'));") )
        assert all(value==0 for value in result.values()), result
        self.state['cleanup_complete']=True
        self.save_state()
        self.proof['cleanup']={'retained_hidden_fixture':True,'disabled_latest_policy':True,**result}

    def browser(self):
        from playwright.sync_api import sync_playwright, expect
        self.out.mkdir(parents=True,exist_ok=True)
        previous_rules = None
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
            try:
                for language,width in [('ar',390),('en',1440)]:
                    ar = language=='ar'
                    label = lambda a,e: a if ar else e
                    page = browser.new_page(viewport={'width':width,'height':1100})
                    page.set_default_timeout(20000)
                    page.on('pageerror',lambda error:self.proof['render_errors'].append(str(error)))
                    page.on('console',lambda msg:self.proof['render_errors'].append(msg.text) if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                    def click(locator):
                        Acceptance.near(page,locator).click()
                        page.wait_for_timeout(150)
                    def control(a,e):
                        pattern = re.compile(re.escape(label(a,e)))
                        return page.get_by_role('button',name=pattern).or_(page.get_by_role('combobox',name=pattern)).first
                    def choose(a,e,options,value,current=None):
                        # Real Flutter keyboard interaction; popup canvas items have no
                        # text semantics in this engine. Order/selection come from RPCs.
                        click(control(a,e))
                        initial = options.index(current) if current is not None else 0
                        target = options.index(value)
                        key = 'ArrowDown' if target > initial else 'ArrowUp'
                        for _ in range(abs(target-initial)):page.keyboard.press(key)
                        page.keyboard.press('Enter')
                        page.wait_for_timeout(200)
                    def screenshot(stage):
                        page.wait_for_timeout(250)
                        file=self.out/f'owner-rules-{language}-{width}-{stage}.png'
                        page.screenshot(path=str(file))
                        self.proof['screens'].append({'language':language,'width':width,'stage':stage,'file':str(file)})
                    try:
                        page.goto(self.app)
                        page.wait_for_selector('flutter-view',timeout=60000)
                        semantics=page.locator('flt-semantics-placeholder')
                        if semantics.count():semantics.evaluate('(element)=>element.click()')
                        page.get_by_role('button',name='احجز الآن',exact=True).first.wait_for(timeout=30000)
                        if not ar:click(page.get_by_role('button',name='EN',exact=True))
                        click(page.get_by_role('button',name=label('دخول الموظفين','Staff sign in'),exact=True))
                        for arabic,english,key in [('البريد الإلكتروني','Email address','email'),('كلمة المرور','Password','password')]:
                            Acceptance.type_into(page,label(arabic,english),self.accounts['users']['owner'][key])
                        with page.expect_response(lambda r:'/rpc/get_admin_console' in r.url,timeout=30000) as signed:
                            click(page.get_by_role('button',name=label('تسجيل الدخول','Sign In'),exact=True))
                        assert signed.value.status==200
                        click(page.get_by_role('button',name=label('إدارة العملاء','CRM'),exact=True))
                        with page.expect_response(lambda r:'/rpc/get_loyalty_policy' in r.url,timeout=30000) as initial:
                            click(page.get_by_role('button',name=label('سياسة زيارات الولاء','Service-visit loyalty policy'),exact=True))
                        assert initial.value.status==200
                        policy_context=initial.value.json()
                        branch_ids=[item['id'] for item in policy_context['branches']]
                        with page.expect_response(lambda r:'/rpc/get_loyalty_redemption_rules' in r.url and
                            json.loads(r.request.post_data or '{}').get('p_policy_version')==self.state['policy'],timeout=30000) as read:
                            choose('الفرع','Branch',branch_ids,self.state['branch'],policy_context['branch_id'])
                        assert read.value.status==200
                        context=read.value.json()
                        assert context['redemption_enabled'] is False and context['policy_version_id']==self.state['policy']
                        assert context['reward_service']['id']==self.state['service']
                        assert (context['current'] or {}).get('rules_version_id')==previous_rules
                        save=page.get_by_role('button',name=label('حفظ إصدار شروط مستقبلي','Save future terms version'),exact=True)
                        Acceptance.near(page,save)  # Disabled interactive control is a reliable scroll anchor.
                        expect(save).to_be_disabled()
                        screenshot('readiness')
                        if ar:
                            rules={'pooling':'policy_version','expiry':'no_expiry','cancellation':'restore_visits','refunded_contribution':'offset_future_visits'}
                            selected=[('تجميع الزيارات','Visit pooling','نفس إصدار السياسة فقط'),('انتهاء صلاحية الزيارات','Visit expiry','دون انتهاء صلاحية'),('إلغاء حجز المكافأة','Reward booking cancellation','إعادة الزيارات إلى الرصيد'),('استرداد زيارة ساهمت في الرصيد','Refunded contributing visit','احترام المكافأة وخصم الأثر من الزيارات المستقبلية')]
                        else:
                            rules={'pooling':'offer_branch','expiry':'snapshot_offer_end','cancellation':'forfeit_visits','refunded_contribution':'freeze_for_owner_review'}
                            selected=[('تجميع الزيارات','Visit pooling','Same offer and branch across policy versions'),('انتهاء صلاحية الزيارات','Visit expiry','Frozen policy offer end'),('إلغاء حجز المكافأة','Reward booking cancellation','Do not restore visits'),('استرداد زيارة ساهمت في الرصيد','Refunded contributing visit','Honor reward; freeze future redemption for owner review')]
                        for key,(a,e,_display) in zip(['pooling','expiry','cancellation','refunded_contribution'],selected):
                            choose(a,e,context['supported_rules'][key],rules[key])
                        Acceptance.near(page,save)
                        expect(save).to_be_enabled()
                        screenshot('explicit-choices')
                        with page.expect_response(lambda r:'/rpc/save_loyalty_redemption_rules' in r.url,timeout=30000) as saved:
                            click(save)
                        assert saved.value.status==200
                        sent=json.loads(saved.value.request.post_data)
                        actual=saved.value.json()
                        assert sent['p_policy_version']==self.state['policy'] and sent['p_expected_rules_version']==previous_rules
                        assert sent['p_rules']==rules and set(sent)=={'p_request','p_policy_version','p_expected_rules_version','p_rules'}
                        assert actual['current']['rules']==rules and actual['rules_saved'] and actual['terms_valid']
                        assert actual['redemption_enabled'] is False and actual['readiness']=='rules_only'
                        if previous_rules is not None:
                            assert any(h['rules_version_id']==previous_rules and h['rules']==self.proof['save_requests'][-1]['request']['p_rules'] for h in actual['history'])
                        previous_rules=actual['current']['rules_version_id']
                        self.proof['save_requests'].append({'language':language,'http_status':200,'request':sent,
                            'rules_version_id':previous_rules,'redemption_enabled':False,'readiness':actual['readiness']})
                        Acceptance.near(page,save)
                        expect(save).to_be_disabled()
                        screenshot('saved-disabled')
                    except Exception:
                        screenshot('diagnostic')
                        (self.out/f'semantics-{language}.txt').write_text(page.locator('body').inner_text())
                        raise
                    finally:
                        page.close()
                assert not self.proof['render_errors'],self.proof['render_errors']
                assert len(self.proof['save_requests'])==2
                assert len({s['rules_version_id'] for s in self.proof['save_requests']})==2
            finally:
                browser.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--screenshots',type=Path,required=True)
    parser.add_argument('--app-url',default='http://127.0.0.1:8080')
    parser.add_argument('--execute',action='store_true',help='Only after root approves this exact local QA mutation plan')
    parser.add_argument('--restore-only',action='store_true')
    args=parser.parse_args()
    if not args.execute:
        print(__doc__)
        return
    harness=Harness(args)
    baseline=None
    try:
        if args.restore_only:
            harness.state=json.loads(harness.state_file.read_text())
            harness.sign_in();harness.restore();harness.proof['restore_only']=True
        else:
            build=harness.r/'resume-owner-rules-web-build.log'
            assert build.is_file() and 'Built build/web' in build.read_text(), 'Wait for the requested owner-rules web build'
            baseline=harness.snapshot()
            harness.sign_in();harness.prepare();harness.browser()
            harness.proof['browser_checks_passed']=True
    except Exception as error:
        harness.proof['error']=str(error)
        raise
    finally:
        try:
            if not args.restore_only:harness.restore()
        except Exception as error:
            harness.proof['cleanup_error']=str(error)
        if baseline is not None:
            after=harness.snapshot()
            missing={table:sum((rows-after[table]).values()) for table,rows in baseline.items() if rows-after[table]}
            harness.proof['preexisting_core_rows_unchanged']=not missing
            harness.proof['changed_preexisting_tables']=missing
        harness.proof['all_passed']=bool(harness.proof.get('browser_checks_passed') and harness.proof.get('preexisting_core_rows_unchanged') and not harness.proof.get('cleanup_error'))
        args.proof.parent.mkdir(parents=True,exist_ok=True)
        args.proof.write_text(json.dumps(harness.proof,indent=2,ensure_ascii=False)+'\n')
    assert harness.proof.get('all_passed') or args.restore_only, harness.proof
    print('PASS actual owner rules AR390/EN1440, explicit four choices, immutable saves, disabled redemption and cleanup')


if __name__=='__main__':
    main()
