-- Test-only core public schema captured by read-only metadata queries on 2026-11-12.
-- Auth and Storage service tables/functions are minimal test stubs, not Supabase replacements.
create role anon; create role authenticated; create role service_role bypassrls;
create schema auth; create schema storage;
create table auth.users(
  id uuid primary key,
  email text,
  email_confirmed_at timestamptz,
  phone text,
  phone_confirmed_at timestamptz,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  deleted_at timestamptz,
  banned_until timestamptz
);
-- Minimal test-only subset of Supabase Auth sessions used by audited
-- same-session approval functions. This is not a replacement for Auth.
create table auth.sessions(
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  not_after timestamptz
);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user) $$;
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb) $$;
grant usage on schema public,auth,storage to anon,authenticated,service_role;
grant execute on all functions in schema auth to anon,authenticated,service_role;
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
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets,name text,owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;

-- Match the real Storage service base privileges; object access still depends on RLS.
grant usage on schema storage to anon,authenticated;
grant select,insert,update,delete on storage.objects to anon,authenticated;
