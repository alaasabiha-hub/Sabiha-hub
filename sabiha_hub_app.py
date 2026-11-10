import streamlit as st
import pandas as pd
from datetime import datetime
import json
import os
import io
import urllib.parse

# استيراد أدوات مكتبة ReportLab لتوليد ملفات الـ PDF برمجياً وبدقة
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_CENTER, TA_RIGHT

# ==========================================
# 1. إعدادات الصفحة والثيم بالأزرق الملكي والحدود الحمراء
# ==========================================
st.set_page_config(page_title="Sabiha Hub Dashboard", layout="wide")

st.markdown("""
    <style>
    .stApp {
        background-color: #0A192F !important;
    }
    html, body, [data-testid="stWidgetLabel"] p, .stMarkdown p, h1, h2, h3, h4, h5, h6, span {
        color: #E2E8F0 !important;
        font-family: 'Cairo', sans-serif;
    }
    /* تصميم البطاقات المخصصة المطابقة تماماً لواجهة الأداء لليوم */
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
        color: #E2E8F0;
        margin-bottom: 12px;
    }
    .card-value-green {
        font-size: 34px;
        font-weight: bold;
        color: #00E676;
    }
    .card-value-gold {
        font-size: 34px;
        font-weight: bold;
        color: #FFD700;
    }
    .logo-container {
        text-align: center;
        padding: 5px;
    }
    .time-container {
        background-color: #172A45;
        padding: 8px 15px;
        border-radius: 8px;
        display: inline-block;
        font-size: 16px;
        color: #64FFDA !important;
        font-weight: bold;
        border: 1px solid #233554;
    }
    .cancel-badge {
        background-color: #D32F2F;
        color: white;
        padding: 4px 10px;
        border-radius: 4px;
        font-size: 13px;
        font-weight: bold;
    }
    </style>
""", unsafe_allow_html=True)

def display_centered_logo():
    st.markdown('<div class="logo-container">', unsafe_allow_html=True)
    st.image("https://placeholder.com", width=180)
    st.markdown('</div>', unsafe_allow_html=True)

display_centered_logo()
# ==========================================
# 2. محرك التخزين السحابي ودالة إنشاء الـ PDF ببيانات العميل
# ==========================================
def load_data(filename, default_value):
    if os.path.exists(filename):
        with open(filename, "r", encoding="utf-8") as f:
            try: return json.load(f)
            except json.JSONDecodeError: return default_value
    return default_value

def save_data(filename, data):
    with open(filename, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)

# دالة مخصصة لإنشاء بايتات ملف الـ PDF لطباعة الإيصال الفوري للعميل
def generate_receipt_pdf(inv_id, date_str, day_ar, plate, package, amount, method, cust_name, cust_phone):
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=letter, rightMargin=30, leftMargin=30, topMargin=30, bottomMargin=30)
    story = []
    
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle('Title', parent=styles['Heading1'], alignment=TA_CENTER, fontSize=24, spaceAfter=15)
    header_style = ParagraphStyle('Header', parent=styles['Normal'], alignment=TA_CENTER, fontSize=12, spaceAfter=20)
    body_style = ParagraphStyle('Body', parent=styles['Normal'], alignment=TA_RIGHT, fontSize=14, spaceAfter=10)
    footer_style = ParagraphStyle('Footer', parent=styles['Normal'], alignment=TA_CENTER, fontSize=12, spaceBefore=30)
    
    story.append(Paragraph("SABIHA HUB", title_style))
    story.append(Paragraph(f"INVOICE RECEIPT / إيصال فاتورة عميل", header_style))
    story.append(Spacer(1, 15))
    
    story.append(Paragraph(f"Invoice No / رقم الفاتورة: #{inv_id}", body_style))
    story.append(Paragraph(f"Date / التاريخ: {date_str} ({day_ar})", body_style))
    story.append(Paragraph(f"Customer Name / اسم العميل: {cust_name if cust_name else 'عميل نقدي'}", body_style))
    story.append(Paragraph(f"Customer Phone / رقم الهاتف: {cust_phone if cust_phone else 'غير مسجل'}", body_style))
    story.append(Paragraph(f"Car Plate / رقم اللوحة: {plate}", body_style))
    story.append(Paragraph(f"Service / الخدمة والباقة: {package}", body_style))
    story.append(Paragraph(f"Payment Method / طريقة السداد: {method}", body_style))
    story.append(Spacer(1, 10))
    story.append(Paragraph(f"Total Amount / الإجمالي المدفوع: {amount} EGP / جنيه مصري (شامل 14% ضريبة)", body_style))
    
    story.append(Spacer(1, 20))
    story.append(Paragraph("Thank you for choosing Sabiha Hub! / شكراً لزيارتكم لنا!", footer_style))
    
    doc.build(story)
    pdf_bytes = buffer.getvalue()
    buffer.close()
    return pdf_bytes

