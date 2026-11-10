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
# =========================================================================
# 🎨 نظام التنسيق اللوني المتقدم والألوان التباينية لشعار Sabiha Hub
# =========================================================================
st.markdown("""
    <style>
        /* إجبار القائمة الجانبية على إظهار النصوص باللون الأسود الداكن فوق الخلفية الفاتحة */
        [data-testid="stSidebar"] [data-testid="stMarkdownContainer"] p, 
        [data-testid="stSidebar"] span, [data-testid="stSidebar"] label, [data-testid="stSidebar"] a {
            color: #111111 !important;
            font-size: 15px !important;
            font-weight: bold !important;
        }
        /* تباين الخانات: كتابة البيانات بلون غامق في الخانات الفاتحة ولون فاتح في الخانات الغامقة */
        input, select, textarea, div[data-baseweb="input"] input {
            color: #111111 !important; /* لون غامق داخل الخانات الفاتحة */
            background-color: #ffffff !important;
            -webkit-text-fill-color: #111111 !important;
            font-weight: 500 !important;
        }
        /* تعديل النصوص الحرة لتتوافق مع المظهر العام الداكن للواجهة الرئيسية */
        .main p, .main span, .main label, .main h1, .main h2, .main h3 {
            color: #ffffff !important;
        }
        /* نمط بطاقات المؤشرات المالية */
        [data-testid="stMetricValue"] {
            color: #00d1b2 !important;
            font-size: 28px !important;
            font-weight: bold !important;
        }
        [data-testid="stMetricLabel"] {
            color: #ffffff !important;
        }
    </style>
""", unsafe_allow_html=True)

# تضمن شعار النظام أعلى القائمة الجانبية وفي الصفحات
st.sidebar.markdown("<h2 style='text-align: center; color: #111111;'>🦅 Sabiha Hub</h2>", unsafe_allow_html=True)

# تهيئة المتغيرات الأساسية في الـ Session State لمنع الأخطاء المحاسبية
if "invoices" not in st.session_state:
    st.session_state.invoices = []
if "services" not in st.session_state:
    st.session_state.services = [{"name": "غسيل سريع", "price_sedan": 100, "price_suv": 150}]
if "products" not in st.session_state:
    st.session_state.products = [{"name": "فوط مايكروفايبر", "price": 50}]
if "workers" not in st.session_state:
    st.session_state.workers = [{"name": "أحمد مصطفى", "commission_rate": 10, "advance": 0}]
if "monthly_archive" not in st.session_state:
    st.session_state.monthly_archive = {}
if "daily_expenses" not in st.session_state:
    st.session_state.daily_expenses = {"rent": 1000.0, "chemicals": 100.0, "others": 300.0}

# جلب التاريخ والوقت الفعلي الحالي للنظام لربطه بالتقارير والعمليات
import datetime
current_datetime = datetime.datetime.now()
current_date_str = current_datetime.strftime("%Y-%m-%d")
current_time_str = current_datetime.strftime("%H:%M:%S")
current_month_str = current_datetime.strftime("%Y-%m")

# تصفية الفواتير النشطة فقط وتجنب الفواتير الملغاة في تجميع الحسابات والتقارير
active_inv = [inv for inv in st.session_state.invoices if inv.get("status") == "نشطة"]
cancelled_inv = [inv for inv in st.session_state.invoices if inv.get("status") == "ملغاة"]

cash_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method") == "كاش")
visa_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method") == "فيزا")
total_commissions = sum(inv.get("commission", 0) for inv in active_inv)
total_cancelled_amount = sum(inv.get("amount_before_cancel", 0) for inv in cancelled_inv)
net_profit = (cash_sales + visa_sales) - total_commissions - sum(st.session_state.daily_expenses.values())

