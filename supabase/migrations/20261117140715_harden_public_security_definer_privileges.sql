-- Supabase's standard default ACL can give anon direct mutation rights on
-- objects created by migrations. Public read access remains policy-controlled;
-- anonymous writes are not part of this app's booking, catalog or loyalty flows.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA public FROM anon;

-- Keep future public tables and RPCs closed to anonymous clients by default.
-- Authenticated RPC grants remain unchanged; migrations should explicitly
-- grant anon only for deliberately public endpoints.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
-- PUBLIC's built-in EXECUTE default is global; a schema-only REVOKE cannot
-- subtract it, so remove it globally for future postgres-owned functions.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- Internal Auth/trigger handlers are not RPC endpoints. Trigger execution
-- remains attached to its existing triggers; only direct API execution is cut.
DO $triggers$
BEGIN
  IF to_regprocedure('public.handle_new_auth_user()') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.handle_new_auth_user() FROM PUBLIC, anon, authenticated';
  END IF;
  IF to_regprocedure('public.sync_customer_email_verified()') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.sync_customer_email_verified() FROM PUBLIC, anon, authenticated';
  END IF;
  IF to_regprocedure('public.restore_cancelled_product_order_stock()') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.restore_cancelled_product_order_stock() FROM PUBLIC, anon, authenticated';
  END IF;
END
$triggers$;

-- These service-only loyalty finalizers must never be callable by API clients.
REVOKE ALL ON FUNCTION public.finalize_service_loyalty(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_service_loyalty(uuid, uuid, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.reverse_service_loyalty(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_service_loyalty(uuid, uuid, text)
  TO service_role;

-- Preserve the legacy authenticated checkout overload while closing its anon
-- grant, which was reintroduced by Supabase's default function ACL.
REVOKE ALL ON FUNCTION public.place_customer_product_order(jsonb, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_customer_product_order(jsonb, uuid, text)
  TO authenticated;