arabic_days = {
    "Monday": "الإثنين", "Tuesday": "الثلاثاء", "Wednesday": "الأربعاء",
    "Thursday": "الخميس", "Friday": "الجمعة", "Saturday": "السبت", "Sunday": "الأحد"
}

invoices_file = "invoices_db.json"
workers_file = "workers_db.json"
packages_file = "packages_db.json"
session_file = "session_db.json"
daily_reports_file = "daily_reports_db.json"

st.session_state.workers = load_data(workers_file, ["أحمد مصطفى", "محمد علي", "كومار"])
st.session_state.packages = load_data(packages_file, [
    {"id": 1, "name": "غسيل سريع ملاكي", "price": 200},
    {"id": 2, "name": "ديتيلينج كامل الملكي", "price": 1500}
])
st.session_state.invoices = load_data(invoices_file, [])
st.session_state.daily_reports = load_data(daily_reports_file, [])

saved_session = load_data(session_file, {"logged_in": False, "user_role": None})
if "logged_in" not in st.session_state or not st.session_state.logged_in:
    st.session_state.logged_in = saved_session["logged_in"]
    st.session_state.user_role = saved_session["user_role"]

now = datetime.now()
current_date_str = now.strftime("%Y-%m-%d")
current_month_str = now.strftime("%Y-%m")
day_name_en = now.strftime("%A")
current_day_ar = arabic_days.get(day_name_en, day_name_en)
# ==========================================
# 3. شاشة تسجيل الدخول الموحدة والمؤمنة
# ==========================================
if not st.session_state.logged_in:
    st.subheader("🔐 تسجيل الدخول إلى نظام Sabiha Hub")
    col_login = st.columns(1)
    with col_login[0]:
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
# 4. صلاحيات القائمة الجانبية المربوطة سحابياً ضد الريفريش
# ==========================================
st.sidebar.markdown(f"👤 الحساب: **{'👑 المالك' if st.session_state.user_role == 'owner' else '🛠️ كاشير العمال'}**")

if st.session_state.user_role == "owner":
    menu = st.sidebar.radio(
        "انتقل بين الصفحات:",
        ["📊 الأداء المالي والتشغيلي لليوم", "📅 تقرير الحسابات الشهرية والأرشيف", "🛒 POS كاشير الاستقبال والبيع", "⚙️ إعدادات الباقات والعمال"]
    )
else:
    menu = st.sidebar.radio("انتقل بين الصفحات:", ["🛒 POS كاشير الاستقبال والبيع"])

st.sidebar.write("---")
if st.sidebar.button("🚪 تسجيل الخروج"):
    st.session_state.logged_in = False
    st.session_state.user_role = None
    save_data(session_file, {"logged_in": False, "user_role": None})
    st.rerun()
    # ==========================================
# 5. استعراض وتحميل منطق الصفحات والحسابات
# ==========================================