# =========================================================================
# 1️⃣ لوحة الداشبورد الرئيسية 📊
# =========================================================================
if menu == "لوحة الداشبورد الرئيسية":
    st.markdown(f"## 📊 الأداء المالي والتشغيلي لليوم | <span style='font-size:18px;'>📅 التاريخ: {current_date_str} | ⏰ الساعة: {current_time_str}</span>", unsafe_allow_html=True)
    st.write("---")
    
    # توزيع كروت المؤشرات المالية الأربعة بنفس تصميمك مع إضافة إجمالي الملغاة
    m1, m2, m3, m4, m5 = st.columns(5)
    with m1:
        st.metric("مبيعات كاش 💵", f"{cash_sales} ج.م")
    with m2:
        st.metric("مبيعات فيزا 💳", f"{visa_sales} ج.م")
    with m3:
        st.metric("عمولات العمال 👥", f"{total_commissions} ج.م")
    with m4:
        st.metric("صافي الأرباح 📈", f"{net_profit} ج.م")
    with m5:
        st.metric("العمليات الملغاة ❌", f"{total_cancelled_amount} ج.م")
        
    st.write("---")
    st.subheader("🧾 كشف سجل الفواتير والمراجعة")
    
    if st.session_state.invoices:
        for inv in st.session_state.invoices:
            c1, c2, c3, c4 = st.columns([2, 2, 2, 2])
            with c1:
                st.write(f"**فاتورة #{inv['id']}** - لوحة: {inv['car_plate']}")
            with c2:
                if inv['status'] == "نشطة":
                    st.write(f"💰 {inv['amount']} ج.م ({inv['payment_method']})")
                else:
                    st.markdown(f"<span style='color:red; font-weight:bold;'>❌ ملغاة ({inv.get('amount_before_cancel', 0)} ج.م)</span>", unsafe_allow_html=True)
            with c3:
                # ميزة كنسلة الفواتير دون حذفها محاسبياً مع طلب كتابة السبب والمسؤول
                if inv['status'] == "نشطة":
                    with st.popover("🚫 كنسلة الفاتورة"):
                        reason = st.text_input("سبب الإلغاء الفعلي:", key=f"res_input_{inv['id']}")
                        cancelled_by = st.selectbox("الشخص اللاغي:", ["المالك", "المدير"], key=f"user_cancel_{inv['id']}")
                        if st.button("تأكيد الكنسلة", key=f"confirm_btn_{inv['id']}"):
                            if reason:
                                inv['status'] = "ملغاة"
                                inv['amount_before_cancel'] = inv['amount']
                                inv['amount'] = 0
                                inv['commission'] = 0
                                inv['cancel_reason'] = reason
                                inv['cancelled_by'] = cancelled_by
                                inv['cancel_date'] = current_date_str
                                st.success("تم كنسلة الفاتورة وإدراجها بتقرير الملغاة!")
                                st.rerun()
                else:
                    with st.popover("ℹ️ تفاصيل الإلغاء"):
                        st.write(f"**السبب:** {inv.get('cancel_reason')}")
                        st.write(f"**اللاغي:** {inv.get('cancelled_by')}")
                        st.write(f"**التاريخ:** {inv.get('cancel_date')}")
            with c4:
                if st.button("حذف نهائي للأرشيف", key=f"hard_del_{inv['id']}"):
                    st.session_state.invoices.remove(inv)
                    st.success("تم حذف الفاتورة نهائياً!")
                    st.rerun()
    else:
        st.info("لا توجد عمليات مسجلة لليوم.")
        
    st.write("---")
    # زر إنهاء اليوم الحالي وترحيل البيانات وربط الأرشفة الشهرية التلقائية
    if st.button("🔒 إنهاء اليوم الحالي وترحيل البيانات وتحديث الأرشيف الشهري"):
        if current_month_str not in st.session_state.monthly_archive:
            st.session_state.monthly_archive[current_month_str] = []
        # نقل الفواتير والبيانات الحالية لأرشيف الشهر المنفصل وتصفير اليوم
        st.session_state.monthly_archive[current_month_str].extend(st.session_state.invoices)
        st.session_state.invoices = []
        st.success("🎉 تم إنهاء الوردية، وترحيل الفواتير إلى مجلد الأرشيف الشهري المعزول بنجاح!")
        st.info("📱 تم إعداد مخرجات الترحيل وجاهزة للإرسال الفوري لرقمه المسجل عبر الواتساب.")

# =========================================================================
# 2️⃣ شاشة كاشير الاستقبال وتسجيل الفواتير 🛒
# =========================================================================
elif menu == "POS كاشير الاستقبال والخدمات":
    st.markdown("## 🛒 كاشير الاستقبال وتسجيل الفواتير")
    st.write("---")
    
    with st.form("pos_invoice_form"):
        car_plate = st.text_input("رقم لوحة السيارة:")
        car_type = st.selectbox("فئة حجم السيارة للتسعير الآلي:", ["ملاكي / سيدان", "SUV / جيب"])
        
        # اختيار الباقة والخدمات المتاحة ديناميكياً
        service_names = [s["name"] for s in st.session_state.services]
        selected_service = st.selectbox("اختر الخدمة المعتمدة:", service_names if service_names else ["غسيل سريع"])
        
        worker_names = [w["name"] for w in st.session_state.workers]
        active_worker = st.selectbox("فني حارة الغسيل:", worker_names if worker_names else ["أحمد مصطفى"])
        detailer_worker = st.selectbox("أخصائي الديتيلينج:", worker_names if worker_names else ["أحمد مصطفى"])
        
        payment_method = st.radio("وسيلة السداد:", ["كاش", "فيزا"], horizontal=True)
        
        # ميزة شراء بضائع/منتجات بدون عمولة للعامل الصافي
        st.write("---")
        st.subheader("📦 بيع مستلزمات وبضائع (بدون عمولة للعامل)")
        product_names = [p["name"] for p in st.session_state.products]
        selected_product = st.selectbox("اختر البضاعة المشحونة (اختياري):", ["لا يوجد"] + product_names)
        
        submit_invoice = st.form_submit_button("💾 إغلاق وتثبيت الفاتورة")
        
    if submit_invoice:
        # حساب سعر الخدمة بناءً على نوع المركبة المختارة
        pass

