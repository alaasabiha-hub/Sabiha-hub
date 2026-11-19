-- The inbox actor guard uses a row lock so a session/customer boundary cannot
-- change while the list query is being assembled. PostgreSQL requires a
-- VOLATILE function for SELECT ... FOR SHARE, so align QA with the local source.
alter function private.list_my_marketing_notifications() volatile;

notify pgrst, 'reload schema';
