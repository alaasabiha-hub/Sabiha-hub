// Server-only, fail closed. Independent of customer/system permissions.
// Enable only after the owner-approved activation step; clients cannot set it.
export function customerPushDeliveryEnabled(read: (name: string) => string | undefined): boolean {
  return read("CUSTOMER_PUSH_DELIVERY_ENABLED") === "true";
}