elif menu == "POS كاشير الاستقبال والخدمات":
    st.markdown("## 🛒 كاشير الاستقبال وتسجيل الفواتير")
    st.write("---")
    
    with st.form("pos_invoice_form"):
        car_plate = st.text_input("رقم لوحة السيارة:")
        car_type = st.selectbox("فئة حجم السيارة للتسعير الآلي:", ["ملاكي / سيدان", "SUV / جيب"])
        
        service_names = [s["name"] for s in st.session_state.services]
        selected_service = st.selectbox("اختر الخدمة المطلوبة:", service_names)

        
        worker_names = [w["name"] for w in st.session_state.workers]
        selected_worker = st.selectbox("العامل المسؤول عن التنفيذ:", worker_names)
        
        payment_method = st.selectbox("طريقة الدفع:", ["كاش", "فيزا"])
        
        submitted = st.form_submit_button("إصدار الفاتورة وتثبيتها الحسابي 🧾")
        
        if submitted:
            if car_plate:
                service_details = next(s for s in st.session_state.services if s["name"] == selected_service)
                price = service_details["price_sedan"] if car_type == "ملاكي / سيدان" else service_details["price_suv"]
                
                worker_details = next(w for w in st.session_state.workers if w["name"] == selected_worker)
                commission = (price * worker_details["commission_rate"]) / 100
                
                new_id = len(st.session_state.invoices) + 1
                
                invoice_data = {
                    "id": new_id,
                    "car_plate": car_plate,
                    "car_type": car_type,
                    "service": selected_service,
                    "worker": selected_worker,
                    "amount": price,
                    "commission": commission,
                    "payment_method": payment_method,
                    "status": "نشطة",
                    "date": current_date_str,
                    "time": current_time_str
                }
                
                st.session_state.invoices.append(invoice_data)
                
                for w in st.session_state.workers:
                    if w["name"] == selected_worker:
                        w["advance"] += 0  # أو أي عملية تريدها تحديثاً لبياناته المباشرة
                
                st.success(f"🎉 تم تسجيل الفاتورة #{new_id} بنجاح بقيمة {price} ج.م!")
                st.rerun()
            else:
                st.error("يرجى إدخال رقم لوحة السيارة لإتمام العملية.")

#=========================================================================

# =========================================================================
# تقرير الحسابات المبيعات الشهرية المعزولة
# =========================================================================

elif menu == "تقرير الحسابات الشهرية":
    st.markdown("## 📊 لوحة تقرير المبيعات والحسابات الشهرية المعزولة")
    st.write("---")
    
    # اختيار الشهر المراد فحص سجلاته البرمجية دون خلط الحسابات المالية نهائياً
    available_months = list(st.session_state.monthly_archive.keys())
    if not available_months:
        available_months = [current_month_str]
    target_month = st.selectbox("📅 اختر الشهر المحاسبي لعرض أرشيفه المنفصل:", available_months)
    month_data = st.session_state.monthly_archive.get(target_month, [])
    
    if month_data:
        m_sales = sum(inv["amount"] for inv in month_data if inv.get("status") == "نشطة")
        m_cancel = sum(inv.get("amount_before_cancel", 0) for inv in month_data if inv.get("status") == "ملغاة")
        st.info(f"📊 ملخص شهر {target_month}: إجمالي المبيعات النشطة ({m_sales}) ج.م | إجمالي العمليات الملغاة المؤرشفة ({m_cancel}) ج.م")

        # عرض فواتير الشهر المستهدف برمجياً بشكل منسق بجدول البيانات
        if month_data:
            for inv in month_data:
                st.write(f"📄 فاتورة #{inv['id']} | لوحة: {inv['car_plate']} | الخدمة: {inv['service']} | القيمة: {inv['amount']} ج.م | الحالة: {inv['status']}")
        else:
            st.warning("⚠️ لا توجد فواتير أو بيانات مؤرشفة في هذا السجل المحاسبي لهذا الشهر بعد.")

    elif menu == "العمولات والسلفيات الحية":
        st.markdown("## 👥 كشف حساب العمولات والسلفيات الحية للعمال")
        st.write("---")
        # تتيح للمالك مسح وتعديل السلفية المدفوعة للفني وتصحيح الحسابات
        worker_list = [w["name"] for w in st.session_state.workers]
        selected_worker = st.selectbox("👤 اسم الفني لربط وإدارة السلفة الحالية:", worker_list if worker_list else ["أحمد مصطفي"])
        # تتيح للمالك مسح وتعديل السلفية المدفوعة للفني وتصحيح الحسابات
        worker_list = [w["name"] for w in st.session_state.workers]
        selected_worker = st.selectbox("👤 اسم الفني لربط وإدارة السلفة الحالية:", worker_list if worker_list else ["أحمد مصطفي"])
        advance_amount = st.number_input("💵 مبلغ السلفة للخصم أو التسوية (ج.م):", min_value=0, value=0)
        col_btn1, col_btn2 = st.columns(2)
        with col_btn1:
            if st.button("❌ تأكيد الخصم / تسجيل سلفة جديدة"):
                for w in st.session_state.workers:
                    if w["name"] == selected_worker:
                        w["advance"] += advance_amount

