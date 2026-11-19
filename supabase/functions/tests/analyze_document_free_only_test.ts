import { handler } from "../analyze-business-document/handler.ts";
function assert(value: unknown): asserts value {
  if (!value) throw Error("Assertion failed");
}
const id = "00000000-0000-4000-8000-000000000001";
const request = (document_id: unknown = id, auth = true) =>
  new Request("https://edge.example.test", {
    method: "POST",
    headers: auth ? { Authorization: "Bearer fake-owner" } : {},
    body: JSON.stringify({ document_id }),
  });
const settings: Record<string, string> = {
  SUPABASE_URL: "https://db.example.test",
  SUPABASE_ANON_KEY: "fake",
  OPENAI_API_KEY: "fake-paid-key",
  OPENAI_DOCUMENT_MODEL: "configured-fake",
  OWNER_EVIDENCE_AI_ENABLED: "true",
};
function fixture(deny = "") {
  const calls: string[] = [];
  const env = (key: string) => {
    assert(key === "SUPABASE_URL" || key === "SUPABASE_ANON_KEY");
    return settings[key];
  };
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    assert(!init?.method || init.method === "GET");
    assert(url.startsWith(settings.SUPABASE_URL));
    if (url.endsWith("/auth/v1/user")) {
      return Response.json({ id: "owner" }, {
        status: deny === "auth" ? 401 : 200,
      });
    }
    if (url.includes("/staff_profiles?")) {
      return Response.json([{
        role: deny === "employee" ? "employee" : "owner",
        is_active: deny !== "inactive",
      }]);
    }
    assert(
      url.includes("/business_documents?document_id=eq." + id) &&
        url.endsWith("&select=document_id"),
    );
    return Response.json(deny === "missing" ? [] : [{ document_id: id }], {
      status: deny === "document" ? 403 : 200,
    });
  };
  return { calls, env, fetcher };
}
Deno.test("document extraction free-only: configured paid keys never read; no file/provider/write", async () => {
  const m = fixture();
  const r = await handler(m.env, m.fetcher)(request());
  const b = await r.json();
  assert(
    r.status === 503 && b.code === "free_engine_unavailable" &&
      b.paid_provider_allowed === false && b.extraction === undefined,
  );
  assert(m.calls.length === 3);
});
Deno.test("document extraction free-only: anonymous and expired Auth denied", async () => {
  const m = fixture();
  assert((await handler(m.env, m.fetcher)(request(id, false))).status === 401);
  assert(m.calls.length === 0);
  const n = fixture("auth");
  assert(
    (await handler(n.env, n.fetcher)(request())).status === 401 &&
      n.calls.length === 1,
  );
});
Deno.test("document extraction free-only: employee/inactive owner denied", async () => {
  for (const denied of ["employee", "inactive"]) {
    const m = fixture(denied);
    assert(
      (await handler(m.env, m.fetcher)(request())).status === 403 &&
        m.calls.length === 2,
    );
  }
});
Deno.test("document extraction free-only: actual document permission and missing ID enforced", async () => {
  for (
    const [denied, status] of [["document", 403], ["missing", 404]] as const
  ) {
    const m = fixture(denied);
    assert(
      (await handler(m.env, m.fetcher)(request())).status === status &&
        m.calls.length === 3,
    );
  }
});
Deno.test("document extraction free-only: malformed request stops before any fetch", async () => {
  const m = fixture();
  assert(
    (await handler(m.env, m.fetcher)(request("bad-id"))).status === 400 &&
      m.calls.length === 0,
  );
});
