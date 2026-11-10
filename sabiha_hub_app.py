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
    visa_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method", "") == "فيزا")
    
    total_sales = cash_sales + visa_sales
    tax_amount = total_sales * 0.14
    worker_commissions = sum(inv["amount"] * 0.10 for inv in active_inv if inv.get("has_commission", True))
    net_profit = total_sales - tax_amount - worker_commissions
    total_cancelled_sum = sum(inv["amount"] for inv in cancelled_inv)

    # عرض جميع العدادات الخمسة بشكل رأسي واضح
    col_c = st.columns(1)
    with col_c:
        st.markdown(f'<div class="finance-card"><div class="card-title">💰 إجمالي المبيعات والدخل اليومي</div><div class="card-value-green">{total_sales} ج.م (كاش: {cash_sales} | فيزا: {visa_sales})</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card"><div class="card-title">📜 الضريبة العامة (14%)</div><div class="card-value-green">{tax_amount:.2f} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card"><div class="card-title">👥 إجمالي عمولات العمال اليومية</div><div class="card-value-green">{worker_commissions:.2f} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card" style="border:2px solid #64FFDA;"><div class="card-title" style="color:#64FFDA;">📈 صافي الأرباح الفعلي</div><div class="card-value-gold">{net_profit:.2f} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card" style="border:2px solid #D32F2F;"><div class="card-title" style="color:#D32F2F;">❌ مجموع حساب العمليات الملغاة</div><div class="card-value-green" style="color:#FF5252 !important;">{total_cancelled_sum} ج.م</div></div>', unsafe_allow_html=True)

    st.write("---")
    st.subheader("🏁 إنهاء اليوم وترحيل الحسابات للأرشيف")
    if st.button("🔒 تقفيل الوردية وترحيل الوردية الحالية أوتوماتيكياً"):
        if any(report["date"] == current_date_str for report in st.session_state.daily_reports):
            st.warning("⚠️ هذا اليوم مغلق ومرحّل مسبقاً!")
        else:
            st.session_state.daily_reports.append({
                "date": current_date_str, "month": current_month_str, "day_name": current_day_ar,
                "cash": cash_sales, "visa": visa_sales, "total": total_sales, "tax": tax_amount,
                "commissions": worker_commissions, "net_profit": net_profit, "cancelled_total": total_cancelled_sum
            })

