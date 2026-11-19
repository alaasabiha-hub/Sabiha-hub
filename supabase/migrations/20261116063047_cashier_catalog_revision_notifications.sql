begin;
-- Realtime publishes only a revision number, never the catalogue's financial
-- configuration. Full content is re-fetched through the existing scoped RPC.
create table public.cashier_catalog_revisions(branch_id uuid primary key references public.business_branches(branch_id),revision bigint not null check(revision>0));
alter table public.cashier_catalog_revisions enable row level security;
revoke all on public.cashier_catalog_revisions from public,anon,authenticated,service_role;
grant select on public.cashier_catalog_revisions to authenticated;
create function private.can_read_cashier_catalog_revision(p_branch uuid)returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$begin
 perform private.cashier_cart_actor(p_branch);return true;exception when sqlstate'42501'then return false;end$$;
revoke all on function private.can_read_cashier_catalog_revision(uuid)from public,anon,authenticated,service_role;
grant execute on function private.can_read_cashier_catalog_revision(uuid)to authenticated;
create policy scoped_cashier_catalog_revision on public.cashier_catalog_revisions for select to authenticated using(private.can_read_cashier_catalog_revision(branch_id));
create function private.notify_cashier_catalog_revision()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_op='UPDATE'and(to_jsonb(new)-array['stock_quantity','updated_at'])is not distinct from(to_jsonb(old)-array['stock_quantity','updated_at'])then return new;end if;
 if tg_op='DELETE'then insert into public.cashier_catalog_revisions values(old.branch_id,1)on conflict(branch_id)do update set revision=cashier_catalog_revisions.revision+1;return old;end if;
 insert into public.cashier_catalog_revisions values(new.branch_id,1)on conflict(branch_id)do update set revision=cashier_catalog_revisions.revision+1;
 if tg_op='UPDATE'and old.branch_id is distinct from new.branch_id then insert into public.cashier_catalog_revisions values(old.branch_id,1)on conflict(branch_id)do update set revision=cashier_catalog_revisions.revision+1;end if;return new;end$$;
revoke all on function private.notify_cashier_catalog_revision()from public,anon,authenticated,service_role;
create trigger notify_cashier_catalog_revision after insert or update or delete on public.business_catalog_items for each row execute function private.notify_cashier_catalog_revision();
create trigger notify_cashier_layout_revision after insert on private.owner_pos_catalog_layouts for each row execute function private.notify_cashier_catalog_revision();
do $$begin
 if not exists(select 1 from pg_publication where pubname='supabase_realtime')then create publication supabase_realtime with(publish='insert,update,delete');end if;
 if not exists(select 1 from pg_publication p where p.pubname='supabase_realtime'and p.puballtables)and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime'and schemaname='public'and tablename='cashier_catalog_revisions')then alter publication supabase_realtime add table public.cashier_catalog_revisions;end if;
end$$;
notify pgrst,'reload schema';commit;
