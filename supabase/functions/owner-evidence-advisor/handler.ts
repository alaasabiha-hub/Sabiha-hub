import {
  answerEvidence,
  factsFrom,
  supportedQuestions,
} from "./free_assistant.ts";
/** Owner-authorized evidence only; paid provider paths are prohibited. */
type Env = (key: string) => string | undefined;
export const actions = {
  reconcile_invoices: {
    evidence: ["billed_revenue", "cash_net"],
    ar:
      "راجع مطابقة الفواتير مع سجلات التحصيل؛ الفوترة والتحصيل قياسان مختلفان.",
    en:
      "Review invoice and collection reconciliation; billing and collections are different measures.",
  },
  review_expense_records: {
    evidence: ["recorded_expenses"],
    ar: "راجع تصنيف المصروفات واكتمال مستنداتها قبل أي قرار مالي.",
    en:
      "Review expense categorization and supporting records before financial decisions.",
  },
  verify_stock_counts: {
    evidence: ["active_products", "out_of_stock_products"],
    ar: "تحقق من الجرد الفعلي وحدود إعادة الطلب قبل تغيير المشتريات.",
    en:
      "Verify physical stock counts and reorder requirements before changing purchases.",
  },
  review_appointment_workload: {
    evidence: ["bookings", "completed_bookings"],
    ar:
      "راجع المواعيد والقدرة التشغيلية؛ عدد الحجوزات وحده لا يقيس إنتاجية الموظفين.",
    en:
      "Review appointments and operating capacity; booking counts alone do not measure employee productivity.",
  },
  review_feedback_coverage: {
    evidence: ["average_review_stars"],
    ar: "راجع مدى تمثيل المراجعات وشجّع جمع ملاحظات أوسع قبل استخلاص نتائج.",
    en:
      "Review how representative the feedback is and seek broader feedback before drawing conclusions.",
  },
} as const;

async function boundedJson(
  message: Request | Response,
  limit: number,
  timeoutMs = 0,
): Promise<unknown> {
  const reader = message.body?.getReader();
  if (!reader) throw Error("Empty body");
  const deadline = timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : undefined;
  const abort = () => {
    void reader.cancel("Body read deadline exceeded");
  };
  deadline?.addEventListener("abort", abort, { once: true });
  try {
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw Error("Body too large");
      }
      chunks.push(value);
    }
    if (deadline?.aborted) throw Error("Body read deadline exceeded");
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } finally {
    deadline?.removeEventListener("abort", abort);
  }
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error("Object required");
  }
  return value as Record<string, unknown>;
}

export function handler(env: Env, fetcher: typeof fetch = fetch) {
  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get("Origin");
    // The QA build is served locally on this exact loopback origin. Keep the
    // fallback narrow so a missing env var never silently becomes wildcard
    // CORS or blocks the intended local browser QA path. A configured list
    // replaces the fallback; it is still parsed as exact origin values.
    const configuredOrigins = env("OWNER_EVIDENCE_AI_APP_ORIGIN") ??
      env("APP_ORIGIN");
    const allowed = (configuredOrigins ??
      "http://127.0.0.1:8790,http://localhost:8790").split(",").map((x) =>
      x.trim()
    ).filter(Boolean);
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    };
    const reply = (status: number, body: unknown) =>
      new Response(JSON.stringify(body), { status, headers });
    if (origin && !allowed.includes(origin)) {
      return reply(403, { code: "origin_denied" });
    }
    if (origin) {
      headers["Access-Control-Allow-Origin"] = origin;
      headers.Vary = "Origin";
    }
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          ...headers,
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers":
            "authorization, apikey, content-type, x-client-info",
        },
      });
    }
    if (request.method !== "POST") return reply(405, { code: "post_required" });
    const auth = request.headers.get("Authorization");
    if (!auth?.match(/^Bearer \S+$/)) {
      return reply(401, { code: "authentication_required" });
    }
    let body: Record<string, unknown>;
    try {
      body = object(await boundedJson(request, 2048, 2000));
      if (
        !["status", "advise", "ask"].includes(String(body.action)) ||
        !["ar", "en"].includes(String(body.language)) ||
        !/^\d{4}-\d{2}-\d{2}$/.test(String(body.from)) ||
        !/^\d{4}-\d{2}-\d{2}$/.test(String(body.to)) ||
        Object.keys(body).some((k) =>
          !["action", "language", "from", "to", "consent", "question"].includes(
            k,
          )
        ) ||
        (body.action === "ask"
          ? typeof body.question !== "string" ||
            body.question.trim().length === 0 || body.question.length > 500
          : body.question !== undefined)
      ) throw Error("Invalid request");
    } catch {
      return reply(400, { code: "invalid_request" });
    }
    const base = env("SUPABASE_URL");
    const anon = env("SUPABASE_ANON_KEY");
    if (!base || !anon) return reply(503, { code: "unavailable" });
    const signal = AbortSignal.timeout(25000);
    const h = {
      apikey: anon,
      Authorization: auth,
      "Content-Type": "application/json",
    };
    try {
      const user = await fetcher(`${base}/auth/v1/user`, {
        headers: h,
        signal,
      });
      if (!user.ok) return reply(401, { code: "authentication_required" });
      // The existing RPC checks the current database role, not JWT user_metadata.
      const response = await fetcher(
        `${base}/rest/v1/rpc/get_owner_business_insights`,
        {
          method: "POST",
          headers: h,
          signal,
          body: JSON.stringify({ p_from: body.from, p_to: body.to }),
        },
      );
      if (!response.ok) {
        return reply(
          response.status === 403 || response.status === 401 ? 403 : 503,
          { code: "owner_evidence_unavailable" },
        );
      }
      const evidence = object(await boundedJson(response, 32768));
      factsFrom(evidence);
      // Only this closed template router can answer; paid configuration is ignored.
      if (body.action === "ask") {
        const answer = answerEvidence(
          evidence,
          String(body.question),
          body.language as "ar" | "en",
        );
        if (answer) {
          return reply(200, {
            ...answer,
            period: { from: body.from, to: body.to },
            scope: "active_default_branch",
          });
        }
        return reply(503, {
          code: "free_engine_unavailable",
          reason: "unsupported_question_or_missing_evidence",
          available: false,
          paid_provider_allowed: false,
          supported_questions: supportedQuestions,
        });
      }
      return reply(body.action === "status" ? 200 : 503, {
        available: false,
        mode: "free_only",
        code: "free_engine_unavailable",
        paid_provider_allowed: false,
        ...(body.action === "status"
          ? {
            free_assistant: {
              available: factsFrom(evidence).length > 0,
              mode: "free_evidence_templates",
              supported_questions: supportedQuestions,
              execution_supported: false,
            },
          }
          : {}),
      });
    } catch {
      return reply(503, { code: "advisor_unavailable" });
    }
  };
}
