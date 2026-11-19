import { customerPushDeliveryEnabled } from "../_shared/customer-push-gate.ts";
import {
  equalSecret,
  firebaseToken,
  headers,
  json,
  serviceKey,
} from "../dispatch-document-expiry-alerts/handler.ts";
type Notice = {
  notification_id: string;
  customer_id: string;
  order_id: string;
  status: string;
};
type Device = { token_id: string; device_token: string; locale: string };
const labels: Record<string, string> = {
  new: "طلب جديد",
  confirmed: "تم التأكيد",
  preparing: "جاري التجهيز",
  out_for_delivery: "خرج للتوصيل",
  delivered: "تم التسليم",
  cancelled: "ملغي",
};
const reply = (status: number, value: unknown) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  const secret = Deno.env.get("ORDER_NOTIFICATION_DISPATCH_SECRET") || "";
  if (
    !secret ||
    !equalSecret(req.headers.get("x-order-notification-secret") || "", secret)
  ) return reply(401, { error: "Unauthorized" });
  if (!customerPushDeliveryEnabled((key) => Deno.env.get(key))) {
    return reply(503, { error: "Customer push delivery is disabled." });
  }
  const base = Deno.env.get("SUPABASE_URL") || "",
    key = serviceKey(),
    project = Deno.env.get("FIREBASE_PROJECT_ID") || "";
  let account: Record<string, unknown>;
  try {
    account = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "");
  } catch {
    return reply(503, { error: "Firebase not configured" });
  }
  if (!base || !key || !project) {
    return reply(503, { error: "Delivery is not configured" });
  }
  const h = headers(key);
  const rest = <T>(path: string, init: RequestInit = {}) =>
    json<T>(base + "/rest/v1/" + path, { ...init, headers: h });
  try {
    const access = await firebaseToken(account);
    const notices = await rest<Notice[]>("rpc/claim_order_notifications", {
      method: "POST",
      body: JSON.stringify({ p_limit: 100 }),
    });
    let sent = 0, failed = 0;
    for (const n of notices) {
      let accepted = 0;
      try {
        const preferences = await rest<{ order_push_enabled: boolean }[]>(
          "customer_marketing_preferences?select=order_push_enabled&customer_id=eq." +
            n.customer_id,
        );
        const devices = preferences[0]?.order_push_enabled
          ? await rest<Device[]>(
            "push_device_tokens?select=token_id,device_token,locale&audience=eq.customer&is_active=eq.true&user_id=eq." +
              n.customer_id,
          )
          : [];
        for (const d of devices) {
          try {
            const response = await fetch(
              "https://fcm.googleapis.com/v1/projects/" +
                encodeURIComponent(project) + "/messages:send",
              {
                method: "POST",
                signal: AbortSignal.timeout(15000),
                headers: {
                  Authorization: "Bearer " + access,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({
                  message: {
                    token: d.device_token,
                    notification: {
                      title: d.locale === "en" ? "Order update" : "تحديث الطلب",
                      body: d.locale === "en" ? n.status : labels[n.status],
                    },
                    data: {
                      type: "order_update",
                      notification_id: n.notification_id,
                      order_id: n.order_id,
                      deep_link: "/orders",
                    },
                    android: {
                      collapse_key: n.notification_id,
                      priority: "HIGH",
                    },
                    apns: {
                      headers: { "apns-collapse-id": n.notification_id },
                      payload: { aps: { sound: "default" } },
                    },
                  },
                }),
              },
            );
            if (response.ok) accepted++;
            else if ((await response.text()).includes("UNREGISTERED")) {
              await rest("push_device_tokens?token_id=eq." + d.token_id, {
                method: "PATCH",
                body: JSON.stringify({ is_active: false }),
              });
            }
          } catch {
            /* Keep inbox authoritative even if provider/device fails. */
          }
        }
      } catch {
        /* Mark this attempt failed without logging customer details. */
      }
      await rest(
        "customer_order_notifications?notification_id=eq." + n.notification_id,
        {
          method: "PATCH",
          body: JSON.stringify({
            push_state: accepted ? "accepted" : "failed",
          }),
        },
      );
      if (accepted) {
        sent++;
      } else failed++;
    }
    return reply(200, { claimed: notices.length, sent, failed });
  } catch {
    return reply(502, { error: "Order notification delivery failed" });
  }
}
