create table public."customers" ("id" uuid not null,
"full_name" text not null,
"phone" text not null,
"email" text not null,
"date_of_birth" date,
"password_hash" text,
"email_verified" boolean default false not null,
"created_at" timestamp with time zone default now() not null);
create table public."vehicles" ("id" uuid default gen_random_uuid() not null,
"customer_id" uuid not null,
"brand" text not null,
"model" text not null,
"year" integer,
"color" text,
"plate_number" text not null,
"created_at" timestamp with time zone default now() not null);
create table public."staff_profiles" ("user_id" uuid not null,
"full_name" text,
"role" text default 'employee'::text not null,
"permissions" jsonb default '{}'::jsonb not null,
"is_active" boolean default true not null,
"created_at" timestamp with time zone default now() not null);
create table public."bookings" ("id" uuid default gen_random_uuid() not null,
"customer_id" uuid,
"service_name" text not null,
"vehicle_type" text,
"booking_date" date not null,
"booking_time" time without time zone not null,
"notes" text,
"status" text default 'pending'::text not null,
"created_at" timestamp with time zone default now() not null);
alter table public."bookings" add constraint "bookings_pkey" PRIMARY KEY (id);
alter table public."customers" add constraint "customers_email_key" UNIQUE (email);
alter table public."customers" add constraint "customers_phone_key" UNIQUE (phone);
alter table public."customers" add constraint "customers_pkey" PRIMARY KEY (id);
alter table public."staff_profiles" add constraint "staff_profiles_pkey" PRIMARY KEY (user_id);
alter table public."staff_profiles" add constraint "staff_profiles_role_check" CHECK ((role = ANY (ARRAY['owner'::text, 'manager'::text, 'employee'::text])));
alter table public."vehicles" add constraint "vehicles_customer_plate_unique" UNIQUE (customer_id, plate_number);
alter table public."vehicles" add constraint "vehicles_pkey" PRIMARY KEY (id);
alter table public."vehicles" add constraint "vehicles_year_valid" CHECK (((year IS NULL) OR ((year >= 1950) AND (year <= 2100))));
alter table public."bookings" add constraint "bookings_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE;
alter table public."customers" add constraint "customers_auth_user_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public."staff_profiles" add constraint "staff_profiles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public."vehicles" add constraint "vehicles_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE;
alter table public."customers" enable row level security;
alter table public."bookings" enable row level security;
alter table public."staff_profiles" enable row level security;
alter table public."vehicles" enable row level security;
create policy "Customers and owner can view bookings" on public."bookings" for SELECT to "authenticated" using (((customer_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM staff_profiles sp
  WHERE ((sp.user_id = ( SELECT auth.uid() AS uid)) AND (sp.role = 'owner'::text) AND (sp.is_active = true))))));
create policy "Customers can create own bookings" on public."bookings" for INSERT to "authenticated" with check ((customer_id = ( SELECT auth.uid() AS uid)));
create policy "Owner can delete bookings" on public."bookings" for DELETE to "authenticated" using ((EXISTS ( SELECT 1
   FROM staff_profiles sp
  WHERE ((sp.user_id = ( SELECT auth.uid() AS uid)) AND (sp.role = 'owner'::text) AND (sp.is_active = true)))));
create policy "Owner can update bookings" on public."bookings" for UPDATE to "authenticated" using ((EXISTS ( SELECT 1
   FROM staff_profiles sp
  WHERE ((sp.user_id = ( SELECT auth.uid() AS uid)) AND (sp.role = 'owner'::text) AND (sp.is_active = true))))) with check ((EXISTS ( SELECT 1
   FROM staff_profiles sp
  WHERE ((sp.user_id = ( SELECT auth.uid() AS uid)) AND (sp.role = 'owner'::text) AND (sp.is_active = true)))));
