import streamlit as st
import pandas as pd
from io import BytesIO

try:
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_RIGHT, TA_CENTER
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether
    REPORTLAB_AVAILABLE = True
except ImportError:
    REPORTLAB_AVAILABLE = False

try:
    import arabic_reshaper
    from bidi.algorithm import get_display
    ARABIC_SHAPING_AVAILABLE = True
except ImportError:
    ARABIC_SHAPING_AVAILABLE = False
import json
import os
import datetime as dt
import uuid
import html
import hashlib
import hmac
import secrets
from copy import deepcopy
from sabiha_storage import (
    get_supabase_client,
    load_business_state,
    save_business_state,
    append_audit_log,
    StateVersionConflict,
    sync_normalized_records,
)

# =============================================================================
# Sabiha Hub - Streamlit application
# =============================================================================
st.set_page_config(
    page_title="Sabiha Hub",
    page_icon="✨",
    layout="wide",
    initial_sidebar_state="expanded",
)

DATA_FILE = "sabiha_persistent_data.json"
APP_TITLE = "Sabiha Hub"

# Password storage: salted PBKDF2-HMAC-SHA256 (one-way; original passwords cannot be displayed).
PASSWORD_HASH_ITERATIONS = 310_000

def hash_password(password: str) -> str:
    """Return a salted, one-way PBKDF2 password hash."""
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, PASSWORD_HASH_ITERATIONS
    )
    return "pbkdf2_sha256${}${}${}".format(
        PASSWORD_HASH_ITERATIONS, salt.hex(), digest.hex()
    )

def is_password_hash(value) -> bool:
    return isinstance(value, str) and value.startswith("pbkdf2_sha256$")

def verify_password(password: str, stored_value: str) -> bool:
    """Verify both new hashes and legacy plaintext values during migration."""
    if not isinstance(stored_value, str):
        return False
    if not is_password_hash(stored_value):
        return hmac.compare_digest(password, stored_value)
    try:
        scheme, iterations, salt_hex, digest_hex = stored_value.split("$", 3)
        if scheme != "pbkdf2_sha256":
            return False
        calculated = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), int(iterations)
        ).hex()
        return hmac.compare_digest(calculated, digest_hex)
    except (ValueError, TypeError):
        return False

def migrate_plaintext_passwords(credentials: dict) -> bool:
    """Upgrade legacy plaintext credentials in-place; return whether data changed."""
    changed = False
    owner = credentials.setdefault("owner", {})
    if owner.get("password") and not is_password_hash(owner.get("password")):
        owner["password"] = hash_password(str(owner["password"]))
        changed = True
    for account in credentials.setdefault("workers_accounts", {}).values():
        stored = account.get("password")
        if stored and not is_password_hash(stored):
            account["password"] = hash_password(str(stored))
            changed = True
    return changed

# Theme: light main area + dark navy sidebar, with explicit widget colors.
st.markdown("""
<style>
:root {
    --sh-primary: #173b63;
    --sh-accent: #18a58a;
    --sh-bg: #f4f7fb;
    --sh-text: #17324d;
    --sh-muted: #52657a;
}
.stApp, [data-testid="stAppViewContainer"] {
    background: var(--sh-bg) !important;
    color: var(--sh-text) !important;
}
[data-testid="stMain"] {
    color: var(--sh-text) !important;
}
.block-container {
    padding-top: 1.35rem;
    padding-bottom: 2.5rem;
    max-width: 1500px;
}
[data-testid="stSidebar"] {
    background: linear-gradient(180deg, #102b49 0%, #173b63 100%) !important;
}
[data-testid="stSidebar"] * {
    color: #f7fbff !important;
}
[data-testid="stMarkdownContainer"],
[data-testid="stMarkdownContainer"] p,
[data-testid="stMarkdownContainer"] li,
[data-testid="stMarkdownContainer"] h1,
[data-testid="stMarkdownContainer"] h2,
[data-testid="stMarkdownContainer"] h3,
[data-testid="stMarkdownContainer"] h4,
[data-testid="stMain"] label,
[data-testid="stMain"] .stCaption {
    color: var(--sh-text) !important;
}
[data-testid="stMetric"] {
    background: #fff !important;
    border: 1px solid #e4ebf2;
    padding: 15px 17px;
    border-radius: 15px;
    box-shadow: 0 4px 16px rgba(20,48,78,.05);
}
[data-testid="stMetricLabel"] p {
    color: var(--sh-muted) !important;
    font-weight: 650;
}
[data-testid="stMetricValue"] {
    color: var(--sh-primary) !important;
    font-weight: 800;
}
.stButton > button, .stDownloadButton > button {
    border-radius: 10px;
    min-height: 2.55rem;
    font-weight: 650;
    border: 1px solid #d5e0eb;
}
.stButton > button[kind="primary"] {
    background: var(--sh-primary) !important;
    color: #fff !important;
}
.stTextInput input, .stNumberInput input, .stDateInput input,
.stTextArea textarea, textarea {
    background: #fff !important;
    color: var(--sh-text) !important;
    border: 1px solid #cbd5e1 !important;
    border-radius: 9px !important;
}
[data-baseweb="select"] > div {
    background: #fff !important;
    color: var(--sh-text) !important;
    border-color: #cbd5e1 !important;
}
[data-baseweb="select"] *, [data-baseweb="popover"] * {
    color: var(--sh-text) !important;
}
[data-testid="stExpander"] {
    border: 1px solid #e4ebf2;
    border-radius: 12px;
    background: #fff;
}
[data-testid="stDataFrame"], [data-testid="stTable"] {
    background: #fff;
    color: #17324d !important;
}
/* Keep text readable inside dark/black cards and custom dark surfaces. */
[data-testid="stSidebar"] *,
[style*="background: rgb(0"],
[style*="background-color: rgb(0"],
[style*="background:#000"],
[style*="background: #000"],
[style*="background-color:#000"],
[style*="background-color: #000"],
[style*="background: #111827"],
[style*="background:#111827"],
[style*="background: #0f172a"],
[style*="background:#0f172a"],
[style*="background: #1f2937"],
[style*="background:#1f2937"],
[style*="background: #102b49"],
[style*="background:#102b49"],
[style*="background: #173b63"],
[style*="background:#173b63"],
[style*="background: rgb(0"] *,
[style*="background-color: rgb(0"] *,
[style*="background:#000"] *,
[style*="background: #000"] *,
[style*="background-color:#000"] *,
[style*="background-color: #000"] *,
[style*="background: #111827"] *,
[style*="background:#111827"] *,
[style*="background: #0f172a"] *,
[style*="background:#0f172a"] *,
[style*="background: #1f2937"] *,
[style*="background:#1f2937"] *,
[style*="background: #102b49"] *,
[style*="background:#102b49"] *,
[style*="background: #173b63"] *,
[style*="background:#173b63"] * {
    color: #ffffff !important;
}
/* Text and values in dark buttons must remain white. */
.stButton > button[kind="primary"],
.stDownloadButton > button[kind="primary"] {
    color: #ffffff !important;
}
.sh-hero {
    background: linear-gradient(115deg, #123456, #1b6b78);
    padding: 23px 27px;
    border-radius: 17px;
    color: white;
    margin-bottom: 18px;
    box-shadow: 0 8px 24px rgba(18,52,86,.14);
}
.sh-hero h1 { color: white !important; margin: 0; font-size: 1.8rem; }
.sh-hero p { color: #e1f2f4 !important; margin: .4rem 0 0 0; }
@media (max-width: 700px) {
    .block-container { padding: 1rem .8rem 2rem; }
    .sh-hero { padding: 17px; }
}

/* === FINAL CONTRAST FIX: white text on every dark-blue/black surface === */
[data-testid="stSidebar"],
[data-testid="stSidebar"] *,
[data-testid="stSidebar"] *::before,
[data-testid="stSidebar"] *::after {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
[data-testid="stSidebar"] [data-testid="stMarkdownContainer"],
[data-testid="stSidebar"] [data-testid="stMarkdownContainer"] *,
[data-testid="stSidebar"] [data-testid="stCaptionContainer"],
[data-testid="stSidebar"] [data-testid="stCaptionContainer"] *,
[data-testid="stSidebar"] label,
[data-testid="stSidebar"] label *,
[data-testid="stSidebar"] .stRadio,
[data-testid="stSidebar"] .stRadio *,
[data-testid="stSidebar"] button,
[data-testid="stSidebar"] button *,
[data-testid="stSidebar"] [data-baseweb="select"],
[data-testid="stSidebar"] [data-baseweb="select"] * {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
.sh-hero,
.sh-hero *,
.sh-hero *::before,
.sh-hero *::after {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
/* Streamlit/custom HTML blue and charcoal panels, including nested text. */
[style*="#173b63"], [style*="#173B63"],
[style*="#123456"], [style*="#123456"],
[style*="#102b49"], [style*="#102B49"],
[style*="#0f172a"], [style*="#0F172A"],
[style*="#111827"], [style*="#1f2937"],
[style*="rgb(23, 59, 99)"], [style*="rgb(18, 52, 86)"],
[style*="rgb(16, 43, 73)"], [style*="rgb(15, 23, 42)"],
[style*="rgb(17, 24, 39)"], [style*="rgb(31, 41, 55)"],
[style*="#173b63"] *, [style*="#173B63"] *,
[style*="#123456"] *, [style*="#102b49"] *,
[style*="#102B49"] *, [style*="#0f172a"] *,
[style*="#0F172A"] *, [style*="#111827"] *,
[style*="#1f2937"] *, [style*="rgb(23, 59, 99)"] *,
[style*="rgb(18, 52, 86)"] *, [style*="rgb(16, 43, 73)"] *,
[style*="rgb(15, 23, 42)"] *, [style*="rgb(17, 24, 39)"] *,
[style*="rgb(31, 41, 55)"] * {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
/* White text on dark primary buttons and their inner spans/icons. */
.stButton > button[kind="primary"],
.stButton > button[kind="primary"] *,
.stDownloadButton > button[kind="primary"],
.stDownloadButton > button[kind="primary"] * {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}


/* === Sidebar important-notices expander: dark panel + readable white text === */
[data-testid="stSidebar"] [data-testid="stExpander"],
[data-testid="stSidebar"] [data-testid="stExpander"] > details,
[data-testid="stSidebar"] [data-testid="stExpander"] details,
[data-testid="stSidebar"] [data-testid="stExpander"] summary,
[data-testid="stSidebar"] [data-testid="stExpander"] [data-testid="stExpanderDetails"] {
    background: #173b63 !important;
    color: #ffffff !important;
    border-color: #52708e !important;
}
[data-testid="stSidebar"] [data-testid="stExpander"] *,
[data-testid="stSidebar"] [data-testid="stExpander"] *::before,
[data-testid="stSidebar"] [data-testid="stExpander"] *::after {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
[data-testid="stSidebar"] [data-testid="stExpander"] [data-testid="stMarkdownContainer"],
[data-testid="stSidebar"] [data-testid="stExpander"] [data-testid="stMarkdownContainer"] p,
[data-testid="stSidebar"] [data-testid="stExpander"] [data-testid="stCaptionContainer"],
[data-testid="stSidebar"] [data-testid="stExpander"] [data-testid="stCaptionContainer"] p {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
    opacity: 1 !important;
}

/* Strong contrast for dark/black custom panels and Streamlit status boxes. */
[style*="background: #000"], [style*="background:#000"],
[style*="background-color: #000"], [style*="background-color:#000"],
[style*="background: rgb(0, 0, 0)"], [style*="background-color: rgb(0, 0, 0)"],
[style*="#212529"], [style*="#343a40"], [style*="#202124"],
[style*="rgb(33, 37, 41)"], [style*="rgb(52, 58, 64)"],
[style*="#212529"] *, [style*="#343a40"] *, [style*="#202124"] *,
[style*="rgb(33, 37, 41)"] *, [style*="rgb(52, 58, 64)"] *,
[style*="background: #000"] *, [style*="background:#000"] *,
[style*="background-color: #000"] *, [style*="background-color:#000"] *,
[style*="background: rgb(0, 0, 0)"] *, [style*="background-color: rgb(0, 0, 0)"] * {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}

/* Final dark-card contrast pass: cover common black/charcoal inline backgrounds. */
[style*="background:#000"], [style*="background: #000"],
[style*="background-color:#000"], [style*="background-color: #000"],
[style*="background:#000000"], [style*="background: #000000"],
[style*="background-color:#000000"], [style*="background-color: #000000"],
[style*="rgb(0,0,0)"], [style*="rgb(0, 0, 0)"],
[style*="rgb(24,24,24)"], [style*="rgb(24, 24, 24)"],
[style*="#1e1e1e"], [style*="#1E1E1E"], [style*="#202124"],
[style*="#212529"], [style*="#343a40"],
[style*="background:#0b0f19"], [style*="background: #0b0f19"],
[style*="background:#111827"], [style*="background: #111827"],
[style*="background:#1f2937"], [style*="background: #1f2937"],
[style*="background-color: rgb(0, 0, 0)"] {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
[style*="background:#000"] *, [style*="background: #000"] *,
[style*="background-color:#000"] *, [style*="background-color: #000"] *,
[style*="background:#000000"] *, [style*="background: #000000"] *,
[style*="background-color:#000000"] *, [style*="background-color: #000000"] *,
[style*="rgb(0,0,0)"] *, [style*="rgb(0, 0, 0)"] *,
[style*="rgb(24,24,24)"] *, [style*="rgb(24, 24, 24)"] *,
[style*="#1e1e1e"] *, [style*="#1E1E1E"] *, [style*="#202124"] *,
[style*="#212529"] *, [style*="#343a40"] *,
[style*="#111827"] *, [style*="#1f2937"] * {
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
}
/* PDF download controls: navy background with high-contrast white labels/icons. */
.stDownloadButton > button, .stDownloadButton > button * {
    background-color: #173b63 !important;
    color: #ffffff !important;
    -webkit-text-fill-color: #ffffff !important;
    border-color: #173b63 !important;
}
</style>
""", unsafe_allow_html=True)


