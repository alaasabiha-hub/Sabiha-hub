## Android real-device test status — 18 November 2026

- A QA-only ARM64 debug APK is ready at `build/staging/android/sabiha-hub-qa-android-arm64-debug.apk` (about 219 MiB). It is signed with the Android debug certificate for sideload testing and cannot be treated as a store build. SHA-256: `ce4d7a48ba7ad7f08b3c67619269567b66d323531c23d2048f023fb693bf4db0`.
- APK inspection passed for application ID, `POST_NOTIFICATIONS`, merged Firebase Messaging service/receiver, generated Google Services app/sender resources, QA Supabase endpoint, absence of the production project host, and APK signature. The QA DB remains the authority; FCM is transport only.
- In QA, `push_device_tokens` and `customer_marketing_preferences` have RLS that binds rows to `auth.uid()`; token rows additionally require the matching active customer or staff profile. This confirms the policy shape; no live account-isolation API attempt was made.
- No phone is connected, so install, permission, token creation, and foreground/background/terminated receipt remain unverified on hardware. No test push was sent. Customer Push requires a distinct QA customer account; the only current QA identity is Owner/staff and should not be used to represent a customer.
- Next manual sequence: install APK; sign into or create a dedicated QA customer account; enable one Push preference and grant OS permission; request approval before sending a single device-targeted test from Firebase Console or a separately approved QA sender. Verify all three app states. Do not turn on campaign/general delivery.
- No FCM sender/scheduler is deployed. The Release AOT build attempt stalled and was stopped; use the verified debug APK for initial handset testing. No production changes, real customer messages, or paid services were used.

## أحدث حالة ربط Firebase QA على الهاتف — 18 نوفمبر 2026

- تم التحقق محليًا من `google-services.json` و`GoogleService-Info.plist` دون عرض قيمهما. كلاهما لمشروع Firebase `sabiha-hub-qa` ومعرّف التطبيق `com.sabihahub.app`، ورقم المرسل متطابق. لكل منصة مفتاح API مستقل؛ يختار Flutter مفتاح Android أو iOS حسب المنصة.
- شغّل `python3 tools/prepare_firebase_qa_config.py` لإعادة التحقق والنسخ المحلي. يقرأ الملفين من `~/Downloads`، ويتأكد من مشروع Firebase، ثم يجهّز كذلك عنوان Supabase QA ومفتاح `sb_publishable_` فقط. ينشئ `local-config/firebase-qa-dart-defines.json` محليًا بصلاحية 0600. كل ملفات Firebase/QA تتجاهلها Git، ولا يطبع السكربت القيم.
- بناء Android وiOS للمحاكي يمر بملف التعريف المحلي: `flutter build apk --debug --dart-define-from-file=local-config/firebase-qa-dart-defines.json` و`flutter build ios --simulator --debug --no-codesign --dart-define-from-file=local-config/firebase-qa-dart-defines.json`. Supabase يظل قاعدة البيانات؛ Firebase Cloud Messaging قناة تسليم فقط.
- لا ترسل أو تضع مفتاح Service Account أو FCM server key في Flutter. إعدادات التطبيق العامة ليست بيانات إرسال خادمية. متغيرات التسليم الخادمية يجب أن تحفظ في أسرار Edge على QA فقط بعد تجهيز المرسل وموافقة منفصلة.
- يوجد تحكم المالك في الحملات والجمهور والجدولة والإلغاء، لكن عامل الجدولة/الإرسال غير منشور. كذلك outbox أحداث التشغيل لا يُرسل للهاتف حاليًا. بوابات الإرسال تبقى مغلقة؛ لا توجد رسائل أو رموز جهاز فعلية من هذا الاختبار.

### حالة APNs والإجراء المطلوب من المالك

- إعداد iOS المحلي يحتوي بالفعل على `UIBackgroundModes` = `remote-notification` وentitlement `aps-environment` (development لـDebug وproduction لـProfile/Release). لم أغيّر توقيع Apple أو ملفات الحساب.
- من Apple Developer: تأكد من أن App ID `com.sabihahub.app` مفعّل له Push Notifications، وأن حساب المطور صالح للتوقيع. أنشئ APNs Authentication Key بصيغة `.p8` ثم أضفه في Firebase Console → Project settings → Cloud Messaging مع Key ID وTeam ID. احتفظ بالملف سرًا ولا ترسله لي.
- قد يتطلب التسجيل أو التجديد في Apple Developer رسومًا؛ لا تدفع أو ترقي أي حساب. إذا لم يكن الحساب مؤهلًا، أوقف هذه الخطوة إلى حين قرارك.
- يلزم اختبار Android مع Google Play services واختبار iPhone فعلي موقّع بعد إعداد APNs. بناء المحاكي لا يثبت وصول الإشعارات. أرسل إشعار اختبار فقط بعد موافقتك المنفصلة.

