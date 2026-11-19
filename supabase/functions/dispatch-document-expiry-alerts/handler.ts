import "jsr:@supabase/functions-js/edge-runtime.d.ts";

type Json = Record<string, unknown>;
type Alert = {
  alert_id: string;
  document_id: string;
  title: string;
  category: string;
  expires_at: string;
  days_before_expiry: number;
};
type Device = {
  token_id: string;
  user_id: string;
  device_token: string;
  locale: string;
};
const scope = "https://www.googleapis.com/auth/firebase.messaging";
const tokenUrl = "https://oauth2.googleapis.com/token";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-document-alert-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
function b64url(bytes: Uint8Array): string {
  let value = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    value += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}
function b64json(value: Json): string {
  return b64url(new TextEncoder().encode(JSON.stringify(value)));
}
function equalSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}
async function json<T>(url: string, init: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    signal: init.signal ?? AbortSignal.timeout(15000),
  });
  const raw = await response.text();
  if (!response.ok) {
    throw new Error(
      `Request failed (${response.status}): ${raw.slice(0, 240)}`,
    );
  }
  return raw ? JSON.parse(raw) as T : undefined as T;
}
function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}
function headers(key: string): Headers {
  const result = new Headers({
    apikey: key,
    "Content-Type": "application/json",
    Accept: "application/json",
  });
  if (!key.startsWith("sb_secret_")) {
    result.set("Authorization", `Bearer ${key}`);
  }
  return result;
}
async function firebaseToken(account: Json): Promise<string> {
  const email = String(account.client_email || ""),
    pem = String(account.private_key || "");
  if (!email || !pem) {
    throw new Error("Firebase service account is incomplete.");
  }
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64json({ alg: "RS256", typ: "JWT" })}.${
    b64json({ iss: email, scope, aud: tokenUrl, iat: now, exp: now + 3600 })
  }`;
  const keyBytes = Uint8Array.from(
    atob(
      pem.replace("-----BEGIN PRIVATE KEY-----", "").replace(
        "-----END PRIVATE KEY-----",
        "",
      ).replaceAll(/\s/g, ""),
    ),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const assertion = `${unsigned}.${b64url(signature)}`;
  const token = await json<{ access_token: string }>(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  return token.access_token;
}
function messageFor(
  alert: Alert,
  locale: string,
): { title: string; body: string } {
  const title = alert.title;
  const days = alert.days_before_expiry;
  if (locale === "en") {
    return {
      title: "Document renewal reminder",
      body: days < 0
        ? `${title} expired. Please renew it.`
        : days === 0
        ? `${title} expires today.`
        : `${title} expires in ${days} days.`,
    };
  }
  return {
    title: "تذكير بتجديد مستند",
    body: days < 0
      ? `انتهت صلاحية ${title}. يرجى تجديده.`
      : days === 0
      ? `تنتهي صلاحية ${title} اليوم.`
      : `تنتهي صلاحية ${title} خلال ${days} يومًا.`,
  };
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { error: "Method not allowed." });
  }
  const configured = Deno.env.get("DOCUMENT_ALERT_DISPATCH_SECRET") || "";
  if (
    !configured ||
    !equalSecret(
      request.headers.get("x-document-alert-secret") || "",
      configured,
    )
  ) return reply(401, { error: "Unauthorized." });

  const base = Deno.env.get("SUPABASE_URL") || "";
  const key = serviceKey();
  const projectId = Deno.env.get("FIREBASE_PROJECT_ID") || "";
  let account: Json;
  try {
    account = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "");
  } catch {
    return reply(503, { error: "Firebase messaging is not configured." });
  }
  if (!base || !key || !projectId) {
    return reply(503, { error: "Document alert delivery is not configured." });
  }

  const h = headers(key);
  const rest = (path: string, init: RequestInit = {}) =>
    json<unknown>(`${base}/rest/v1/${path}`, {
      ...init,
      headers: new Headers([...h, ...new Headers(init.headers)]),
    });
  try {
    const owners = await rest(
      "staff_profiles?select=user_id&role=eq.owner&is_active=eq.true",
    ) as { user_id: string }[];
    const ownerIds = [...new Set(owners.map((owner) => owner.user_id))];
    let devices: Device[] = [];
    if (ownerIds.length) {
      const filter = `(${ownerIds.join(",")})`;
      devices = await rest(
        `push_device_tokens?select=token_id,user_id,device_token,locale&audience=eq.staff&is_active=eq.true&user_id=in.${
          encodeURIComponent(filter)
        }`,
      ) as Device[];
    }
    if (!devices.length) {
      return reply(200, {
        claimed: 0,
        sent: 0,
        failed: 0,
        reason: "No owner push device is registered.",
      });
    }
    const access = devices.length ? await firebaseToken(account) : "";
    const alerts = await rest("rpc/claim_due_business_document_alerts", {
      method: "POST",
      body: JSON.stringify({
        p_today: new Date().toISOString().slice(0, 10),
        p_limit: 100,
      }),
    }) as Alert[];
    if (!alerts.length) return reply(200, { claimed: 0, sent: 0, failed: 0 });
    let sent = 0, failed = 0;
    for (const alert of alerts) {
      const eligible = devices.filter((device) =>
        ownerIds.includes(device.user_id)
      );
      let accepted = 0;
      let failure = eligible.length
        ? "All owner devices rejected the alert."
        : "No active owner push device is registered.";
      for (const device of eligible) {
        const copy = messageFor(alert, device.locale);
        try {
          const response = await fetch(
            `https://fcm.googleapis.com/v1/projects/${
              encodeURIComponent(projectId)
            }/messages:send`,
            {
              method: "POST",
              signal: AbortSignal.timeout(15000),
              headers: {
                Authorization: `Bearer ${access}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                message: {
                  token: device.device_token,
                  notification: copy,
                  data: {
                    type: "business_document_expiry",
                    document_id: alert.document_id,
                    deep_link: "/business-documents",
                    expires_at: alert.expires_at,
                  },
                  android: {
                    priority: "HIGH",
                    notification: {
                      click_action: "FLUTTER_NOTIFICATION_CLICK",
                    },
                  },
                  apns: { payload: { aps: { sound: "default" } } },
                },
              }),
            },
          );
          if (response.ok) accepted++;
          else {
            const detail = await response.text();
            failure = `FCM ${response.status}: ${detail.slice(0, 200)}`;
            if (detail.includes("UNREGISTERED")) {
              const patchHeaders = new Headers(h);
              patchHeaders.set("Prefer", "return=minimal");
              await json(
                `${base}/rest/v1/push_device_tokens?token_id=eq.${device.token_id}`,
                {
                  method: "PATCH",
                  headers: patchHeaders,
                  body: JSON.stringify({ is_active: false }),
                },
              ).catch(() => undefined);
            }
          }
        } catch {
          failure =
            "FCM connection failed or timed out; delivery could not be confirmed.";
        }
      }
      const delivered = accepted > 0;
      await rest("rpc/finish_business_document_alert", {
        method: "POST",
        body: JSON.stringify({
          p_alert_id: alert.alert_id,
          p_sent: delivered,
          p_error: delivered ? null : failure,
        }),
      });
      if (delivered) sent++;
      else failed++;
    }
    return reply(200, { claimed: alerts.length, sent, failed });
  } catch (error) {
    return reply(500, {
      error: error instanceof Error ? error.message : "Alert delivery failed.",
    });
  }
}

export { firebaseToken, headers, json, equalSecret, serviceKey };