save_data(daily_reports_file, st.session_state.daily_reports)
st.success("🎉 تم ترحيل أداء اليوم بنجاح إلى الأرشيف!")
st.rerun()
st.write("---")
st.write("### 🧾 كشف فواتير اليوم (تعديل وإلغاء)")
st.write("---")
st.write("### 🧾 كشف فواتير اليوم (تعديل وإلغاء)")
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
if st.button("👁️ تفاصيل الإلغاء", key=f"view_{inv['id']}"):
st.info(f"السبب: {inv.get('cancel_reason')} | بواسطة: {inv.get('cancelled_by')}")
elif menu == "📅 الأرشيف والحسابات الشهرية" and st.session_state.user_role == "owner":
st.title("📅 مجلد أرشيف الفواتير والحسابات الشهرية")
if st.session_state.daily_reports:
df_reports = pd.DataFrame(st.session_state.daily_reports)
selected_month = st.selectbox("📊 اختر الشهر لعرض حساباته:", df_reports['month'].unique())
month_df = df_reports[df_reports['month'] == selected_month]
st.write(f"#### 📁 أرشيف حسابات شهر {selected_month}")
df_display = month_df[["date", "day_name", "cash", "visa", "total", "tax", "commissions", "net_profit"]].copy()
df_display.columns = ["التاريخ الفعلي", "اليوم", "كاش (ج.م)", "فيزا (ج.م)", "إجمالي الدخل (ج.م)", "الضريبة 14%", "عمولات العمال", "صافي الربح"]
st.dataframe(df_display, use_container_width=True, hide_index=True)
else:
st.info("📂 لا توجد أيام مرحلة في الأرشيف المالي حتى الآن.")
st.write("---")
st.write("### 📜 سجل وأرشيف مراجعة الفواتير الكلي")
if st.session_state.invoices:
df_all_inv = pd.DataFrame(st.session_state.invoices)
st.dataframe(df_all_inv[["id", "date", "car_plate", "customer", "amount", "payment_method", "status"]], use_container_width=True, hide_index=True)
elif menu == "🛒 POS كاشير الاستقبال" or st.session_state.user_role == "worker":
st.subheader("📥 كاشير الاستقبال وتسجيل العمليات")
with st.form("car_form_pos"):
cust_name = st.text_input("اسم الزبون:")
cust_phone = st.text_input("رقم الهاتف (201xxxxxxxx):")
car_plate = st.text_input("رقم لوحة السيارة:")
pkg_options = [p["name"] for p in st.session_state.packages]
selected_pkg_name = st.selectbox("اختر الباقة المعتمدة:", pkg_options)
selected_pkg = next(p for p in st.session_state.packages if p["name"] == selected_pkg_name)
selected_workers = st.multiselect("تحديد طاقم العمل لتقسيم العمولة بالتساوي:", st.session_state.workers, max_selections=2)
pay_method = st.radio("طريقة دفع الفاتورة:", ["كاش", "فيزا"], horizontal=True)
submit_invoice = st.form_submit_button("✅ طباعة وتسجيل الفاتورة الحالية")
if submit_invoice and car_plate and selected_workers:
new_id = max([i["id"] for i in st.session_state.invoices]) + 1 if st.session_state.invoices else 101
new_inv = {
"id": new_id, "date": current_date_str, "month": current_month_str,
"customer_name": cust_name, "customer_phone": cust_phone, "car_plate": car_plate,
"customer": selected_pkg["name"], "amount": selected_pkg["price"], "status": "نشطة",
"has_commission": True, "assigned_workers": selected_workers, "payment_method": pay_method
}
st.session_state.invoices.append(new_inv)
save_data(invoices_file, st.session_state.invoices)
st.success(f"🎉 تم قيد الفاتورة رقم #{new_id} وحفظها سحابياً!")
pdf_bytes = generate_receipt_pdf(new_id, current_date_str, current_day_ar, car_plate, selected_pkg["name"], selected_pkg["price"], pay_method, cust_name, cust_phone)
st.download_button(label="📄 تحميل وطباعة إيصال الفاتورة (PDF)", data=pdf_bytes, file_name=f"Invoice_{new_id}.pdf", mime="application/pdf")
if cust_phone:
msg = f"مرحباً بك في Sabiha Hub 🚗\nتم تسجيل فاتورتك بنجاح رقم: #{new_id}\n🔹 إجمالي المبلغ: {selected_pkg['price']} ج.م"
st.markdown(f'📱 إرسال الفاتورة بالواتساب', unsafe_allow_html=True)
elif menu == "⚙️ إعدادات الباقات والعمال" and st.session_state.user_role == "owner":
st.subheader("⚙️ إعدادات التشغيل السحابية")
tab_p, tab_w = st.tabs(["✨ الباقات والعروض", "👥 طاقم العمال"])
with tab_p:
st.dataframe(pd.DataFrame(st.session_state.packages), use_container_width=True)
p_name = st.text_input("اسم الباقة الجديدة:")
p_price = st.number_input("سعر الباقة (ج.م):", min_value=0, step=50)
if st.button("حفظ الباقة"):
if p_name:
new_id = max([p["id"] for p in st.session_state.packages]) + 1 if st.session_state.packages else 1
st.session_state.packages.append({"id": new_id, "name": p_name, "price": p_price})
save_data(packages_file, st.session_state.packages)
st.success("تم الحفظ بنجاح")
st.rerun()