# =============================================================================
# Data model, migration and safe local-file persistence
# =============================================================================
def default_data():
    return {
        "credentials": {
            "owner": {"username": "", "password": ""},
            "workers_accounts": {},
        },
        "workers": [
            {"name": "أحمد مصطفى", "advance": 0.0},
            {"name": "محمد علي", "advance": 0.0},
        ],
        "commission_rate": 10.0,
        "vat_rate_percent": 14.0,
        "vat_included_in_sales": False,
        "services": {
            "غسيل سريع": {"الملكي": 150.0, "SUV": 200.0, "fixed_commission": 20.0},
            "تلميع نانو سريع": {"الملكي": 300.0, "SUV": 400.0, "fixed_commission": 50.0},
            "تنظيف صالون عميق": {"الملكي": 250.0, "SUV": 350.0, "fixed_commission": 40.0},
        },
        "products": {
            "معطر سيارة فاخر": 30.0,
            "فوطة مايكرو فايبر": 50.0,
            "سائل ممسحة زجاج": 40.0,
        },
        "session_state_invoices": {},
        "business_orders": [],
        "daily_sales": 0.0,
        "daily_expenses": {"rent": 0.0, "operational": 0.0, "utilities": 0.0},
        "daily_archive": {},
        "monthly_archive": {},
    }


def deep_merge(defaults, saved):
    """Keep saved values while adding any newly introduced default keys."""
    if isinstance(defaults, dict) and isinstance(saved, dict):
        merged = deepcopy(defaults)
        for key, value in saved.items():
            if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
                merged[key] = deep_merge(merged[key], value)
            else:
                merged[key] = value
        return merged
    return saved if saved is not None else deepcopy(defaults)


def load_system_data():
    defaults = default_data()
    client = get_supabase_client()
    if client is not None:
        try:
            saved, version = load_business_state(client)
            st.session_state["_supabase_state_version"] = version
            st.session_state["_storage_error"] = False
            if saved is not None:
                data = deep_merge(defaults, saved)
            else:
                # First connection: preserve an existing local JSON file if one exists.
                if os.path.exists(DATA_FILE):
                    with open(DATA_FILE, "r", encoding="utf-8") as file:
                        data = deep_merge(defaults, json.load(file))
                else:
                    data = defaults
        except Exception as error:
            st.session_state["_storage_error"] = True
            st.error(
                "تعذر الاتصال بقاعدة البيانات المشتركة. أوقفنا الحفظ مؤقتاً "
                "حتى لا يتم استبدال بيانات أحدث بنسخة قديمة."
            )
            return defaults
    else:
        st.session_state["_supabase_state_version"] = 0
        st.session_state["_storage_error"] = False
        if not os.path.exists(DATA_FILE):
            return defaults
        try:
            with open(DATA_FILE, "r", encoding="utf-8") as file:
                data = deep_merge(defaults, json.load(file))
        except (OSError, json.JSONDecodeError, TypeError):
            st.error("تعذر قراءة ملف البيانات الحالي. لم يتم استبداله حتى لا نفقد البيانات.")
            return defaults

    # Normalize fields that older versions may not have contained.
    data.setdefault("credentials", defaults["credentials"])
    data["credentials"].setdefault("owner", defaults["credentials"]["owner"])
    data["credentials"].setdefault("workers_accounts", {})
    data.setdefault("workers", [])
    data.setdefault("session_state_invoices", {})
    data.setdefault("business_orders", [])
    data.setdefault("vat_rate_percent", defaults["vat_rate_percent"])
    data.setdefault("vat_included_in_sales", defaults["vat_included_in_sales"])
    data.setdefault("daily_expenses", defaults["daily_expenses"])
    return data