Restore point: `work/checkpoints/firebase-qa-before-20261118T063603Z/`.

# إعداد إشعارات Sabiha Hub — الحالة الحالية

آخر مراجعة: 18 نوفمبر 2026. هذا الملف يميز ما يعمل محليًا عن ما يحتاج تهيئة خارجية أو اختبار جهاز. لم يُفعّل الإرسال الحقيقي ولم يُنشر أي Edge Function في QA ضمن هذه المرحلة.

## ما هو موصول حاليًا

- تستخدم Flutter حزمتي `firebase_core` و`firebase_messaging` وخدمة `PushNotificationService`، بما في ذلك طلب إذن النظام وفق اختيار العميل، استقبال الرسالة أثناء فتح التطبيق، فتح الإشعار/الرابط الداخلي، وإدارة رموز الجهاز ضمن جمهور العملاء. عند إيقاف العميل كلًا من Push التسويقي وPush الطلبات، تزال رموز أجهزته المسجلة. إعدادات التسويق داخل التطبيق وPush مستقلة.
- شاشة المالك `OwnerNotificationsScreen` تدير الحملات والمسودات والجدولة والإيقاف والإلغاء، نصًا عربيًا وإنجليزيًا، صورة عبر رابط HTTPS أو رفع صورة من الجهاز إلى Storage، ربط عرض منشور، وروابط داخلية للعروض أو الحجز. الجمهور الحالي: كل الموافقين، فرع نشط محدد، عملاء مختارون بمعرفاتهم، عملاء جدد، غير نشطين، وقريبون من مكافأة الولاء. صلاحية لوحة المالك يحكمها Supabase، ولا تستدعي الواجهة المرسل.
- زر «إرسال الآن» يضيف الحملة إلى قائمة التنفيذ بموعد حالي؛ لا يرسل بنفسه. تعرض اللوحة ذلك صراحةً. يحتاج الإرسال أيًا كان الموعد إلى عامل التوزيع وبوابتي الأمان الموضحتين أدناه.
- مركز العميل الداخلي في `AppInboxScreen` يعرض حملات التسويق التي وافق العميل على استقبالها داخل التطبيق، يدعم مقروء/غير مقروء واللغتين، ويمسح البيانات عند تبديل الجلسة. دوال القراءة والتحديث مقيدة بالعميل الحالي؛ لا تُقرأ جداول المستلمين مباشرة من التطبيق.
- سجل الفروع يحدد العملاء المؤهلين عبر طلبات الفرع والحجوزات غير الملغاة ثم يتقاطع مع موافقة العميل. يعاد التحقق من موافقة Push وموافقة الصندوق قبل التنفيذ. إعادة المحاولة لا تنشئ مستلمًا مكررًا للحملة نفسها.
- الترحيلان QA الخاصان بهذا المسار: `20261118045400_customer_marketing_in_app_and_branch_target` و`20261118053000_customer_marketing_inbox_list_volatility`. سجل التشغيل في `docs/STAGING.md`.

## اختبارات منفذة

- `flutter test test/app_inbox_marketing_test.dart test/app_inbox_widget_test.dart test/owner_notifications_test.dart test/public_landing_test.dart test/public_navigation_test.dart test/recruitment_test.dart`: 36 اختبارًا ناجحًا، تشمل الصندوق والحملات والعربية/الإنجليزية وأحجام الهاتف/الكمبيوتر والوظائف العامة. اختبار القائمة الأفقية للكمبيوتر كشف overflow وتم إصلاحه.
- `npx --yes deno@2.1.4 test --allow-env --allow-net supabase/functions/tests/contracts_test.ts`: 11 اختبارًا ناجحًا. تشمل عزل الشريحة/الفرع، عدم طلب FCM عند بوابة الإرسال المغلقة، وإعادة التحقق من الموافقات. لا يثبت هذا تسليم هاتف فعليًا.
- `dart analyze` على ملفات الإشعارات والصفحات العامة والاختبارات المتأثرة: بلا ملاحظات.
- تطبيق ترحيل QA والتحقق قراءة فقط: RLS مفعّل على سجل المستلمين والتشغيل؛ `anon` بلا قراءة، وامتياز `authenticated` المباشر محكوم بسياسات SELECT للمالك فقط. صندوق العميل يستخدم RPC مقيدًا بالحساب بدل قراءة الصفوف مباشرة، و`service_role` وحده ينهي تشغيل الحملة. عُدّلت دالة القراءة إلى `VOLATILE` لتوافق قفل الصف داخل حارس الجلسة. لم تُنشأ حملة أو مستلم اختبار دائم.

