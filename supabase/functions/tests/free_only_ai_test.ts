import { handler as advisor } from "../owner-evidence-advisor/handler.ts";
import { handler as documents } from "../ask-business-documents/handler.ts";
function assert(value: unknown): asserts value {
  if (!value) throw Error("Assertion failed");
}
const settings: Record<string, string> = {
  SUPABASE_URL: "https://db.example.test",
  SUPABASE_ANON_KEY: "fake-anon",
  OPENAI_API_KEY: "fake-key-never-send",
  OWNER_EVIDENCE_AI_ENABLED: "true",
  OPENAI_OWNER_EVIDENCE_MODEL: "fake-model",
  OPENAI_DOCUMENT_MODEL: "fake-model",
  APP_ORIGIN: "https://app.example.test",
};
const env = (key: string) => settings[key];
const request = (kind: string, action = "advise", authenticated = true) =>
  new Request("https://edge.example.test/" + kind, {
    method: "POST",
    headers: authenticated
      ? { Authorization: "Bearer fake-jwt", "Content-Type": "application/json" }
      : { "Content-Type": "application/json" },
    body: JSON.stringify(
      kind === "advisor"
        ? {
          action,
          language: "en",
          from: "2026-11-01",
          to: "2026-11-15",
          consent: true,
        }
        : { question: "What is approved?", consent: true },
    ),
  });
function mock(kind: string, denied = "") {
  const calls: string[] = [];
  const fetcher: typeof fetch = async (input) => {
    const url = String(input);
    calls.push(url);
    // Any paid provider, budget claim or other endpoint is a test failure.
    assert(url.startsWith(settings.SUPABASE_URL + "/"));
    if (url.endsWith("/auth/v1/user")) {
      return Response.json({ id: "fake-owner" }, {
        status: denied === "auth" ? 401 : 200,
      });
    }
    if (
      kind === "advisor" &&
      url.endsWith("/rest/v1/rpc/get_owner_business_insights")
    ) {
      return Response.json({
        metrics: [{
          code: "billed_revenue",
          value: 100,
          unit: "EGP",
          source: "business_invoices",
          count: 20,
          basis: "window",
        }],
      }, { status: denied === "owner" ? 403 : 200 });
    }
    if (kind === "documents" && url.includes("/rest/v1/staff_profiles?")) {
      return Response.json([{
        role: denied === "owner" ? "employee" : "owner",
        is_active: true,
      }]);
    }
    if (kind === "documents" && url.includes("/rest/v1/business_documents?")) {
      return Response.json([{
        document_id: "approved-fixture",
        title: "Private document fixture",
        extracted_data: { private: "never-forward" },
      }], { status: denied === "documents" ? 403 : 200 });
    }
    throw Error("Unexpected network path");
  };
  return { calls, fetcher };
}
for (const kind of ["advisor", "documents"]) {
  Deno.test(
    kind + ": configured fake paid keys cannot enable provider",
    async () => {
      const m = mock(kind);
      const run = (kind === "advisor" ? advisor : documents)(env, m.fetcher);
      const response = await run(request(kind));
      const body = await response.json();
      assert(
        response.status === 503 && body.code === "free_engine_unavailable" &&
          body.paid_provider_allowed === false && body.available === false,
      );
      assert(m.calls.length === (kind === "advisor" ? 2 : 3));
      assert(!JSON.stringify(body).includes("Private document"));
    },
  );
  Deno.test(kind + ": authentication still required", async () => {
    const m = mock(kind);
    const run = (kind === "advisor" ? advisor : documents)(env, m.fetcher);
    assert((await run(request(kind, "advise", false))).status === 401);
    assert(m.calls.length === 0);
    assert((await run(request(kind))).status === 503); // owner check runs only after actual mocked Auth success
  });
  Deno.test(kind + ": current owner permission remains required", async () => {
    const m = mock(kind, "owner");
    const run = (kind === "advisor" ? advisor : documents)(env, m.fetcher);
    assert((await run(request(kind))).status === 403);
    assert(m.calls.length === 2);
  });
}
Deno.test("advisor: status truthfully unavailable despite enabled setting", async () => {
  const m = mock("advisor");
  const response = await advisor(env, m.fetcher)(request("advisor", "status"));
  const body = await response.json();
  assert(
    response.status === 200 && body.available === false &&
      body.mode === "free_only" && body.paid_provider_allowed === false,
  );
  assert(m.calls.length === 2);
});
Deno.test("documents: approved document permission still enforced", async () => {
  const m = mock("documents", "documents");
  assert(
    (await documents(env, m.fetcher)(request("documents"))).status === 403,
  );
  assert(m.calls.length === 3);
});
Deno.test("both: rejected Auth server session cannot reach owner or documents", async () => {
  for (const kind of ["advisor", "documents"]) {
    const m = mock(kind, "auth");
    assert(
      (await (kind === "advisor" ? advisor : documents)(env, m.fetcher)(
        request(kind),
      )).status === 401,
    );
    assert(m.calls.length === 1);
  }
});