def save_system_data():
    payload = {
        "credentials": st.session_state.credentials,
        "workers": st.session_state.workers,
        "commission_rate": st.session_state.commission_rate,
        "vat_rate_percent": st.session_state.get("vat_rate_percent", 14.0),
        "vat_included_in_sales": st.session_state.get("vat_included_in_sales", False),
        "services": st.session_state.services,
        "products": st.session_state.products,
        "session_state_invoices": st.session_state.session_state_invoices,
        "business_orders": st.session_state.get("business_orders", []),
        "daily_sales": st.session_state.daily_sales,
        "daily_expenses": st.session_state.daily_expenses,
        "daily_archive": st.session_state.daily_archive,
        "monthly_archive": st.session_state.monthly_archive,
    }
    client = get_supabase_client()
    if client is not None:
        if st.session_state.get("_storage_error", False):
            st.error("الحفظ متوقف بسبب مشكلة اتصال سابقة. حدّث الصفحة قبل المحاولة.")
            return False
        try:
            actor = str(st.session_state.get("current_user") or "system")
            expected_version = int(st.session_state.get("_supabase_state_version", 0))
            new_version = save_business_state(
                client, payload, expected_version, actor
            )
            st.session_state["_supabase_state_version"] = new_version
            try:
                sync_normalized_records(client, payload, actor)
            except Exception:
                st.warning("تم حفظ البيانات الأساسية، لكن تعذّر تحديث بعض الجداول التفصيلية. سنعيد المحاولة مع الحفظ التالي.")
            try:
                append_audit_log(
                    client,
                    actor=actor,
                    action="save_state",
                    entity="business_app_state",
                    entity_id="primary",
                    details={"version": new_version},
                )
            except Exception:
                # Audit logging must not falsely report a failed business save.
                pass
            return True
        except Exception as error:
            if "STATE_VERSION_CONFLICT" in str(error):
                st.error(
                    "فيه مستخدم تاني حفظ بيانات أحدث. لم نكتب فوقها؛ "
                    "حدّث الصفحة وحاول مرة تانية."
                )
            else:
                st.error("تعذر حفظ البيانات في Supabase. لم نستخدم نسخة محلية بديلة.")
            return False

    temp_file = DATA_FILE + ".tmp"
    try:
        with open(temp_file, "w", encoding="utf-8") as file:
            json.dump(payload, file, ensure_ascii=False, indent=2)
        os.replace(temp_file, DATA_FILE)
        return True
    except OSError as error:
        st.error(f"تعذر حفظ البيانات على مساحة التشغيل: {error}")
        return False


if "system_loaded" not in st.session_state:
    persisted = load_system_data()
    for key, value in persisted.items():
        st.session_state[key] = value
    st.session_state.system_loaded = True

if st.session_state.get("_storage_error", False):
    st.error("Sabiha Hub متوقف مؤقتاً لأن قاعدة البيانات غير متاحة. لم نسمح بالدخول إلى بيانات افتراضية أو حفظ فوق بيانات غير مؤكدة.")
    st.stop()

# Automatically migrate any legacy plaintext passwords to salted one-way hashes.
if migrate_plaintext_passwords(st.session_state.credentials):
    save_system_data()

# Normalize older worker accounts.
for account in st.session_state.credentials.get("workers_accounts", {}).values():
    account.setdefault("permissions", ["🛒 كاشير الاستقبال POS"])
    account.setdefault("role", "worker")

# =============================================================================
# Login
# =============================================================================
for key, default in {
    "logged_in": False,
    "user_role": None,
    "current_user": None,
    "current_user_id": None,
}.items():
    if key not in st.session_state:
        st.session_state[key] = default

if not st.session_state.logged_in:
    owner_setup = st.session_state.credentials.get("owner", {})
    if not owner_setup.get("username") or not owner_setup.get("password"):
        st.markdown(
            "<h1 style='text-align:center;color:#173b63'>✨ إعداد Sabiha Hub لأول مرة</h1>",
            unsafe_allow_html=True,
        )
        st.info("أنشئ حساب المالك الأول. لم نعد نضع كلمات مرور افتراضية معروفة داخل الكود.")
        setup_username = st.text_input("اسم مستخدم المالك", key="first_owner_username").strip()
        setup_password = st.text_input("كلمة مرور المالك", type="password", key="first_owner_password")
        setup_confirm = st.text_input("تأكيد كلمة المرور", type="password", key="first_owner_confirm")
        if st.button("إنشاء حساب المالك الآمن", type="primary", use_container_width=True):
            if not setup_username or len(setup_password) < 12 or not any(c.isalpha() for c in setup_password) or not any(c.isdigit() for c in setup_password):
                st.error("استخدم اسم مستخدم وكلمة مرور لا تقل عن 12 حرفاً وتحتوي على حروف وأرقام.")
            elif setup_password != setup_confirm:
                st.error("تأكيد كلمة المرور غير مطابق.")
            else:
                st.session_state.credentials["owner"] = {
                    "username": setup_username,
                    "password": hash_password(setup_password),
                }
                if save_system_data():
                    st.success("تم إنشاء حساب المالك. سجّل الدخول الآن.")
                    st.rerun()
        st.stop()

    st.markdown(
        "<h1 style='text-align:center;color:#173b63'>✨ Sabiha Hub | تسجيل الدخول</h1>",
        unsafe_allow_html=True,
    )
    st.write("---")
    left, center, right = st.columns([1, 2, 1])
    with center:
        st.subheader("🔑 أدخل بيانات حسابك")
        login_user = st.text_input("👤 اسم المستخدم", key="login_username").strip()
        login_password = st.text_input("🔒 كلمة المرور", type="password", key="login_password").strip()
        if st.button("دخول النظام 🚀", type="primary", use_container_width=True):
            owner = st.session_state.credentials.get("owner", {})
            if login_user == owner.get("username") and verify_password(login_password, owner.get("password", "")):
                st.session_state.logged_in = True
                st.session_state.user_role = "owner"
                st.session_state.current_user = "المالك"
                st.session_state.current_user_id = "owner"
                st.rerun()
            else:
                matched = None
                for uid, account in st.session_state.credentials.get("workers_accounts", {}).items():
                    if login_user == uid and verify_password(login_password, account.get("password", "")):
                        matched = (uid, account)
                        break
                if matched:
                    uid, account = matched
                    st.session_state.logged_in = True
                    st.session_state.user_role = "worker"
                    st.session_state.current_user = account.get("name", uid)
                    st.session_state.current_user_id = uid
                    st.rerun()
                else:
                    st.error("بيانات الدخول غير صحيحة. راجع اسم المستخدم وكلمة المرور.")
        st.caption("بيانات الدخول لا تُعرض داخل النظام، وكلمات المرور محفوظة بتجزئة آمنة.")
    st.stop()


# =============================================================================
# Navigation and shared helpers
# =============================================================================
st.sidebar.markdown(f"### 👋 مرحباً: {st.session_state.current_user}")
st.sidebar.caption(f"نوع الحساب: {st.session_state.user_role}")
if get_supabase_client() is not None:
    st.sidebar.success("قاعدة البيانات المشتركة: Supabase")
else:
    st.sidebar.warning("التخزين الحالي: ملف JSON محلي")
st.sidebar.write("---")

if st.sidebar.button("تسجيل الخروج 🔓", use_container_width=True):
    st.session_state.logged_in = False
    st.session_state.user_role = None
    st.session_state.current_user = None
    st.session_state.current_user_id = None
    st.rerun()

if st.sidebar.button("🔄 تحديث البيانات", use_container_width=True):
    st.rerun()

PAGES = [
    "📊 لوحة الداشبورد الرئيسية",
    "🛒 كاشير الاستقبال POS",
    "🚗 متابعة الطلبات",
    "📉 تقرير الحسابات والأرشيف",
    "💸 العمولات والسلفيات الحية",
    "📑 دفتر المصروفات",
    "⚙️ إعدادات الباقات والعمال",
]
if st.session_state.user_role == "owner":
    allowed_pages = PAGES
else:
    acc = st.session_state.credentials.get("workers_accounts", {}).get(
        st.session_state.current_user_id, {}
    )
    allowed_pages = [p for p in acc.get("permissions", []) if p in PAGES]
    if not allowed_pages:
        allowed_pages = ["🛒 كاشير الاستقبال POS"]

