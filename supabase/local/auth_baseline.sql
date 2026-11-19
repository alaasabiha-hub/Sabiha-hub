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
