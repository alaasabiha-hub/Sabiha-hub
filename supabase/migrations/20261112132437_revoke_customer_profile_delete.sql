-- Prevent customer clients from deleting their own profile rows.
REVOKE DELETE ON TABLE public.customers FROM authenticated;
