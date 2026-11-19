begin;
alter table public.business_catalog_items add column image_url text check(image_url is null or(length(image_url)<=2048 and image_url ~ '^https://[^[:space:]]+$'));
-- Sensitive catalogue changes are owner-only even through a SECURITY DEFINER
-- adapter. Stock-only mutations retain their existing checkout/refund guards.
create function private.guard_owner_catalog_definition()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if auth.uid()is null then return new;end if;
 if tg_op='UPDATE'and(to_jsonb(new)-array['stock_quantity','updated_at'])is not distinct from(to_jsonb(old)-array['stock_quantity','updated_at'])then return new;end if;
 perform private.require_owner_tax_branch(new.branch_id);
 if tg_op='UPDATE'and old.branch_id is distinct from new.branch_id then perform private.require_owner_tax_branch(old.branch_id);end if;
 return new;end$$;
revoke all on function private.guard_owner_catalog_definition()from public,anon,authenticated,service_role;
create trigger guard_owner_catalog_definition before insert or update on public.business_catalog_items for each row execute function private.guard_owner_catalog_definition();
create policy owner_catalog_definition_insert on public.business_catalog_items as restrictive for insert to authenticated with check(private.active_staff_role()='owner'and private.has_live_invoice_session());
create policy owner_catalog_definition_update on public.business_catalog_items as restrictive for update to authenticated using(private.active_staff_role()='owner'and private.has_live_invoice_session())with check(private.active_staff_role()='owner'and private.has_live_invoice_session());
CREATE OR REPLACE FUNCTION private.get_cashier_cart_context(p_branch uuid, p_search text, p_after uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;items jsonb;staff jsonb;rules private.cashier_tax_rules;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_search is null or length(p_search)>120 then raise exception 'Valid search required'using errcode='22023';end if;
 select *into rules from private.cashier_tax_rules where branch_id=p_branch;
 select coalesce(jsonb_agg(to_jsonb(x)order by item_id),'[]')into items from(select item_id,item_type,name,name_en,price,stock_quantity,image_url from public.business_catalog_items where branch_id=p_branch and is_active and(p_after is null or item_id>p_after)and(name ilike'%'||p_search||'%'or name_en ilike'%'||p_search||'%')order by item_id limit 101)x;
 select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')into staff from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and e.currency='EGP'and e.starts_on<=current_date and(e.ends_on is null or e.ends_on>=current_date)and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=p_branch));
 return jsonb_build_object('items',case when jsonb_array_length(items)>100 then items-100 else items end,'has_more',jsonb_array_length(items)>100,'staff',staff,'tax_rules',coalesce(rules.rules,'[]'),'tax_rules_version',coalesce(rules.version,0),'owner',private.active_staff_role()='owner','can_discount',private.active_staff_role()in('owner','manager')or exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'invoice_discount'='true'),'price_basis','exclusive','quote_only',true,'can_issue',false);
end$function$;
notify pgrst,'reload schema';commit;