selected_page = st.sidebar.radio("📍 التنقل بين الصفحات", allowed_pages)
menu_map = {
    "📊 لوحة الداشبورد الرئيسية": "dashboard",
    "🛒 كاشير الاستقبال POS": "pos",
    "🚗 متابعة الطلبات": "orders",
    "📉 تقرير الحسابات والأرشيف": "archive",
    "💸 العمولات والسلفيات الحية": "commissions",
    "📑 دفتر المصروفات": "expenses",
    "⚙️ إعدادات الباقات والعمال": "settings",
}
page = menu_map[selected_page]

workers = [
    item.get("name")
    for item in st.session_state.workers
    if isinstance(item, dict) and item.get("name")
]
if not workers:
    workers = ["لا يوجد فني مسؤول"]


def get_all_invoices():
    """Invoices are stored under each participating worker; show each invoice once."""
    result, seen = [], set()
    for invoice_list in st.session_state.session_state_invoices.values():
        for invoice in invoice_list:
            invoice_id = invoice.get("id")
            if invoice_id and invoice_id not in seen:
                seen.add(invoice_id)
                result.append(invoice.copy())
    return sorted(result, key=lambda x: x.get("time", ""))


def update_invoice(invoice_id, updates):
    for invoice_list in st.session_state.session_state_invoices.values():
        for invoice in invoice_list:
            if invoice.get("id") == invoice_id:
                invoice.update(updates)


def invoice_workers(invoice):
    names = invoice.get("workers") or invoice.get("commission_workers") or []
    if not names:
        names = [invoice.get("worker1", "مبيعات مباشرة")]
    return [name for name in names if name and name != "مبيعات مباشرة"]


def printable_html(title, body):
    safe_title = html.escape(str(title))
    return f"""<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
    <title>{safe_title}</title><style>
    body{{font-family:Arial,sans-serif;padding:24px;color:#17324d;direction:rtl}}
    h1,h2{{color:#173b63}}table{{width:100%;border-collapse:collapse;margin-top:18px}}
    th,td{{border:1px solid #d8e1ea;padding:8px;text-align:right}}
    th{{background:#edf3f8}}.summary{{padding:14px;background:#f4f7fb;border-radius:10px}}
    </style></head><body><h1>{safe_title}</h1>{body}</body></html>"""


def _pdf_text(value):
    """Prepare readable RTL text when Arabic shaping dependencies are installed."""
    value = str(value if value is not None else "")
    if ARABIC_SHAPING_AVAILABLE:
        try:
            return get_display(arabic_reshaper.reshape(value))
        except Exception:
            return value
    return value


def build_pdf(title, lines, table_data=None):
    """Build an A4 PDF with embedded Arabic font and RTL shaping when available."""
    if not REPORTLAB_AVAILABLE:
        return None
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer, pagesize=A4, rightMargin=32, leftMargin=32,
        topMargin=36, bottomMargin=36,
        title=str(title), author="Sabiha Hub",
    )
    styles = getSampleStyleSheet()
    font_name = "Helvetica"
    # Ship the Arabic font with the app so Streamlit Cloud does not fall back
    # to Helvetica (which renders Arabic letters as empty squares).
    app_dir = os.path.dirname(os.path.abspath(__file__))
    font_paths = [
        os.path.join(app_dir, "assets", "NotoNaskhArabic-Regular.ttf"),
        os.path.join(app_dir, "NotoNaskhArabic-Regular.ttf"),
        "/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf",
    ]
    for font_path in font_paths:
        if os.path.exists(font_path):
            try:
                if "SabihaArabic" not in pdfmetrics.getRegisteredFontNames():
                    pdfmetrics.registerFont(TTFont("SabihaArabic", font_path))
                font_name = "SabihaArabic"
                break
            except Exception:
                pass
    title_style = ParagraphStyle(
        "SabihaTitle", parent=styles["Title"], fontName=font_name,
        fontSize=17, leading=23, alignment=TA_CENTER, textColor=colors.HexColor("#173b63"),
    )
    body_style = ParagraphStyle(
        "SabihaBody", parent=styles["BodyText"], fontName=font_name,
        fontSize=9, leading=15, alignment=TA_RIGHT, textColor=colors.HexColor("#17324d"),
    )
    story = [Paragraph(html.escape(_pdf_text(title)), title_style), Spacer(1, 14)]
    for line in lines or []:
        story.append(Paragraph(html.escape(_pdf_text(line)), body_style))
        story.append(Spacer(1, 4))
    if table_data:
        header_style = ParagraphStyle(
            "SabihaTableHeader", parent=body_style, textColor=colors.white,
            fontName=font_name, fontSize=8, leading=11,
        )
        shaped_rows = []
        for row_index, row in enumerate(table_data):
            cell_style = header_style if row_index == 0 else body_style
            shaped_rows.append([Paragraph(html.escape(_pdf_text(cell)), cell_style) for cell in row])
        table = Table(shaped_rows, repeatRows=1, hAlign="RIGHT")
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#173b63")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#cbd5e1")),
            ("BACKGROUND", (0, 1), (-1, -1), colors.white),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ]))
        story.extend([Spacer(1, 10), table])
    doc.build(story)
    return buffer.getvalue()


def invoice_pdf(inv):
    workers_text = "، ".join(invoice_workers(inv)) or "مبيعات مباشرة"
    lines = [
        f"رقم الفاتورة: {inv.get('id', '')}",
        f"التاريخ: {inv.get('time', '')}",
        f"رقم اللوحة: {inv.get('plate_number', '---')}",
        f"الخدمة / المنتج: {inv.get('service', '')}",
        f"فئة السيارة: {inv.get('car_type', '---')}",
        f"الفنيون: {workers_text}",
        f"الخصم: {float(inv.get('discount', 0)):.2f} ج.م",
        f"الإجمالي الصافي: {float(inv.get('total', 0)):.2f} ج.م",
        f"العمولة الإجمالية: {float(inv.get('commission_total', 0)):.2f} ج.م",
        f"طريقة الدفع: {inv.get('payment', 'كاش')}",
        f"الحالة: {'مرتجع' if inv.get('status') == 'Refunded' else 'نشطة'}",
    ]
    return build_pdf("فاتورة Sabiha Hub", lines)


def report_pdf(title, invoices, summary_lines=None):
    df = invoice_dataframe(invoices)
    columns = ["رقم الفاتورة", "التاريخ", "رقم اللوحة", "البيان", "الإجمالي", "الحالة"]
    rows = [columns]
    if not df.empty:
        for _, row in df.iterrows():
            rows.append([str(row.get(c, "")) for c in columns])
    return build_pdf(title, summary_lines or [], rows if len(rows) > 1 else None)


def invoice_dataframe(invoices):
    rows = []
    for inv in invoices:
        rows.append({
            "رقم الفاتورة": inv.get("id", ""),
            "التاريخ": inv.get("time", ""),
            "رقم اللوحة": inv.get("plate_number", "---"),
            "النوع": "منتج" if inv.get("sale_type") == "product" else "خدمة",
            "البيان": inv.get("service", ""),
            "الفئة": inv.get("car_type", "---"),
            "الإجمالي": float(inv.get("total", 0)),
            "الخصم": float(inv.get("discount", 0)),
            "الفنيون": "، ".join(invoice_workers(inv)),
            "العمولة": float(inv.get("commission_total", 0)),
            "الحالة": "نشطة" if inv.get("status", "Active") == "Active" else "مرتجع",
            "الدفع": inv.get("payment", "كاش"),
        })
    return pd.DataFrame(rows)