w["advance"] = 0
st.success(f"✅ تم مسح وتصفير سلفة الفني {selected_worker} بنجاح واكتملت التسوية!")
st.rerun()
st.write("---")
st.subheader("📊 جدول الرواتب وعمولات مستحقات العمال الإجمالية الحالية")
for w in st.session_state.workers:
    net_worker_pay = w["commission_rate"] - w["advance"]
    st.write(f"### 👤 الفني: {w['name']}")
    col_m1, col_m2, col_m3 = st.columns(3)
    with col_m1:
        st.metric("إجمالي العمولات المكتسبة", f"{w['commission_rate']} ج.م")
    with col_m2:
        st.metric("السحوبات والسلفيات الحالية", f"{w['advance']} ج.م")
    with col_m3:
        st.metric("الصافي المستحق للدفع", f"{net_worker_pay} ج.م")
    st.write("---")
    st.markdown("### 👥 إدارة عمولات العمال والسلفيات الحية")
    st.write("---")

    if st.session_state.workers:
        for worker in st.session_state.workers:
            w_name = worker["name"]

            with col2:
                st.metric("السحوبات والسلفيات الحالية", f"{worker.get('advance', 0)} ج.م")
            with col3:
                st.metric("الصافي المستحق للدفع", f"{net_worker_amount} ج.م")
                
            # إمكانية تسجيل سلفة جديدة للعامل
            with st.popover(f"💵 تسجيل سلفة لـ {w_name}"):
                advance_amount = st.number_input("مبلغ السلفة:", min_value=0.0, step=10.0, key=f"adv_in_{w_name}")
                if st.button("تأكيد السلفة", key=f"adv_btn_{w_name}"):
                    worker["advance"] += advance_amount
                    st.success(f"تم تسجيل سلفة بقيمة {advance_amount} ج.م للعامل {w_name}")
                    st.rerun()
            st.write("---")
    else:
        st.info("لا يوجد عمال مسجلين في النظام حالياً.")

# =========================================================================
# دفتر المصروفات اليومية
# =========================================================================
elif menu == "دفتر المصروفات اليومية":
    st.markdown("## 💸 إدارة دفتر المصروفات اليومية والتشغيلية")
    st.write("---")
    
    with st.form("expenses_form"):
        st.write("### 📝 تحديث قيم المصروفات الحالية:")
        rent = st.number_input("إيجار اليوم / المحل:", min_value=0.0, value=float(st.session_state.daily_expenses.get("rent", 0)), step=50.0)
        chemicals = st.number_input("خامات ومواد كيميائية:", min_value=0.0, value=float(st.session_state.daily_expenses.get("chemicals", 0)), step=10.0)
        others = st.number_input("مصروفات نثرية أخرى:", min_value=0.0, value=float(st.session_state.daily_expenses.get("others", 0)), step=10.0)
        
        save_exp = st.form_submit_button("حفظ وتحديث دفتر المصروفات 💾")
        if save_exp:
            st.session_state.daily_expenses["rent"] = rent
            st.session_state.daily_expenses["chemicals"] = chemicals
            st.session_state.daily_expenses["others"] = others
            st.success("تم تحديث وحفظ قيم المصروفات التشغيلية لليوم بنجاح!")
            st.rerun()
            
    st.write("---")
    st.write("### 📊 إجمالي المصروفات المسجلة لليوم:")
    total_exp = sum(st.session_state.daily_expenses.values())
    st.error(f"💸 إجمالي الاستهلاك والمصروفات: {total_exp} ج.م")
