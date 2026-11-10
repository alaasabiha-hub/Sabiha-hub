import streamlit as st
import pandas as pd
from datetime import datetime
import json
import os
import io
import urllib.parse

from reportlab.lib.pagesizes import letter
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer
)
from reportlab.lib.styles import (
    getSampleStyleSheet, ParagraphStyle
)
from reportlab.lib.enums import (
    TA_CENTER, TA_RIGHT
)

# ==========================================
# 1. إعدادات الثيم والخطوط البيضاء الواضحة
# ==========================================
st.set_page_config(
    page_title="Sabiha Hub", layout="wide"
)

st.markdown("""
    <style>
    .stApp {
        background-color: #0A192F !important;
    }
    html, body, [data-testid="stWidgetLabel"] p, 
    .stMarkdown p, h1, h2, h3, h4, h5, h6, 
    span, label, p {
        color: #FFFFFF !important;
        font-family: 'Cairo', sans-serif !important;
        font-weight: 500 !important;
    }
    .finance-card {
        background-color: #0F223A;
        border: 2px solid #FF3366;
        border-radius: 12px;
        padding: 22px;
        text-align: center;
        margin-bottom: 15px;
    }
    .card-title {
        font-size: 19px;
        font-weight: bold;
        color: #FFFFFF !important;
        margin-bottom: 12px;
    }
    .card-value-green {
        font-size: 32px;
        font-weight: bold;
        color: #00E676 !important;
    }
    .card-value-gold {
        font-size: 32px;
        font-weight: bold;
        color: #FFD700 !important;
    }
    .time-container {
        background-color: #172A45;
        padding: 8px 15px;
        border-radius: 8px;
        display: inline-block;
        font-size: 17px;
        color: #64FFDA !important;
        font-weight: bold;
        border: 1px solid #233554;
    }
    .cancel-badge {
        background-color: #D32F2F;
        color: white !important;
        padding: 4px 10px;
        border-radius: 4px;
        font-size: 13px;
        font-weight: bold;
    }
    </style>
""", unsafe_allow_html=True)

st.markdown(
    '<h1 style="color:#FF3366;text-align:center;'
    'font-size:38px;font-weight:bold;">'
    'Sabiha Hub</h1>', 
    unsafe_allow_html=True
)

# ==========================================
# 2. محرك التخزين السحابي والـ PDF
# ==========================================
def load_data(filename, default_value):
    if os.path.exists(filename):
        with open(filename, "r", encoding="utf-8") as f:
            try: return json.load(f)
            except: return default_value
    return default_value

def save_data(filename, data):
    with open(filename, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)

def generate_receipt_pdf(
    inv_id, date_str, day_ar, plate, 
    package, amount, method, cust_name, cust_phone
):
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer, pagesize=letter, 
        rightMargin=30, leftMargin=30, 
        topMargin=30, bottomMargin=30
    )
    story = []
    styles = getSampleStyleSheet()
    
    title_style = ParagraphStyle(
        'T', parent=styles['Heading1'], 
        alignment=TA_CENTER, fontSize=24
    )
    body_style = ParagraphStyle(
        'B', parent=styles['Normal'], 
        alignment=TA_RIGHT, fontSize=14
    )
    
    story.append(Paragraph("SABIHA HUB", title_style))
    story.append(Spacer(1, 15))
    story.append(Paragraph(f"رقم الفاتورة: #{inv_id}", body_style))
    story.append(Paragraph(f"التاريخ: {date_str}", body_style))
    story.append(Paragraph(f"الزبون: {cust_name} - {cust_phone}", body_style))
    story.append(Paragraph(f"اللوحة: {plate}", body_style))
    story.append(Paragraph(f"الباقة: {package}", body_style))
    story.append(Paragraph(f"الإجمالي: {amount} ج.م", body_style))
    
    doc.build(story)
    p_bytes = buffer.getvalue()
    buffer.close()
    return p_bytes

