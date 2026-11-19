#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QA_DEFINES="$PROJECT_ROOT/local-config/firebase-qa-dart-defines.json"
if [[ ! -f "$QA_DEFINES" ]]; then
  echo "Missing local QA defines. Restore Firebase QA config and Supabase QA publishable config first."
  exit 2
fi
cd "$PROJECT_ROOT"
flutter build ios --debug --flavor qa-free --no-codesign \
  --dart-define-from-file="$QA_DEFINES" \
  --dart-define=IOS_QA_DISABLE_PUSH=true
open "$PROJECT_ROOT/ios/Runner.xcworkspace"
echo "QA iOS app built without code signing; select the qa-free scheme and your Personal Team in Xcode to install on iPhone."
