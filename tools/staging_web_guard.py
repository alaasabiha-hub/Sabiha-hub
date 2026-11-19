"""Fail-closed config builder for an isolated Flutter Web staging build."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
from urllib.parse import urlsplit


class StagingConfigError(ValueError):
    pass


def _host(value: str, *, label: str) -> str:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise StagingConfigError(f"{label} is malformed") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or port is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or not parsed.hostname.endswith(".supabase.co")
    ):
        raise StagingConfigError(f"{label} must be a bare HTTPS Supabase project URL")
    return parsed.hostname.lower()


def _is_publishable_key(value: str) -> bool:
    if value.startswith("sb_publishable_"):
        return True
    if value.startswith("sb_secret_"):
        return False
    parts = value.split(".")
    if len(parts) != 3:
        return False
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (ValueError, UnicodeError, json.JSONDecodeError):
        return False
    return isinstance(claims, dict) and claims.get("role") == "anon"


def make_defines(staging_url: str, staging_key: str, production_url: str) -> dict[str, str]:
    qa_host = _host(staging_url, label="STAGING_SUPABASE_URL")
    production_host = _host(production_url, label="PRODUCTION_SUPABASE_URL")
    if qa_host == production_host:
        raise StagingConfigError("Staging and production must use different projects")
    if not staging_key or not _is_publishable_key(staging_key):
        raise StagingConfigError("Use only the QA publishable/anon key; service keys are rejected")
    return {
        "APP_ENV": "staging",
        "ALLOW_REMOTE_STAGING": "true",
        "SUPABASE_URL": staging_url.rstrip("/"),
        "SUPABASE_PUBLISHABLE_KEY": staging_key,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        defines = make_defines(
            os.environ.get("STAGING_SUPABASE_URL", ""),
            os.environ.get("STAGING_SUPABASE_PUBLISHABLE_KEY", ""),
            os.environ.get("PRODUCTION_SUPABASE_URL", ""),
        )
    except StagingConfigError as error:
        print(f"Staging configuration rejected: {error}")
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(defines), encoding="utf-8")
    args.output.chmod(0o600)
    print("QA-only web build settings prepared; no credential values were printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