def show_invoice_card(inv, prefix, index, allow_refund=True):
    status = inv.get("status", "Active")
    with st.container(border=True):
        c1, c2, c3 = st.columns([2, 2, 2])
        with c1:
            st.markdown(f"**🧾 {inv.get('id', '')}**")
            st.caption(f"اللوحة: {inv.get('plate_number', '---')}")
        with c2:
            st.write(inv.get("service", ""))
            st.caption(inv.get("time", ""))
        with c3:
            st.metric("صافي الفاتورة", f"{float(inv.get('total', 0)):.2f}")
            st.caption("ج.م")
        st.write(
            f"الفنيون: {', '.join(invoice_workers(inv)) or 'مبيعات مباشرة'} · "
            f"العمولة الإجمالية: {float(inv.get('commission_total', 0)):.2f} ج.م"
        )
        pdf_data = invoice_pdf(inv)
        if pdf_data:
            st.download_button(
                "📄 تحميل الفاتورة PDF",
                data=pdf_data,
                file_name=f"{inv.get('id', 'invoice')}.pdf",
                mime="application/pdf",
                key=f"{prefix}_pdf_{inv.get('id', '')}_{index}",
            )
        else:
            st.warning("تحميل PDF يحتاج إضافة reportlab إلى requirements.txt.")
        if status == "Refunded":
            st.error(
                f"مرتجع بواسطة: {inv.get('cancelled_by', '---')} | "
                f"السبب: {inv.get('refund_reason', 'غير محدد')}"
            )
        elif allow_refund:
            with st.expander("إرجاع الفاتورة"):
                reason = st.text_input("سبب الإرجاع", key=f"{prefix}_reason_{inv['id']}_{index}")
                cancelled_by = st.selectbox(
                    "الموظف المسؤول عن الإرجاع",
                    ["اختر الموظف"] + workers,
                    key=f"{prefix}_by_{inv['id']}_{index}",
                )
                if st.button("تأكيد إرجاع الفاتورة ↩️", key=f"{prefix}_refund_{inv['id']}_{index}"):
                    if not reason.strip():
                        st.error("اكتب سبب الإرجاع أولاً.")
                    elif cancelled_by == "اختر الموظف":
                        st.error("اختر الموظف المسؤول.")
                    else:
                        update_invoice(inv["id"], {
                            "status": "Refunded",
                            "refund_reason": reason.strip(),
                            "cancelled_by": cancelled_by,
                        })
                        save_system_data()
                        st.success("تم تسجيل الإرجاع.")
                        st.rerun()


invoices = get_all_invoices()
active_invoices = [x for x in invoices if x.get("status", "Active") == "Active"]
refunded_invoices = [x for x in invoices if x.get("status") == "Refunded"]
service_invoices = [x for x in active_invoices if x.get("sale_type", "service") == "service"]
sales_today = sum(float(x.get("total", 0)) for x in active_invoices)
commissions_today = sum(float(x.get("commission_total", 0)) for x in active_invoices)
expenses_today = sum(float(v) for v in st.session_state.daily_expenses.values())
vat_rate = float(st.session_state.get("vat_rate_percent", 14.0))
vat_included = bool(st.session_state.get("vat_included_in_sales", False))
vat_today = sales_today * vat_rate / (100.0 + vat_rate) if vat_included else sales_today * vat_rate / 100.0
net_today = sales_today - expenses_today - vat_today - commissions_today
st.session_state.daily_sales = sales_today

