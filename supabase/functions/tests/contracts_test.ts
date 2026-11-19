import { handleRequest as orderPush } from "../dispatch-order-notifications/handler.ts";
import { handleRequest as ask } from "../ask-business-documents/handler.ts";
import { handleRequest as expiry } from "../dispatch-document-expiry-alerts/handler.ts";
import { handleRequest as marketing } from "../dispatch-marketing-campaigns/handler.ts";
const assert = (value: unknown, message = "Assertion failed") => {
  if (!value) throw new Error(message);
};
const response = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const post = (body: unknown, auth = true) =>
  new Request("http://local/functions/v1/ask-business-documents", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(auth ? { Authorization: "Bearer test-owner" } : {}),
    },
    body: JSON.stringify(body),
  });
const id = "00000000-0000-4000-8000-000000000001";
function configure() {
  Deno.env.set("SUPABASE_URL", "http://local");
  Deno.env.set("SUPABASE_ANON_KEY", "test-anon");
  Deno.env.set("OPENAI_API_KEY", "test-key-not-real");
}
async function mocked(run: () => Promise<void>, mock: typeof fetch) {
  const original = globalThis.fetch;
  const previous = new Map(
    [
      "SUPABASE_URL",
      "SUPABASE_ANON_KEY",
      "OPENAI_API_KEY",
      "MARKETING_DISPATCH_SECRET",
      "DOCUMENT_ALERT_DISPATCH_SECRET",
      "ORDER_NOTIFICATION_DISPATCH_SECRET",
      "SUPABASE_SERVICE_ROLE_KEY",
      "FIREBASE_PROJECT_ID",
      "FIREBASE_SERVICE_ACCOUNT_JSON",
      "CUSTOMER_PUSH_DELIVERY_ENABLED",
      "CUSTOMER_IN_APP_CAMPAIGN_DELIVERY_ENABLED",
    ].map((k) => [k, Deno.env.get(k)]),
  );
  globalThis.fetch = mock;
  try {
    await run();
  } finally {
    globalThis.fetch = original;
    for (const [k, v] of previous) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  }
}
Deno.test("document assistant rejects anonymous and non-owner without contacting AI", async () => {
  await mocked(
    async () => {
      configure();
      assert(
        (await ask(post({ question: "expiry", consent: true }, false)))
          .status === 401,
      );
      assert(
        (await ask(post({ question: "expiry", consent: true }))).status === 403,
      );
    },
    ((url: string | URL | Request) => {
      const path = String(url);
      if (path.endsWith("/auth/v1/user")) {
        return Promise.resolve(
          response({ id }),
        );
      }
      if (path.includes("staff_profiles")) {
        return Promise.resolve(
          response([{ role: "employee", is_active: true }]),
        );
      }
      throw new Error("Unexpected external request");
    }) as typeof fetch,
  );
});
Deno.test("free-only document policy: consent retained and no paid citations requested", async () => {
  let aiCalls = 0;
  await mocked(
    async () => {
      configure();
      assert((await ask(post({ question: "expiry" }))).status === 400);
      assert(aiCalls === 0);
      assert(
        (await ask(post({ question: "expiry", consent: true }))).status === 503,
      );
      assert(aiCalls === 0);
    },
    (async (url: string | URL | Request, init?: RequestInit) => {
      const path = String(url);
      if (path.endsWith("/auth/v1/user")) return response({ id });
      if (path.includes("staff_profiles")) {
        return response([{
          role: "owner",
          is_active: true,
        }]);
      }
      if (path.includes("business_documents")) {
        assert(path.includes("approved_at=not.is.null"));
        return response([{
          document_id: id,
          title: "Local license",
          category: "License",
          extracted_data: { expires_at: "2026-12-01" },
        }]);
      }
      if (path === "https://api.openai.com/v1/responses") {
        aiCalls++;
        const payload = JSON.parse(String(init?.body));
        assert(payload.store === false);
        return response({
          output: [{
            content: [{
              type: "output_text",
              text: JSON.stringify({
                answer: "Unsupported",
                document_ids: ["invented"],
              }),
            }],
          }],
        });
      }
      throw new Error("Unexpected request");
    }) as typeof fetch,
  );
});
Deno.test("free-only document policy: approved evidence cannot enable paid answers or writes", async () => {
  let paidCalls = 0;
  await mocked(
    async () => {
      configure();
      const result = await ask(
        post({ question: "When does license expire?", consent: true }),
      );
      assert(result.status === 503);
      const value = await result.json();
      assert(value.code === "free_engine_unavailable");
      assert(value.paid_provider_allowed === false);
      assert(value.extraction === undefined && value.citations === undefined);
      assert(paidCalls === 0);
    },
    (async (url: string | URL | Request, init?: RequestInit) => {
      const path = String(url);
      if (path.endsWith("/auth/v1/user")) return response({ id });
      if (path.includes("staff_profiles")) {
        return response([{
          role: "owner",
          is_active: true,
        }]);
      }
      if (path.includes("business_documents")) {
        assert(!init?.method || init.method === "GET");
        return response([{
          document_id: id,
          title: "License",
          category: "License",
          expires_at: "2026-12-01",
          extracted_data: {},
        }]);
      }
      if (path === "https://api.openai.com/v1/responses") {
        paidCalls++;
        return response({
          output: [{
            content: [{
              type: "output_text",
              text: JSON.stringify({
                answer: "2026-12-01",
                document_ids: [id],
              }),
            }],
          }],
        });
      }
      throw new Error("Unexpected request");
    }) as typeof fetch,
  );
});
Deno.test("dispatchers require independent scheduler secrets before any network access", async () => {
  await mocked(
    async () => {
      Deno.env.set("DOCUMENT_ALERT_DISPATCH_SECRET", "test-doc-secret");
      Deno.env.set("MARKETING_DISPATCH_SECRET", "test-marketing-secret");
      assert((await expiry(post({}))).status === 401);
      assert((await marketing(post({}))).status === 401);
      const req = new Request("http://local", {
        method: "POST",
        headers: { "x-document-alert-secret": "test-marketing-secret" },
      });
      assert((await expiry(req)).status === 401);
    },
    (() => {
      throw new Error("Unauthorized dispatcher attempted network");
    }) as typeof fetch,
  );
});
Deno.test("expiry dispatcher leaves alerts unclaimed when no owner device exists", async () => {
  await mocked(
    async () => {
      Deno.env.set("DOCUMENT_ALERT_DISPATCH_SECRET", "test-doc-secret");
      Deno.env.set("SUPABASE_URL", "http://local");
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service");
      Deno.env.set("FIREBASE_PROJECT_ID", "local-test");
      Deno.env.set("FIREBASE_SERVICE_ACCOUNT_JSON", "{}");
      const result = await expiry(
        new Request("http://local", {
          method: "POST",
          headers: { "x-document-alert-secret": "test-doc-secret" },
        }),
      );
      assert(result.status === 200);
      assert((await result.json()).claimed === 0);
    },
    ((url: string | URL | Request) => {
      if (String(url).includes("staff_profiles")) {
        return Promise.resolve(
          response([]),
        );
      }
      throw new Error("No device: must not claim or deliver alerts");
    }) as typeof fetch,
  );
});

