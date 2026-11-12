# Sabiha Hub: Streamlit + Supabase setup

The Streamlit server reads Supabase credentials from Streamlit Secrets. The service-role key is server-side only and must never be committed to this repository or added to Flutter/browser code.

Add this in Streamlit Cloud > app > Settings > Secrets:

```toml
[supabase]
url = "https://YOUR_PROJECT_REF.supabase.co"
service_role_key = "YOUR_SERVICE_ROLE_KEY"
```

Use the URL and service-role key from the Supabase project's API settings. Do not send the service-role key in chat or put it in GitHub.

## Database tables

The Streamlit operational schema is in `supabase/sql/streamlit_business_schema.sql`. It creates server-only tables for shared app state, workers, service orders, invoices, expenses, daily closures, audit events, staff account hashes, and settings. RLS is enabled and public/anon/authenticated access is revoked; only the server-side service role is granted access.

The Streamlit app uses optimistic version checks when saving the shared state. If another session has saved newer data, the app refuses to overwrite it and asks the user to refresh.

## First connection and existing data

When Supabase is configured but the shared state row does not exist, the app imports the current local JSON file if it exists. Otherwise it starts from the app defaults. Make and verify a JSON backup before switching a live installation. The app does not automatically overwrite an existing Supabase state row.

## Deployment

This branch is not the Streamlit production branch. Review and test it before merging into `main`. The current live Streamlit app URL remains `https://sabiha-auto.streamlit.app`.
