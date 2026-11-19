import { handler } from "../owner-evidence-advisor/handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw Error(message);
}
const settings: Record<string, string> = {
  SUPABASE_URL: "https://db.example.test",
  SUPABASE_ANON_KEY: "anon",
  OWNER_EVIDENCE_AI_ENABLED: "true",
  OPENAI_API_KEY: "server-secret",
  OPENAI_OWNER_EVIDENCE_MODEL: "configured-test-model",
  OWNER_EVIDENCE_AI_APP_ORIGIN: "https://app.example.test",
};
const env = (key: string) => settings[key];
const evidence = (count = 20) => ({
  as_of: "2026-11-14T10:00:00Z",
  branch_id: "MUST_NOT_SEND",
  documents: ["MUST_NOT_SEND"],
  metrics: [{
    code: "billed_revenue",
    value: 100,
    unit: "EGP",
    source: "business_invoices",
    count,
    basis: "window",
  }, {
    code: "cash_net",
    value: 90,
    unit: "EGP",
    source: "business_payment_events",
    count,
    basis: "window",
  }, {
    code: "average_review_stars",
    value: null,
    unit: "stars",
    source: "employee_service_reviews",
    count: 0,
    basis: "window",
  }],
});
const request = (extra: Record<string, unknown> = {}) =>
  new Request("https://edge.example.test", {
    method: "POST",
    headers: { Authorization: "Bearer owner" },
    body: JSON.stringify({
      action: "advise",
      from: "2026-11-01",
      to: "2026-11-14",
      language: "en",
      consent: true,
      ...extra,
    }),
  });
const valid = {
  suggestions: [{
    action_code: "reconcile_invoices",
    evidence_ids: ["billed_revenue", "cash_net"],
  }],
};
function mock(
  options: {
    count?: number;
    denied?: boolean;
    authDenied?: boolean;
    budgetDenied?: boolean;
    answer?: unknown;
    providerFailure?: boolean;
  } = {},
) {
  const calls: string[] = [];
  let providerBody: Record<string, unknown> | undefined;
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    if (url.endsWith("/auth/v1/user")) {
      return new Response("{}", { status: options.authDenied ? 401 : 200 });
    }
    if (url.endsWith("/get_owner_business_insights")) {
      return new Response(
        JSON.stringify(
          options.denied ? { code: "42501" } : evidence(options.count),
        ),
        { status: options.denied ? 403 : 200 },
      );
    }
    if (url.endsWith("/claim_owner_evidence_ai_budget")) {
      return new Response("{}", { status: options.budgetDenied ? 400 : 200 });
    }
    assert(
      url === "https://api.openai.com/v1/responses",
      "Unexpected external URL",
    );
    providerBody = JSON.parse(String(init?.body));
    if (options.providerFailure) throw Error("Mock timeout");
    return new Response(
      JSON.stringify({
        output: [{
          content: [{
            type: "output_text",
            text: JSON.stringify(options.answer ?? valid),
          }],
        }],
      }),
    );
  };
  return {
    fetcher,
    calls,
    get body() {
      return providerBody;
    },
  };
}
async function assertFreeOnly(response: Response, m: ReturnType<typeof mock>) {
  assert(response.status === 503);
  const data = await response.json();
  assert(data.code === "free_engine_unavailable");
  assert(data.mode === "free_only" && data.available === false);
  assert(data.paid_provider_allowed === false);
  assert(m.calls.length === 2);
  assert(
    !m.calls.some((url) =>
      url.includes("openai.com") || url.includes("claim_owner")
    ),
  );
  assert(m.body === undefined);
  assert(!JSON.stringify(data).includes("server-secret"));
  assert(!JSON.stringify(data).includes("MUST_NOT_SEND"));
}
Deno.test("free-only policy: configured owner advice remains unavailable without paid calls", async () => {
  const m = mock();
  await assertFreeOnly(await handler(env, m.fetcher)(request()), m);
});
Deno.test("unauthenticated or nonowner calls cannot reserve budget or reach provider", async () => {
  for (const options of [{ authDenied: true }, { denied: true }]) {
    const m = mock(options);
    const response = await handler(env, m.fetcher)(request());
    assert(response.status === 401 || response.status === 403);
    assert(
      !m.calls.some((u) =>
        u.includes("openai.com") || u.includes("claim_owner")
      ),
    );
  }
});
Deno.test("disabled configuration reports unavailable and never calls provider", async () => {
  const m = mock();
  const disabled = (key: string) =>
    key === "OPENAI_API_KEY" ? undefined : env(key);
  const status = await handler(disabled, m.fetcher)(
    request({ action: "status", consent: false }),
  );
  assert(status.status === 200);
  assert((await status.json()).available === false);
  const response = await handler(disabled, m.fetcher)(request());
  assert(response.status === 503);
  assert(
    !m.calls.some((u) => u.includes("openai.com") || u.includes("claim_owner")),
  );
});

