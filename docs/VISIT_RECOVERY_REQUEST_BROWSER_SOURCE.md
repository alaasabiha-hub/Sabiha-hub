# Request, review and inbox browser check — source only

`tools/visit_recovery_requests_browser.py` defaults to a plan. It has not signed in,
created a case, executed a browser, or changed data during source preparation.
It requires an explicit accepted build manifest covering the integrated request,
evidence wrapper, inbox, owner review and main routing source, plus the exact served
compiled JavaScript hash. Root executes one locale at a time after source review.

The Arabic 390 and English 1440 runs use respectively the first and second EXISTING
private `recovery-bridge-fixture.private.json` accounts. Preflight requires their
actual confirmed account and registered valid phone, and no open/linked request.
It creates no Auth account, branch, catalog service, registration, claim or link.
The existing hidden fixture branch is irrelevant to request submission.

Each run signs in the existing owner before any submission so finally cleanup has
an already authenticated authorized actor. It follows real customer profile UI,
explicit fresh server consent and new-request button, actual receipt acknowledgement,
and the genuine inbox entry. The owner uses the existing CRM request screen for
more-information and rejection; each action must target the exact new case, with
actual request nonces journalled before dispatch. Customer status and each fixed
inbox event are verified against actual own RPC responses and settled screenshots.
Raw owner status codes are never text selectors. No claim/evidence buttons are used.

Only necessary startup reads, recovery submission/recovery/close, owner unmapped
review commands, and inbox list/read RPCs are allowed. Ads are suppressed without a
write. All other remote traffic and business mutations are blocked; only verified
static font resources are allowed outside loopback. SDK JSON null is normalized
only for parameterless startup reads. No provider, finance, HR, notification push,
claim/link or history authorization operations are enabled.

Cleanup uses the exact recorded submission nonce if the response was lost, closes
only recorded owner commands, and rejects only the new unmapped case if still open.
It never deletes an audit row or touches prior terminal cases. Preexisting
public/private full-row multisets, document counters and Auth identity data
(excluding normal sign-in timestamps) must remain unchanged. Partial checkpoints,
private failure screenshots and sanitized RPC name/status metadata survive failure.
Contact/name paragraphs and inputs are masked; credentials and response bodies are
never persisted. Actual screenshots are produced only on `--execute`.

Example (root substitutes runtime/build manifest and output paths):

```sh
python3 tools/visit_recovery_requests_browser.py \
  --runtime /Users/user/Documents/Codex/2026-11-12/v/work/runtime \
  --build-proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/visit-recovery-web-build-source.json \
  --proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/recovery-request-ar390-proof.json \
  --screenshots /Users/user/Documents/Codex/2026-11-12/v/outputs/recovery-requests \
  --language ar
```

Default is PLAN. Append `--execute` only after root release. Use a separate proof
file and `--language en` for English; an accepted Arabic journey must not be repeated
to repair a later independent English selector issue. There is no automatic retry.

Not covered: manual receipt-proof bridge, canonical owner approval, linked-history
access, guest financial consent, health-page browser coverage, or external push.
Those are independent integrations; this request-only check does not imply they pass.