# --- [صفحة المالك] 1. الأداء المالي والتشغيلي لليوم ---
if menu == "📊 الأداء المالي والتشغيلي لليوم" and st.session_state.user_role == "owner":
    st.title("📊 الأداء المالي والتشغيلي لليوم")
    
    formatted_date_time = f"📅 اليوم: {current_day_ar} | التاريخ: {current_date_str} | 🕒 الساعة: {now.strftime('%H:%M:%S')}"
    st.markdown(f'<div class="time-container">{formatted_date_time}</div>', unsafe_allow_html=True)
    st.write(" ")

    active_inv = [inv for inv in st.session_state.invoices if inv["status"] == "نشطة" and inv.get("date") == current_date_str]
    
    cash_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method", "كاش") == "كاش")
    visa_sales = sum(inv["amount"] for inv in active_inv if inv.get("payment_method", "") == "فيزا")
    total_sales = cash_sales + visa_sales
    tax_amount = total_sales * 0.14
    worker_commissions = sum(inv["amount"] * 0.10 for inv in active_inv if inv.get("has_commission", True))
    net_profit = total_sales - tax_amount - worker_commissions
    
    col_cards, _ = st.columns()
    with col_cards:
        st.markdown(f'<div class="finance-card"><div class="card-title">💵 مبيعات كاش اليوم</div><div class="card-value-green">{cash_sales} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card"><div class="card-title">💳 مبيعات فيزا اليوم</div><div class="card-value-green">{visa_sales} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card"><div class="card-title">📜 ضريبة اليوم 14%</div><div class="card-value-green">{tax_amount:.2f} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card"><div class="card-title">👥 عمولات عمال اليوم</div><div class="card-value-green">{worker_commissions:.2f} ج.م</div></div>', unsafe_allow_html=True)
        st.markdown(f'<div class="finance-card" style="border: 2px solid #64FFDA;"><div class="card-title" style="color: #64FFDA;">📈 صافي أرباح اليوم الفعلي</div><div class="card-value-gold">{net_profit:.2f} ج.م</div></div>', unsafe_allow_html=True)

    st.write("---")
    st.write("### 🔒 إدارة نهاية الوردية وتقفيل اليوم")
    if st.button("🔒 تقفيل الوردية وإغلاق اليوم الحالي وترحيله للأرشيف"):
        if any(report["date"] == current_date_str for report in st.session_state.daily_reports):
            st.warning("⚠️ هذا اليوم تم إغلاقه وترحيله مسبقاً للأرشيف الشهري!")
        else:
            st.session_state.daily_reports.append({
                "date": current_date_str, "month": current_month_str, "day_name": current_day_ar,
                "cash": cash_sales, "visa": visa_sales, "total": total_sales, "tax": tax_amount,
                "commissions": worker_commissions, "net_profit": net_profit
            })
            save_data(daily_reports_file, st.session_state.daily_reports)
            st.success(f"🎉 تم بنجاح إنهاء اليوم وترحيل الأرصدة للأرشيف الشهري!")
            st.rerun()

    st.write("---")
    st.write("### 🧾 كشف الحركات والفواتير الحية المسجلة اليوم")
    for inv in st.session_state.invoices:
        if inv.get("date") == current_date_str:
            c1, c2, c3, c4, c5 = st.columns()
            with c1: st.write(f"#{inv['id']}")
            with c2: st.write(f"السيارة: {inv.get('car_plate', 'بضائع')} | {inv['customer']}")
            with c3: st.write(f"{inv['amount']} ج.م ({inv.get('payment_method', 'كاش')})")
            with c4:
                if inv["status"] == "نشطة": st.write("🟢 نشطة")
                else: st.markdown('<span class="cancel-badge">ملغاة ❌</span>', unsafe_allow_html=True)
            with c5:
                if inv["status"] == "نشطة":
                    with st.popover("❌ كنسلة"):
                        reason = st.text_input("سبب إلغاء العملية ماليًا:", key=f"res_{inv['id']}")
                        if st.button("تأكيد كنسلة الفاتورة واستبعادها", key=f"btn_{inv['id']}"):
                            if reason:
                                inv["status"] = "ملغاة"
                                inv["cancel_reason"] = reason
                                inv["cancelled_by"] = "المالك"
                                inv["cancel_date"] = current_date_str
                                save_data(invoices_file, st.session_state.invoices)
                                st.success("تم الكنسلة الفورية!")
                                st.rerun()
                                # --- [متاحة للمالك والعمال] 2. شاشة POS كاشير الاستقبال ---