## بوابات تمنع أي إرسال الآن

يجب أن يظل المتغيران التاليان **غير مضبوطين** في QA والإنتاج حتى موافقة المالك وتجهيز اختبار معزول:

- `CUSTOMER_PUSH_DELIVERY_ENABLED` — إتاحة إرسال FCM من الخادم.
- `CUSTOMER_IN_APP_CAMPAIGN_DELIVERY_ENABLED` — إتاحة إنشاء عناصر حملات في الصندوق الداخلي.

كل دوال الحملات والطلب التي ترسل FCM يجب أن تتحقق من البوابة الخادمية، لا من Flutter. لا توجد مفاتيح Firebase أو حساب خدمة في المشروع. لا يوجد نشر جديد لدالة الحملات أو جدولة تشغيلية مثبتة في QA. لذلك الواجهة وسجل الحملة وتجهيز الخادم لا تعني أن العميل تلقى إشعارًا.

## أحداث التشغيل الموصولة على QA

- سجل QA: `20261118053440_customer_operational_inbox_and_campaign_media`، `20261118054253_customer_operational_notification_idempotency_fix`، `20261118054752_customer_operational_booking_reminder_reschedule_keys`، و`20261118055646_customer_notification_unlinked_visit_safety`، و`20261118055919_customer_booking_reminder_cancel_due_unread`. أسماء ملفات المصدر المحلية موجودة في `supabase/migrations/`.
- تحفظ أحداث العميل في سجل خاص داخل معاملة الحدث وبمفتاح فريد. لا يقرأ العميل الجداول الخاصة مباشرة؛ RPC القراءة/التعليم كمقروء مرتبطة بجلسة العميل نفسه، وبحد أقصى 100 عنصر.
- المصادر المتصلة: استلام/تأكيد/تغيير/إلغاء الحجز، تذكير الموعد، بدء الخدمة، فحص الجودة، جاهزية السيارة بعد اكتمال الخدمة، التسليم، إلغاء الخدمة، وكسب نقاط/زيارة الولاء. إشعار النقاط لا يصدر إلا لمسار زيارة مدفوعة ومكتملة وفاتورة/حجز متحققين؛ إدخال نقاط غير مؤهل لا يكفي.
- تذكير الحجز يُجدول قبل الموعد بـ24 ساعة، ويظهر فورًا إذا كان الموعد بعد أكثر من ساعتين وأقل من 24 ساعة. إعادة الجدولة أو الإلغاء تلغي التذكير السابق. لكل انتقال جدولة مفتاح جديد حتى لا يمنع الموعد القديم الملغى إنشاء تذكير عند العودة إلى وقت سابق.
- Push له Outbox منفصل ولا يُنشأ إلا إذا كان خيار إشعارات الطلبات للعميل مفعّلًا. لا يوجد عامل إرسال أو جدولة منشور ولا مفاتيح FCM، لذا لا يرسل هذا السجل إلى الهواتف.
- `AppInboxScreen` يضم الصندوق التشغيلي بجانب صندوق الحملات، ويدعم العربية والإنجليزية وحالات المقروء، ويمسح محتواه عند تبديل الحساب. روابط التشغيل محصورة في الحجوزات والطلبات؛ روابط Push للطلبات مدعومة الآن.
- مساحة صور الحملات `customer-notification-media` مستقلة. القراءة عامة عمدًا لأن الصور الترويجية معروضة للعملاء (أي شخص لديه الرابط يستطيع عرضها)، والرفع للمالك النشط فقط، بحد 3 MiB وأنواع JPEG/PNG/WebP ومسار UUID عشوائي. لا يستطيع `anon`/`authenticated` الاستبدال أو الحذف. لا تحفظ فيها مستندات أو بيانات خاصة. Flutter يتحقق من التوقيع الفعلي والامتداد قبل الرفع.

