"""Server-side Supabase persistence for the Sabiha Hub Streamlit app.

The service-role key is read only from Streamlit secrets or environment variables.
Never commit it to GitHub or expose it to browser-side code.
"""
from __future__ import annotations

import os
from typing import Any

_client = None
_client_configured = False


class StateVersionConflict(RuntimeError):
    """Raised when another session saved newer data before this session."""


def _read_config() -> tuple[str, str]:
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = (
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
        or os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    )
    try:
        import streamlit as st
        config = st.secrets.get("supabase", {})
        url = url or str(config.get("url", "")).strip()
        key = key or str(
            config.get("service_role_key", "") or config.get("secret_key", "")
        ).strip()
    except Exception:
        pass
    return url, key


def get_supabase_client():
    """Return a cached server-side client, or None when not configured."""
    global _client, _client_configured
    if _client_configured:
        return _client
    _client_configured = True
    url, key = _read_config()
    if not url or not key:
        _client = None
        return None
    from supabase import create_client
    _client = create_client(url, key)
    return _client


def load_business_state(client) -> tuple[dict[str, Any] | None, int]:
    response = (
        client.table("business_app_state")
        .select("payload,version")
        .eq("state_id", "primary")
        .limit(1)
        .execute()
    )
    rows = response.data or []
    if not rows:
        return None, 0
    row = rows[0]
    return row.get("payload") or {}, int(row.get("version") or 1)


def save_business_state(
    client,
    payload: dict[str, Any],
    expected_version: int,
    actor: str,
) -> int:
    response = client.rpc(
        "save_business_app_state",
        {
            "p_payload": payload,
            "p_expected_version": int(expected_version),
            "p_actor": actor or "unknown",
        },
    ).execute()
    data = response.data
    if isinstance(data, list) and data:
        version = data[0].get("new_version")
    elif isinstance(data, dict):
        version = data.get("new_version")
    else:
        version = None
    if version is None:
        raise RuntimeError("Supabase did not return the saved state version.")
    return int(version)


def append_audit_log(
    client,
    actor: str,
    action: str,
    entity: str = "app_state",
    entity_id: str | None = None,
    details: dict[str, Any] | None = None,
) -> None:
    client.table("business_audit_log").insert(
        {
            "actor": actor or "unknown",
            "action": action,
            "entity": entity,
            "entity_id": entity_id,
            "details": details or {},
        }
    ).execute()