arabic_days = {
    "Monday": "الإثنين", "Tuesday": "الثلاثاء", 
    "Wednesday": "الأربعاء", "Thursday": "الخميس", 
    "Friday": "الجمعة", "Saturday": "السبت", "Sunday": "الأحد"
}

invoices_file = "invoices_db.json"
workers_file = "workers_db.json"
packages_file = "packages_db.json"
session_file = "session_db.json"
daily_reports_file = "daily_reports_db.json"

st.session_state.workers = load_data(
    workers_file, ["أحمد مصطفى", "محمد علي", "كومار"]
)
st.session_state.packages = load_data(
    packages_file, [
        {"id": 1, "name": "غسيل سريع", "price": 200},
        {"id": 2, "name": "ديتيلينج كامل", "price": 1500}
    ]
)
st.session_state.invoices = load_data(invoices_file, [])
st.session_state.daily_reports = load_data(daily_reports_file, [])

saved_session = load_data(
    session_file, {"logged_in": False, "user_role": None}
)
if "logged_in" not in st.session_state or not st.session_state.logged_in:
    st.session_state.logged_in = saved_session["logged_in"]
    st.session_state.user_role = saved_session["user_role"]

now = datetime.now()
current_date_str = now.strftime("%Y-%m-%d")
current_month_str = now.strftime("%Y-%m")
current_day_ar = arabic_days.get(now.strftime("%A"), now.strftime("%A"))

# ==========================================
# 3. شاشة تسجيل الدخول
# ==========================================
if not st.session_state.logged_in:
    st.subheader("🔐 تسجيل الدخول إلى نظام Sabiha Hub")
    username = st.text_input("اسم المستخدم:")
    password = st.text_input("كلمة المرور:", type="password")
    if st.button("🔑 دخول النظام"):
        if username == "owner" and password == "sabiha2026":
            st.session_state.logged_in = True
            st.session_state.user_role = "owner"
            save_data(session_file, {"logged_in": True, "user_role": "owner"})
            st.rerun()
        elif username == "worker" and password == "pos123":
            st.session_state.logged_in = True
            st.session_state.user_role = "worker"
            save_data(session_file, {"logged_in": True, "user_role": "worker"})
            st.rerun()
        else:
            st.error("❌ بيانات الدخول غير صحيحة!")
    st.stop()

# ==========================================
# 4. القائمة الجانبية والصلاحيات
# ==========================================
st.sidebar.markdown(f"👤 الحساب: **{'👑 المالك' if st.session_state.user_role == 'owner' else '🛠️ كاشير العمال'}**")

if st.session_state.user_role == "owner":
    menu = st.sidebar.radio(
        "انتقل بين الصفحات:",
        [
            "📊 الأداء لليوم", 
            "📅 الأرشيف والحسابات الشهرية", 
            "🛒 POS كاشير الاستقبال", 
            "⚙️ إعدادات الباقات والعمال"
        ]
    )
else:
    menu = st.sidebar.radio(
        "انتقل بين الصفحات:", 
        ["🛒 POS كاشير الاستقبال"]
    )

if st.sidebar.button("🚪 تسجيل الخروج"):
    st.session_state.logged_in = False
    st.session_state.user_role = None
    save_data(session_file, {"logged_in": False, "user_role": None})
    st.rerun()