## نتائج QA والقيود

- اختبار قاعدة QA داخل `BEGIN/ROLLBACK` أنشأ حجزًا مؤقتًا عبر trigger الحقيقي، وفحص إشعار الاستلام والتأكيد وتغيير الموعد ثم الرجوع للموعد السابق والإلغاء. تحقق وجود تذكير نشط واحد بعد إعادة الجدولة وإلغاء القديمة؛ انتهى الاختبار بـ`ROLLBACK`.
- اختبار معاملة منفصل كرر enqueue بالمفتاح نفسه، وتحقق من نفس المعرّف وموعد مستقبلي ثم الإلغاء؛ نجح. كما اختبر حجزًا حقيقيًا داخل معاملة مؤقتة: الاستلام والتأكيد وإعادة الجدولة للموعد السابق ثم العودة، وإلغاء تذكير أصبح موعده مستحقًا لكنه غير مقروء مع الحفاظ على تذكير سبق أن قرأه العميل كسجل تاريخي. انتهى الاختبار بـ`ROLLBACK`. كشف التشغيل الأول تعارض PL/pgSQL مع عمود `customers.id`؛ أصلحناه في ترحيل QA أمامي ثم نجح الاختبار.
- قراءة QA بعد التراجع: لا سجلات إشعارات تشغيلية أو Push أو صور متبقية. صلاحيات القراءة: `anon` لا ينفذ RPC ولا يقرأ الجداول الخاصة؛ `authenticated` ينفذ RPC الذاتية فقط ولا يقرأ الجدول الخاص مباشرة. لا جلسة مالك حية متاحة هنا لإثبات رفع الصورة الإيجابي؛ لم يُرفع شيء.
- 24 اختبار Flutter مستهدفًا نجحت، بما فيها RTL/LTR بعرض 390×844 و1440×900، فتح الطلبات، رفض deep link غير مسموح، ومسح البيانات عند تبديل هوية الحساب. `dart analyze` للملفات المتأثرة نظيف. اختبارات الصور تتحقق من MIME والتوقيع والحجم.
- لم نختبر trigger الإيجابي للخدمة/الولاء على سجل عمل حقيقي مكتمل؛ QA لا يحتوي دورة بيع/خدمة مؤهلة. trigger والتحقق المشروط موجودان، لكن المسار الإيجابي غير مثبت حيًا. لا قياس لفتح Push أو تسليم FCM؛ لا جهاز/تهيئة Firebase.

## خطوات تحتاج تدخل المالك لإعداد Firebase وAPNs لاحقًا

1. من Firebase Console استخدم مشروعًا مخصصًا لـQA فقط. راجع أن FCM هو الخيار المجاني، ولا تضف Cloud Functions أو خدمات أخرى قد تتطلب ترقية/رسومًا. لم ننشئ موارد نيابة عنك.
2. سجّل Android QA app بالمعرّف المعتمد محليًا `com.sabihahub.app`.
3. سجّل iOS QA app بالـBundle ID المعتمد محليًا `com.sabihahub.app`، ونزّل `GoogleService-Info.plist` إلى `ios/Runner/` محليًا. لا تسجل التطبيق قبل التأكد من أن المعرّف غير مستخدم ضمن حسابات المتاجر الخاصة بك؛ فالفحص العام لا يكشف التطبيقات الخاصة أو غير المنشورة. لا ترفع هذه الملفات إلى Git أو المحادثة.
4. التطبيق الحالي لا يستخدم FlutterFire CLI أو ملف `firebase_options.dart`: يأخذ القيم التالية من Dart compile-time defines عند البناء: `FIREBASE_API_KEY`، `FIREBASE_PROJECT_ID`، `FIREBASE_MESSAGING_SENDER_ID`، `FIREBASE_ANDROID_APP_ID`، `FIREBASE_IOS_APP_ID`، و`FIREBASE_IOS_BUNDLE_ID`. استخدم القيم من تطبيق QA فقط، ولا تمرر أبدًا مفاتيح إرسال الخادم إلى Flutter. لم تُنشأ هذه القيم أو تُحفظ في المشروع.
5. في إعدادات Apple Developer تأكد من تفعيل Push Notifications للتطبيق. ملفات entitlements المحلية تحتوي بالفعل على `aps-environment`، لكن `UIBackgroundModes`/Remote notifications غير مضافة بعد. بعد التحقق من حساب المطور، فعّل Background Modes > Remote notifications، وأنشئ مفتاح APNs `.p8` ثم أدخل Key ID وTeam ID في Firebase Cloud Messaging. لا ترسل المفتاح أو بيانات الدخول هنا. امتلاك حساب Apple Developer أو تجديده قد يتطلب رسومًا؛ لا تشترِ/تجدّد دون موافقتك.
6. اختبر Android على جهاز QA أو محاكي به Google Play services. اختبر APNs على iPhone موقّع بحساب Apple المؤهل؛ البناء على محاكي وحده لا يثبت وصول Push.
7. بعد موافقة منفصلة على إرسال اختبار، تُحفظ بيانات اعتماد FCM في Edge secrets على QA فقط، ويُبنى sender خادمي مع بوابات مغلقة افتراضيًا، ثم يُختبر إلى جهازك فقط. لا تفعّل رسائل العملاء العامة.

