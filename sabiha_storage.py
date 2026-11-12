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


def sync_normalized_records(client, payload: dict[str, Any], actor: str) -> None:
    """Mirror operational records into queryable tables after the state save."""
    workers = payload.get("workers") or []
    worker_rows = [
        {
            "name": str(item.get("name", "")).strip(),
            "advance_balance": float(item.get("advance", 0) or 0),
            "is_active": True,
        }
        for item in workers
        if isinstance(item, dict) and str(item.get("name", "")).strip()
    ]
    if worker_rows:
        client.table("business_workers").upsert(
            worker_rows, on_conflict="name"
        ).execute()

    seen: set[str] = set()
    invoice_rows = []
    for invoice_list in (payload.get("session_state_invoices") or {}).values():
        for item in invoice_list or []:
            if not isinstance(item, dict):
                continue
            invoice_id = str(item.get("id") or "").strip()
            if not invoice_id or invoice_id in seen:
                continue
            seen.add(invoice_id)
            raw_time = item.get("created_at") or item.get("time")
            invoice_rows.append(
                {
                    "invoice_id": invoice_id,
                    "plate_number": item.get("plate_number"),
                    "service_name": str(item.get("service") or "غير محدد"),
                    "vehicle_type": item.get("car_type"),
                    "total": float(item.get("total", 0) or 0),
                    "discount": float(item.get("discount", 0) or 0),
                    "sale_type": "product" if item.get("sale_type") == "product" else "service",
                    "payment_method": item.get("payment"),
                    "status": str(item.get("status", "Active")).lower(),
                    "commission_total": float(item.get("commission_total", 0) or 0),
                    "commission_share": float(item.get("commission_share", 0) or 0),
                    "workers": item.get("workers") or item.get("commission_workers") or [],
                    "issued_at": raw_time,
                    "created_by": actor or "system",
                }
            )
    if invoice_rows:
        client.table("business_invoices").upsert(
            invoice_rows, on_conflict="invoice_id"
        ).execute()

    expense_rows = []
    today = __import__("datetime").date.today().isoformat()
    for category, amount in (payload.get("daily_expenses") or {}).items():
        value = float(amount or 0)
        expense_rows.append(
                {
                    "expense_date": today,
                    "category": str(category),
                    "amount": value,
                    "created_by": actor or "system",
                }
            )
    if expense_rows:
        client.table("business_expenses").upsert(
            expense_rows, on_conflict="expense_date,category"
        ).execute()

    orders = payload.get("business_orders") or []
    order_rows = []
    for order in orders:
        if not isinstance(order, dict) or not order.get("order_number"):
            continue
        order_rows.append(
            {
                "order_number": str(order["order_number"]),
                "customer_name": order.get("customer_name"),
                "customer_phone": order.get("customer_phone"),
                "plate_number": order.get("plate_number"),
                "vehicle_type": order.get("vehicle_type"),
                "service_name": str(order.get("service_name") or "غير محدد"),
                "assigned_workers": order.get("assigned_workers") or [],
                "status": str(order.get("status") or "received"),
                "notes": order.get("notes"),
                "created_by": order.get("created_by") or actor or "system",
                "created_at": order.get("created_at"),
            }
        )
    if order_rows:
        client.table("business_orders").upsert(
            order_rows, on_conflict="order_number"
        ).execute()


    # Keep the owner and employee login hashes server-side in a queryable table.
    credentials = payload.get("credentials") or {}
    account_rows = []
    owner = credentials.get("owner") or {}
    if owner.get("username") and owner.get("password"):
        account_rows.append(
            {
                "username": str(owner["username"]),
                "display_name": "المالك",
                "password_hash": str(owner["password"]),
                "role": "owner",
                "permissions": ["all"],
                "is_active": True,
            }
        )
    for username, account in (credentials.get("workers_accounts") or {}).items():
        if not isinstance(account, dict) or not account.get("password"):
            continue
        account_rows.append(
            {
                "username": str(username),
                "display_name": str(account.get("name") or username),
                "password_hash": str(account["password"]),
                "role": "worker",
                "permissions": account.get("permissions") or [],
                "is_active": True,
            }
        )
    if account_rows:
        client.table("business_staff_accounts").upsert(
            account_rows, on_conflict="username"
        ).execute()

    # A closed day is unique by calendar date; the DB primary key prevents a
    # second closure record for the same date.
    closure_rows = []
    for day_label, summary in (payload.get("daily_archive") or {}).items():
        date_key = str(day_label)[:10]
        if len(date_key) == 10:
            closure_rows.append(
                {
                    "closure_date": date_key,
                    "summary": summary or {},
                    "closed_by": actor or "system",
                }
            )
    if closure_rows:
        client.table("business_daily_closures").upsert(
            closure_rows, on_conflict="closure_date"
        ).execute()

    settings = {
        "commission_rate": payload.get("commission_rate", 0),
        "vat_rate_percent": payload.get("vat_rate_percent", 14.0),
        "vat_included_in_sales": payload.get("vat_included_in_sales", False),
        "services": payload.get("services") or {},
        "products": payload.get("products") or {},
    }
    setting_rows = [
        {
            "setting_key": key,
            "setting_value": value,
            "updated_by": actor or "system",
        }
        for key, value in settings.items()
    ]
    if setting_rows:
        client.table("business_settings").upsert(
            setting_rows, on_conflict="setting_key"
        ).execute()


def append_business_notification(
    client,
    order_number: str,
    message: str,
    status: str,
    actor: str,
) -> None:
    client.table("business_notifications").insert(
        {
            "order_number": order_number,
            "message": message,
            "status": status,
            "actor": actor or "system",
            "is_read": False,
        }
    ).execute()