async function fakeFirebaseAccount() {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  const raw = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return {
    client_email: "local-test@example.test",
    private_key: `-----BEGIN PRIVATE KEY-----\n${
      btoa(raw)
    }\n-----END PRIVATE KEY-----`,
  };
}
Deno.test("expiry delivery captures provider acceptance without exposing document numbers or URLs", async () => {
  const account = await fakeFirebaseAccount();
  let sent = false, finished = false;
  await mocked(
    async () => {
      Deno.env.set("DOCUMENT_ALERT_DISPATCH_SECRET", "test-doc-secret");
      Deno.env.set("SUPABASE_URL", "http://local");
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service");
      Deno.env.set("FIREBASE_PROJECT_ID", "local-test");
      Deno.env.set("FIREBASE_SERVICE_ACCOUNT_JSON", JSON.stringify(account));
      const result = await expiry(
        new Request("http://local", {
          method: "POST",
          headers: { "x-document-alert-secret": "test-doc-secret" },
        }),
      );
      assert(result.status === 200);
      assert((await result.json()).sent === 1);
      assert(sent && finished);
    },
    (async (url: string | URL | Request, init?: RequestInit) => {
      const path = String(url);
      if (path.includes("staff_profiles")) return response([{ user_id: id }]);
      if (path.includes("push_device_tokens?select=")) {
        assert(path.includes("audience=eq.staff"));
        return response([{
          token_id: "test-device",
          user_id: id,
          device_token: "synthetic-device",
          locale: "en",
        }]);
      }
      if (path === "https://oauth2.googleapis.com/token") {
        return response({
          access_token: "test-fcm-token",
        });
      }
      if (path.includes("rpc/claim_due_business_document_alerts")) {
        return response([{
          alert_id: id,
          document_id: id,
          title: "Local license",
          category: "Other",
          expires_at: "2026-12-01",
          days_before_expiry: 7,
        }]);
      }
      if (path.startsWith("https://fcm.googleapis.com/")) {
        const payload = JSON.parse(String(init?.body));
        assert(payload.message.token === "synthetic-device");
        assert(payload.message.data.deep_link === "/business-documents");
        assert(!JSON.stringify(payload).includes("storage_path"));
        assert(!JSON.stringify(payload).includes("document_number"));
        sent = true;
        return response({ name: "local-message-id" });
      }
      if (path.includes("rpc/finish_business_document_alert")) {
        const body = JSON.parse(String(init?.body));
        assert(body.p_sent === true);
        finished = true;
        return response(null);
      }
      throw new Error("Unexpected network request: " + path);
    }) as typeof fetch,
  );
});
Deno.test("expiry delivery disables unregistered tokens and marks the attempt failed", async () => {
  const account = await fakeFirebaseAccount();
  let disabled = false, failed = false;
  await mocked(
    async () => {
      Deno.env.set("DOCUMENT_ALERT_DISPATCH_SECRET", "test-doc-secret");
      Deno.env.set("SUPABASE_URL", "http://local");
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service");
      Deno.env.set("FIREBASE_PROJECT_ID", "local-test");
      Deno.env.set("FIREBASE_SERVICE_ACCOUNT_JSON", JSON.stringify(account));
      const result = await expiry(
        new Request("http://local", {
          method: "POST",
          headers: { "x-document-alert-secret": "test-doc-secret" },
        }),
      );
      assert((await result.json()).failed === 1);
      assert(disabled && failed);
    },
    (async (url: string | URL | Request, init?: RequestInit) => {
      const path = String(url);
      if (path.includes("staff_profiles")) return response([{ user_id: id }]);
      if (path.includes("push_device_tokens?select=")) {
        return response([{
          token_id: "test-device",
          user_id: id,
          device_token: "expired-device",
          locale: "ar",
        }]);
      }
      if (path === "https://oauth2.googleapis.com/token") {
        return response({
          access_token: "test-fcm-token",
        });
      }
      if (path.includes("rpc/claim_due_business_document_alerts")) {
        return response([{
          alert_id: id,
          document_id: id,
          title: "Local license",
          category: "Other",
          expires_at: "2026-12-01",
          days_before_expiry: 0,
        }]);
      }
      if (path.startsWith("https://fcm.googleapis.com/")) {
        return response({
          error: { status: "UNREGISTERED" },
        }, 404);
      }
      if (path.includes("push_device_tokens?token_id=")) {
        disabled = JSON.parse(String(init?.body)).is_active === false;
        return response(null);
      }
      if (path.includes("rpc/finish_business_document_alert")) {
        failed = JSON.parse(String(init?.body)).p_sent === false;
        return response(null);
      }
      throw new Error("Unexpected network request");
    }) as typeof fetch,
  );
});
Deno.test("marketing rechecks consent immediately before delivery and suppresses an opt-out", async () => {
  const account = await fakeFirebaseAccount();
  let preferenceReads = 0, suppressed = false, finished = false;
  await mocked(
    async () => {
      Deno.env.set("MARKETING_DISPATCH_SECRET", "test-marketing-secret");
      Deno.env.set("CUSTOMER_PUSH_DELIVERY_ENABLED", "true");
      Deno.env.set("SUPABASE_URL", "http://local");
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service");
      Deno.env.set("FIREBASE_PROJECT_ID", "local-test");
      Deno.env.set("FIREBASE_SERVICE_ACCOUNT_JSON", JSON.stringify(account));
      const result = await marketing(
        new Request("http://local", {
          method: "POST",
          headers: { "x-marketing-dispatch-secret": "test-marketing-secret" },
        }),
      );
      assert(result.status === 200);
      assert(suppressed && finished);
    },
    (async (url: string | URL | Request, init?: RequestInit) => {
      const path = String(url);
      if (path === "https://oauth2.googleapis.com/token") {
        return response({
          access_token: "test-token",
        });
      }
      if (path.includes("rpc/claim_due_marketing_campaigns")) {
        return response([
          { run_id: id, campaign_id: id },
        ]);
      }
      if (path.includes("marketing_campaigns?")) {
        return response([{
          campaign_id: id,
          title: "Local campaign",
          body: "Local only",
          target_segment: { type: "all" },
          deep_link: "/offers",
        }]);
      }
      if (path.includes("customer_marketing_preferences?")) {
        preferenceReads++;
        return response(preferenceReads === 1 ? [{ customer_id: id }] : []);
      }
      if (
        path.includes("marketing_campaign_recipients?") &&
        init?.method === "POST"
      ) return response([{ recipient_id: id, customer_id: id }]);
      if (path.includes("marketing_campaign_recipients?") && !init?.method) {
        return response([{ recipient_id: id, customer_id: id }]);
      }
      if (
        path.includes("marketing_campaign_recipients?") &&
        init?.method === "PATCH"
      ) {
        suppressed = JSON.parse(String(init.body)).status === "suppressed";
        return response(null);
      }
      if (path.includes("rpc/finish_marketing_campaign_run")) {
        const body = JSON.parse(String(init?.body));
        assert(body.p_accepted_count === 0);
        finished = true;
        return response(null);
      }
      throw new Error(
        "Opted-out customer must not receive a notification: " + path,
      );
    }) as typeof fetch,
  );
});