create policy "Customers can insert own profile" on public."customers" for INSERT to "authenticated" with check ((id = auth.uid()));
create policy "Customers can update own profile" on public."customers" for UPDATE to "authenticated" using ((id = auth.uid())) with check ((id = auth.uid()));
create policy "Customers can view own profile" on public."customers" for SELECT to "authenticated" using ((id = auth.uid()));
create policy "Staff can read own profile" on public."staff_profiles" for SELECT to "authenticated" using ((user_id = auth.uid()));
create policy "Customers can add own vehicles" on public."vehicles" for INSERT to "authenticated" with check ((customer_id = auth.uid()));
create policy "Customers can delete own vehicles" on public."vehicles" for DELETE to "authenticated" using ((customer_id = auth.uid()));
create policy "Customers can update own vehicles" on public."vehicles" for UPDATE to "authenticated" using ((customer_id = auth.uid())) with check ((customer_id = auth.uid()));
create policy "Customers can view own vehicles" on public."vehicles" for SELECT to "authenticated" using ((customer_id = auth.uid()));
grant DELETE on public."bookings" to "authenticated";
grant INSERT on public."bookings" to "authenticated";
grant SELECT on public."bookings" to "authenticated";
grant UPDATE on public."bookings" to "authenticated";
grant DELETE on public."bookings" to "service_role";
grant INSERT on public."bookings" to "service_role";
grant REFERENCES on public."bookings" to "service_role";
grant SELECT on public."bookings" to "service_role";
grant TRIGGER on public."bookings" to "service_role";
grant TRUNCATE on public."bookings" to "service_role";
grant UPDATE on public."bookings" to "service_role";
grant SELECT on public."customers" to "authenticated";
grant DELETE on public."customers" to "service_role";
grant INSERT on public."customers" to "service_role";
grant REFERENCES on public."customers" to "service_role";
grant SELECT on public."customers" to "service_role";
grant TRIGGER on public."customers" to "service_role";
grant TRUNCATE on public."customers" to "service_role";
grant UPDATE on public."customers" to "service_role";
grant DELETE on public."staff_profiles" to "authenticated";
grant INSERT on public."staff_profiles" to "authenticated";
grant SELECT on public."staff_profiles" to "authenticated";
grant UPDATE on public."staff_profiles" to "authenticated";
grant DELETE on public."staff_profiles" to "service_role";
grant INSERT on public."staff_profiles" to "service_role";
grant REFERENCES on public."staff_profiles" to "service_role";
grant SELECT on public."staff_profiles" to "service_role";
grant TRIGGER on public."staff_profiles" to "service_role";
grant TRUNCATE on public."staff_profiles" to "service_role";
grant UPDATE on public."staff_profiles" to "service_role";
grant DELETE on public."vehicles" to "authenticated";
grant INSERT on public."vehicles" to "authenticated";
grant SELECT on public."vehicles" to "authenticated";
grant UPDATE on public."vehicles" to "authenticated";
grant DELETE on public."vehicles" to "service_role";
grant INSERT on public."vehicles" to "service_role";
grant REFERENCES on public."vehicles" to "service_role";
grant SELECT on public."vehicles" to "service_role";
grant TRIGGER on public."vehicles" to "service_role";
grant TRUNCATE on public."vehicles" to "service_role";
grant UPDATE on public."vehicles" to "service_role";
grant INSERT ("booking_date") on public."bookings" to "authenticated";
grant SELECT ("booking_date") on public."bookings" to "authenticated";
grant UPDATE ("booking_date") on public."bookings" to "authenticated";
grant INSERT ("booking_date") on public."bookings" to "service_role";
grant REFERENCES ("booking_date") on public."bookings" to "service_role";
grant SELECT ("booking_date") on public."bookings" to "service_role";
grant UPDATE ("booking_date") on public."bookings" to "service_role";
grant INSERT ("booking_time") on public."bookings" to "authenticated";
grant SELECT ("booking_time") on public."bookings" to "authenticated";
grant UPDATE ("booking_time") on public."bookings" to "authenticated";
grant INSERT ("booking_time") on public."bookings" to "service_role";
grant REFERENCES ("booking_time") on public."bookings" to "service_role";
grant SELECT ("booking_time") on public."bookings" to "service_role";
grant UPDATE ("booking_time") on public."bookings" to "service_role";
grant INSERT ("created_at") on public."bookings" to "authenticated";
grant SELECT ("created_at") on public."bookings" to "authenticated";
grant UPDATE ("created_at") on public."bookings" to "authenticated";
grant INSERT ("created_at") on public."bookings" to "service_role";
grant REFERENCES ("created_at") on public."bookings" to "service_role";
grant SELECT ("created_at") on public."bookings" to "service_role";
grant UPDATE ("created_at") on public."bookings" to "service_role";
grant INSERT ("customer_id") on public."bookings" to "authenticated";
grant SELECT ("customer_id") on public."bookings" to "authenticated";
grant UPDATE ("customer_id") on public."bookings" to "authenticated";
grant INSERT ("customer_id") on public."bookings" to "service_role";
grant REFERENCES ("customer_id") on public."bookings" to "service_role";
grant SELECT ("customer_id") on public."bookings" to "service_role";
grant UPDATE ("customer_id") on public."bookings" to "service_role";
grant INSERT ("id") on public."bookings" to "authenticated";
grant SELECT ("id") on public."bookings" to "authenticated";
grant UPDATE ("id") on public."bookings" to "authenticated";
grant INSERT ("id") on public."bookings" to "service_role";
grant REFERENCES ("id") on public."bookings" to "service_role";
grant SELECT ("id") on public."bookings" to "service_role";
grant UPDATE ("id") on public."bookings" to "service_role";
grant INSERT ("notes") on public."bookings" to "authenticated";
grant SELECT ("notes") on public."bookings" to "authenticated";
grant UPDATE ("notes") on public."bookings" to "authenticated";
grant INSERT ("notes") on public."bookings" to "service_role";
grant REFERENCES ("notes") on public."bookings" to "service_role";
grant SELECT ("notes") on public."bookings" to "service_role";
grant UPDATE ("notes") on public."bookings" to "service_role";
grant INSERT ("service_name") on public."bookings" to "authenticated";
grant SELECT ("service_name") on public."bookings" to "authenticated";
grant UPDATE ("service_name") on public."bookings" to "authenticated";
grant INSERT ("service_name") on public."bookings" to "service_role";
grant REFERENCES ("service_name") on public."bookings" to "service_role";
grant SELECT ("service_name") on public."bookings" to "service_role";
grant UPDATE ("service_name") on public."bookings" to "service_role";
grant INSERT ("status") on public."bookings" to "authenticated";
grant SELECT ("status") on public."bookings" to "authenticated";
grant UPDATE ("status") on public."bookings" to "authenticated";
grant INSERT ("status") on public."bookings" to "service_role";
grant REFERENCES ("status") on public."bookings" to "service_role";
grant SELECT ("status") on public."bookings" to "service_role";
grant UPDATE ("status") on public."bookings" to "service_role";
grant INSERT ("vehicle_type") on public."bookings" to "authenticated";
grant SELECT ("vehicle_type") on public."bookings" to "authenticated";
grant UPDATE ("vehicle_type") on public."bookings" to "authenticated";
grant INSERT ("vehicle_type") on public."bookings" to "service_role";
grant REFERENCES ("vehicle_type") on public."bookings" to "service_role";
grant SELECT ("vehicle_type") on public."bookings" to "service_role";
grant UPDATE ("vehicle_type") on public."bookings" to "service_role";
grant SELECT ("created_at") on public."customers" to "authenticated";
grant INSERT ("created_at") on public."customers" to "service_role";
grant REFERENCES ("created_at") on public."customers" to "service_role";
grant SELECT ("created_at") on public."customers" to "service_role";
grant UPDATE ("created_at") on public."customers" to "service_role";
grant SELECT ("date_of_birth") on public."customers" to "authenticated";
grant INSERT ("date_of_birth") on public."customers" to "service_role";
grant REFERENCES ("date_of_birth") on public."customers" to "service_role";
grant SELECT ("date_of_birth") on public."customers" to "service_role";
grant UPDATE ("date_of_birth") on public."customers" to "service_role";
grant SELECT ("email") on public."customers" to "authenticated";
grant INSERT ("email") on public."customers" to "service_role";
grant REFERENCES ("email") on public."customers" to "service_role";
grant SELECT ("email") on public."customers" to "service_role";
grant UPDATE ("email") on public."customers" to "service_role";
grant SELECT ("email_verified") on public."customers" to "authenticated";
grant INSERT ("email_verified") on public."customers" to "service_role";
grant REFERENCES ("email_verified") on public."customers" to "service_role";
grant SELECT ("email_verified") on public."customers" to "service_role";
grant UPDATE ("email_verified") on public."customers" to "service_role";
grant SELECT ("full_name") on public."customers" to "authenticated";
grant INSERT ("full_name") on public."customers" to "service_role";
grant REFERENCES ("full_name") on public."customers" to "service_role";
grant SELECT ("full_name") on public."customers" to "service_role";
grant UPDATE ("full_name") on public."customers" to "service_role";
grant SELECT ("id") on public."customers" to "authenticated";
grant INSERT ("id") on public."customers" to "service_role";
grant REFERENCES ("id") on public."customers" to "service_role";
grant SELECT ("id") on public."customers" to "service_role";
grant UPDATE ("id") on public."customers" to "service_role";
grant SELECT ("password_hash") on public."customers" to "authenticated";
grant INSERT ("password_hash") on public."customers" to "service_role";
grant REFERENCES ("password_hash") on public."customers" to "service_role";
grant SELECT ("password_hash") on public."customers" to "service_role";
grant UPDATE ("password_hash") on public."customers" to "service_role";
grant SELECT ("phone") on public."customers" to "authenticated";
grant INSERT ("phone") on public."customers" to "service_role";
grant REFERENCES ("phone") on public."customers" to "service_role";
grant SELECT ("phone") on public."customers" to "service_role";
grant UPDATE ("phone") on public."customers" to "service_role";
grant INSERT ("created_at") on public."staff_profiles" to "authenticated";
grant SELECT ("created_at") on public."staff_profiles" to "authenticated";
grant UPDATE ("created_at") on public."staff_profiles" to "authenticated";
grant INSERT ("created_at") on public."staff_profiles" to "service_role";
grant REFERENCES ("created_at") on public."staff_profiles" to "service_role";
grant SELECT ("created_at") on public."staff_profiles" to "service_role";
grant UPDATE ("created_at") on public."staff_profiles" to "service_role";
grant INSERT ("full_name") on public."staff_profiles" to "authenticated";
grant SELECT ("full_name") on public."staff_profiles" to "authenticated";
grant UPDATE ("full_name") on public."staff_profiles" to "authenticated";
grant INSERT ("full_name") on public."staff_profiles" to "service_role";
grant REFERENCES ("full_name") on public."staff_profiles" to "service_role";
grant SELECT ("full_name") on public."staff_profiles" to "service_role";
grant UPDATE ("full_name") on public."staff_profiles" to "service_role";
grant INSERT ("is_active") on public."staff_profiles" to "authenticated";
grant SELECT ("is_active") on public."staff_profiles" to "authenticated";
grant UPDATE ("is_active") on public."staff_profiles" to "authenticated";
grant INSERT ("is_active") on public."staff_profiles" to "service_role";
grant REFERENCES ("is_active") on public."staff_profiles" to "service_role";
grant SELECT ("is_active") on public."staff_profiles" to "service_role";
grant UPDATE ("is_active") on public."staff_profiles" to "service_role";
grant INSERT ("permissions") on public."staff_profiles" to "authenticated";
grant SELECT ("permissions") on public."staff_profiles" to "authenticated";
grant UPDATE ("permissions") on public."staff_profiles" to "authenticated";
grant INSERT ("permissions") on public."staff_profiles" to "service_role";
grant REFERENCES ("permissions") on public."staff_profiles" to "service_role";
grant SELECT ("permissions") on public."staff_profiles" to "service_role";
grant UPDATE ("permissions") on public."staff_profiles" to "service_role";
grant INSERT ("role") on public."staff_profiles" to "authenticated";
grant SELECT ("role") on public."staff_profiles" to "authenticated";
grant UPDATE ("role") on public."staff_profiles" to "authenticated";
grant INSERT ("role") on public."staff_profiles" to "service_role";
grant REFERENCES ("role") on public."staff_profiles" to "service_role";
grant SELECT ("role") on public."staff_profiles" to "service_role";
grant UPDATE ("role") on public."staff_profiles" to "service_role";
grant INSERT ("user_id") on public."staff_profiles" to "authenticated";
grant SELECT ("user_id") on public."staff_profiles" to "authenticated";
grant UPDATE ("user_id") on public."staff_profiles" to "authenticated";
grant INSERT ("user_id") on public."staff_profiles" to "service_role";
grant REFERENCES ("user_id") on public."staff_profiles" to "service_role";
grant SELECT ("user_id") on public."staff_profiles" to "service_role";
grant UPDATE ("user_id") on public."staff_profiles" to "service_role";
grant INSERT ("brand") on public."vehicles" to "authenticated";
grant SELECT ("brand") on public."vehicles" to "authenticated";
grant UPDATE ("brand") on public."vehicles" to "authenticated";
grant INSERT ("brand") on public."vehicles" to "service_role";
grant REFERENCES ("brand") on public."vehicles" to "service_role";
grant SELECT ("brand") on public."vehicles" to "service_role";
grant UPDATE ("brand") on public."vehicles" to "service_role";
grant INSERT ("color") on public."vehicles" to "authenticated";
grant SELECT ("color") on public."vehicles" to "authenticated";
grant UPDATE ("color") on public."vehicles" to "authenticated";
grant INSERT ("color") on public."vehicles" to "service_role";
grant REFERENCES ("color") on public."vehicles" to "service_role";
grant SELECT ("color") on public."vehicles" to "service_role";
grant UPDATE ("color") on public."vehicles" to "service_role";
grant INSERT ("created_at") on public."vehicles" to "authenticated";
grant SELECT ("created_at") on public."vehicles" to "authenticated";
grant UPDATE ("created_at") on public."vehicles" to "authenticated";
grant INSERT ("created_at") on public."vehicles" to "service_role";
grant REFERENCES ("created_at") on public."vehicles" to "service_role";
grant SELECT ("created_at") on public."vehicles" to "service_role";
grant UPDATE ("created_at") on public."vehicles" to "service_role";
grant INSERT ("customer_id") on public."vehicles" to "authenticated";
grant SELECT ("customer_id") on public."vehicles" to "authenticated";
grant UPDATE ("customer_id") on public."vehicles" to "authenticated";
grant INSERT ("customer_id") on public."vehicles" to "service_role";
grant REFERENCES ("customer_id") on public."vehicles" to "service_role";
grant SELECT ("customer_id") on public."vehicles" to "service_role";
grant UPDATE ("customer_id") on public."vehicles" to "service_role";
grant INSERT ("id") on public."vehicles" to "authenticated";
grant SELECT ("id") on public."vehicles" to "authenticated";
grant UPDATE ("id") on public."vehicles" to "authenticated";
grant INSERT ("id") on public."vehicles" to "service_role";
grant REFERENCES ("id") on public."vehicles" to "service_role";
grant SELECT ("id") on public."vehicles" to "service_role";
grant UPDATE ("id") on public."vehicles" to "service_role";
grant INSERT ("model") on public."vehicles" to "authenticated";
grant SELECT ("model") on public."vehicles" to "authenticated";
grant UPDATE ("model") on public."vehicles" to "authenticated";
grant INSERT ("model") on public."vehicles" to "service_role";
grant REFERENCES ("model") on public."vehicles" to "service_role";
grant SELECT ("model") on public."vehicles" to "service_role";
grant UPDATE ("model") on public."vehicles" to "service_role";
grant INSERT ("plate_number") on public."vehicles" to "authenticated";
grant SELECT ("plate_number") on public."vehicles" to "authenticated";
grant UPDATE ("plate_number") on public."vehicles" to "authenticated";
grant INSERT ("plate_number") on public."vehicles" to "service_role";
grant REFERENCES ("plate_number") on public."vehicles" to "service_role";
grant SELECT ("plate_number") on public."vehicles" to "service_role";
grant UPDATE ("plate_number") on public."vehicles" to "service_role";
grant INSERT ("year") on public."vehicles" to "authenticated";
grant SELECT ("year") on public."vehicles" to "authenticated";
grant UPDATE ("year") on public."vehicles" to "authenticated";
grant INSERT ("year") on public."vehicles" to "service_role";
grant REFERENCES ("year") on public."vehicles" to "service_role";
grant SELECT ("year") on public."vehicles" to "service_role";
grant UPDATE ("year") on public."vehicles" to "service_role";

