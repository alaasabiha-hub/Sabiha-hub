(() => {
  'use strict';

  const config = window.SABIHA_RECOVERY_CONFIG || {};
  const recoveryOrigin = 'https://sabiha-hub-qa-password-reset.pages.dev';
  const $ = (id) => document.getElementById(id);
  let recoveryAccessToken = null;
  let isEnglish = false;
  const strings = {
    ar: {
      title: 'استعادة كلمة المرور',
      intro: 'أدخل بريد حسابك. سنرسل رابطًا آمنًا صالحًا لمرة واحدة لإعادة تعيين كلمة المرور.',
      email: 'البريد الإلكتروني', send: 'إرسال رابط الاستعادة',
      passwordIntro: 'اختر كلمة مرور جديدة لحسابك.', password: 'كلمة المرور الجديدة',
      confirm: 'تأكيد كلمة المرور', save: 'حفظ كلمة المرور',
      footer: 'لن نطلب كلمة مرورك عبر البريد أو الدعم. رابط الاستعادة لمرة واحدة.',
      sent: 'إذا كان البريد مسجلًا، فستصلك رسالة استعادة. افتح الرابط من أي جهاز تملكه.',
      invalidEmail: 'أدخل بريدًا إلكترونيًا صحيحًا.',
      requestError: 'تعذر إرسال الطلب الآن. انتظر قليلًا ثم حاول مرة أخرى.',
      rateLimited: 'وصل المشروع إلى حد إرسال البريد الحالي. انتظر ساعة قبل طلب رسالة أخرى.',
      senderNotAllowed: 'مزود البريد التجريبي لا يسمح بهذا العنوان. يحتاج المشروع إلى SMTP مخصص موثّق.',
      invalidLink: 'رابط الاستعادة غير صالح أو انتهت صلاحيته. ابدأ طلبًا جديدًا.',
      tooShort: 'يجب ألا تقل كلمة المرور عن 8 أحرف.',
      mismatch: 'كلمتا المرور غير متطابقتين.',
      saveError: 'تعذر حفظ كلمة المرور. قد يكون الرابط منتهي الصلاحية؛ ابدأ طلبًا جديدًا.',
      saved: 'تم تغيير كلمة المرور. يمكنك الآن العودة إلى Sabiha Hub وتسجيل الدخول.',
      missingConfig: 'تعذر بدء الاستعادة. إعدادات QA غير مكتملة.',
      wrongOrigin: 'افتح صفحة الاستعادة من رابط Sabiha Hub QA المعتمد.',
    },
    en: {
      title: 'Reset your password',
      intro: 'Enter your account email. We will send a one-time secure reset link.',
      email: 'Email address', send: 'Send reset link',
      passwordIntro: 'Choose a new password for your account.', password: 'New password',
      confirm: 'Confirm password', save: 'Save password',
      footer: 'We will never ask for your password by email or support. Reset links can be used once.',
      sent: 'If the email is registered, a reset message will arrive. Open the link on a device you control.',
      invalidEmail: 'Enter a valid email address.',
      requestError: 'The request could not be sent. Wait a moment and try again.',
      rateLimited: 'This project reached its current email limit. Wait an hour before requesting another message.',
      senderNotAllowed: 'The test mailer cannot send to this address. The project needs authenticated custom SMTP.',
      invalidLink: 'This reset link is invalid or expired. Start a new request.',
      tooShort: 'Use at least 8 characters for the password.',
      mismatch: 'The passwords do not match.',
      saveError: 'The password could not be saved. The link may have expired; start a new request.',
      saved: 'Your password has been changed. Return to Sabiha Hub and sign in.',
      missingConfig: 'Recovery is unavailable. QA configuration is incomplete.',
      wrongOrigin: 'Open the approved Sabiha Hub QA recovery page.',
    },
  };

  const tr = (key) => strings[isEnglish ? 'en' : 'ar'][key];
  const showMessage = (text) => {
    $('message').textContent = text;
    $('message').hidden = false;
  };
  const clearMessage = () => {
    $('message').textContent = '';
    $('message').hidden = true;
  };

  function renderLanguage() {
    document.documentElement.lang = isEnglish ? 'en' : 'ar';
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

  $('language').addEventListener('click', () => {
    isEnglish = !isEnglish;
    renderLanguage();
  });

  $('request-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    clearMessage();
    const email = $('email').value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      showMessage(tr('invalidEmail'));
      return;
    }
    if (!config.supabaseUrl || !config.publishableKey) {
      showMessage(tr('missingConfig'));
      return;
    }
    if (location.origin !== recoveryOrigin || location.pathname !== '/') {
      showMessage(tr('wrongOrigin'));
      return;
    }

    const button = $('request-button');
    button.disabled = true;
    let retainCooldown = false;
    try {
      const endpoint = new URL('/auth/v1/recover', config.supabaseUrl);
      endpoint.searchParams.set('redirect_to', recoveryOrigin + '/');
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: config.publishableKey },
        body: JSON.stringify({ email }),
        cache: 'no-store',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
      });
      // Only known error codes are inspected; no response body or recipient is logged.
      if (!response.ok) {
        let errorCode = '';
        try {
          const body = await response.json();
          errorCode = String(body.error_code || body.code || '');
        } catch (_) {}
        if (response.status === 429 || errorCode === 'over_email_send_rate_limit') {
          retainCooldown = true;
          showMessage(tr('rateLimited'));
          window.setTimeout(() => { button.disabled = false; }, 60 * 60 * 1000);
          return;
        }
        if (errorCode === 'email_address_not_authorized') {
          showMessage(tr('senderNotAllowed'));
          return;
        }
        throw new Error('recovery_request_failed');
      }
      $('request-panel').hidden = true;
      showMessage(tr('sent'));
    } catch (_) {
      showMessage(tr('requestError'));
    } finally {
      if (!retainCooldown) button.disabled = false;
    }
  });

  $('password-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    clearMessage();
    const password = $('password').value;
    if (!recoveryAccessToken) { showMessage(tr('invalidLink')); return; }
    if (password.length < 8) { showMessage(tr('tooShort')); return; }
    if (password !== $('confirm').value) { showMessage(tr('mismatch')); return; }

    const button = $('save-button');
    button.disabled = true;
    try {
      const response = await fetch(new URL('/auth/v1/user', config.supabaseUrl), {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          apikey: config.publishableKey,
          Authorization: 'Bearer ' + recoveryAccessToken,
        },
        body: JSON.stringify({ password }),
        cache: 'no-store',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
      });
      if (!response.ok) throw new Error('password_update_failed');

      recoveryAccessToken = null;
      $('password').value = '';
      $('confirm').value = '';
      $('password-panel').hidden = true;
      $('request-panel').hidden = true;
      history.replaceState(null, '', location.pathname);
      showMessage(tr('saved'));
    } catch (_) {
      recoveryAccessToken = null;
      $('password').value = '';
      $('confirm').value = '';
      $('password-panel').hidden = true;
      $('request-panel').hidden = false;
      history.replaceState(null, '', location.pathname);
      showMessage(tr('saveError'));
    } finally {
      button.disabled = false;
    }
  });

  function handleRecoveryLink() {
    const hasFragment = Boolean(location.hash);
    const fragment = new URLSearchParams(hasFragment ? location.hash.slice(1) : '');
    const accessToken = fragment.get('access_token');
    const recoveryType = fragment.get('type');
    // Clear access_token and refresh_token from the address bar before any network call.
    if (hasFragment) history.replaceState(null, '', location.pathname);
    if (location.origin !== recoveryOrigin || location.pathname !== '/') {
      showMessage(tr('wrongOrigin'));
    } else if (accessToken && recoveryType === 'recovery') {
      recoveryAccessToken = accessToken;
      $('request-panel').hidden = true;
      $('password-panel').hidden = false;
      $('intro').textContent = tr('passwordIntro');
    } else if (hasFragment || new URLSearchParams(location.search).has('error_code')) {
      showMessage(tr('invalidLink'));
    }
  }

  renderLanguage();
  handleRecoveryLink();
})();
