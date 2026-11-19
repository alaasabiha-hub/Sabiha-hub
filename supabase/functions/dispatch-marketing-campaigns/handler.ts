import { customerPushDeliveryEnabled } from "../_shared/customer-push-gate.ts";
import { customerInAppCampaignDeliveryEnabled } from "../_shared/customer-in-app-campaign-gate.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_AUDIENCE = "https://oauth2.googleapis.com/token";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-marketing-dispatch-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Json = Record<string, unknown>;
type Campaign = {
  campaign_id: string;
  title: string;
  body: string;
  title_en: string | null;
  body_en: string | null;
  image_url: string | null;
  deep_link: string;
  offer_id: string | null;
  target_segment: Json;
};
type Recipient = {
  customer_id: string;
  created_at?: string;
  customers?: { created_at?: string } | null;
  marketing_push_enabled?: boolean;
  marketing_in_app_enabled?: boolean;
};
type DeviceToken = {
  token_id: string;
  user_id: string;
  device_token: string;
  locale: string;
};

let cachedFcmToken = "";
let cachedFcmTokenExpiresAt = 0;

function json(status: number, data: Json): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}

function base64UrlJson(value: Json): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function secureEquals(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return difference === 0;
}

function getServiceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}

function serviceHeaders(
  serviceKey: string,
  extra: HeadersInit = {},
): HeadersInit {
  const headers = new Headers(extra);
  headers.set("apikey", serviceKey);
  if (!serviceKey.startsWith("sb_secret_")) {
    headers.set("Authorization", `Bearer ${serviceKey}`);
  }
  headers.set("Content-Type", "application/json");
  headers.set("Accept", "application/json");
  return headers;
}

async function requestJson<T>(url: string, init: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    signal: init.signal ?? AbortSignal.timeout(15000),
  });
  const raw = await response.text();
  if (!response.ok) {
    throw new Error(
      `Backend request failed (${response.status}): ${raw.slice(0, 300)}`,
    );
  }
  return raw ? JSON.parse(raw) as T : undefined as T;
}

async function rest<T>(
  baseUrl: string,
  headers: HeadersInit,
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const combinedHeaders = new Headers(headers);
  new Headers(init.headers).forEach((value, key) =>
    combinedHeaders.set(key, value)
  );
  return await requestJson<T>(`${baseUrl}/rest/v1/${path}`, {
    ...init,
    headers: combinedHeaders,
  });
}

async function pages<T>(
  baseUrl: string,
  headers: HeadersInit,
  path: string,
): Promise<T[]> {
  const output: T[] = [];
  for (let offset = 0; offset < 10000; offset += 1000) {
    const page = await rest<T[]>(baseUrl, headers, path, {
      headers: { Range: `${offset}-${offset + 999}` },
    });
    output.push(...page);
    if (page.length < 1000) break;
  }
  return output;
}

function query(values: Record<string, string>): string {
  return new URLSearchParams(values).toString();
}

function readConsentPreferencePath(
  pushEnabled: boolean,
  inAppEnabled: boolean,
): string {
  const channelFilter = pushEnabled && inAppEnabled
    ? "&or=(marketing_push_enabled.eq.true,marketing_in_app_enabled.eq.true)"
    : pushEnabled
    ? "&marketing_push_enabled=eq.true"
    : "&marketing_in_app_enabled=eq.true";
  return `customer_marketing_preferences?${
    query({
      select:
        "customer_id,marketing_push_enabled,marketing_in_app_enabled,customers!inner(created_at)",
    })
  }${channelFilter}`;
}

