-- SOURCE ONLY; load this pg_temp helper BEFORE the bundle in root's one-session
-- rollback review. Capture JSON before A/B, compare exact JSON after A/B and
-- after new fixture ROLLBACK. Emits only counts/digests, never quote/customer data.
create function pg_temp.typed_reward_auth_golden()returns jsonb language plpgsql as $$
declare v_quotes jsonb;v_invoices jsonb;v_functions jsonb;v_coverage_oid oid;
begin
 select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(jsonb_build_object('row',to_jsonb(quote),'customer_projection',private.customer_reward_quote(quote))::text,''order by quote.quote_id),'')))into v_quotes
 from private.service_reward_quotes quote where quote.owner_kind='auth_customer';
 select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(jsonb_build_object('redemption',to_jsonb(receipt)-'offline_issue_id','invoice',to_jsonb(invoice),'coverage',private.reward_invoice_coverage(invoice.invoice_id),'snapshot',private.invoice_snapshot(invoice.invoice_id))::text,''order by receipt.redemption_id),'')))into v_invoices
 from private.service_reward_redemptions receipt join public.business_invoices invoice on invoice.invoice_id=receipt.invoice_id where receipt.owner_kind='auth_customer';
 v_coverage_oid:=coalesce(to_regprocedure('private.reward_invoice_coverage_auth_before_offline_issuer(text)'),to_regprocedure('private.reward_invoice_coverage(text)'));
 select jsonb_object_agg(name,hash)into v_functions from(
 select signature name,encode(extensions.digest(proc.prosrc,'sha256'),'hex')hash from unnest(array['private.quote_service_reward(uuid,uuid,uuid,uuid,date,time without time zone,uuid,uuid,text)','private.place_customer_reward_booking(uuid,uuid,text,boolean,boolean)','private.sync_customer_rewards(uuid)','private.reward_credit_terms(uuid,uuid)','private.customer_reward_quote(private.service_reward_quotes)'])signature join pg_proc proc on proc.oid=to_regprocedure(signature)
 union all select 'auth_coverage_body',encode(extensions.digest(prosrc,'sha256'),'hex')from pg_proc where oid=v_coverage_oid)x;
 assert(v_quotes->>'count')::integer>0 and(v_invoices->>'count')::integer>0,'Require actual nonempty old Auth golden fixtures';
 return jsonb_build_object('all_auth_quotes',v_quotes,'all_auth_coverage_invoices',v_invoices,'auth_function_bodies',v_functions);
end$$;
