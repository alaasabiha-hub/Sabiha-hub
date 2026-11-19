"""Prepare a separate local Supabase folder. Never links or modifies a hosted project."""
from pathlib import Path
import argparse
import re
import shutil

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('destination',type=Path)
args=parser.parse_args()
dest=args.destination.resolve()
config=dest/'supabase/config.toml'
if not config.is_file(): raise SystemExit('Initialize the separate local directory with supabase init first.')
text=config.read_text()
if 'project_id = "supabase-local"' not in text and 'project_id = "sabiha-local"' not in text:
    raise SystemExit('Refusing to modify an unrelated local project.')
text=text.replace('# auto_expose_new_tables = true','auto_expose_new_tables = false')
text=text.replace('enable_confirmations = false','enable_confirmations = true')
for name in ['dispatch-marketing-campaigns','dispatch-document-expiry-alerts','analyze-business-document','ask-business-documents','dispatch-order-notifications']:
 if f'[functions.{name}]' not in text:
  text+=f'\n[functions.{name}]\nverify_jwt = '+('false' if name.startswith('dispatch-') else 'true')+'\n'
for kind in ['confirmation','recovery']:
 if f'[auth.email.template.{kind}]' not in text:
  text+=f'\n[auth.email.template.{kind}]\nsubject = "Sabiha Hub verification code"\ncontent_path = "./supabase/templates/{kind}.html"\n'
shutil.copytree(root/'supabase/templates',dest/'supabase/templates',dirs_exist_ok=True)
config.write_text(text)
shutil.copytree(root/'supabase/functions',dest/'supabase/functions',dirs_exist_ok=True)
bootstrap=(root/'test/database/bootstrap.sql').read_text()
bootstrap=bootstrap[bootstrap.index('create table public.'):bootstrap.index('create table storage.buckets')]
# Grant lists were captured from the existing schema; remove broad local defaults first.
first_constraint=bootstrap.index('alter table public.')
bootstrap=bootstrap[:first_constraint]+'\nrevoke all on public.customers,public.vehicles,public.staff_profiles,public.bookings from anon,authenticated;\n'+bootstrap[first_constraint:]
bootstrap+='\nalter default privileges for role postgres in schema public revoke all on tables from anon,authenticated;\n'
bootstrap+=(root/'test/database/streamlit_business_schema.sql').read_text()
bootstrap+='\n'+ '\n'.join(p.read_text() for p in sorted((root/'supabase/migrations').glob('*.sql')))
bootstrap+='\n'+(root/'supabase/local/auth_baseline.sql').read_text()+'\nnotify pgrst, \'reload schema\';\n'
(dest/'bootstrap-local.sql').write_text(bootstrap)
print('Prepared separate local schema and functions; no hosted action performed.')