-- Sabiha Hub Streamlit operational data schema.
-- Tables are server-only: Streamlit uses the service-role key from deployment secrets.
-- Never place that key in source code or client-side applications.

CREATE TABLE IF NOT EXISTS public.business_app_state (
  state_id text PRIMARY KEY DEFAULT 'primary' CHECK (state_id = 'primary'),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  version bigint NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);

CREATE TABLE IF NOT EXISTS public.business_workers (
  worker_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  advance_balance numeric(12,2) NOT NULL DEFAULT 0 CHECK (advance_balance >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_orders (
  order_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number text NOT NULL UNIQUE,
  customer_name text,
  customer_phone text,
  plate_number text,
  vehicle_type text,
  service_name text NOT NULL,
  assigned_workers jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'received'
    CHECK (status IN ('received','in_progress','quality_check','completed','delivered','cancelled')),
  notes text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_invoices (
  invoice_id text PRIMARY KEY,
  order_id uuid REFERENCES public.business_orders(order_id) ON DELETE SET NULL,
  plate_number text,
  service_name text NOT NULL,
  vehicle_type text,
  total numeric(12,2) NOT NULL CHECK (total >= 0),
  discount numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  sale_type text NOT NULL DEFAULT 'service' CHECK (sale_type IN ('service','product')),
  payment_method text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','refunded','void')),
  commission_total numeric(12,2) NOT NULL DEFAULT 0,
  commission_share numeric(12,2) NOT NULL DEFAULT 0,
  workers jsonb NOT NULL DEFAULT '[]'::jsonb,
  issued_at timestamptz NOT NULL DEFAULT now(),
  created_by text
);

CREATE TABLE IF NOT EXISTS public.business_expenses (
  expense_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_date date NOT NULL DEFAULT current_date,
  category text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount >= 0),
  note text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_daily_closures (
  closure_date date PRIMARY KEY,
  summary jsonb NOT NULL,
  closed_by text NOT NULL,
  closed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_audit_log (
  audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor text NOT NULL,
  action text NOT NULL,
  entity text NOT NULL,
  entity_id text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_settings (
  setting_key text PRIMARY KEY,
  setting_value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);

CREATE TABLE IF NOT EXISTS public.business_staff_accounts (
  username text PRIMARY KEY,
  display_name text NOT NULL,
  password_hash text NOT NULL,
  role text NOT NULL CHECK (role IN ('owner','worker')),
  permissions jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.business_app_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_daily_closures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_staff_accounts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.business_app_state, public.business_workers,
  public.business_orders, public.business_invoices, public.business_expenses,
  public.business_daily_closures, public.business_audit_log,
  public.business_settings, public.business_staff_accounts
FROM anon, authenticated;

GRANT ALL ON public.business_app_state, public.business_workers,
  public.business_orders, public.business_invoices, public.business_expenses,
  public.business_daily_closures, public.business_audit_log,
  public.business_settings, public.business_staff_accounts
TO service_role;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

CREATE UNIQUE INDEX IF NOT EXISTS business_expenses_date_category_uidx
  ON public.business_expenses(expense_date, category);
CREATE INDEX IF NOT EXISTS business_orders_status_created_idx
  ON public.business_orders(status, created_at DESC);
CREATE INDEX IF NOT EXISTS business_orders_plate_created_idx
  ON public.business_orders(plate_number, created_at DESC);
CREATE INDEX IF NOT EXISTS business_invoices_issued_idx
  ON public.business_invoices(issued_at DESC);
CREATE INDEX IF NOT EXISTS business_expenses_date_idx
  ON public.business_expenses(expense_date DESC);
CREATE INDEX IF NOT EXISTS business_audit_created_idx
  ON public.business_audit_log(created_at DESC);

CREATE OR REPLACE FUNCTION public.save_business_app_state(
  p_payload jsonb,
  p_expected_version bigint,
  p_actor text
)
RETURNS TABLE(new_version bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_version bigint;
BEGIN
  SELECT s.version INTO current_version
  FROM public.business_app_state AS s
  WHERE s.state_id = 'primary'
  FOR UPDATE;

  IF current_version IS NULL THEN
    IF p_expected_version <> 0 THEN
      RAISE EXCEPTION 'STATE_VERSION_CONFLICT';
    END IF;
    INSERT INTO public.business_app_state(state_id, payload, version, updated_by)
    VALUES ('primary', p_payload, 1, p_actor);
    RETURN QUERY SELECT 1::bigint;
    RETURN;
  END IF;

  IF current_version <> p_expected_version THEN
    RAISE EXCEPTION 'STATE_VERSION_CONFLICT';
  END IF;

  UPDATE public.business_app_state AS s
  SET payload = p_payload,
      version = current_version + 1,
      updated_at = now(),
      updated_by = p_actor
  WHERE s.state_id = 'primary';

  RETURN QUERY SELECT (current_version + 1);
END;
$$;

REVOKE ALL ON FUNCTION public.save_business_app_state(jsonb, bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_business_app_state(jsonb, bigint, text)
  TO service_role;

CREATE TABLE IF NOT EXISTS public.business_notifications (
  notification_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number text NOT NULL,
  message text NOT NULL,
  status text,
  actor text NOT NULL,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.business_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_notifications FROM anon, authenticated;
GRANT ALL ON public.business_notifications TO service_role;
CREATE INDEX IF NOT EXISTS business_notifications_unread_created_idx
  ON public.business_notifications(is_read, created_at DESC);

-- Auth profile triggers captured through read-only schema inspection; local baseline only.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  INSERT INTO public.customers (
    id,
    full_name,
    phone,
    email,
    date_of_birth
  )
  VALUES (
    NEW.id,
    COALESCE(
      NULLIF(TRIM(NEW.raw_user_meta_data->>'full_name'), ''),
      'عميل جديد'
    ),
    COALESCE(
      NULLIF(TRIM(NEW.raw_user_meta_data->>'phone'), ''),
      'غير مسجل-' || NEW.id::text
    ),
    NEW.email,
    NULLIF(
      NEW.raw_user_meta_data->>'date_of_birth',
      ''
    )::date
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$function$
;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();
CREATE OR REPLACE FUNCTION public.sync_customer_email_verified()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.customers
  SET email_verified = (NEW.email_confirmed_at IS NOT NULL)
  WHERE id = NEW.id;

  RETURN NEW;
END;
$function$
;
CREATE TRIGGER on_auth_user_email_verified AFTER UPDATE OF email_confirmed_at ON auth.users FOR EACH ROW WHEN ((old.email_confirmed_at IS DISTINCT FROM new.email_confirmed_at)) EXECUTE FUNCTION sync_customer_email_verified();
