-- Applied to the Sabiha Hub Supabase project.
-- Customer profiles are provisioned by the auth.users trigger.
-- Customer clients may read their own profile, but must not write
-- profile identity, verification, or legacy password fields directly.
REVOKE INSERT, UPDATE ON TABLE public.customers FROM authenticated;
GRANT SELECT ON TABLE public.customers TO authenticated;
