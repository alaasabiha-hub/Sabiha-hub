# قبول محدث — 15 نوفمبر 2026

تعلو هذه الفقرة على وصف source-only التاريخي أدناه ضمن نطاقها فقط. يوجد الآن panel وأسئلة محادثة مدعومة AR/EN في Flutter باستخدام الـEdge نفسها، ومقترحات مراجعة يدوية من خمسة أنواع بأدلة يلتقطها الخادم وإصدارات وnonce وسجل قرارات وصلاحية المالك. لا ينفّذ أي منها تعديلًا ماليًا أو تغيير أسعار أو عقوبة. بيانات الربح/التوقع غير الكافية تبقى صريحة، وليست نتائج نموذج عام.

المحادثة تحتفظ بآخر عشر إجابات في RAM فقط، وتمسحها عند تغير الجلسة/اللغة/الفترة. السؤال غير المدعوم لا يرسل طلبًا ولا يُختلق له جواب؛ كل جواب يتحقق من مصدره وفترته ورفض paid-provider/execution flags. SelectionArea+Text يحافظان على النسخ وقراءة الجواب في الويب.12 اختبارات جديدة، contract حي، وAR390/EN1440 من التطبيق الرئيسي/Edge الحقيقية ومطابقة SQL مقبولة دون تغيير سجلات الأعمال أو عداد الميزانية المدفوعة. المقترحات لها6 widgets و4 QA browser write journeys و17 HTTP وسباقان فعليان وrollback lifecycle/dismissal. الأدلة تحت work/runtime ومسمّاة في PROJECT_HANDOFF.md.

تبقى breadth التحليلات والتوصيات/التنفيذ الآمن والجدولة والطوارئ وبقية المصفوفة جزئية؛ هذا ليس إعلان اكتمال Sabiha AI بالكامل أو native. لا نشر/إنتاج/مزود مدفوع.

---

# Bounded free owner evidence assistant — source/test stage

No provider, external model, API key, paid quota, environment activation or business action exists in the new pure template helper. The Edge handler retains its existing Auth server check and current-owner evidence RPC; no extra query/RPC or provider call is added. This stage is not deployed or wired to a new UI.

## Request and response

POST `owner-evidence-advisor` with existing bearer authentication and allowed origin:

```json
{"action":"ask","language":"en","from":"2026-11-01","to":"2026-11-15","question":"billing"}
```

`question` accepts a topic ID or the exact advertised Arabic/English phrase, normalized only for case, surrounding/repeated whitespace and final punctuation. It must contain1–500 characters. Additional instructions, arbitrary questions, execution/foreign fields and oversized input are not interpreted. Periods remain checked by the existing SQL RPC. The response is scoped to its actual active default branch, never an invented consolidated result.

Topics and phrases:

| ID | English | Arabic |
|---|---|---|
| summary | Business summary | ملخص النشاط |
| billing | Invoice totals | إجمالي الفواتير |
| collections | Cash collections | التحصيل النقدي |
| expenses | Recorded expenses | المصروفات المسجلة |
| stock | Current stock | المخزون الحالي |
| bookings | Booking summary | ملخص الحجوزات |
| reviews | Review summary | ملخص المراجعات |
| profit | Is actual profit available? | هل الربح الفعلي متاح؟ |
| forecast | Is a revenue forecast available? | هل توقع الإيرادات متاح؟ |

A supported grounded answer returns200 with `state:answer|missing_data`, `topic`, fixed localized `answer`, validated `facts`, source/basis/count `citations`, requested `period`, `scope:active_default_branch`, `mode:free_evidence_templates`, `paid_provider_allowed:false`, `execution_supported:false`, `requires_owner_review:true` and explicit limitations. Profit and forecast only explain why those outputs are unavailable; no arithmetic/projection is invented. Null review average is unavailable; recorded zero stays zero. Negative net cash is preserved. Stock is a current snapshot; booking counts do not cover every walk-in or measure worker productivity.

Each answer requires the exact relevant metric IDs, expected table source, unit and window/current basis. Duplicate metrics, invalid/nonfinite values, unsafe/fractional counts, invalid star range or malformed evidence fail closed. Unknown metric/text fields are discarded and never cited or reflected. Missing required facts, unsupported questions, unavailable/malformed evidence return503. Auth/owner rejection remains401/403. Question text, document data, customer/employee names, branch IDs and extra evidence fields are never echoed.

Existing `advise` remains503 and optional-model `status.available` remainsfalse. Status adds a distinct `free_assistant` object (`available`, `mode`, `supported_questions`, `execution_supported:false`) after the same current-owner evidence checks. This preserves the old optional-model boundary without claiming an unrestricted assistant.

## Verification and limits

Only `supabase/functions/tests/free_owner_assistant_test.ts` was run with cached-only Deno and no permissions:12 cases passed initially; one status fixture mistakenly included a question, was corrected, then that case alone passed (12 filtered). This gives13 distinct focused passing cases across the two logs, not a claim of a single full rerun. Previously accepted cost-lock suites were not repeated. Every HTTP test uses an injected whitelist mock and rejects provider/budget/extra endpoints; no real HTTP, credentials or database access.

This is a deterministic9-topic evidence helper. It is not broad free-form chat, documents Q&A, automatic alerts, profit accounting, forecasting, staffing/purchasing recommendations, a suggestion approval/execution workflow, scheduled reports or a new UI. Documents assistant remains unavailable. Existing SQL evidence completeness and default-branch scope remain its limits. No DB changes, build, deployment, paid service or business mutations.
