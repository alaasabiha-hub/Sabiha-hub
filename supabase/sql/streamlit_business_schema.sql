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