# =============================================================================
# Dashboard
# =============================================================================
@st.fragment(run_every="5s")
def render_dashboard():
    # Read the latest shared JSON data on every dashboard refresh. This lets the
    # owner's dashboard see invoices created by another logged-in worker session.
    latest = load_system_data()
    if st.session_state.get("_storage_error", False):
        st.warning("تعذر تحديث البيانات من Supabase حالياً. لم نكتب فوق البيانات المحفوظة.")
        return
    for key in (
        "credentials", "session_state_invoices", "daily_sales", "daily_expenses",
        "daily_archive", "monthly_archive", "workers", "commission_rate",
        "services", "products", "business_orders", "vat_rate_percent",
        "vat_included_in_sales",
    ):
        if key in latest:
            st.session_state[key] = latest[key]

    current_invoices = get_all_invoices()
    current_active = [x for x in current_invoices if x.get("status", "Active") == "Active"]
    current_refunded = [x for x in current_invoices if x.get("status") == "Refunded"]
    current_services = [x for x in current_active if x.get("sale_type", "service") == "service"]
    current_sales = sum(float(x.get("total", 0)) for x in current_active)
    current_commissions = sum(float(x.get("commission_total", 0)) for x in current_active)
    current_expenses = sum(float(v) for v in st.session_state.daily_expenses.values())
    current_vat = (
        current_sales * vat_rate / (100.0 + vat_rate)
        if vat_included
        else current_sales * vat_rate / 100.0
    )
    current_net = current_sales - current_expenses - current_vat - current_commissions
    st.session_state.daily_sales = current_sales

    st.markdown("""
    <section class="sh-hero">
      <h1>✨ Sabiha Hub | لوحة التحكم</h1>
      <p>متابعة المبيعات والعمولات والمصروفات وحركة السيارات</p>
    </section>""", unsafe_allow_html=True)
    st.caption(f"🟢 تحديث تلقائي كل 5 ثوانٍ · آخر تحديث: {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    a, b, c, d = st.columns(4)
    a.metric("💰 المبيعات المحصلة", f"{current_sales:,.2f} ج.م", f"{len(current_active)} فاتورة")
    b.metric("📉 مصروفات اليوم", f"{current_expenses:,.2f} ج.م")
    c.metric(f"🏛️ ضريبة {vat_rate:g}% تقديرية", f"{current_vat:,.2f} ج.م")
    d.metric("🚗 سيارات مخدومة", len(current_services))
    active_orders = [o for o in st.session_state.get("business_orders", []) if o.get("status") not in ("delivered", "cancelled")]
    e, f, g = st.columns(3)
    e.metric("👨‍🔧 عمولات الفنيين", f"{current_commissions:,.2f} ج.م")
    f.metric("🟩 صافي تقديري", f"{current_net:,.2f} ج.م")
    g.metric("↩️ إجمالي المرتجعات", f"{sum(float(x.get('total',0)) for x in current_refunded):,.2f} ج.م")
    st.metric("🚘 الطلبات المفتوحة", len(active_orders))
    tax_mode = "مضمنة داخل إجمالي المبيعات" if vat_included else "تُضاف على المبيعات قبل الضريبة"
    st.info(f"طريقة التقدير الحالية: {vat_rate:g}%، والضريبة {tax_mode}. راجع النسبة وطريقة التطبيق مع المحاسب وفق بلد النشاط.")
    st.divider()
    st.subheader("📥 تقرير اليوم")
    df = invoice_dataframe(current_invoices)
    if not df.empty:
        st.dataframe(df, use_container_width=True, hide_index=True)
        st.download_button(
            "تحميل فواتير اليوم CSV",
            df.to_csv(index=False).encode("utf-8-sig"),
            file_name=f"sabiha_invoices_{dt.date.today()}.csv",
            mime="text/csv",
        )
        report_body = (
            f"<div class='summary'><p>المبيعات: {current_sales:.2f} ج.م</p>"
            f"<p>المصروفات: {current_expenses:.2f} ج.م</p>"
            f"<p>الضريبة التقديرية: {current_vat:.2f} ج.م</p>"
            f"<p>العمولات: {current_commissions:.2f} ج.م</p>"
            f"<p>الصافي التقديري: {current_net:.2f} ج.م</p></div>"
            + df.to_html(index=False, border=0)
        )
        daily_pdf = report_pdf(
            "التقرير اليومي - Sabiha Hub", current_invoices,
            [
                f"تاريخ التقرير: {dt.date.today()}",
                f"المبيعات: {current_sales:.2f} ج.م",
                f"المصروفات: {current_expenses:.2f} ج.م",
                f"الضريبة التقديرية: {current_vat:.2f} ج.م",
                f"العمولات: {current_commissions:.2f} ج.م",
                f"الصافي التقديري: {current_net:.2f} ج.م",
            ],
        )
        if daily_pdf:
            st.download_button(
                "📄 تحميل تقرير اليوم PDF",
                data=daily_pdf,
                file_name=f"sabiha_daily_report_{dt.date.today()}.pdf",
                mime="application/pdf",
                key="download_daily_report_pdf",
            )
        st.download_button(
            "تحميل تقرير اليوم HTML (قابل للطباعة PDF)",
            printable_html("التقرير اليومي - Sabiha Hub", report_body).encode("utf-8"),
            file_name=f"sabiha_daily_report_{dt.date.today()}.html",
            mime="text/html",
        )
    else:
        st.info("لا توجد فواتير مسجلة اليوم.")
    st.divider()
    st.subheader("🏁 إغلاق اليوم وترحيله")
    c1, c2 = st.columns(2)
    with c1:
        if st.button("إغلاق وترحيل اليوم الحالي", type="primary", use_container_width=True):
            if not current_invoices and current_expenses == 0:
                st.warning("لا توجد معاملات لترحيلها.")
            else:
                today_key = dt.datetime.now().strftime("%Y-%m-%d (%A)")
                if today_key in st.session_state.daily_archive:
                    st.error("يوجد أرشيف مسجل لهذا التاريخ بالفعل؛ راجع الأرشيف قبل الإغلاق مرة أخرى.")
                else:
                    st.session_state.daily_archive[today_key] = {
                        "sales": current_sales,
                        "expenses": current_expenses,
                        "tax": current_vat,
                        "commissions": current_commissions,
                        "cars_count": len(current_services),
                        "canceled_total": sum(float(x.get("total", 0)) for x in current_refunded),
                        "net": current_net,
                        "invoices": deepcopy(st.session_state.session_state_invoices),
                    }
                    st.session_state.session_state_invoices = {}
                    st.session_state.daily_sales = 0.0
                    st.session_state.daily_expenses = {"rent": 0.0, "operational": 0.0, "utilities": 0.0}
                    save_system_data()
                    st.success("تم إغلاق اليوم وترحيله.")
                    st.rerun()
    with c2:
        if st.button("إغلاق الشهر الحالي", use_container_width=True):
            month_key = dt.datetime.now().strftime("%Y-%m")
            if not st.session_state.daily_archive:
                st.warning("أرشيف الأيام فارغ. أغلق الأيام أولاً.")
            elif month_key in st.session_state.monthly_archive:
                st.error("يوجد أرشيف لهذا الشهر بالفعل.")
            else:
                st.session_state.monthly_archive[month_key] = deepcopy(st.session_state.daily_archive)
                st.session_state.daily_archive = {}
                save_system_data()
                st.success("تم حفظ الأرشيف الشهري.")
                st.rerun()
    st.divider()
    st.subheader("📋 الفواتير والمرتجعات")
    for i, inv in enumerate(current_invoices):
        show_invoice_card(inv, "dash", i)

if page == "dashboard":
    render_dashboard()


# =============================================================================
# POS
# =============================================================================
elif page == "pos":
    st.markdown("## 🛒 كاشير الاستقبال وإصدار الفواتير")
    sale_type = st.radio(
        "نوع العملية",
        ["خدمة سيارة 🛠️", "بيع منتج 📦"],
        horizontal=True,
        key="pos_sale_type",
    )
    is_product = sale_type.startswith("بيع منتج")
    base_price = 0.0
    selected_item = ""
    plate = "---"
    car_type = "---"
    selected_workers = []

    if not is_product:
        plate = st.text_input("🔢 رقم لوحة السيارة").strip()
        car_type = st.selectbox("🚗 فئة السيارة", ["ملاكي / سيدان", "SUV"])
        price_key = "الملكي" if car_type == "ملاكي / سيدان" else "SUV"
        service_names = list(st.session_state.services.keys())
        if service_names:
            selected_item = st.selectbox("🛠️ الخدمة", service_names)
            base_price = float(st.session_state.services[selected_item].get(price_key, 0))
        else:
            st.warning("لا توجد خدمات. أضف خدمة من الإعدادات.")
        selected_workers = st.multiselect(
            "👨‍🔧 الفنيون المشاركون في السيارة",
            workers,
            default=[workers[0]] if workers and workers[0] != "لا يوجد فني مسؤول" else [],
            key="pos_workers",
            help="يمكن اختيار أكثر من فني. العمولة الإجمالية تُقسم بالتساوي بينهم.",
        )
    else:
        product_names = list(st.session_state.products.keys())
        if product_names:
            selected_item = st.selectbox("📦 المنتج", product_names)
            base_price = float(st.session_state.products[selected_item])
        else:
            st.warning("لا توجد منتجات. أضف منتجاً من الإعدادات.")
        product_worker = st.selectbox("الموظف المسؤول عن البيع", ["مبيعات مباشرة"] + workers)

    p1, p2 = st.columns(2)
    with p1:
        st.metric("السعر الأساسي (ج.م)", f"{base_price:.2f}")
    with p2:
        discount = st.number_input("الخصم (ج.م)", min_value=0.0, value=0.0, key="pos_discount")
    final_total = max(0.0, base_price - discount)
    payment = st.radio("وسيلة الدفع", ["كاش", "فيزا"], horizontal=True)
    commission_total = 0.0 if is_product else final_total * float(st.session_state.commission_rate) / 100.0
    commission_share = commission_total / len(selected_workers) if selected_workers else 0.0
    st.markdown(f"### الإجمالي الصافي: **{final_total:.2f} ج.م**")
    st.caption(
        f"العمولة الإجمالية: {commission_total:.2f} ج.م | "
        f"عدد الفنيين: {len(selected_workers)} | نصيب كل فني: {commission_share:.2f} ج.م"
    )
    if st.button("🟢 إتمام المعاملة وإصدار الفاتورة", type="primary", use_container_width=True):
        invalid = not selected_item
        if not is_product and not plate:
            invalid = True
        if not is_product and not selected_workers:
            st.error("اختر فنيًا واحدًا على الأقل لتسجيل عمولته.")
            invalid = True
        if invalid:
            st.error("راجع بيانات العملية قبل إصدار الفاتورة.")
        else:
            now = dt.datetime.now().astimezone()
            invoice_id = f"INV-{now.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6].upper()}"
            assigned = selected_workers if not is_product else (
                [product_worker] if product_worker != "مبيعات مباشرة" else []
            )
            inv = {
                "id": invoice_id,
                "plate_number": plate,
                "service": selected_item,
                "car_type": car_type,
                "total": final_total,
                "discount": discount,
                "sale_type": "product" if is_product else "service",
                "worker1": assigned[0] if assigned else "مبيعات مباشرة",
                "worker2": assigned[1] if len(assigned) > 1 else "لا يوجد",
                "workers": assigned,
                "commission_rate": float(st.session_state.commission_rate) if not is_product else 0.0,
                "commission_total": commission_total,
                "commission_share": commission_share,
                "commission_workers": assigned,
                "payment": payment,
                "status": "Active",
                "time": now.strftime("%Y-%m-%d %H:%M:%S"),
                "created_at": now.isoformat(timespec="seconds"),
            }
            # Store a copy under every participating worker; dashboard deduplicates by invoice ID.
            invoice_buckets = assigned if assigned else ["مبيعات مباشرة"]
            for worker_name in invoice_buckets:
                st.session_state.session_state_invoices.setdefault(worker_name, []).append(inv.copy())
            if not is_product:
                order_number = f"ORD-{now.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6].upper()}"
                st.session_state.setdefault("business_orders", []).append({
                    "order_number": order_number,
                    "invoice_id": invoice_id,
                    "plate_number": plate,
                    "vehicle_type": car_type,
                    "service_name": selected_item,
                    "assigned_workers": assigned,
                    "status": "received",
                    "created_by": st.session_state.get("current_user") or "system",
                    "created_at": now.isoformat(timespec="seconds"),
                })
            if save_system_data():
                st.success(f"تم إصدار الفاتورة بنجاح: {invoice_id}")
                st.balloons()
                st.rerun()
            else:
                st.error("لم يتم تأكيد حفظ الفاتورة. لا تعِد إصدارها قبل تحديث الصفحة والتحقق من سجل الفواتير.")

    st.divider()
    st.subheader("📋 فواتير اليوم")
    for i, inv in enumerate(invoices):
        show_invoice_card(inv, "pos", i)


# =============================================================================
# Live service orders and worker status tracking
# =============================================================================
elif page == "orders":
    @st.fragment(run_every="5s")
    def render_orders():
        latest = load_system_data()
        if not st.session_state.get("_storage_error", False):
            for key in (
                "credentials", "workers", "commission_rate", "services", "products",
                "session_state_invoices", "business_orders", "daily_sales",
                "daily_expenses", "daily_archive", "monthly_archive",
            ):
                if key in latest:
                    st.session_state[key] = latest[key]

        st.markdown("## 🚗 متابعة الطلبات وحالة السيارات")
        all_orders = st.session_state.get("business_orders", [])
        if st.session_state.user_role == "owner":
            visible_orders = all_orders
        else:
            visible_orders = [
                order for order in all_orders
                if st.session_state.current_user in (order.get("assigned_workers") or [])
            ]

        status_labels = {
            "received": "تم الاستلام",
            "in_progress": "جاري التنفيذ",
            "quality_check": "مراجعة الجودة",
            "completed": "اكتملت الخدمة",
            "delivered": "تم التسليم",
            "cancelled": "ملغي",
        }
        status_values = list(status_labels)
        st.caption("مزامنة تلقائية كل 5 ثوانٍ. المالك يرى كل الطلبات، والموظف يرى الطلبات المسندة إليه.")
        if not visible_orders:
            st.info("لا توجد طلبات مسندة أو مسجلة حالياً.")
        for index, order in enumerate(reversed(visible_orders)):
            order_number = order.get("order_number", f"order-{index}")
            current_status = order.get("status", "received")
            with st.expander(
                f"{order_number} · لوحة {order.get('plate_number', '---')} · "
                f"{status_labels.get(current_status, current_status)}",
                expanded=current_status in ("received", "in_progress", "quality_check"),
            ):
                c1, c2, c3 = st.columns(3)
                c1.write(f"**الخدمة:** {order.get('service_name', '---')}")
                c2.write(f"**السيارة:** {order.get('vehicle_type', '---')}")
                c3.write(f"**الفنيون:** {', '.join(order.get('assigned_workers') or []) or '---'}")
                st.caption(f"وقت الإنشاء: {order.get('created_at', '---')}")
                selected_status = st.selectbox(
                    "تحديث حالة الطلب",
                    status_values,
                    index=status_values.index(current_status) if current_status in status_values else 0,
                    format_func=lambda value: status_labels[value],
                    key=f"order_status_{order_number}",
                )
                if st.button("حفظ حالة الطلب", key=f"save_order_{order_number}"):
                    order["status"] = selected_status
                    order["updated_at"] = dt.datetime.now().astimezone().isoformat(timespec="seconds")
                    if save_system_data():
                        st.success("تم تحديث حالة الطلب وتسجيل العملية.")
                        st.rerun()

    render_orders()


# =============================================================================
# Reports and archives
# =============================================================================
elif page == "archive":
    st.markdown("## 📉 تقرير الحسابات والأرشيف")
    tab_days, tab_months = st.tabs(["📁 أرشيف الأيام", "🗄️ الأرشيف الشهري"])
    with tab_days:
        if st.session_state.daily_archive:
            for day, record in st.session_state.daily_archive.items():
                with st.expander(f"{day} | صافي: {float(record.get('net', 0)):.2f} ج.م"):
                    st.json(record)
        else:
            st.info("لا يوجد أرشيف أيام مغلقة.")
    with tab_months:
        if st.session_state.monthly_archive:
            for month, records in st.session_state.monthly_archive.items():
                with st.expander(f"أرشيف شهر {month}"):
                    st.json(records)
        else:
            st.info("لا يوجد أرشيف شهري.")
    st.divider()
    st.subheader("تنزيل كشف الأرشيف")
    archive_rows = []
    for day, record in st.session_state.daily_archive.items():
        archive_rows.append({
            "اليوم": day,
            "المبيعات": record.get("sales", 0),
            "المصروفات": record.get("expenses", 0),
            "الضريبة": record.get("tax", 0),
            "العمولات": record.get("commissions", 0),
            "عدد السيارات": record.get("cars_count", 0),
            "المرتجعات": record.get("canceled_total", 0),
            "الصافي": record.get("net", 0),
        })
    archive_df = pd.DataFrame(archive_rows)
    if not archive_df.empty:
        st.dataframe(archive_df, use_container_width=True, hide_index=True)
        st.download_button(
            "تحميل الأرشيف CSV",
            archive_df.to_csv(index=False).encode("utf-8-sig"),
            file_name="sabiha_archive.csv",
            mime="text/csv",
        )
        archive_pdf_data = build_pdf(
            "أرشيف Sabiha Hub",
            [f"عدد الأيام المسجلة: {len(archive_rows)}"],
            [["اليوم", "المبيعات", "المصروفات", "الضريبة", "العمولات", "الصافي"]]
            + [[
                str(row["اليوم"]), f"{float(row['المبيعات']):.2f}",
                f"{float(row['المصروفات']):.2f}", f"{float(row['الضريبة']):.2f}",
                f"{float(row['العمولات']):.2f}", f"{float(row['الصافي']):.2f}",
            ] for row in archive_rows],
        )
        if archive_pdf_data:
            st.download_button(
                "📄 تحميل تقرير الأرشيف PDF",
                data=archive_pdf_data,
                file_name="sabiha_archive_report.pdf",
                mime="application/pdf",
                key="download_archive_report_pdf",
            )
    else:
        st.caption("لا توجد سجلات يومية قابلة للتنزيل حالياً.")


# =============================================================================
# Worker commissions and advances
# =============================================================================
elif page == "commissions":
    st.markdown("## 💸 العمولات والسلفيات")
    for index, worker in enumerate(st.session_state.workers):
        if not isinstance(worker, dict) or not worker.get("name"):
            continue
        name = worker["name"]
        worker_invoices = st.session_state.session_state_invoices.get(name, [])
        earned = sum(
            float(inv.get("commission_share", 0))
            for inv in worker_invoices
            if inv.get("status", "Active") == "Active"
        )
        advance = float(worker.get("advance", 0))
        due = earned - advance
        with st.expander(f"👨‍🔧 {name} | صافي المستحق الحالي: {due:.2f} ج.م"):
            x, y, z = st.columns(3)
            x.metric("العمولات", f"{earned:.2f} ج.م")
            y.metric("السلف", f"{advance:.2f} ج.م")
            z.metric("الصافي", f"{due:.2f} ج.م")
            new_advance = st.number_input(
                f"قيمة السلفة الجديدة لـ {name}",
                min_value=0.0,
                value=0.0,
                key=f"advance_{index}",
            )
            if st.button("تسجيل السلفة", key=f"save_advance_{index}"):
                st.session_state.workers[index]["advance"] = advance + new_advance
                save_system_data()
                st.success("تم تسجيل السلفة.")
                st.rerun()
            st.caption("تصفية الحساب هنا تسجل أن المستحق الحالي تم صرفه، مع الاحتفاظ بالفواتير.")
            if st.button("تصفية المستحق الحالي", key=f"settle_{index}"):
                # Keep historical invoices; reset the current advance balance only.
                st.session_state.workers[index]["advance"] = earned
                save_system_data()
                st.success("تمت تصفية المستحق الحالي. احتفظ النظام بالفواتير.")
                st.rerun()


# =============================================================================
# Expenses
# =============================================================================
elif page == "expenses":
    st.markdown("## 📑 دفتر المصروفات اليومية")
    current = st.session_state.daily_expenses
    with st.form("expenses_form"):
        rent = st.number_input("🏢 الإيجار (ج.م)", min_value=0.0, value=float(current.get("rent", 0)))
        operational = st.number_input(
            "🧪 مصروفات تشغيلية (ج.م)",
            min_value=0.0,
            value=float(current.get("operational", 0)),
        )
        utilities = st.number_input(
            "⚡ المرافق والطاقة (ج.م)",
            min_value=0.0,
            value=float(current.get("utilities", 0)),
        )
        submitted = st.form_submit_button("💾 حفظ المصروفات", use_container_width=True)
    if submitted:
        st.session_state.daily_expenses = {
            "rent": rent,
            "operational": operational,
            "utilities": utilities,
        }
        save_system_data()
        st.success("تم حفظ المصروفات.")
        st.rerun()
    st.metric("إجمالي مصروفات اليوم", f"{rent + operational + utilities:.2f} ج.م")


# =============================================================================
# Settings, workers, services, products, accounts and backup
# =============================================================================
elif page == "settings":
    st.markdown("## ⚙️ إعدادات Sabiha Hub")
    tab_workers, tab_prices, tab_accounts, tab_backup = st.tabs([
        "👨‍🔧 العمال", "🛍️ الخدمات والمنتجات", "🔐 الحسابات والصلاحيات", "💾 النسخ الاحتياطي"
    ])

    with tab_workers:
        st.subheader("إضافة فني")
        new_name = st.text_input("اسم الفني الجديد", key="new_worker_name")
        if st.button("إضافة الفني"):
            clean_name = new_name.strip()
            if not clean_name:
                st.error("اكتب اسم الفني.")
            elif clean_name in [w.get("name") for w in st.session_state.workers]:
                st.error("هذا الفني موجود بالفعل.")
            else:
                st.session_state.workers.append({"name": clean_name, "advance": 0.0})
                save_system_data()
                st.success("تمت إضافة الفني.")
                st.rerun()
        st.divider()
        st.subheader("قائمة الفنيين")
        for i, worker in enumerate(list(st.session_state.workers)):
            col_a, col_b = st.columns([4, 1])
            col_a.write(f"**{worker.get('name', '---')}**")
            if col_b.button("حذف", key=f"delete_worker_{i}"):
                worker_name = worker.get("name")
                # Do not delete invoices; remove only worker from active staff list.
                st.session_state.workers = [
                    w for w in st.session_state.workers if w.get("name") != worker_name
                ]
                save_system_data()
                st.rerun()

    with tab_prices:
        st.subheader("نسبة عمولة الخدمات")
        st.caption("العمولة تُحسب من صافي الخدمة بعد الخصم، ثم تُقسم بالتساوي على الفنيين المشاركين. المنتجات بلا عمولة.")
        rate = st.number_input(
            "نسبة العمولة الإجمالية (%)",
            min_value=0.0,
            max_value=100.0,
            value=float(st.session_state.commission_rate),
            step=0.5,
            key="commission_rate_edit",
        )
        if st.button("حفظ نسبة العمولة"):
            st.session_state.commission_rate = float(rate)
            save_system_data()
            st.success("تم حفظ نسبة العمولة.")
            st.rerun()
        st.divider()
        st.subheader("إضافة خدمة")
        s1, s2, s3 = st.columns(3)
        with s1:
            service_name = st.text_input("اسم الخدمة", key="new_service_name")
        with s2:
            price_sedan = st.number_input("سعر الملاكي", min_value=0.0, value=150.0, key="new_sedan")
        with s3:
            price_suv = st.number_input("سعر SUV", min_value=0.0, value=200.0, key="new_suv")
        if st.button("إضافة الخدمة"):
            name = service_name.strip()
            if name:
                st.session_state.services[name] = {
                    "الملكي": float(price_sedan),
                    "SUV": float(price_suv),
                    "fixed_commission": 0.0,
                }
                save_system_data()
                st.rerun()
        st.divider()
        if st.session_state.services:
            edit_service = st.selectbox("اختر خدمة لتعديل أسعارها", list(st.session_state.services))
            service_data = st.session_state.services[edit_service]
            e1, e2 = st.columns(2)
            with e1:
                edit_sedan = st.number_input(
                    "سعر الملاكي الحالي",
                    min_value=0.0,
                    value=float(service_data.get("الملكي", 0)),
                    key=f"edit_sedan_{edit_service}",
                )
            with e2:
                edit_suv = st.number_input(
                    "سعر SUV الحالي",
                    min_value=0.0,
                    value=float(service_data.get("SUV", 0)),
                    key=f"edit_suv_{edit_service}",
                )
            if st.button("حفظ أسعار الخدمة"):
                st.session_state.services[edit_service] = {
                    **service_data,
                    "الملكي": float(edit_sedan),
                    "SUV": float(edit_suv),
                }
                save_system_data()
                st.rerun()
            if st.button("حذف الخدمة المحددة"):
                del st.session_state.services[edit_service]
                save_system_data()
                st.rerun()
        st.divider()
        st.subheader("إضافة منتج")
        p1, p2 = st.columns(2)
        with p1:
            product_name = st.text_input("اسم المنتج", key="new_product_name")
        with p2:
            product_price = st.number_input("سعر المنتج", min_value=0.0, value=30.0, key="new_product_price")
        if st.button("إضافة المنتج"):
            name = product_name.strip()
            if name:
                st.session_state.products[name] = float(product_price)
                save_system_data()
                st.rerun()
        if st.session_state.products:
            remove_product = st.selectbox("حذف منتج", ["لا تحذف"] + list(st.session_state.products))
            if remove_product != "لا تحذف" and st.button("تأكيد حذف المنتج"):
                del st.session_state.products[remove_product]
                save_system_data()
                st.rerun()

    with tab_accounts:
        st.subheader("حساب المالك")
        owner_username = st.text_input(
            "اسم مستخدم المالك",
            value=st.session_state.credentials["owner"].get("username", "owner"),
        )
        st.info("🔐 كلمة مرور المالك محفوظة بتجزئة آمنة، ولا يمكن عرض النص الأصلي. يمكنك تعيين كلمة مرور جديدة في أي وقت.")
        owner_password = st.text_input(
            "كلمة مرور جديدة (اتركها فارغة دون تغيير)",
            type="password",
            key="owner_new_password",
        )
        if st.button("حفظ بيانات المالك"):
            if owner_username.strip():
                st.session_state.credentials["owner"]["username"] = owner_username.strip()
            if owner_password.strip():
                st.session_state.credentials["owner"]["password"] = hash_password(owner_password.strip())
            save_system_data()
            st.success("تم تحديث بيانات المالك. سجّل الخروج ثم ادخل بالبيانات الجديدة.")
        st.divider()
        st.subheader("حسابات الموظفين")
        accounts = st.session_state.credentials.setdefault("workers_accounts", {})
        for uid, account in list(accounts.items()):
            with st.expander(f"{account.get('name', uid)} ({uid})"):
                st.caption("🔐 كلمة المرور محفوظة بتجزئة آمنة ولا يمكن عرضها. يمكنك تعيين كلمة مرور جديدة أدناه.")
                display_name = st.text_input(
                    "اسم الموظف",
                    value=account.get("name", uid),
                    key=f"acc_name_{uid}",
                )
                new_password = st.text_input(
                    "تغيير كلمة المرور (اختياري)",
                    type="password",
                    key=f"acc_password_{uid}",
                )
                perms = st.multiselect(
                    "الصلاحيات",
                    PAGES,
                    default=[p for p in account.get("permissions", []) if p in PAGES],
                    key=f"acc_perms_{uid}",
                )
                if st.button("حفظ حساب الموظف", key=f"save_acc_{uid}"):
                    account["name"] = display_name.strip() or uid
                    account["permissions"] = perms
                    if new_password.strip():
                        account["password"] = hash_password(new_password.strip())
                    save_system_data()
                    st.success("تم تحديث الحساب.")
                    st.rerun()
                if st.button("حذف الحساب", key=f"delete_acc_{uid}"):
                    if len(accounts) <= 1:
                        st.error("يجب الاحتفاظ بحساب موظف واحد على الأقل.")
                    else:
                        del accounts[uid]
                        save_system_data()
                        st.rerun()
        st.divider()
        st.subheader("إنشاء حساب موظف")
        n1, n2, n3 = st.columns(3)
        with n1:
            display = st.text_input("اسم الموظف الجديد", key="create_display")
        with n2:
            username = st.text_input("اسم المستخدم الجديد", key="create_username")
        with n3:
            password = st.text_input("كلمة المرور الجديدة", type="password", key="create_password")
        permissions = st.multiselect(
            "صلاحيات الموظف الجديد",
            PAGES,
            default=["🛒 كاشير الاستقبال POS", "🚗 متابعة الطلبات"],
            key="create_permissions",
        )
        if st.button("إنشاء حساب الموظف"):
            uid = username.strip().lower()
            if not display.strip() or not uid or not password.strip():
                st.error("أكمل الاسم واسم المستخدم وكلمة المرور.")
            elif uid in accounts:
                st.error("اسم المستخدم مستخدم بالفعل.")
            else:
                accounts[uid] = {
                    "name": display.strip(),
                    "password": hash_password(password.strip()),
                    "role": "worker",
                    "permissions": permissions,
                }
                save_system_data()
                st.success("تم إنشاء الحساب.")
                st.rerun()

    with tab_backup:
        st.subheader("نسخة احتياطية من بيانات النظام")
        st.warning(
            "ملف JSON المحلي على Streamlit Community Cloud قد لا يبقى بعد إعادة إنشاء بيئة التشغيل. "
            "نزّل نسخة احتياطية بانتظام واحتفظ بها خارج الموقع."
        )
        backup_payload = {
            "credentials": st.session_state.credentials,
            "workers": st.session_state.workers,
            "commission_rate": st.session_state.commission_rate,
            "services": st.session_state.services,
            "products": st.session_state.products,
            "session_state_invoices": st.session_state.session_state_invoices,
            "business_orders": st.session_state.get("business_orders", []),
            "daily_sales": st.session_state.daily_sales,
            "daily_expenses": st.session_state.daily_expenses,
            "daily_archive": st.session_state.daily_archive,
            "monthly_archive": st.session_state.monthly_archive,
        }
        st.download_button(
            "⬇️ تنزيل نسخة احتياطية JSON",
            json.dumps(backup_payload, ensure_ascii=False, indent=2).encode("utf-8"),
            file_name=f"sabiha_backup_{dt.date.today()}.json",
            mime="application/json",
            use_container_width=True,
        )
        uploaded_backup = st.file_uploader("استعادة نسخة JSON احتياطية", type=["json"])
        confirm_restore = st.checkbox("أؤكد استبدال بيانات النظام الحالية بالنسخة المرفوعة")
        if st.button("استعادة النسخة الاحتياطية", disabled=not (uploaded_backup and confirm_restore)):
            try:
                imported = json.load(uploaded_backup)
                merged = deep_merge(default_data(), imported)
                for key in [
                    "credentials", "workers", "commission_rate", "services", "products",
                    "session_state_invoices", "business_orders", "daily_sales", "daily_expenses",
                    "daily_archive", "monthly_archive",
                ]:
                    st.session_state[key] = merged[key]
                save_system_data()
                st.success("تمت استعادة النسخة الاحتياطية.")
                st.rerun()
            except (json.JSONDecodeError, TypeError, KeyError) as error:
                st.error(f"ملف النسخة الاحتياطية غير صالح: {error}")


# =============================================================================
# Security and persistence reminders
# =============================================================================
if st.session_state.user_role == "owner":
    with st.sidebar.expander("ℹ️ تنبيهات مهمة"):
        st.caption(
            "غيّر كلمات المرور الافتراضية فوراً. لا تضع كلمات مرور حقيقية داخل ملف GitHub العام. "
            "للاستخدام الفعلي، انقل كلمات المرور إلى Streamlit Secrets واستخدم تخزيناً دائماً خارج "
            "ملفات التشغيل المحلية."
        )