async function eligibleCustomers(
  baseUrl: string,
  headers: HeadersInit,
  campaign: Campaign,
  pushEnabled: boolean,
  inAppEnabled: boolean,
): Promise<string[]> {
  const preferences = await pages<Recipient>(
    baseUrl,
    headers,
    readConsentPreferencePath(pushEnabled, inAppEnabled),
  );
  const consented = new Set(preferences.map((row) => row.customer_id));
  const segment = campaign.target_segment || {};
  const type = typeof segment.type === "string" ? segment.type : "all";

  if (type === "all") return [...consented];
  if (type === "selected") {
    const selected = Array.isArray(segment.customer_ids)
      ? new Set(
        segment.customer_ids.filter((id): id is string =>
          typeof id === "string"
        ),
      )
      : new Set<string>();
    return [...consented].filter((id) => selected.has(id));
  }
  if (type === "new_customers") {
    const days = Number.isFinite(Number(segment.days))
      ? Math.max(1, Math.min(365, Number(segment.days)))
      : 30;
    const cutoff = new Date(Date.now() - days * 86400000).toISOString();
    return preferences
      .filter((row) => (row.customers?.created_at || "") >= cutoff)
      .map((row) => row.customer_id);
  }
  if (type === "inactive") {
    const days = Number.isFinite(Number(segment.days))
      ? Math.max(1, Math.min(730, Number(segment.days)))
      : 45;
    const cutoff = new Date(Date.now() - days * 86400000).toISOString();
    const sales = await pages<
      { customer_id: string; business_invoices: { issued_at: string }[] }
    >(
      baseUrl,
      headers,
      `business_orders?${
        query({
          select: "customer_id,business_invoices!inner(issued_at)",
          "business_invoices.status": "eq.active",
        })
      }`,
    );
    const lastVisit = new Map<string, string>();
    for (const sale of sales) {
      for (const invoice of sale.business_invoices || []) {
        if (!sale.customer_id) continue;
        const prior = lastVisit.get(sale.customer_id) || "";
        if (invoice.issued_at > prior) {
          lastVisit.set(sale.customer_id, invoice.issued_at);
        }
      }
    }
    return [...consented].filter((id) =>
      !lastVisit.has(id) || lastVisit.get(id)! <= cutoff
    );
  }
  if (type === "loyalty_near_reward") {
    const threshold = Math.max(
      1,
      Math.min(20, Number(segment.points_before_reward) || 2),
    );
    const balances = await pages<
      { customer_id: string; points_balance: number }
    >(
      baseUrl,
      headers,
      `business_loyalty_balances?${
        query({
          select: "customer_id,points_balance",
          points_balance: `gte.${threshold}`,
        })
      }`,
    );
    const selected = new Set(balances.map((row) => row.customer_id));
    return [...consented].filter((id) => selected.has(id));
  }
  if (type === "branch") {
    const branchId = typeof segment.branch_id === "string"
      ? segment.branch_id
      : "";
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        .test(branchId)
    ) {
      throw new Error("A valid branch is required for this campaign segment.");
    }
    const activeBranch = await rest<Json[]>(
      baseUrl,
      headers,
      `business_branches?${
        query({
          select: "branch_id",
          branch_id: `eq.${branchId}`,
          is_active: "eq.true",
          limit: "1",
        })
      }`,
    );
    if (!activeBranch.length) {
      throw new Error("Campaign branch is unavailable.");
    }
    const [orders, bookings] = await Promise.all([
      pages<{ customer_id: string | null }>(
        baseUrl,
        headers,
        `business_orders?${
          query({
            select: "customer_id",
            branch_id: `eq.${branchId}`,
            customer_id: "not.is.null",
          })
        }`,
      ),
      pages<{ customer_id: string | null }>(
        baseUrl,
        headers,
        `bookings?${
          query({
            select: "customer_id",
            branch_id: `eq.${branchId}`,
            customer_id: "not.is.null",
            status: "not.eq.cancelled",
          })
        }`,
      ),
    ]);
    const branchCustomers = new Set(
      [...orders, ...bookings]
        .map((row) => row.customer_id)
        .filter((id): id is string => typeof id === "string"),
    );
    return [...consented].filter((id) => branchCustomers.has(id));
  }
  throw new Error("Unsupported campaign audience segment.");
}

async function firebaseAccessToken(serviceAccount: Json): Promise<string> {
  if (cachedFcmToken && cachedFcmTokenExpiresAt > Date.now() + 60000) {
    return cachedFcmToken;
  }
  const email = String(serviceAccount.client_email || "");
  const privateKeyPem = String(serviceAccount.private_key || "");
  if (!email || !privateKeyPem) {
    throw new Error("Firebase service account configuration is invalid.");
  }

  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlJson({ alg: "RS256", typ: "JWT" });
  const claims = base64UrlJson({
    iss: email,
    scope: FCM_SCOPE,
    aud: TOKEN_AUDIENCE,
    iat: now,
    exp: now + 3600,
  });
  const unsigned = `${header}.${claims}`;
  const encodedKey = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replaceAll(/\s/g, "");
  const keyBytes = Uint8Array.from(
    atob(encodedKey),
    (character) => character.charCodeAt(0),
  );
  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      signingKey,
      new TextEncoder().encode(unsigned),
    ),
  );
  const assertion = `${unsigned}.${base64Url(signature)}`;
  const tokenResponse = await requestJson<
    { access_token: string; expires_in: number }
  >(TOKEN_AUDIENCE, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  cachedFcmToken = tokenResponse.access_token;
  cachedFcmTokenExpiresAt = Date.now() +
    Math.max(60, tokenResponse.expires_in - 120) * 1000;
  return cachedFcmToken;
}

