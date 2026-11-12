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

When Supabase is configured but the shared state row does not exist, the app imports the current local JSON file if it exists. Otherwise it starts with empty owner credentials and displays a first-owner setup screen; no public default password is shipped. The app does not automatically overwrite an existing Supabase state row.

Before switching the live app:
1. Sign in to the current live app as owner.
2. Open **Settings → Backup**, download the JSON backup, and keep a copy outside Streamlit.
3. Configure all required Streamlit Secrets before merging/deploying.
4. After the upgraded app starts and the first owner is set up, open **Settings → Backup**, upload the saved JSON, confirm the restore, and wait for the success message.
5. Verify the invoice count, worker list, daily archive, and monthly archive before using the new app for live transactions.

Legacy plaintext passwords in imported JSON backups are upgraded to salted PBKDF2 hashes before the restored data is saved to Supabase.

Production startup now requires Supabase credentials. It will stop with a setup message instead of silently falling back to ephemeral local JSON storage. For isolated local development only, set `SABIHA_ALLOW_LOCAL_STORAGE=true` to explicitly enable the JSON fallback. Do not set this flag on Streamlit Cloud.

The sidebar's refresh action forces a new read from Supabase. The dashboard and live order screen also refresh their shared state every five seconds. If two sessions edit at once, the version check blocks a stale save rather than overwriting newer work.

## Deployment

This branch is not the Streamlit production branch. Review and test it before merging into `main`. The current live Streamlit app URL remains `https://sabiha-auto.streamlit.app`.

For Streamlit Cloud, set the main file path to `app.py` (the compatibility entry point that launches `sabiha_hub_app.py` on every rerun). You may also point Streamlit directly to `sabiha_hub_app.py`.

## Remaining Supabase Auth hardening

The Supabase security advisor still reports leaked-password protection as disabled for Supabase Auth users (including the separate Flutter app). Enable it in Supabase Dashboard under Authentication security/password protection. This setting is not controlled by the Streamlit service-role integration.

## Optional AI business advisor

The owner-only `🧠 مساعد Sabiha الذكي` page uses the OpenAI Responses API. Add an API key under the `[openai]` section in Streamlit Cloud Secrets (see `STREAMLIT_SECRETS.example.toml`). The model defaults to `gpt-6-luna` and can be changed with the `model` setting. The assistant runs only when the owner clicks its analyze button; it does not run automatically. It receives aggregate business figures only—customer names, phone numbers, emails, and license plates are not sent. OpenAI API usage is billed separately from ChatGPT subscriptions; review current rates at https://platform.openai.com/pricing/.

## First-owner bootstrap protection

Because the Streamlit app may be publicly reachable, the first-owner setup form is locked unless a private bootstrap token is configured. Add `bootstrap.owner_setup_token` to Streamlit Cloud Secrets before first launch. Generate a long random value locally (for example, with Python's `secrets.token_urlsafe(32)`) and keep it private. Enter it only in the first-owner setup screen. After the owner account is created, this token is no longer requested. Never commit or send the token in chat.
