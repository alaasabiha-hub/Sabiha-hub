begin;
-- Eligibility uses current Cairo clock and current authorization helpers.
-- Keep original applied definition unchanged; declare fresh evaluation honestly.
alter function private.get_offline_walk_in_context(uuid) volatile;
notify pgrst,'reload schema';
commit;
