begin;
-- A stalled trusted worker/source lock must enter the existing retry/backoff path.
alter function private.drain_loyalty_visit_event() set lock_timeout='20s';
commit;
