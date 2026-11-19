#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

temp_dir="$(mktemp -d)"
chmod 700 "$temp_dir"
trap 'rm -rf "$temp_dir"' EXIT
defines_file="$temp_dir/staging-defines.json"

python3 tools/staging_web_guard.py --output "$defines_file"
flutter build web --release \
  --dart-define-from-file="$defines_file" \
  --output=build/staging_web

test -s build/staging_web/index.html
test -s build/staging_web/main.dart.js
echo "Staging web artifact built at build/staging_web. It has not been uploaded or deployed."
