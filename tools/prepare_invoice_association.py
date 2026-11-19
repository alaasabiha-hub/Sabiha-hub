"""Generate reviewable App/Universal Link files locally; never upload or deploy."""
import argparse,json,re
from pathlib import Path
from urllib.parse import urlsplit
p=argparse.ArgumentParser();p.add_argument('--origin',required=True);p.add_argument('--android-package',required=True);p.add_argument('--android-sha256',required=True);p.add_argument('--apple-team',required=True);p.add_argument('--ios-bundle',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
u=urlsplit(a.origin)
if u.scheme!='https' or not u.hostname or u.path not in ('','/') or u.query or u.fragment or u.username or u.port:raise SystemExit('An HTTPS origin with no path or credentials is required.')
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*){2,}',a.android_package) or a.android_package.startswith('com.example.'):raise SystemExit('Final Android application ID required.')
if not re.fullmatch(r'(?:[A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}',a.android_sha256):raise SystemExit('Release signing SHA256 fingerprint required.')
if not re.fullmatch(r'[A-Z0-9]{10}',a.apple_team) or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}',a.ios_bundle) or a.ios_bundle.startswith('com.example.'):raise SystemExit('Final Apple Team ID and bundle ID required.')
a.out.mkdir(parents=True,exist_ok=True)
files={
'assetlinks.json':json.dumps([{'relation':['delegate_permission/common.handle_all_urls'],'target':{'namespace':'android_app','package_name':a.android_package,'sha256_cert_fingerprints':[a.android_sha256.upper()]}}],indent=2),
'apple-app-site-association':json.dumps({'applinks':{'details':[{'appIDs':[a.apple_team+'.'+a.ios_bundle],'components':[{'/':'/','?':{'invoice':'*'},'comment':'Authenticated invoice links only'}]}]}},indent=2),
'android-invoice-intent-filter.xml':f'<intent-filter android:autoVerify="true">\n<action android:name="android.intent.action.VIEW"/>\n<category android:name="android.intent.category.DEFAULT"/>\n<category android:name="android.intent.category.BROWSABLE"/>\n<data android:scheme="https" android:host="{u.hostname}" android:path="/"/>\n</intent-filter>\n',
'invoice-link-defines.json':json.dumps({'INVOICE_PORTAL_ORIGIN':'https://'+u.hostname},indent=2),
'INSTALLATION.md':f'''Generated locally only. Review before applying. No files were uploaded.
Serve assetlinks.json and apple-app-site-association under HTTPS /.well-known/ with correct JSON content types and no authentication redirects.
Add the generated Android intent filter to MainActivity and disable Flutter's default deep-link handler when using app_links.
Add applinks:{u.hostname} to Associated Domains for the signed iOS app and set FlutterDeepLinkingEnabled=false.
Merge the generated Dart define with existing local/release defines; do not replace existing configuration.
QR content uses /?invoice=UUID. Both website and app require login plus DB authorization. Keep old invoice domains reachable if the global origin changes: issued invoice QR origins are immutable.
Verify Android App Link ownership with release signing and iPhone Universal Links on physical devices before release.
Do not publish any association file or app until final approval.
'''}
for name in files:
 if (a.out/name).exists():raise SystemExit('Output exists; choose a new review directory to preserve prior files.')
for name,value in files.items():(a.out/name).write_text(value)
print('Prepared reviewable association files locally; no deployment or project identity change.')