# ==========================================
# 5. استعراض الحسابات والعدادات الـ 5
# ==========================================
if menu == "📊 الأداء لليوم" and st.session_state.user_role == "owner":
    st.title("📊 الأداء المالي والتشغيلي لليوم")
    
    f_time = f"📅 اليوم: {current_day_ar} | التاريخ: {current_date_str}"
    st.markdown(f'<div class="time-container">{f_time}</div>', unsafe_allow_html=True)
    st.write(" ")

    active_inv = [inv for inv in st.session_state.invoices if inv["status"] == "نشطة"]
    cancelled_inv = [inv for inv in st.session_state.invoices if inv["status"] == "ملغاة"]
    
    cash_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method", "كاش") == "كاش")
        # حساب وبناء مربعات الأداء لليوم (تكملة لصفحة الأداء لليوم الحالية)
        # --- حساب وبناء مربعات الأداء لليوم (إزاحة 8 مسافات دقيقة للداخل) ---
        col_a, col_b, col_c = st.columns(3)
        with col_a:
            st.metric("إجمالي مبيعات اليوم", f"{sum(inv['amount'] for inv in active_inv)} ج.م")
        with col_b:
            st.metric("المبيعات الكاش", f"{cash_sales} ج.م")
        with col_c:
            st.metric("مبيعات الفيزا", f"{sum(inv['amount'] for inv in active_inv if inv.get('payment_method') == 'فيزا')} ج.م")

        st.write("---")
        st.write("### 🧾 كشف فواتير اليوم (تعديل وإلغاء)")

        if "invoices" in st.session_state and st.session_state.invoices:
            for inv in st.session_state.invoices:
                c1, c2, c3, c4 = st.columns(4)
                with c1:
                    st.write(f"#{inv['id']} - {inv['customer']}")
                with c2:
                    st.write(f"{inv['amount']} ج.م ({inv.get('payment_method', 'كاش')})")
                with c3:
                    if inv.get('status') != 'cancelled':
                        if st.button("إلغاء الفاتورة", key=f"cancel_{inv['id']}"):
                            inv['status'] = 'cancelled'
                            inv['amount'] = 0
                            st.success(f"تم إلغاء الفاتورة رقم {inv['id']}")
                            st.rerun()
                    else:
                        st.warning("ملغاة ❌")
                with c4:
                    if st.button("حذف نهائي", key=f"del_{inv['id']}"):
                        st.session_state.invoices.remove(inv)
                        st.success("تم الحذف بنجاح!")
                        st.rerun()
        else:
            st.info("لا توجد فواتير مسجلة اليوم.")

# --- بناء بقية الصفحات لتظهر عند الضغط عليها في القائمة الجانبية (تبدأ من أول السطر تماماً جهة اليسار) ---
elif menu == "كاشير الاستقبال POS" and st.session_state.user_role == "owner":
    st.title("🛒 كاشير الاستقبال POS")
    st.write("---")
    st.info("شاشة الكاشير ونظام نقطة البيع جاهز لإضافة محتواك.")

elif menu == "إعدادات الباقات والعمال" and st.session_state.user_role == "owner":
    st.title("⚙️ إعدادات الباقات والخدمات")
    st.write("---")
    st.info("شاشة إدارة الخدمات والباقات والعمال المتاحة بالمغسلة.")

# --- تنظيف وإصلاح ألوان الثيم والخانات والقائمة الجانبية (تبدأ من أول السطر تماماً جهة اليسار) ---
st.markdown("""
    <style>
        /* إجبار القائمة الجانبية على إظهار النصوص باللون الأسود الداكن بوضوح */
        [data-testid="stSidebar"] [data-testid="stMarkdownContainer"] p, 
        [data-testid="stSidebar"] span, 
        [data-testid="stSidebar"] label,
        [data-testid="stSidebar"] a {
            color: #111111 !important;
            font-size: 15px !important;
            font-weight: bold !important;
        }
        /* إصلاح الخانات البيضاء ليكون النص المكتوب داخلها أسود واضح جداً */
        input, select, textarea, div[data-baseweb="input"] input {
            color: #111111 !important;
            background-color: #ffffff !important;
            -webkit-text-fill-color: #111111 !important;
        }
        /* إصلاح نصوص التنبيهات والمقاييس لكي تظهر بوضوح */
        .stAlert p, [data-testid="stMetricValue"] {
            color: #111111 !important;
        }
    </style>
""", unsafe_allow_html=True)
