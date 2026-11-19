const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers });
type Env = (key: string) => string | undefined;
export function handler(env: Env, fetcher: typeof fetch = fetch) {
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") return new Response("ok", { headers });
    if (request.method !== "POST") {
      return reply(405, { error: "Method not allowed" });
    }
    const auth = request.headers.get("Authorization");
    if (!auth?.startsWith("Bearer ")) {
      return reply(401, { error: "Sign in as owner" });
    }
    const base = env("SUPABASE_URL"),
      key = env("SUPABASE_ANON_KEY");
    if (!base || !key) {
      return reply(503, { error: "Document assistant is not configured" });
    }
    const h = { apikey: key, Authorization: auth };
    try {
      const userResponse = await fetcher(`${base}/auth/v1/user`, {
        headers: h,
      });
      if (!userResponse.ok) return reply(401, { error: "Session expired" });
      const user = await userResponse.json();
      const profileResponse = await fetcher(
        `${base}/rest/v1/staff_profiles?user_id=eq.${
          encodeURIComponent(user.id)
        }&select=role,is_active`,
        { headers: h },
      );
      if (!profileResponse.ok) {
        return reply(403, { error: "Owner access required" });
      }
      const profiles = await profileResponse.json();
      if (
        !Array.isArray(profiles) || profiles[0]?.role !== "owner" ||
        profiles[0]?.is_active !== true
      ) return reply(403, { error: "Owner access required" });
      let body;
      try {
        body = await request.json();
      } catch {
        return reply(400, { error: "Invalid request" });
      }
      const question = typeof body.question === "string"
        ? body.question.trim()
        : "";
      if (!question || question.length > 1000) {
        return reply(400, {
          error: "Question must contain 1 to 1000 characters",
        });
      }
      if (body.consent !== true) {
        return reply(400, {
          error:
            "Owner consent is required before sending approved document fields to AI",
        });
      }
      const docsResponse = await fetcher(
        `${base}/rest/v1/business_documents?select=document_id,title,category,document_number,issued_at,expires_at,extracted_data&approved_at=not.is.null&order=approved_at.desc&limit=100`,
        { headers: h },
      );
      if (!docsResponse.ok) {
        return reply(403, { error: "Approved documents unavailable" });
      }
      // Authorization to read approved documents remains enforced above. Never
      // forward document data to a paid provider, regardless of keys/settings.
      return reply(503, {
        code: "free_engine_unavailable",
        error: "The free document assistant is not available yet",
        available: false,
        mode: "free_only",
        paid_provider_allowed: false,
      });
    } catch {
      return reply(502, {
        error:
          "Document assistant could not complete the request; stored documents were not changed",
      });
    }
  };
}
// One-argument wrapper keeps Deno.serve's second handler-info argument out of env.
export const handleRequest = (request: Request): Promise<Response> =>
  handler((key) => Deno.env.get(key))(request);