async function sendToDevice(
  token: string,
  campaign: Campaign,
  recipientId: string,
  locale: string,
  firebaseToken: string,
  firebaseProjectId: string,
): Promise<{ messageId?: string; errorCode?: string }> {
  const message: Json = {
    token,
    notification: {
      title: locale === "en" && campaign.title_en
        ? campaign.title_en
        : campaign.title,
      body: locale === "en" && campaign.body_en
        ? campaign.body_en
        : campaign.body,
      ...(campaign.image_url ? { image: campaign.image_url } : {}),
    },
    data: {
      type: "marketing_campaign",
      campaign_id: campaign.campaign_id,
      recipient_id: recipientId,
      deep_link: campaign.deep_link,
    },
    android: {
      priority: "HIGH",
      notification: { click_action: "FLUTTER_NOTIFICATION_CLICK" },
    },
    apns: { payload: { aps: { sound: "default" } } },
  };
  try {
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${
        encodeURIComponent(firebaseProjectId)
      }/messages:send`,
      {
        method: "POST",
        signal: AbortSignal.timeout(15000),
        headers: {
          Authorization: `Bearer ${firebaseToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ message }),
      },
    );
    const result = await response.json().catch(() => ({})) as Json;
    if (!response.ok) {
      const error = (result.error && typeof result.error === "object")
        ? result.error as Json
        : {};
      const details = Array.isArray(error.details)
        ? error.details as Json[]
        : [];
      const providerCode = typeof error.status === "string"
        ? error.status
        : "FCM_SEND_FAILED";
      if (
        providerCode === "UNREGISTERED" ||
        details.some((item) => item.errorCode === "UNREGISTERED")
      ) {
        return { errorCode: "UNREGISTERED" };
      }
      return { errorCode: providerCode.slice(0, 80) };
    }
    return {
      messageId: typeof result.name === "string" ? result.name : undefined,
    };
  } catch {
    return { errorCode: "FCM_NETWORK_ERROR" };
  }
}

async function deliverRun(
  baseUrl: string,
  headers: HeadersInit,
  runId: string,
  campaign: Campaign,
  accessToken: string,
  firebaseProjectId: string,
  pushEnabled: boolean,
  inAppEnabled: boolean,
): Promise<
  { recipients: number; accepted: number; failed: number; inApp: number }
