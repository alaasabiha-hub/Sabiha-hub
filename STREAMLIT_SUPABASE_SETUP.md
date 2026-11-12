# Sabiha Hub: Streamlit + Supabase setup

The Streamlit server reads Supabase credentials from Streamlit Secrets. The service-role key is server-side only and must never be committed to this repository or added to Flutter/browser code.

Add this in Streamlit Cloud > app > Settings > Secrets:

```toml
[supabase]
url = "https://cujfeqsuanwxobtupxaz.supabase.co"
service_role_key = "YOUR_SERVICE_ROLE_KEY"
```

Use the URL and service-role key from the Supabase project's API settings. Do not send the service-role key in chat or put it in GitHub.

## Database tables

The Streamlit operational schema is in `supabase/sql/streamlit_business_schema.sql`. It creates server-only tables for shared app state, workers, service orders, invoices, expenses, daily closures, audit events, owner notifications, staff account hashes, and settings. RLS is enabled and public/anon/authenticated access is revoked; only the server-side service role is granted access.

The app also records order-status notifications for the owner, provides a read-only owner audit-log screen, and lets the owner configure the VAT percentage and whether invoice prices include tax. Tax remains an estimate and must be confirmed for the business jurisdiction with its accountant.\n\nThe Streamlit app uses optimistic version checks when saving the shared state. If another session has saved newer data, the app refuses to overwrite it and asks the user to refresh.

## First connection and existing data

When Supabase is configured but the shared state row does not exist, the app imports the current local JSON file if it exists. Otherwise it starts with empty owner credentials and displays a first-owner setup screen; no public default password is shipped. Make and verify a JSON backup before switching a live installation. The app does not automatically overwrite an existing Supabase state row.

## Deployment

This branch is not the Streamlit production branch. Review and test it before merging into `main`. The current live Streamlit app URL remains `https://sabiha-auto.streamlit.app`.

## Remaining Supabase Auth hardening

The Supabase security advisor still reports leaked-password protection as disabled for Supabase Auth users (including the separate Flutter app). Enable it in Supabase Dashboard under Authentication security/password protection. This setting is not controlled by the Streamlit service-role integration.