Deno.test("QA loopback fallback permits only exact local browser origins", async () => {
  const localEnv = (key: string) =>
    key === "OWNER_EVIDENCE_AI_APP_ORIGIN" || key === "APP_ORIGIN"
      ? undefined
      : settings[key];
  const preflight = await handler(localEnv, async () => {
    throw Error("preflight must not reach Supabase");
  })(new Request("https://edge.example.test", {
    method: "OPTIONS",
    headers: { Origin: "http://127.0.0.1:8790" },
  }));
  assert(preflight.status === 204);
  assert(
    preflight.headers.get("Access-Control-Allow-Origin") ===
      "http://127.0.0.1:8790",
  );

  const denied = await handler(localEnv, async () => {
    throw Error("denied origin must not reach Supabase");
  })(new Request("https://edge.example.test", {
    method: "OPTIONS",
    headers: { Origin: "https://attacker.example" },
  }));
  assert(denied.status === 403);
  assert(denied.headers.get("Access-Control-Allow-Origin") === null);
});
Deno.test("free-only policy: insufficient data never enables paid advice", async () => {
  const m = mock({ count: 1 });
  await assertFreeOnly(await handler(env, m.fetcher)(request()), m);
});
Deno.test("free-only policy: missing consent never enables provider or budget", async () => {
  const m = mock();
  await assertFreeOnly(
    await handler(env, m.fetcher)(request({ consent: false })),
    m,
  );
});
Deno.test("free-only policy: daily budget is never requested", async () => {
  const m = mock({ budgetDenied: true });
  await assertFreeOnly(await handler(env, m.fetcher)(request()), m);
});
Deno.test("free-only policy: provider citation fixtures cannot bypass cost denial", async () => {
  for (
    const answer of [
      {
        suggestions: [{
          action_code: "reconcile_invoices",
          evidence_ids: ["profit"],
        }],
      },
      {
        suggestions: [{
          action_code: "review_feedback_coverage",
          evidence_ids: ["average_review_stars"],
        }],
      },
      {
        suggestions: [{
          action_code: "verify_stock_counts",
          evidence_ids: ["billed_revenue"],
        }],
      },
      {
        suggestions: [{
          action_code: "reconcile_invoices",
          evidence_ids: ["billed_revenue"],
          claim: "Profit will rise 100%",
        }],
      },
      { suggestions: valid.suggestions, profit: 100 },
    ]
  ) {
    const m = mock({ answer });
    const response = await handler(env, m.fetcher)(request());
    await assertFreeOnly(response, m);
  }
});
Deno.test("free-only policy: provider failure fixture is never invoked", async () => {
  const m = mock({ providerFailure: true });
  await assertFreeOnly(await handler(env, m.fetcher)(request()), m);
});
Deno.test("untrusted origin and oversized request fail before any HTTP", async () => {
  const m = mock();
  const response = await handler(env, m.fetcher)(
    new Request("https://edge.example.test", {
      method: "POST",
      headers: {
        Origin: "https://evil.example.test",
        Authorization: "Bearer owner",
      },
      body: "{}",
    }),
  );
  assert(response.status === 403);
  const huge = await handler(env, m.fetcher)(
    request({ question: "x".repeat(3000) }),
  );
  assert(huge.status === 400);
  assert(m.calls.length === 0);
});
