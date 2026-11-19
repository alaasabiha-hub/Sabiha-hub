import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('./qa-password-recovery-site/recovery.js', import.meta.url),
  'utf8',
);

class Element {
  value = '';
  textContent = '';
  hidden = false;
  disabled = false;
  listeners = new Map();
  addEventListener(name, callback) { this.listeners.set(name, callback); }
}

function createPage(
  hash = '',
  origin = 'https://sabiha-hub-qa-password-reset.pages.dev',
  fetchResult = { ok: true, status: 200 },
) {
  const ids = [
    'language', 'title', 'intro', 'email-label', 'request-button', 'password-intro',
    'password-label', 'confirm-label', 'save-button', 'footer', 'message', 'request-panel',
    'password-panel', 'request-form', 'password-form', 'email', 'password', 'confirm',
  ];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element()]));
  elements['password-panel'].hidden = true;
  elements.message.hidden = true;
  const location = { origin, pathname: '/', hash, search: '' };
  let replaceCalls = 0;
  const calls = [];
  const context = {
    window: {
      SABIHA_RECOVERY_CONFIG: {
        supabaseUrl: 'https://aspijgoujajgyfgvdcav.supabase.co',
        publishableKey: 'public-test-key',
      },
      setTimeout: () => 1,
    },
    document: { title: '', documentElement: { lang: '', dir: '' }, getElementById: (id) => elements[id] },
    location,
    history: { replaceState: (_state, _title, next) => { replaceCalls++; location.pathname = next; location.hash = ''; location.search = ''; } },
    URL, URLSearchParams,
    fetch: async (url, options) => {
      calls.push({ url: String(url), options });
      return fetchResult;
    },
  };
  vm.runInNewContext(source, context, { timeout: 1000 });
  return { elements, location, calls, get replaceCalls() { return replaceCalls; } };
}

const resetPage = createPage('#access_token=synthetic-only&refresh_token=synthetic-refresh&type=recovery');
assert.equal(resetPage.location.hash, '', 'recovery secrets must be removed from the URL immediately');
assert.equal(resetPage.elements['password-panel'].hidden, false, 'a valid recovery fragment opens password setup');
assert.equal(resetPage.elements['request-panel'].hidden, true, 'recovery does not fall back to normal sign-in');
assert.equal(resetPage.elements['password-intro'].textContent, 'اختر كلمة مرور جديدة لحسابك.');
resetPage.elements.password.value = 'synthetic-password-only';
resetPage.elements.confirm.value = 'synthetic-password-only';
await resetPage.elements['password-form'].listeners.get('submit')({ preventDefault() {} });
assert.equal(resetPage.calls.length, 1, 'password update uses one Auth request');
assert.equal(resetPage.calls[0].url, 'https://aspijgoujajgyfgvdcav.supabase.co/auth/v1/user');
assert.equal(resetPage.calls[0].options.method, 'PUT');
assert.equal(resetPage.calls[0].options.headers.Authorization, 'Bearer synthetic-only');
assert.equal(resetPage.calls[0].options.referrerPolicy, 'no-referrer');
assert.equal(resetPage.elements.password.value, '', 'password is cleared after completion');
assert.equal(resetPage.elements.confirm.value, '', 'confirmation is cleared after completion');
assert.equal(resetPage.elements['password-panel'].hidden, true, 'reset form closes after success');
assert.match(resetPage.elements.message.textContent, /تم تغيير كلمة المرور/);

const requestPage = createPage();
requestPage.elements.email.value = 'qa-owner@example.invalid';
await requestPage.elements['request-form'].listeners.get('submit')({ preventDefault() {} });
assert.equal(requestPage.calls.length, 1, 'request sends one Supabase recovery request');
const request = requestPage.calls[0];
const requestUrl = new URL(request.url);
assert.equal(requestUrl.origin, 'https://aspijgoujajgyfgvdcav.supabase.co');
assert.equal(requestUrl.pathname, '/auth/v1/recover');
assert.equal(requestUrl.searchParams.get('redirect_to'), 'https://sabiha-hub-qa-password-reset.pages.dev/');
assert.equal(requestUrl.searchParams.has('code_challenge'), false, 'cross-device recovery does not depend on local PKCE storage');
assert.equal(request.options.credentials, 'omit');
assert.equal(request.options.referrerPolicy, 'no-referrer');
assert.equal(requestPage.elements['request-panel'].hidden, true, 'request screen switches to generic confirmation');
assert.match(requestPage.elements.message.textContent, /إذا كان البريد مسجلًا/);

const wrongTypePage = createPage('#access_token=synthetic-only&type=signup');
assert.equal(wrongTypePage.location.hash, '', 'non-recovery tokens are scrubbed');
assert.equal(wrongTypePage.elements['password-panel'].hidden, true, 'non-recovery token does not open password form');
assert.match(wrongTypePage.elements.message.textContent, /رابط الاستعادة غير صالح/);

const wrongOriginPage = createPage('', 'https://attacker.pages.dev');
wrongOriginPage.elements.email.value = 'qa-owner@example.invalid';
await wrongOriginPage.elements['request-form'].listeners.get('submit')({ preventDefault() {} });
assert.equal(wrongOriginPage.calls.length, 0, 'unapproved origin cannot request a reset');
assert.match(wrongOriginPage.elements.message.textContent, /صفحة الاستعادة من رابط/);

const limitedPage = createPage('', undefined, {
  ok: false,
  status: 429,
  json: async () => ({ error_code: 'over_email_send_rate_limit' }),
});
limitedPage.elements.email.value = 'qa-owner@example.invalid';
await limitedPage.elements['request-form'].listeners.get('submit')({ preventDefault() {} });
assert.match(limitedPage.elements.message.textContent, /حد إرسال البريد/);
assert.equal(limitedPage.elements['request-button'].disabled, true, 'rate-limited resend stays disabled');

console.log('QA recovery page flow simulation: PASS (synthetic credentials only; no Auth request made)');