Deno.test("in-app branch campaigns include only opted-in customers and never call FCM", async () => {
  const branch = "00000000-0000-4000-8000-000000000010";
  const optedIn = "00000000-0000-4000-8000-000000000011";
  const optedOut = "00000000-0000-4000-8000-000000000012";
  let visibleRecipient = false, inAppOnly = false, finished = false;
  await mocked(async () => {
    Deno.env.set("MARKETING_DISPATCH_SECRET", "test-marketing-secret");
    Deno.env.set("CUSTOMER_IN_APP_CAMPAIGN_DELIVERY_ENABLED", "true");
    Deno.env.set("SUPABASE_URL", "http://local");
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service");
    const result = await marketing(new Request("http://local", {
      method:"POST", headers:{"x-marketing-dispatch-secret":"test-marketing-secret"},
    }));
    assert(result.status === 200);
    const payload = await result.json();
    assert(payload.results[0].inApp === 1);
    assert(finished && visibleRecipient && inAppOnly);
  }, (async (url: string | URL | Request, init?: RequestInit) => {
    const path = String(url);
    if (path.includes("rpc/claim_due_marketing_campaigns")) return response([{run_id:id,campaign_id:id}]);
    if (path.includes("marketing_campaigns?")) return response([{
      campaign_id:id,title:"محلي",body:"QA only",title_en:"Local",body_en:"QA only",
      target_segment:{type:"branch",branch_id:branch},deep_link:"/offers",
    }]);
    if (path.includes("customer_marketing_preferences?") && path.includes("select=customer_id%2Cmarketing_push_enabled%2Cmarketing_in_app_enabled")) {
      return response([{customer_id:optedIn,marketing_push_enabled:false,marketing_in_app_enabled:true,customers:{created_at:"2026-11-01T00:00:00Z"}}]);
    }
    if (path.includes("customer_marketing_preferences?") && path.includes(`customer_id=eq.${optedIn}`)) {
      return response([{customer_id:optedIn,marketing_push_enabled:false,marketing_in_app_enabled:true}]);
    }
    if (path.includes("business_branches?")) return response([{branch_id:branch}]);
    if (path.includes("business_orders?")) return response([{customer_id:optedIn}]);
    if (path.includes("bookings?")) return response([{customer_id:optedOut}]);
    if (path.includes("marketing_campaign_recipients?") && init?.method === "POST") return response([]);
    if (path.includes("marketing_campaign_recipients?") && !init?.method) return response([{recipient_id:id,customer_id:optedIn}]);
    if (path.includes("marketing_campaign_recipients?") && init?.method === "PATCH") {
      const data = JSON.parse(String(init.body));
      if (data.in_app_visible === true) visibleRecipient = true;
      if (data.status === "in_app_only") inAppOnly = true;
      return response(null);
    }
    if (path.includes("finish_marketing_campaign_run_with_in_app")) {
      const data = JSON.parse(String(init?.body));
      assert(data.p_accepted_count === 0 && data.p_in_app_count === 1);
      finished = true;
      return response(null);
    }
    throw new Error("Unexpected request; no FCM delivery is permitted in this test: " + path);
  }) as typeof fetch);
});

