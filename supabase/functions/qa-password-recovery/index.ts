import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const projectUrl = "https://aspijgoujajgyfgvdcav.supabase.co";

const page = String.raw`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="referrer" content="no-referrer">
  <meta name="color-scheme" content="light">
  <title>Sabiha Hub | استعادة كلمة المرور</title>
  <style>
    :root{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;color:#071a36;background:#f4f6f9}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px}
    main{width:min(100%,460px);background:white;border:1px solid #d7dce4;border-radius:22px;padding:30px;box-shadow:0 18px 52px #071a3617}
    .mark{width:54px;height:54px;border-radius:16px;background:#071a36;color:#fff;display:grid;place-items:center;font-weight:800;font-size:20px;letter-spacing:-1px;margin-bottom:18px}
    h1{font-size:24px;margin:0 0 8px;color:#071a36}p{line-height:1.7;color:#536174;margin:0 0 20px}
    label{display:block;font-size:14px;font-weight:700;margin:16px 0 7px}input{width:100%;height:48px;border:1px solid #c5cbd5;border-radius:12px;padding:0 13px;font:inherit;color:#071a36;background:white}
    input:focus{outline:3px solid #174b8330;border-color:#174b83}button{width:100%;min-height:48px;border:0;border-radius:12px;background:#174b83;color:white;font:inherit;font-weight:750;margin-top:20px;cursor:pointer}
    button:disabled{opacity:.6;cursor:wait}.quiet{background:white;color:#174b83;border:1px solid #c5cbd5;margin-top:10px}
    [hidden]{display:none!important}.message{margin-top:16px;padding:12px;border-radius:10px;background:#eef3f8;color:#071a36;overflow-wrap:anywhere}
    .lang{display:flex;justify-content:flex-end;margin-bottom:18px}.lang button{width:auto;min-height:36px;padding:4px 12px;margin:0;background:white;border:1px solid #c5cbd5;color:#174b83}
    footer{font-size:12px;color:#687589;margin-top:20px;text-align:center}
  </style>
</head>
<body>
<main>
  <div class="lang"><button id="language" type="button">English</button></div>
  <div class="mark" aria-label="Sabiha Hub">SH</div>
  <h1 id="title">استعادة كلمة المرور</h1>
  <p id="intro">أدخل بريد حسابك. سنرسل رابطًا آمنًا صالحًا لمرة واحدة لإعادة تعيين كلمة المرور.</p>
  <section id="request-panel">
    <form id="request-form" novalidate>
      <label id="email-label" for="email">البريد الإلكتروني</label>
      <input id="email" type="email" inputmode="email" autocomplete="email" autocapitalize="none" required>
      <button id="request-button" type="submit">إرسال رابط الاستعادة</button>
    </form>
  </section>
  <section id="password-panel" hidden>
    <p id="password-intro">اختر كلمة مرور جديدة لحسابك.</p>
    <form id="password-form" novalidate>
      <label id="password-label" for="password">كلمة المرور الجديدة</label>
      <input id="password" type="password" autocomplete="new-password" minlength="8" required>
      <label id="confirm-label" for="confirm">تأكيد كلمة المرور</label>
      <input id="confirm" type="password" autocomplete="new-password" minlength="8" required>
      <button id="save-button" type="submit">حفظ كلمة المرور</button>
    </form>
  </section>
  <div id="message" class="message" role="status" aria-live="polite" hidden></div>
  <footer id="footer">لن نطلب كلمة مرورك عبر البريد أو الدعم. رابط الاستعادة لمرة واحدة.</footer>
</main>
<script nonce="__NONCE__">
(() => {
  'use strict';
  const projectUrl = '__PROJECT_URL__';
  const publicKey = '__PUBLIC_KEY__';
  const $ = (id) => document.getElementById(id);
  let recoveryAccessToken = null;
  let isEnglish = false;
  const copy = {
    ar: {
      title: 'استعادة كلمة المرور', intro: 'أدخل بريد حسابك. سنرسل رابطًا آمنًا صالحًا لمرة واحدة لإعادة تعيين كلمة المرور.',
      email: 'البريد الإلكتروني', send: 'إرسال رابط الاستعادة', passwordIntro: 'اختر كلمة مرور جديدة لحسابك.',
      password: 'كلمة المرور الجديدة', confirm: 'تأكيد كلمة المرور', save: 'حفظ كلمة المرور',
      footer: 'لن نطلب كلمة مرورك عبر البريد أو الدعم. رابط الاستعادة لمرة واحدة.',
      genericSent: 'إذا كان البريد مسجلًا، فستصلك رسالة استعادة. افتحها على هذا الجهاز والمتصفح الذي بدأ الطلب.',
      invalidEmail: 'أدخل بريدًا إلكترونيًا صحيحًا.', requestError: 'تعذر إرسال الطلب الآن. انتظر قليلًا ثم حاول مرة أخرى.',
      invalidLink: 'رابط الاستعادة غير صالح أو انتهت صلاحيته. ابدأ طلبًا جديدًا.',
      tooShort: 'يجب ألا تقل كلمة المرور عن 8 أحرف.', mismatch: 'كلمتا المرور غير متطابقتين.',
      saveError: 'تعذر حفظ كلمة المرور. قد يكون الرابط منتهي الصلاحية؛ ابدأ طلبًا جديدًا.',
      saved: 'تم تغيير كلمة المرور. يمكنك الآن العودة إلى Sabiha Hub وتسجيل الدخول.',
      missingConfig: 'تعذر بدء الاستعادة. راجع إعدادات QA.',
    },
    en: {
      title: 'Reset your password', intro: 'Enter your account email. We will send a one-time secure reset link.',
      email: 'Email address', send: 'Send reset link', passwordIntro: 'Choose a new password for your account.',
      password: 'New password', confirm: 'Confirm password', save: 'Save password',
      footer: 'We will never ask for your password by email or support. Reset links can be used once.',
      genericSent: 'If the email is registered, a reset message will arrive. Open it on the same device and browser that started the request.',
      invalidEmail: 'Enter a valid email address.', requestError: 'The request could not be sent. Wait a moment and try again.',
      invalidLink: 'This reset link is invalid or expired. Start a new request.',
      tooShort: 'Use at least 8 characters for the password.', mismatch: 'The passwords do not match.',
      saveError: 'The password could not be saved. The link may have expired; start a new request.',
      saved: 'Your password has been changed. Return to Sabiha Hub and sign in.',
      missingConfig: 'Recovery is unavailable. Check QA configuration.',
    },
  };
  const tr = (key) => copy[isEnglish ? 'en' : 'ar'][key];
  const message = (text) => { $('message').textContent = text; $('message').hidden = false; };
  const clearMessage = () => { $('message').textContent = ''; $('message').hidden = true; };
  function renderLanguage() {
    const lang = isEnglish ? 'en' : 'ar';
    document.documentElement.lang = lang;
    document.documentElement.dir = isEnglish ? 'ltr' : 'rtl';
    $('language').textContent = isEnglish ? 'العربية' : 'English';
    $('title').textContent = tr('title');
    document.title = 'Sabiha Hub | ' + tr('title');
    $('intro').textContent = tr('intro');
    $('email-label').textContent = tr('email');
    $('request-button').textContent = tr('send');
    $('password-intro').textContent = tr('passwordIntro');
    $('password-label').textContent = tr('password');
    $('confirm-label').textContent = tr('confirm');
    $('save-button').textContent = tr('save');
    $('footer').textContent = tr('footer');
  }
  $('language').addEventListener('click', () => { isEnglish = !isEnglish; renderLanguage(); });
  $('request-form').addEventListener('submit', async (event) => {
    event.preventDefault(); clearMessage();
    const email = $('email').value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { message(tr('invalidEmail')); return; }
    if (!projectUrl || !publicKey) { message(tr('missingConfig')); return; }
    const button = $('request-button'); button.disabled = true;
    const callback = location.origin + location.pathname;
    try {
      const endpoint = new URL('/auth/v1/recover', projectUrl);
      endpoint.searchParams.set('redirect_to', callback);
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: publicKey },
        body: JSON.stringify({ email }),
        cache: 'no-store',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
      });
      // Do not expose the Auth response body: it may disclose account or request details.
      if (!response.ok) throw new Error('recovery_request_failed');
      $('request-panel').hidden = true;
      message(tr('genericSent'));
    } catch (_) {
      message(tr('requestError'));
    } finally {
      button.disabled = false;
    }
  });
  $('password-form').addEventListener('submit', async (event) => {
    event.preventDefault(); clearMessage();
    const password = $('password').value;
    if (!recoveryAccessToken) { message(tr('invalidLink')); return; }
    if (password.length < 8) { message(tr('tooShort')); return; }
    if (password !== $('confirm').value) { message(tr('mismatch')); return; }
    const button = $('save-button'); button.disabled = true;
    try {
      const response = await fetch(new URL('/auth/v1/user', projectUrl), {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          apikey: publicKey,
          Authorization: 'Bearer ' + recoveryAccessToken,
        },
        body: JSON.stringify({ password }),
        cache: 'no-store',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
      });
      if (!response.ok) throw new Error('password_update_failed');
      // The recovery bearer token exists only in this page's memory and is discarded now.
      recoveryAccessToken = null;
      $('password').value = '';
      $('confirm').value = '';
      message(tr('saved'));
      $('password-panel').hidden = true;
      $('request-panel').hidden = true;
      history.replaceState(null, '', location.pathname);
    } catch (_) {
      recoveryAccessToken = null;
      $('password').value = '';
      $('confirm').value = '';
      message(tr('saveError'));
      $('password-panel').hidden = true;
      $('request-panel').hidden = false;
      history.replaceState(null, '', location.pathname);
    } finally {
      button.disabled = false;
    }
  });
  function consumeRecoveryFragment() {
    const fragment = new URLSearchParams(location.hash.startsWith('#') ? location.hash.slice(1) : location.hash);
    const accessToken = fragment.get('access_token');
    const type = fragment.get('type');
    // Remove every fragment field, including refresh_token, before rendering or network activity.
    if (location.hash) history.replaceState(null, '', location.pathname);
    if (accessToken && type === 'recovery') {
      recoveryAccessToken = accessToken;
      $('request-panel').hidden = true;
      $('password-panel').hidden = false;
      $('intro').textContent = tr('passwordIntro');
    } else if (location.hash || type) {
      message(tr('invalidLink'));
    }
  }
  renderLanguage();
  consumeRecoveryFragment();
})();
</script>
</body>
</html>`;

Deno.serve((request) => {
  if (request.method !== "GET") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { "Allow": "GET", "Cache-Control": "no-store" },
    });
  }

  const publicKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const nonceBytes = crypto.getRandomValues(new Uint8Array(18));
  const nonce = btoa(String.fromCharCode(...nonceBytes))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const html = page
    .replaceAll("__NONCE__", nonce)
    .replaceAll("__PROJECT_URL__", projectUrl)
    .replaceAll("__PUBLIC_KEY__", publicKey);

  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store, no-cache, max-age=0, must-revalidate",
      "Pragma": "no-cache",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
      "Content-Security-Policy": `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; connect-src ${projectUrl}; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`,
    },
  });
});
