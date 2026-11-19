begin;
-- Session IDs in immutable audit records are historical references, not FKs:
-- Supabase Auth must be able to revoke/delete ephemeral sessions. Authorization
-- still validates actual current auth.sessions rows at every protected action.
do $$declare c record;n integer:=0;begin
 for c in select conname,conkey from pg_constraint where conrelid='private.mixed_visit_groups'::regclass and confrelid='auth.sessions'::regclass and contype='f'loop
 if c.conkey<>array[(select attnum from pg_attribute where attrelid='private.mixed_visit_groups'::regclass and attname='session_id')]::smallint[]then raise exception 'Unexpected mixed visit session relationship; review before changing'using errcode='55000';end if;
 execute format('alter table private.mixed_visit_groups drop constraint %I',c.conname);n:=n+1;
 end loop;
 if n<>1 then raise exception 'Expected original session audit FK exactly once'using errcode='55000';end if;
 if exists(select 1 from pg_constraint where conrelid='private.mixed_visit_verbal_consents'::regclass and confrelid='auth.sessions'::regclass and contype='f')then raise exception 'Verbal audit must not prevent Auth session revocation'using errcode='55000';end if;
end$$;
commit;