elif menu == "🛒 POS كاشير الاستقبال والبيع":
    st.subheader("📥 كاشير الاستقبال وتسجيل فواتير العمليات")
    
    with st.form("car_form_pos"):
        cust_name = st.text_input("اسم العميل:")
        cust_phone = st.text_input("رقم هاتف العميل للواتساب (مثال: 20100xxxxxxxx):")
        car_plate = st.text_input("رقم لوحة السيارة الفعلي:")
        pkg_options = [p["name"] for p in st.session_state.packages]
        selected_pkg_name = st.selectbox("اختر الخدمة/الباقة المسجلة:", pkg_options)
        selected_pkg = next(p for p in st.session_state.packages if p["name"] == selected_pkg_name)
        selected_workers = st.multiselect("طاقم العمل المكلف (عامل أو عاملين لتقسيم العمولة بالتساوي):", st.session_state.workers, max_selections=2)
        pay_method = st.radio("طريقة دفع وسداد التذكرة للسيارة:", ["كاش", "فيزا"], horizontal=True)
        
        submit_invoice = st.form_submit_button("✅ طباعة وتسجيل الفاتورة المباشرة")
        
    if submit_invoice:
        if car_plate and selected_workers:
            new_id = max([i["id"] for i in st.session_state.invoices]) + 1 if st.session_state.invoices else 101
            new_inv_obj = {
                "id": new_id, "date": current_date_str, "month": current_month_str,
                "customer_name": cust_name, "customer_phone": cust_phone,
                "car_plate": car_plate, "customer": selected_pkg["name"], "amount": selected_pkg["price"],
                "status": "نشطة", "has_commission": True, "assigned_workers": selected_workers, "payment_method": pay_method
            }
            st.session_state.invoices.append(new_inv_obj)
            save_data(invoices_file, st.session_state.invoices)
            st.success(f"🎉 تم قيد الفاتورة #{new_id} ومزامنتها بنجاح!")
            
            # توليد وتحميل ملف الـ PDF الفوري للطباعة للعميل
            pdf_bytes = generate_receipt_pdf(new_id, current_date_str, current_day_ar, car_plate, selected_pkg["name"], selected_pkg["price"], pay_method, cust_name, cust_phone)
            st.download_button(label="📄 تحميل وطباعة إيصال الفاتورة (PDF)", data=pdf_bytes, file_name=f"Sabiha_Hub_Receipt_{new_id}.pdf", mime="application/pdf")
            
            # توليد الرابط المباشر للواتساب
            if cust_phone:
                msg_text = f"مرحباً يا فندم بـ *Sabiha Hub* 🚗✨\n\nتم إصدار فاتورتك الفورية رقم: *#{new_id}*\n🔹 الخدمة: {selected_pkg['name']}\n🔹 لوحة السيارة: {car_plate}\n🔹 الإجمالي: {selected_pkg['price']} ج.م\n\nشكراً لزيارتكم لنا، ونسعد دائماً بخدمتكم! 👋"
                whatsapp_url = f"https://whatsapp.com{cust_phone}&text={urllib.parse.quote(msg_text)}"
                st.markdown(f' <a href="{whatsapp_url}" target="_blank"><button style="background-color: #25D366; color: white; padding: 8px 16px; border: none; border-radius: 5px; font-weight: bold; cursor: pointer;">📱 إرسال الفاتورة عبر الواتساب للعميل</button></a>', unsafe_allow_html=True)
        else:
            st.error("⚠️ يرجى تعبئة لوحة السيارة وتحديد طاقم العمل أولاً.")

