#!/usr/bin/env python3
"""Validate and install the owner's Firebase QA client configuration locally.

The Firebase client values are used only as Flutter compile-time defines.
This script never prints configuration values or touches Firebase/Supabase APIs.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS = Path.home() / "Downloads"
EXPECTED_PROJECT = "sabiha-hub-qa"
EXPECTED_APP_ID = "com.sabihahub.app"


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"Firebase QA config not prepared: {message}")


def main() -> None:
    android_source = DOWNLOADS / "google-services.json"
    ios_source = DOWNLOADS / "GoogleService-Info.plist"
    supabase_source = ROOT / "local-config/supabase-qa.local.json"
    if not android_source.is_file() or not ios_source.is_file():
        fail("expected files were not found in ~/Downloads")
    if not supabase_source.is_file():
        fail("QA Supabase client config is missing from local-config/supabase-qa.local.json")

    try:
        android_doc = json.loads(android_source.read_text(encoding="utf-8"))
        ios_doc = plistlib.loads(ios_source.read_bytes())
        project = android_doc["project_info"]["project_id"]
        sender_id = android_doc["project_info"]["project_number"]
        clients = android_doc["client"]
        android_client = next(
            client
            for client in clients
            if client["client_info"]["android_client_info"]["package_name"]
            == EXPECTED_APP_ID
        )
        android_app_id = android_client["client_info"]["mobilesdk_app_id"]
        android_api_key = android_client["api_key"][0]["current_key"]
        ios_project = ios_doc["PROJECT_ID"]
        ios_sender_id = ios_doc["GCM_SENDER_ID"]
        ios_bundle_id = ios_doc["BUNDLE_ID"]
        ios_app_id = ios_doc["GOOGLE_APP_ID"]
        ios_api_key = ios_doc["API_KEY"]
        supabase_doc = json.loads(supabase_source.read_text(encoding="utf-8"))
        supabase_url = supabase_doc["SUPABASE_URL"]
        supabase_key = supabase_doc["SUPABASE_PUBLISHABLE_KEY"]
    except (KeyError, IndexError, StopIteration, TypeError, ValueError) as exc:
        fail(f"required Firebase fields are missing or malformed ({type(exc).__name__})")

    if project != EXPECTED_PROJECT or ios_project != EXPECTED_PROJECT:
        fail("the files do not both belong to the expected Firebase QA project")
    if ios_project != project or ios_sender_id != sender_id:
        fail("Android and iOS config files refer to different Firebase projects")
    if ios_bundle_id != EXPECTED_APP_ID:
        fail("the iOS bundle ID does not match the approved application ID")
    if not android_app_id.startswith(f"1:{sender_id}:android:"):
        fail("Android Firebase app ID does not match the configured sender")
    if not ios_app_id.startswith(f"1:{sender_id}:ios:"):
        fail("iOS Firebase app ID does not match the configured sender")
    if not android_api_key or not ios_api_key or not android_app_id or not ios_app_id:
        fail("one or more Firebase client identifiers are empty")
    parsed_supabase_url = urlparse(supabase_url)
    if (
        parsed_supabase_url.scheme != "https"
        or parsed_supabase_url.hostname != "aspijgoujajgyfgvdcav.supabase.co"
        or parsed_supabase_url.path not in ("", "/")
        or parsed_supabase_url.query
        or parsed_supabase_url.fragment
    ):
        fail("Supabase URL is not the dedicated QA project")
    if not isinstance(supabase_key, str) or not supabase_key.startswith("sb_publishable_"):
        fail("only the QA publishable Supabase key is allowed; secret/service keys are rejected")

    target_android = ROOT / "android/app/google-services.json"
    target_ios = ROOT / "ios/Runner/GoogleService-Info.plist"
    target_defines = ROOT / "local-config/firebase-qa-dart-defines.json"
    defines = {
        "FIREBASE_ANDROID_API_KEY": android_api_key,
        "FIREBASE_IOS_API_KEY": ios_api_key,
        "FIREBASE_PROJECT_ID": project,
        "FIREBASE_MESSAGING_SENDER_ID": sender_id,
        "FIREBASE_ANDROID_APP_ID": android_app_id,
        "FIREBASE_IOS_APP_ID": ios_app_id,
        "FIREBASE_IOS_BUNDLE_ID": ios_bundle_id,
        "SUPABASE_URL": supabase_url.rstrip("/"),
        "SUPABASE_PUBLISHABLE_KEY": supabase_key,
        "APP_ENV": "staging",
        "ALLOW_REMOTE_STAGING": "true",
    }
    define_bytes = (json.dumps(defines, ensure_ascii=False, indent=2) + "\n").encode()
    for target, source in ((target_android, android_source), (target_ios, ios_source)):
        if target.exists() and target.read_bytes() != source.read_bytes():
            fail(f"refusing to overwrite an existing local file: {target.name}")
    if target_defines.exists():
        try:
            previous_defines = json.loads(target_defines.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            fail("refusing to overwrite an unreadable local Firebase define file")
        firebase_keys = {
            "FIREBASE_ANDROID_API_KEY",
            "FIREBASE_IOS_API_KEY",
            "FIREBASE_PROJECT_ID",
            "FIREBASE_MESSAGING_SENDER_ID",
            "FIREBASE_ANDROID_APP_ID",
            "FIREBASE_IOS_APP_ID",
            "FIREBASE_IOS_BUNDLE_ID",
        }
        if any(previous_defines.get(key) != defines[key] for key in firebase_keys):
            fail("refusing to replace Firebase defines that do not match the current QA files")
    target_android.parent.mkdir(parents=True, exist_ok=True)
    target_ios.parent.mkdir(parents=True, exist_ok=True)
    target_defines.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(android_source, target_android)
    shutil.copy2(ios_source, target_ios)
    os.chmod(target_android, 0o600)
    os.chmod(target_ios, 0o600)

    target_defines.write_bytes(define_bytes)
    os.chmod(target_defines, 0o600)
    print("Firebase QA files validated and copied locally.")
    print("Project and both app IDs match the approved QA configuration.")
    print("Native config and Flutter define files have owner-only permissions; values not displayed.")


if __name__ == "__main__":
    main()
