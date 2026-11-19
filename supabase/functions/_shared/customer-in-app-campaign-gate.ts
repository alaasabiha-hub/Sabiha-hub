// Server-only, fail-closed. In-app campaign insertion is separately gated
// from FCM push delivery and cannot be enabled by a client request.
export function customerInAppCampaignDeliveryEnabled(
  read: (name: string) => string | undefined,
): boolean {
  return read("CUSTOMER_IN_APP_CAMPAIGN_DELIVERY_ENABLED") === "true";
}