# --- [صفحة المالك] 3. تقرير الحسابات الشهرية والأرشيف التلقائي ---
elif menu == "📅 تقرير الحسابات الشهرية والأرشيف" and st.session_state.user_role == "owner":
    st.title("📅 تقرير الحسابات الشهرية والأرشيف المالي المغلق")
    if st.session_state.daily_reports:
        df_reports = pd.DataFrame(st.session_state.daily_reports)
        selected_month = st.selectbox("📊 اختر الشهر المطلوب عرض أرشيفه المحفوظ مستقل كليًا:", df_reports['month'].unique())
        month_filter_df = df_reports[df_reports['month'] == selected_month]
        
        st.write(f"### 📊 ملخص الأداء المالي لشهر: {selected_month}")
        c_m1, c_m2, c_m3 = st.columns(3)
        with c_m1: st.metric("💰 إجمالي المبيعات بالشهر", f"{month_filter_df['total'].sum():.2f} ج.م")
        with c_m2: st.metric("📜 إجمالي الضرائب 14%", f"{month_filter_df['tax'].sum():.2f} ج.م")
        with c_m3: st.metric("📈 صافي الأرباح الصافي بالشهر", f"{month_filter_df['net_profit'].sum():.2f} ج.م")
        
        st.write("---")
        df_display = month_filter_df[["date", "day_name", "cash", "visa", "total", "tax", "commissions", "net_profit"]].copy()
        df_display.columns = ["التاريخ الفعلي", "اليوم الفعلي", "مبيعات كاش (ج.م)", "مبيعات فيزا (ج.م)", "إجمالي الإيراد (ج.م)", "الضريبة 14% (ج.م)", "عمولات العمال (ج.م)", "صافي الأرباح (ج.م)"]
        st.dataframe(df_display, use_container_width=True, hide_index=True)
    else:
        st.info("📂 لا توجد أيام مرحّلة أو سجلات وردية مغلقة ومحفوظة في الأرشيف حتى الآن.")

# --- [صفحة المالك] 4. مركز التحكم بالباقات والعمال ---
elif menu == "⚙️ إعدادات الباقات والعمال" and st.session_state.user_role == "owner":
    st.subheader("⚙️ مركز إعدادات عناصر التشغيل والباقات")
    tab_pkg, tab_work = st.tabs(["✨ الباقات والعروض المتاحة", "👥 إدارة وطاقم العمال"])
    
    with tab_pkg:
        st.dataframe(pd.DataFrame(st.session_state.packages), use_container_width=True)
        p_name = st.text_input("اسم الخدمة/الباقة الجديدة:")
        p_price = st.number_input("سعر الباقة المقترح (ج.م):", min_value=0, step=50)
        if st.button("حفظ وإضافة الباقة"):
            if p_name:
                new_id = max([p["id"] for p in st.session_state.packages]) + 1 if st.session_state.packages else 1
                st.session_state.packages.append({"id": new_id, "name": p_name, "price": p_price})
                save_data(packages_file, st.session_state.packages)
                st.success("تم حفظ الباقة الجديدة وتفعيلها سحابياً للقوائم!")
                st.rerun()

    with tab_work:
        st.write(st.session_state.workers)
        new_worker_name = st.text_input("اسم الفني الجديد المعتمد لطاقم العمل:")
        if st.button("تسجيل العامل بالسيستم"):
            if new_worker_name and new_worker_name not in st.session_state.workers:
                st.session_state.workers.append(new_worker_name)
                save_data(workers_file, st.session_state.workers)
                st.success("تم تسجيل العامل بنجاح وطرحه لقوائم الكاشير!")
                st.rerun()