Deno.test("order dispatcher requires its own secret and real provider configuration",async()=>{
 await mocked(async()=>{
  Deno.env.set('ORDER_NOTIFICATION_DISPATCH_SECRET','order-secret');
  assert((await orderPush(new Request('http://local',{method:'POST'}))).status===401);
  Deno.env.delete('FIREBASE_SERVICE_ACCOUNT_JSON');
  assert((await orderPush(new Request('http://local',{method:'POST',headers:{'x-order-notification-secret':'order-secret'}}))).status===503);
 },(()=>{throw new Error('Missing credentials must not contact a provider');}) as typeof fetch);
});
Deno.test("order push is transactional, private, and honors order opt-out",async()=>{
 const account=await fakeFirebaseAccount();let pushes=0,finished=0;
 await mocked(async()=>{
  configure();Deno.env.set('ORDER_NOTIFICATION_DISPATCH_SECRET','order-secret');Deno.env.set('CUSTOMER_PUSH_DELIVERY_ENABLED','true');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','service-test');Deno.env.set('FIREBASE_PROJECT_ID','local-test');Deno.env.set('FIREBASE_SERVICE_ACCOUNT_JSON',JSON.stringify(account));
  const result=await orderPush(new Request('http://local',{method:'POST',headers:{'x-order-notification-secret':'order-secret'}}));assert(result.status===200);assert(pushes===1);assert(finished===2);
 },(async(url:string|URL|Request,init?:RequestInit)=>{
  const path=String(url);
  if(path==='https://oauth2.googleapis.com/token')return response({access_token:'fake'});
  if(path.includes('rpc/claim_order_notifications'))return response([{notification_id:id,customer_id:id,order_id:id,status:'confirmed'},{notification_id:id+'x',customer_id:id+'x',order_id:id,status:'preparing'}]);
  if(path.includes('customer_marketing_preferences?'))return response([{order_push_enabled:!path.endsWith('x')}]);
  if(path.includes('push_device_tokens?'))return response([{token_id:id,device_token:'local-test-token',locale:'ar'}]);
  if(path.includes('fcm.googleapis.com')){const message=JSON.parse(String(init?.body)).message;assert(message.data.deep_link==='/orders');assert(!JSON.stringify(message).includes('address'));assert(!JSON.stringify(message).includes('phone'));pushes++;return response({name:'accepted'});}
  if(path.includes('customer_order_notifications?')){finished++;return response(null);}
  throw new Error('Unexpected network path '+path);
 }) as typeof fetch);
});