FCM نفسه مدرج بلا تكلفة في تسعير Firebase الحالي، لكن هذا لا يعني أن حساب Apple أو أي خدمات إضافية مجانية. راجع [التسعير الرسمي لـFirebase](https://firebase.google.com/pricing) و[إعداد FCM لتطبيق Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started) و[إعداد APNs على iOS](https://firebase.google.com/docs/cloud-messaging/ios/get-started).

## ضوابط ثابتة

- لا SMS ولا WhatsApp ولا مزود AI مدفوع لهذا المسار.
- لا ترسل للحملات التسويقية دون موافقة القناة المناسبة؛ إيقاف التسويق لا يوقف إشعارات تشغيلية لازمة، لكن يلزم تفضيل مستقل لكل نوع عند تنفيذ مصادرها.
- لا تعرض الرمز أو بيانات الجهاز أو مفاتيح الخادم في لوحة المالك أو السجلات. لا تُسجل نص الشكوى أو بيانات الدفع ضمن payload الإشعار.
- روابط الحملات محصورة في `/offers` و`/booking`، والإشعارات التشغيلية في `/booking` و`/orders`.
- لا تغيّر قاعدة الإنتاج أو الموقع الرسمي، ولا تفعّل أي بوابة أو إرسال حقيقي أثناء الاختبارات.

## معرّفات Firebase QA

المعرّف المحلي المعتمد لكل من Android وiOS هو `com.sabihahub.app`. الفحص العام لمتجري Apple وGoogle لم يجد تطبيقًا منشورًا بهذا المعرّف (Apple lookup: 0 نتائج، Google Play: HTTP 404)، لكنه لا يكشف التسجيلات الخاصة أو الحجوزات داخل حساب المطور أو Firebase. تحقّق من حساباتك قبل الإضافة.
## Samsung device-only FCM QA path — 18 November 2026

- Added a diagnostic entry to the customer sign-in screen that exists only in native Debug + `APP_ENV=staging` with Firebase configured. It requests permission and obtains/copies the installation's registration token. It does not authenticate, persist or bind the token in Supabase, or send any message.
- Install/update with `build/staging/android/sabiha-hub-qa-android-arm64-debug.apk` (versionCode 2, about 116 MiB). SHA-256: `f808f0bd5d2e30f1925d7f86362243d8cd9cc53465ab481121190649123dcfbe`. It has the same package ID and local Debug signing as the earlier QA Debug APK. If Android reports a signing conflict, cancel; do not uninstall the current app.
- On Samsung: open Customer Sign In → “QA device push test tool” → request permission → copy token locally. Paste only into the Firebase Console one-device test-message screen; do not share it here. Wait for explicit send approval; no message was sent by this task. This account-free method tests device delivery, not account authorization.
- Account-bound Push registration remains untested because current QA's only Auth identity/customer row is the active Owner/staff account. Keep that account unchanged; use a separate legitimate QA customer identity for the RLS binding test. No fake email/provider alias was created.
- Four focused Flutter tests pass; Dart analyze clean; QA-only APK build and package/config/service/permission/signature checks pass. Real device interaction is pending: the Samsung is not connected to this Mac. No FCM sender/dispatcher is deployed; no production changes or paid services.
