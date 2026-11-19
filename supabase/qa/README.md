# QA-only Supabase baseline

This schema baseline is for the isolated `sabiha-hub-qa` project only. It defines structure and RLS but inserts no customer, employee, invoice, or other business rows. It is assembled from the test-only core schema, the schema-only Streamlit definitions, and the local Auth profile-trigger baseline.

The test-only `auth` and `storage` stubs, test-created database roles, cron/Reatime shims, and fixture rows are deliberately excluded. Supabase-managed Auth, Storage, Realtime and database roles must remain managed by Supabase. Apply this baseline before the ordered files in `supabase/migrations/`; do not apply this baseline to the production project or represent it as a production migration.