> {
  const customerIds = await eligibleCustomers(
    baseUrl,
    headers,
    campaign,
    pushEnabled,
    inAppEnabled,
  );
  if (!customerIds.length) {
    return { recipients: 0, accepted: 0, failed: 0, inApp: 0 };
  }
  for (let offset = 0; offset < customerIds.length; offset += 500) {
    const batch = customerIds.slice(offset, offset + 500);
    if (!batch.length) continue;
    await rest<Json[]>(
      baseUrl,
      headers,
      `marketing_campaign_recipients?${
        query({ on_conflict: "run_id,customer_id" })
      }`,
      {
        method: "POST",
        headers: {
          Prefer: "resolution=ignore-duplicates,return=representation",
        },
        body: JSON.stringify(batch.map((customerId) => ({
          run_id: runId,
          campaign_id: campaign.campaign_id,
          customer_id: customerId,
        }))),
      },
    );
  }
  const recipientRows = await pages<{
    recipient_id: string;
    customer_id: string;
  }>(
    baseUrl,
    headers,
    `marketing_campaign_recipients?${
      query({
        select: "recipient_id,customer_id",
        run_id: `eq.${runId}`,
        customer_id: `in.(${customerIds.join(",")})`,
      })
    }`,
  );
  let accepted = 0;
  let failed = 0;
  let inApp = 0;
  for (const recipient of recipientRows) {
    const consent = await rest<Json[]>(
      baseUrl,
      headers,
      `customer_marketing_preferences?${
        query({
          select: "customer_id,marketing_push_enabled,marketing_in_app_enabled",
          customer_id: `eq.${recipient.customer_id}`,
          limit: "1",
        })
      }`,
    );
    const pushConsent = pushEnabled &&
      consent[0]?.marketing_push_enabled === true;
    const inAppConsent = inAppEnabled &&
      consent[0]?.marketing_in_app_enabled === true;
    if (!pushConsent && !inAppConsent) {
      await rest(
        baseUrl,
        headers,
        `marketing_campaign_recipients?recipient_id=eq.${recipient.recipient_id}`,
        {
          method: "PATCH",
          body: JSON.stringify({
            status: "suppressed",
            error_message: "Customer marketing consent is disabled.",
          }),
        },
      );
      continue;
    }
    if (inAppConsent) {
      await rest(
        baseUrl,
        headers,
        `marketing_campaign_recipients?recipient_id=eq.${recipient.recipient_id}`,
        { method: "PATCH", body: JSON.stringify({ in_app_visible: true }) },
      );
      inApp++;
    }
    if (!pushConsent) {
      await rest(
        baseUrl,
        headers,
        `marketing_campaign_recipients?recipient_id=eq.${recipient.recipient_id}`,
        {
          method: "PATCH",
          body: JSON.stringify({
            status: "in_app_only",
            device_count: 0,
            accepted_device_count: 0,
            failed_device_count: 0,
            error_message: null,
          }),
        },
      );
      continue;
    }
    const tokens = await rest<DeviceToken[]>(
      baseUrl,
      headers,
      `push_device_tokens?${
        query({
          select: "token_id,user_id,device_token,locale",
          user_id: `eq.${recipient.customer_id}`,
          audience: "eq.customer",
          is_active: "eq.true",
        })
      }`,
    );
    if (!tokens.length) {
      await rest(
        baseUrl,
        headers,
        `marketing_campaign_recipients?recipient_id=eq.${recipient.recipient_id}`,
        {
          method: "PATCH",
          body: JSON.stringify({
            status: inAppConsent ? "in_app_only" : "suppressed",
            device_count: 0,
            accepted_device_count: 0,
            failed_device_count: 0,
          }),
        },
      );
      if (!inAppConsent) continue;
      // The in-app item is delivered; no FCM device was available.
      continue;
    }

    let deviceAccepted = 0;
    let deviceFailed = 0;
    for (const device of tokens) {
      const attemptResponse = await rest<Json[]>(
        baseUrl,
        headers,
        `marketing_campaign_delivery_attempts?${
          query({ on_conflict: "recipient_id,token_id" })
        }`,
        {
          method: "POST",
          headers: {
            Prefer: "resolution=ignore-duplicates,return=representation",
          },
          body: JSON.stringify([{
            recipient_id: recipient.recipient_id,
            token_id: device.token_id,
            status: "sending",
          }]),
        },
      );
      if (!attemptResponse.length) continue;
      const sent = await sendToDevice(
        device.device_token,
        campaign,
        recipient.recipient_id,
        device.locale,
        accessToken,
        firebaseProjectId,
      );
      const attempt = {
        status: sent.messageId ? "accepted" : "failed",
        provider_message_id: sent.messageId ?? null,
        error_message: sent.errorCode ?? null,
        attempted_at: new Date().toISOString(),
      };
      await rest(
        baseUrl,
        headers,
        `marketing_campaign_delivery_attempts?recipient_id=eq.${recipient.recipient_id}&token_id=eq.${device.token_id}`,
        {
          method: "PATCH",
          body: JSON.stringify(attempt),
        },
      );
      if (sent.messageId) {
        deviceAccepted++;
      } else {
        deviceFailed++;
        if (sent.errorCode === "UNREGISTERED") {
          await rest(
            baseUrl,
            headers,
            `push_device_tokens?token_id=eq.${device.token_id}`,
            {
              method: "PATCH",
              body: JSON.stringify({
                is_active: false,
                updated_at: new Date().toISOString(),
              }),
            },
          );
        }
      }
    }

    const recipientStatus = deviceAccepted > 0 ? "accepted" : "failed";
    await rest(
      baseUrl,
      headers,
      `marketing_campaign_recipients?recipient_id=eq.${recipient.recipient_id}`,
      {
        method: "PATCH",
        body: JSON.stringify({
          status: recipientStatus,
          device_count: tokens.length,
          accepted_device_count: deviceAccepted,
          failed_device_count: deviceFailed,
          sent_at: deviceAccepted > 0 ? new Date().toISOString() : null,
          error_message: deviceAccepted > 0
            ? null
            : "No device accepted the message.",
        }),
      },
    );
    if (deviceAccepted > 0) {
      accepted++;
      await rest(baseUrl, headers, "marketing_campaign_events", {
        method: "POST",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          campaign_id: campaign.campaign_id,
          run_id: runId,
          recipient_id: recipient.recipient_id,
          customer_id: recipient.customer_id,
          event_type: "accepted",
        }),
      });
    } else {
      failed++;
    }
  }
  return { recipients: recipientRows.length, accepted, failed, inApp };
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json(405, { error: "Method not allowed." });
  }

  const configuredSecret = Deno.env.get("MARKETING_DISPATCH_SECRET") || "";
  if (
    !configuredSecret ||
    !secureEquals(
      request.headers.get("x-marketing-dispatch-secret") || "",
      configuredSecret,
    )
  ) {
    return json(401, { error: "Unauthorized scheduler request." });
  }

  const pushEnabled = customerPushDeliveryEnabled((key) => Deno.env.get(key));
  const inAppEnabled = customerInAppCampaignDeliveryEnabled((key) =>
    Deno.env.get(key)
  );
  if (!pushEnabled && !inAppEnabled) {
    return json(503, { error: "Customer campaign delivery is disabled." });
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = getServiceKey();
  if (!supabaseUrl || !serviceKey) {
    return json(503, { error: "Campaign dispatch is not configured." });
  }
  let projectId = "", accessToken = "";
  if (pushEnabled) {
    const serviceAccountRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ||
      "";
    let serviceAccount: Json;
    try {
      serviceAccount = JSON.parse(serviceAccountRaw);
    } catch {
      return json(503, { error: "Firebase messaging is not configured." });
    }
    projectId = Deno.env.get("FIREBASE_PROJECT_ID") ||
      String(serviceAccount.project_id || "");
    if (!projectId) {
      return json(503, { error: "Campaign dispatch is not configured." });
    }
    try {
      accessToken = await firebaseAccessToken(serviceAccount);
    } catch {
      return json(503, {
        error: "Could not authorize the Firebase messaging connection.",
      });
    }
  }

  const headers = serviceHeaders(serviceKey);
  try {
    const runs = await rest<{ run_id: string; campaign_id: string }[]>(
      supabaseUrl,
      headers,
      "rpc/claim_due_marketing_campaigns",
      {
        method: "POST",
        body: JSON.stringify({ p_now: new Date().toISOString(), p_limit: 25 }),
      },
    );
    const results: Json[] = [];
    for (const run of runs) {
      try {
        const campaigns = await rest<Campaign[]>(
          supabaseUrl,
          headers,
          `marketing_campaigns?${
            query({
              select:
                "campaign_id,title,body,title_en,body_en,image_url,deep_link,offer_id,target_segment",
              campaign_id: `eq.${run.campaign_id}`,
              limit: "1",
            })
          }`,
        );
        const campaign = campaigns[0];
        if (!campaign) throw new Error("Campaign record is missing.");
        const counts = await deliverRun(
          supabaseUrl,
          headers,
          run.run_id,
          campaign,
          accessToken,
          projectId,
          pushEnabled,
          inAppEnabled,
        );
        const runStatus = counts.accepted > 0 || counts.inApp > 0
          ? "sent"
          : "failed";
        await rest(
          supabaseUrl,
          headers,
          "rpc/finish_marketing_campaign_run_with_in_app",
          {
            method: "POST",
            body: JSON.stringify({
              p_run_id: run.run_id,
              p_status: runStatus,
              p_recipient_count: counts.recipients,
              p_accepted_count: counts.accepted,
              p_failed_count: counts.failed,
              p_in_app_count: counts.inApp,
              p_error_message: counts.accepted > 0 || counts.inApp > 0
                ? null
                : "No eligible device accepted this campaign.",
            }),
          },
        );
        results.push({
          run_id: run.run_id,
          campaign_id: run.campaign_id,
          ...counts,
          status: runStatus,
        });
      } catch (error) {
        await rest(
          supabaseUrl,
          headers,
          "rpc/finish_marketing_campaign_run_with_in_app",
          {
            method: "POST",
            body: JSON.stringify({
              p_run_id: run.run_id,
              p_status: "failed",
              p_recipient_count: 0,
              p_accepted_count: 0,
              p_failed_count: 0,
              p_in_app_count: 0,
              p_error_message: error instanceof Error
                ? error.message
                : "Campaign dispatch failed.",
            }),
          },
        ).catch(() => undefined);
        results.push({
          run_id: run.run_id,
          campaign_id: run.campaign_id,
          status: "failed",
        });
      }
    }
    return json(200, { runs: results.length, results });
  } catch (error) {
    return json(500, {
      error: error instanceof Error
        ? error.message
        : "Campaign dispatch failed.",
    });
  }
}
