const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const responseHeaders = {
  ...corsHeaders,
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders,
  });
}

type Env = (key: string) => string | undefined;
export function handler(env: Env, fetcher: typeof fetch = fetch) {
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }
    if (request.method !== "POST") {
      return jsonResponse(405, { error: "Method not allowed." });
    }

    const authorization = request.headers.get("Authorization");
    const apiKey = env("SUPABASE_ANON_KEY");
    const supabaseUrl = env("SUPABASE_URL");

    if (!authorization?.startsWith("Bearer ")) {
      return jsonResponse(401, {
        error: "Sign in as an owner to analyze documents.",
      });
    }
    if (!apiKey || !supabaseUrl) {
      return jsonResponse(503, {
        error: "Document analysis is not configured.",
      });
    }

    try {
      let documentId = "";
      try {
        const body = await request.json();
        documentId = typeof body?.document_id === "string"
          ? body.document_id
          : "";
      } catch {
        return jsonResponse(400, { error: "A valid document_id is required." });
      }
      if (
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
          .test(documentId)
      ) {
        return jsonResponse(400, { error: "A valid document_id is required." });
      }

      const headers = { apikey: apiKey, Authorization: authorization };
      // The caller id is resolved by Auth, not supplied by the request body.
      const userResponse = await fetcher(`${supabaseUrl}/auth/v1/user`, {
        headers,
      });
      if (!userResponse.ok) {
        return jsonResponse(401, {
          error: "Your session has expired. Sign in again.",
        });
      }
      const user = await userResponse.json();
      const ownerProfileResponse = await fetcher(
        `${supabaseUrl}/rest/v1/staff_profiles?user_id=eq.${
          encodeURIComponent(user.id)
        }&select=user_id,role,is_active`,
        { headers },
      );
      if (!ownerProfileResponse.ok) {
        return jsonResponse(403, {
          error: "Owner access could not be verified.",
        });
      }
      const profiles = await ownerProfileResponse.json();
      if (
        !Array.isArray(profiles) || profiles[0]?.role !== "owner" ||
        profiles[0]?.is_active !== true
      ) {
        return jsonResponse(403, {
          error: "Only an active owner can analyze business documents.",
        });
      }

      const documentResponse = await fetcher(
        `${supabaseUrl}/rest/v1/business_documents?document_id=eq.${
          encodeURIComponent(documentId)
        }&select=document_id`,
        { headers },
      );
      if (!documentResponse.ok) {
        return jsonResponse(403, {
          error: "This document is unavailable to your account.",
        });
      }
      const documents = await documentResponse.json();
      const document = Array.isArray(documents) ? documents[0] : null;
      if (!document || document.document_id !== documentId) {
        return jsonResponse(404, { error: "Document not found." });
      }

      // Hard free-only policy. Permission is checked without downloading private
      // file bytes, forwarding fields, reading provider keys or writing extraction.
      return jsonResponse(503, {
        code: "free_engine_unavailable",
        error:
          "Free document extraction is not available yet; the stored document was not changed.",
        available: false,
        mode: "free_only",
        paid_provider_allowed: false,
      });
    } catch {
      return jsonResponse(503, {
        code: "document_analysis_unavailable",
        error: "Document analysis unavailable; no document was changed.",
      });
    }
  };
}
export const handleRequest = (request: Request): Promise<Response> =>
  handler((key) => Deno.env.get(key))(request);
