"""PLAN by default: existing QA candidate, one new isolated recovery request.

No profile creation, contact edits, claims, linking, money or loyalty writes.
Root pins current Flutter build and reviews labels before executing.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import urllib.error
import urllib.request

from visit_recovery_requests_browser import RequestJourney, nonce
from offline_customer_registration_browser import Harness as Intake
from service_booking_acceptance import Acceptance


class InvestigationJourney(RequestJourney):
    def __init__(self, args):
        super().__init__(args)
        self.proof['proof_scope'] = 'case_scoped_owner_candidate_search_and_details_only'
        self.queries = {}
        self.detail_reads = {}
        self.candidate = None

    def preflight(self):
        super().preflight()
        # Reuse a real existing LOCAL QA reception profile. Never fabricate a
        # candidate or change the customer's registered phone to make it match.
        self.candidate = json.loads(self.h.sql("""
          select jsonb_build_object('profile_id',p.profile_id,'plate',c.plate_key)
          from private.offline_customer_profiles p
          join private.offline_customer_car_refs c on c.profile_id=p.profile_id
          where p.full_name like 'QA%'
            and exists(select 1 from private.offline_customer_enrollment_receipts r
                       where r.profile_id=p.profile_id)
            and not exists(select 1 from private.offline_customer_trusted_links l
                           where l.profile_id=p.profile_id and l.revoked_at is null)
            and (select count(distinct cc.profile_id)
                 from private.offline_customer_car_refs cc where cc.plate_key=c.plate_key)=1
          order by p.created_at desc,c.created_at desc limit 1;
        """))
        assert nonce(self.candidate['profile_id']) and self.candidate['plate']
        self.state['qa_candidate'] = self.candidate
        self.save()

    def allow_rpc(self, name, body, role):
        if name == 'get_my_visit_recovery_proposal':
            assert role == 'customer' and set(body)=={'p_case'} and nonce(body['p_case'])
            if body['p_case'] in self.state.get('old_case_ids',[])+[self.state['case_id']]:
                return True
            # Flutter's confirmed-submission callback may mount its child before
            # expect_response has processed the submit body. Settle only the
            # already-journaled exact producer; never allow an arbitrary UUID.
            rid=self.state.get('submission')
            assert nonce(rid)
            found=self.h.sql("select exists(select 1 from private.visit_recovery_submission_requests where request_id='"+rid+"' and actor_id='"+self.actor+"' and case_id='"+body['p_case']+"');")
            assert found=='t' and body['p_case'] not in self.state['old_case_ids']
            self.state['case_id']=body['p_case']
            self.proof['new_case_id']=body['p_case']
            self.save()
            return True
        if name == 'search_visit_recovery_candidates':
            assert role == 'owner' and set(body) == {'p_query','p_case','p_purpose','p_plate','p_limit'}
            assert body['p_case'] == self.state['case_id'] and nonce(body['p_query'])
            assert body['p_limit'] <= 25 and body['p_purpose'] == self.tag + ' investigation'
            assert body['p_plate'] in (None,self.candidate['plate'])
            prior = self.queries.get(body['p_query'])
            assert prior in (None,body)
            self.queries[body['p_query']] = body.copy()
            self.state['queries'] = self.queries
            self.save()
            return True
        if name == 'get_visit_recovery_candidate':
            assert role == 'owner' and set(body) == {'p_request','p_query','p_profile','p_purpose','p_plate'}
            assert nonce(body['p_request']) and body['p_query'] in self.queries
            assert body['p_profile'] == self.candidate['profile_id']
            assert body['p_plate'] == self.candidate['plate']
            assert body['p_purpose'] == self.tag + ' investigation'
            prior = self.detail_reads.get(body['p_request'])
            assert prior in (None,body)
            self.detail_reads[body['p_request']] = body.copy()
            self.state['detail_reads'] = self.detail_reads
            self.save()
            return True
        return super().allow_rpc(name,body,role)

    def execute(self):
        self.preflight()
        from playwright.sync_api import sync_playwright, expect
        pages = {}
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
                try:
                    for role in ('owner','customer'):
                        page = browser.new_page(viewport={'width':390 if self.ar else 1440,'height':1100})
                        page.set_default_timeout(30000)
                        self.page_roles[page] = role
                        page.route('**/*',lambda route,request,role=role:self.guard(route,role))
                        page.on('response',lambda response,role=role:self.observe(response,role))
                        page.on('pageerror',lambda _:self.proof['render_errors'].append('javascript_error'))
                        page.on('console',lambda msg:self.proof['render_errors'].append('render_error') if 'overflowed' in msg.text or 'EXCEPTION CAUGHT' in msg.text else None)
                        pages[role] = page
                    owner,customer = pages['owner'],pages['customer']
                    self.login(owner,'owner')
                    self.login(customer,'customer')
                    context = self.customer_panel(customer)
                    assert context['new_request_allowed'] and self.case_from(context)['status'] in ('rejected','revoked')
                    check = customer.get_by_role('checkbox',name=self.t('أوافق على طلب المراجعة بهذا النطاق','I agree to this review request scope'),exact=True)
                    Acceptance.near(customer,check)
                    expect(check).not_to_be_checked()
                    check.click()
                    with self.wait_rpc(customer,'submit_visit_recovery_request') as result:
                        self.click(customer,self.button(customer,self.t('إرسال طلب جديد للمراجعة','Send a new request for review')))
                    assert result.value.status == 200 and self.case_from(result.value.json())['status']=='awaiting_matching'
                    self.click(customer,self.button(customer,self.t('راجعت النتيجة','I reviewed the result')))
                    self.proof['necessary_new_case_setup_only'] = True
                    self.owner_list(owner)
                    # Labels are intentionally checked against the actual new
                    # source before execution; this harness never edits the UI.
                    self.run_investigation(owner)
                    assert not self.proof['blocked_requests'] and not self.proof['render_errors']
                    self.proof['all_passed'] = True
                except Exception as e:
                    self.proof['failure_type'] = type(e).__name__
                    for role,page in pages.items():
                        try:self.shot(page,role+'-investigation-failure-private')
                        except Exception:pass
                    raise
                finally:
                    browser.close()
        finally:
            try:self.cleanup()
            except Exception as e:self.proof['cleanup_error_type']=type(e).__name__
            if self.before is not None:
                after=Intake.snapshot(self.h)
                self.proof['preexisting_public_private_rows_unchanged']=all(not(rows-after.get(table,Counter()))for table,rows in self.before.items())
                self.proof['document_counters_unchanged']=Intake.counters(self.h)==self.counters
                self.proof['auth_users_unchanged_except_signin_metadata']=self.auth_hash()==self.auth_before
            self.save()
        assert self.proof['all_passed'] and self.state['cleanup_complete']
        assert self.proof['preexisting_public_private_rows_unchanged'] and self.proof['document_counters_unchanged'] and self.proof['auth_users_unchanged_except_signin_metadata']

    def run_investigation(self,page):
        self.stage('owner_actual_case_investigation')
        self.click(page,self.button(page,self.t('التحقق من سجلات الاستقبال','Investigate reception records')).first)
        Acceptance.type_into(page,self.t('الغرض من التحقق (١٠ أحرف على الأقل)','Investigation purpose (at least 10 characters)'),self.tag+' investigation')
        Acceptance.type_into(page,self.t('لوحة السيارة الدقيقة (اختياري)','Exact vehicle plate (optional)'),self.candidate['plate'])
        # Blur the actual input and let the form enable its real control.
        page.get_by_role('textbox',name=self.t('لوحة السيارة الدقيقة (اختياري)','Exact vehicle plate (optional)'),exact=True).press('Tab')
        with self.wait_rpc(page,'search_visit_recovery_candidates') as response:
            self.click(page,self.button(page,self.t('التحقق من السجلات المحتملة','Investigate possible records')))
        assert response.value.status==200
        data=response.value.json()
        assert data['candidate_count']==1 and data['candidates'][0]['profile_reference']==self.candidate['profile_id']
        assert data['candidate_is_identity_proof'] is False and data['linking_enabled'] is False
        self.proof['checks']['owner_actual_case_bound_candidate_search']=True
        with self.wait_rpc(page,'get_visit_recovery_candidate') as response:
            self.click(page,self.button(page,self.t('عرض تفاصيل هذا السجل للمراجعة','Review details of this record')).first)
        assert response.value.status==200
        data=response.value.json()
        assert data['candidate']['profile_reference']==self.candidate['profile_id']
        assert data['candidate']['candidate_is_identity_proof'] is False and data['candidate']['linking_enabled'] is False
        self.proof['checks']['owner_explicit_actual_candidate_details']=True
        # Private screenshots mask actual profile/contact/plate labels as well as
        # every input; no raw RPC bodies or credentials are written into proof.
        row=data['candidate']
        self.owner_masks += [str(row['name'])]
        self.owner_masks += [str(x['phone'])for x in row.get('contacts',[])if x.get('phone')]
        self.owner_masks += [str(x['plate_number'])for x in row.get('cars',[])if x.get('plate_number')]
        self.shot(page,'owner-case-bound-investigation-details')
        # This is a new endpoint authorization check, not a repeat of the old
        # canonical claim suite. A denied customer request must append no audit.
        denied=False
        try:
            self.rpc_as('customer','search_visit_recovery_candidates',{
                'p_query':str(__import__('uuid').uuid4()),'p_case':self.state['case_id'],
                'p_purpose':self.tag+' investigation','p_plate':self.candidate['plate'],'p_limit':10})
        except RuntimeError as error:
            denied=isinstance(error.__cause__,urllib.error.HTTPError) and error.__cause__.code==403
        assert denied
        self.proof['checks']['actual_customer_endpoint_denied']=True


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for key in ('runtime','proof','screenshots','build-proof'):p.add_argument('--'+key,type=Path,required=True)
    p.add_argument('--language',choices=('ar','en'),required=True)
    p.add_argument('--app-url',default='http://127.0.0.1:8080')
    p.add_argument('--execute',action='store_true')
    args=p.parse_args()
    if not args.execute:
        print(json.dumps({'plan_only':True,'scope':'actual owner case candidate search/detail; existing QA profile only','no_claim_link_or_financial_writes':True,'cleanup':'reject exact new unmapped case; audit retained','requires':'current pinned build and reviewed actual labels'}))
        return
    InvestigationJourney(args).execute()


if __name__=='__main__':main()
