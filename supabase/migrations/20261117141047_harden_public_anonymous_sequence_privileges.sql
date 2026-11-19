-- Sequences are not protected by table RLS. Supabase's default ACL can grant
-- anon USAGE/UPDATE on identity and serial sequences, so close current and
-- future public sequences to anonymous API clients.
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
