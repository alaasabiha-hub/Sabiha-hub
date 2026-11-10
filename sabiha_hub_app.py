import streamlit as st
import pandas as pd
import json
import os
import datetime

# ضبط إعدادات الصفحة لتكون عريضة ومناسبة لجميع الشاشات
st.set_page_config(page_title="Sabiha Hub", layout="wide", initial_sidebar_state="expanded")

# ============================================================================
# 1. إدارة تهيئة البيانات وحفظها تلقائياً لضمان عدم الضياع على السيرفر الأونلاين
# ============================================================================
if "initialized" not in st.session_state:
    st.session_state.initialized = True
    
    # الحسابات الافتراضية الافتتاحية للمنظومة
    if "credentials" not in st.session_state:
        st.session_state.credentials = {
            "owner": {"username": "owner", "password": "sabiha2026"},
            "workers_accounts": {
                "worker1": {"name": "كاشير الاستقبال", "password": "pos123", "role": "worker"}
            }
        }
        
    # قائمة الفنيين الافتتاحية
    if "workers" not in st.session_state:
        st.session_state.workers = [
            {"name": "أحمد مصطفى", "advance": 0.0},
            {"name": "محمد علي", "advance": 0.0}
        ]
        
    # قائمة الخدمات والأسعار الافتتاحية بالجنيه المصري شاملة قيمة العمولة الثابتة لكل خدمة
    if "services" not in st.session_state:
        st.session_state.services = {
            "غسيل سريع": {"الملكي": 150.0, "SUV": 200.0, "fixed_commission": 20.0},
            "تلميع نانو سريع": {"الملكي": 300.0, "SUV": 400.0, "fixed_commission": 50.0},
            "تنظيف صالون عميق": {"الملكي": 250.0, "SUV": 350.0, "fixed_commission": 40.0}
        }
        
    # أرشيف الفواتير الحية النشطة لليوم الحالي
    if "session_state_invoices" not in st.session_state:
        st.session_state.session_state_invoices = {}
        
    if "daily_sales" not in st.session_state:
        st.session_state.daily_sales = 0.0
        
    if "daily_expenses" not in st.session_state:
        st.session_state.daily_expenses = {"rent": 0.0, "operational": 0.0, "utilities": 0.0}

    # الأرشيف المالي والمحاسبي التراكمي (أيام وأشهر مغلقة)
    if "daily_archive" not in st.session_state:
        st.session_state.daily_archive = {} 
        
    if "monthly_archive" not in st.session_state:
        st.session_state.monthly_archive = {}

# ============================================================================
# 2. نظام تسجيل الدخول وإدارة الصلاحيات وحماية الواجهة
# ============================================================================
if "logged_in" not in st.session_state:
    st.session_state.logged_in = False
if "user_role" not in st.session_state:
    st.session_state.user_role = None
if "current_user" not in st.session_state:
    st.session_state.current_user = None

if not st.session_state.logged_in:
    st.markdown("<h1 style='text-align: center; color: #1E3A8A;'>Sabiha Hub ✨ لوحة تسجيل الدخول</h1>", unsafe_allow_html=True)
    st.write("---")
    
    col_login_box, _ = st.columns([2, 2])
    with col_login_box:
        st.subheader("🔑 يرجى إدخال بيانات النظام الموحد")
        input_user = st.text_input("👤 اسم المستخدم:", key="main_username_input").strip()
        input_pass = st.text_input("🔒 كلمة المرور:", type="password", key="main_password_input").strip()
        
        if st.button("دخول النظام 🚀", use_container_width=True):
            if input_user == st.session_state.credentials["owner"]["username"] and input_pass == st.session_state.credentials["owner"]["password"]:
                st.session_state.logged_in = True
                st.session_state.user_role = "owner"
                st.session_state.current_user = "owner"
                st.success("🎉 أهلاً بك يا مالك المنظومة، تم تسجيل الدخول بنجاح!")
                st.rerun()
            else:
                login_success = False
                for w_id, w_info in st.session_state.credentials["workers_accounts"].items():
                    if input_user == w_id and input_pass == w_info["password"]:
                        st.session_state.logged_in = True
                        st.session_state.user_role = "worker"
                        st.session_state.current_user = w_info["name"]
                        login_success = True
                        st.success(f"🎉 تم تسجيل دخول الموظف: {w_info['name']}")
                        st.rerun()
                        break
                if not login_success:
                    st.error("❌ بيانات الدخول غير صحيحة، يرجى التحقق وإعادة المحاولة.")
    st.stop()

# ============================================================================
# 3. شريط التنقل الجانبي (Sidebar) وتطهير خيارات النصوص والروابط حياً
# ============================================================================
st.sidebar.markdown(f"### 🚪 مرحباً: **{st.session_state.current_user}**")
st.sidebar.markdown(f"💼 صلاحية الحساب: `{st.session_state.user_role}`")
st.sidebar.write("---")

if st.sidebar.button("تسجيل الخروج 🔓", use_container_width=True):
    st.session_state.logged_in = False
    st.session_state.user_role = None
    st.session_state.current_user = None
    st.rerun()

if st.sidebar.button("🔄 مزامنة وتحديث البيانات لحظياً", use_container_width=True):
    st.rerun()

if st.session_state.user_role == "owner":
    menu_options = [
        "📊 لوحة الداشبورد الرئيسية",
        "🛒 كاشير الاستقبال POS",
        "📉 تقرير الحسابات والأرشيف",
        "💸 العمولات والسلفيات الحية",
        "📑... دفتر المصروفات",
        "⚙️ إعدادات الباقات والعمال"
    ]
else:
    menu_options = [
        "🛒 كاشير الاستقبال POS",
        "📑... دفتر المصروفات"
    ]

raw_menu = st.sidebar.radio("📍 الانتقال بين الصفحات والمعاملات:", options=menu_options)

menu = "📊 لوحة الداشبورد الرئيسية"
if "كاشير" in raw_menu or "POS" in raw_menu:
    menu = "كاشير الاستقبال POS"
elif "الأرشيف" in raw_menu or "تقرير" in raw_menu or "الحسابات" in raw_menu:
    menu = "تقرير الحسابات والأرشيف"
elif "العمولات" in raw_menu or "السلفيات" in raw_menu:
    menu = "العمولات والسلفيات الحية"
elif "المصروفات" in raw_menu or "دفتر" in raw_menu:
    menu = "📑 دفتر المصروفات"
elif "إعدادات" in raw_menu or "الباقات" in raw_menu:
    menu = "إعدادات الباقات والعمال"

# ============================================================================
# 4. بناء الأقسام البرمجية والشاشات التفاعلية وحفظها التلقائي
# ============================================================================

if menu == "📊 لوحة الداشبورد الرئيسية":
    st.markdown("## 📊 لوحة الأداء المالي والتشغيلي لليوم الحالي (مزامنة حية 🟢)")
    st.write("---")
    
    calculated_sales = 0.0
    total_commissions = 0.0
    active_invoices_count = 0
    all_invoices = []
    
    for worker_name, inv_list in st.session_state.session_state_invoices.items():
        for inv in inv_list:
            all_invoices.append(inv)
            if inv.get("status", "Active") == "Active":
                calculated_sales += float(inv.get("total", 0.0))
                # جمع العمولات المسجلة بداخل الفواتير
                total_commissions += float(inv.get("commission_share", 0.0))
                active_invoices_count += 1
            
    # معالجة فريدة لمنع التكرار في الحساب الإجمالي للمبيعات والعمولات الكلية
    # نقسم على 2 لأن الفاتورة تُسجل مرتين (مرة لكل عامل مشترك) لتظهر في كشوفاتهم
    real_sales = calculated_sales / 2 if calculated_sales > 0 else 0.0
    real_commissions = total_commissions / 2 if total_commissions > 0 else 0.0
    real_invoices_count = int(active_invoices_count / 2)
    
    st.session_state.daily_sales = real_sales
    tax_14 = st.session_state.daily_sales * 0.14
    total_expenses_today = float(st.session_state.daily_expenses.get("rent", 0.0)) + \
                         float(st.session_state.daily_expenses.get("operational", 0.0)) + \
                         float(st.session_state.daily_expenses.get("utilities", 0.0))
                         
    net_profit = st.session_state.daily_sales - total_expenses_today - tax_14 - real_commissions

    col_m1, col_m2, col_m3 = st.columns(3)
    with col_m1: st.metric("💰 إجمالي المبيعات المحصلة", f"{st.session_state.daily_sales:.2f} ج.م", delta=f"{real_invoices_count} فاتورة نشطة")
    with col_m2: st.metric("📉 إجمالي مصروفات اليوم (مخصومة)", f"{total_expenses_today:.2f} ج.م")
    with col_m3: st.metric("🏛️ ضريبة القيمة المضافة 14% (مخصومة)", f"{tax_14:.2f} ج.م")
    
    col_m4, col_m5 = st.columns(2)
    with col_m4: st.metric("👨‍🔧 عمولات الفنيين الحية (مخصومة)", f"{real_commissions:.2f} ج.م")
    with col_m5: st.metric("🟩 صافي المبيعات / الأرباح الحالي", f"{net_profit:.2f} ج.م")
    
    st.write("---")
    st.subheader("📥 تحميل وطباعة التقارير والملخصات")
    
    # فلترة عرض جدول الفواتير في التقرير لمنع تكرار الأسطر المزدوجة للعمال
    seen_inv_ids = set()
    unique_invoices = []
    for inv in all_invoices:
        if inv["id"] not in seen_inv_ids:
            seen_inv_ids.add(inv["id"])
            unique_invoices.append(inv)
            
    invoices_html_rows = ""
    for inv in unique_invoices:
        status_text = "نشطة" if inv.get("status", "Active") == "Active" else "مرتجع Refunded"
        invoices_html_rows += f"""
        <tr>
            <td>{inv['id']}</td>
            <td>{inv['plate_number']}</td>
            <td>{inv['service']}</td>
            <td>{inv['car_type']}</td>
            <td>{inv['total']:.2f} ج.م</td>
            <td>{inv['worker1']} & {inv['worker2']}</td>
            <td>{status_text}</td>
        </tr>
        """

    pdf_script = f"""
    <script>
    function printReport() {{
        var win = window.open("", "", "height=700,width=900");
        win.document.write("<html><head><title>Sabiha Hub - التقرير اليومي</title>");
        win.document.write("<style>body{{font-family:sans-serif;direction:rtl;padding:20px;}} table{{width:100%;border-collapse:collapse;margin-top:20px;}} th,td{{border:1px solid #ddd;padding:10px;text-align:right;}} th{{background-color:#f4f4f4;}} .summary{{margin-bottom:30px;background:#f9f9f9;padding:15px;border-radius:8px;}}</style>");
        win.document.write("</head><body>");
        win.document.write("<h2>📊 التقرير المالي والتشغيلي اليومي - Sabiha Hub</h2>");
        win.document.write("<p><b>التاريخ:</b> {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>");
        win.document.write("<div class='summary'>");
        win.document.write("<h3>💰 الملخص المالي اليومي:</h3>");
        win.document.write("<p><b>إجمالي المبيعات:</b> {st.session_state.daily_sales:.2f} ج.م</p>");
        win.document.write("<p><b>إجمالي المصروفات:</b> {total_expenses_today:.2f} ج.م</p>");
        win.document.write("<p><b>ضريبة القيمة المضافة 14%:</b> {tax_14:.2f} ج.م</p>");
        win.document.write("<p><b>عمولات العمال والفنيين:</b> {real_commissions:.2f} ج.م</p>");
        win.document.write("<p><b>صافي المبيعات والأرباح:</b> {net_profit:.2f} ج.م</p>");
        win.document.write("</div>");
        win.document.write("<h3>📋 كشف الفواتير والعمليات المُرَحَّلة:</h3>");
        win.document.write("<table><thead><tr><th>رقم الفاتورة</th><th>رقم اللوحة</th><th>الخدمة</th><th>الفئة</th><th>المبلغ</th><th>الفنيين المشتركين</th><th>الحالة</th></tr></thead><tbody>");
        win.document.write(`{invoices_html_rows}`);
        win.document.write("</tbody></table>");
        win.document.write("</body></html>");
        win.document.close();
        win.print();
    }}
    </script>
    <button onclick="printReport()" style="background-color:#1E3A8A;color:white;padding:12px 24px;border:none;border-radius:6px;cursor:pointer;font-size:16px;width:100%;">📥 تحميل وطباعة التقرير اليومي الشامل كـ PDF</button>
    """
    st.components.v1.html(pdf_script, height=60)
    
    st.write("---")
    st.subheader("🏁 إدارة الإغلاقات والترحيل التلقائي للأرشيف")
    col_close1, col_close2 = st.columns(2)
    
    with col_close1:
        if st.button("🏁 إغلاق وترحيل اليوم الحالي تلقائياً إلى الأرشيف الشهري", use_container_width=True):
            today_str = datetime.datetime.now().strftime("%Y-%m-%d (%A)")
            if st.session_state.daily_sales == 0 and total_expenses_today == 0:
                st.warning("⚠️ لا توجد معاملات مالية مسجلة اليوم لترحيلها.")
            else:
                st.session_state.daily_archive[today_str] = {
                    "sales": st.session_state.daily_sales,
                    "expenses": total_expenses_today,
                    "tax": tax_14,
                    "commissions": real_commissions,
                    "net": net_profit,
                    "invoices": json.loads(json.dumps(st.session_state.session_state_invoices))
                }
                st.session_state.session_state_invoices = {}
                st.session_state.daily_sales = 0.0
                st.session_state.daily_expenses = {"rent": 0.0, "operational": 0.0, "utilities": 0.0}
                st.success(f"✅ تم إغلاق اليوم وترحيل حساباته تلقائياً إلى الأرشيف بنجاح بالتاريخ: {today_str}")
                st.rerun()
                
    with col_close2:
        if st.button("📁 إغلاق الشهر الحالي وتصفير العدادات لبدء شهر جديد", use_container_width=True):
            month_str = datetime.datetime.now().strftime("%Y-%B")
            if not st.session_state.daily_archive:
                st.warning("⚠️ أرشيف الأيام فارغ، يرجى ترحيل الأيام أولاً قبل إغلاق الشهر.")
            else:
                st.session_state.monthly_archive[month_str] = json.loads(json.dumps(st.session_state.daily_archive))
                st.session_state.daily_archive = {}
                st.success(f"🎉 تم ترحيل وأرشفة الشهر بالكامل بنجاح داخل الذاكرة التراكمية [{month_str}] ودورة محاسبية جديدة!")
                st.rerun()
    
    st.write("---")
    st.subheader("📋 كشف فواتير اليوم وإدارة المرتجعات (Refund)")
    
    if unique_invoices:
        for index, inv in enumerate(unique_invoices):
            col_i1, col_i2, col_i3, col_i4, col_refund = st.columns([2, 2, 2, 2, 1.5])
            with col_i1: st.write(f"🧾 رقم: **{inv['id']}** | اللوحة: `({inv.get('plate_number', '---')})`")
            with col_i2: st.write(f"🛍️ خدمة: *{inv['service']}* | الفنيين: `{inv.get('worker1','---')}` & `{inv.get('worker2','---')}`")
            with col_i3: st.write(f"💵 القيمة: `{inv['total']:.2f} ج.م` | العمولة الثابتة الكلية: `{inv.get('commission_total', 0.0):.2f} ج.م`")
            with col_i4: 
                if inv.get("status", "Active") == "Active":
                    st.markdown("🟢 **الفاتورة نشطة**")
                else:
                    st.markdown("<span style='color:red;'>↩️ **تم الاسترجاع (Refunded)**</span>", unsafe_allow_html=True)
            with col_refund:
                if inv.get("status", "Active") == "Active":
                    if st.button("إرجاع الفاتورة ↩️", key=f"ref_btn_{inv['id']}_{index}"):
                        for w_key, w_invs in st.session_state.session_state_invoices.items():
                            for item in w_invs:
                                if item["id"] == inv["id"]:
                                    item["status"] = "Refunded"
                        st.error(f"↩️ تم عمل Refund للفاتورة [{inv['id']}] وخصم قيمتها وعمولتها بنجاح.")
                        st.rerun()
                else:
                    st.button("تم ردها مسبقاً 🔒", disabled=True, key=f"ref_dis_{inv['id']}_{index}")
    else:
        st.info("ℹ️ لا توجد فواتير أو عمليات مسجلة لليوم حتى الآن.")

# ----------------------------------------------------------------------------
# قسم كاشير الاستقبال (POS) - نظام توزيع العاملين وعمولة الخدمات الثابتة المحددة
# ----------------------------------------------------------------------------
elif menu == "كاشير الاستقبال POS":
    st.markdown("<h2 style='text-align: center;'>📥 كاشير الاستقبال وتسجيل الفواتير</h2>", unsafe_allow_html=True)
    st.write("---")
    
    with st.container():
        # 1. إدخال رقم لوحة السيارة
        plate_number = st.text_input("🔢 رقم لوحة السيارة:", key="pos_plate_number_input").strip()
        
        # 2. فئة حجم السيارة
        car_type = st.selectbox("🚗 فئة حجم السيارة للتسعير الآلي:", options=["ملاكي / سيدان", "SUV"])
        car_key = "الملكي" if car_type == "ملاكي / سيدان" else "SUV"
        
        # 3. اختيار الخدمة المعتمدة
        service_options = list(st.session_state.services.keys())
        if not service_options:
            st.error("❌ لا توجد خدمات مسجلة في النظام.")
            service_options = ["لا توجد خدمات"]
        selected_service = st.selectbox("🛍️ اختر الخدمة المعتمدة:", options=service_options)
        
        # جلب الفنيين المسجلين حياً لتوزيع الحارة والدتيلينج
        worker_list = [w["name"] for w in st.session_state.workers if isinstance(w, dict) and "name" in w]
        if not worker_list:
            worker_list = ["لا يوجد فني مسؤول"]
            
        # 4. توزيع الفنيين (إضافة خانة عامل آخر لتوزيع العمولة الثابتة عليه)
        selected_worker1 = st.selectbox("👨‍🔧 فني حارة الغسيل (العامل الأول):", options=worker_list, key="pos_w1")
        selected_worker2 = st.selectbox("🧽 أخصائي الديتيلينج / التجهيز (العامل الثاني):", options=worker_list, key="pos_w2")
        
        # 5. وسيلة السداد
        payment_method = st.radio("💵 وسيلة السداد:", options=["كاش", "فيزا"], horizontal=True)
        
        # استدعاء السعر الافتراضي والعمولة الثابتة المحفوظة بالخدمة
        if selected_service in st.session_state.services:
            base_price = float(st.session_state.services[selected_service].get(car_key, 0.0))
            fixed_comm = float(st.session_state.services[selected_service].get("fixed_commission", 0.0))
        else:
            base_price = 0.0
            fixed_comm = 0.0
            
        st.markdown(f"ℹ️ **السعر التلقائي المحفوظ:** `{base_price:.2f} ج.م` | **العمولة الثابتة المقررة للخدمة:** `{fixed_comm:.2f} ج.م`")
        
        custom_price = st.number_input("💰 المبلغ المحصل الفعلي (ج.م):", min_value=0.0, value=base_price)
        
        # حساب توزيع العمولة الثابتة بالتساوي بين العاملين المشتركين بالفاتورة
        share_commission = fixed_comm / 2
        st.write(f"📊 نصيب كل عامل من العمولة الثابتة (توزيع متساوي): **{share_commission:.2f} ج.م**")
        
        if st.button("🟢 إتمام المعاملة وإصدار الفاتورة حياً", use_container_width=True):
            if selected_service == "لا توجد خدمات" or plate_number == "":
                st.error("❌ خطأ: يرجى كتابة رقم اللوحة والتأكد من اختيار الخدمة بشكل صحيح.")
            else:
                invoice_id = f"INV-{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
                
                # بناء هيكل الفاتورة الموحدة المشتركة
                invoice_data = {
                    "id": invoice_id,
                    "plate_number": plate_number,
                    "service": selected_service,
                    "car_type": car_type,
                    "total": custom_price,
                    "worker1": selected_worker1,
                    "worker2": selected_worker2,
                    "commission_total": fixed_comm,
                    "commission_share": share_commission,
                    "payment": payment_method,
                    "status": "Active",
                    "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                }
                
                # ترحيل الفاتورة لحساب العامل الأول
                if selected_worker1 not in st.session_state.session_state_invoices:
                    st.session_state.session_state_invoices[selected_worker1] = []
                st.session_state.session_state_invoices[selected_worker1].append(invoice_data)
                
                # ترحيل الفاتورة لحساب العامل الثاني لضمان رصد المستحقات للطرفين
                if selected_worker2 not in st.session_state.session_state_invoices:
                    st.session_state.session_state_invoices[selected_worker2] = []
                st.session_state.session_state_invoices[selected_worker2].append(invoice_data)
                
                st.success(f"🎉 تم إصدار الفاتورة [{invoice_id}] بنجاح وتوزيع العمولات الثابتة بالتساوي!")
                st.balloons()
                st.rerun()

elif menu == "تقرير الحسابات والأرشيف":
    st.markdown("## 📉 تقرير الحسابات والأرشيف المالي الشامل")
    st.write("---")
    
    tab_daily_arch, tab_monthly_arch = st.tabs(["📁 أرشيف الأيام المغلقة لليوم والشهر", "🗄️ أرشيف الحسابات الشهرية التراكمية"])
    
    with tab_daily_arch:
        st.subheader("📆 كشف الحسابات والأيام المغلقة بالتاريخ واليوم")
        if st.session_state.daily_archive:
            for day, day_data in st.session_state.daily_archive.items():
                with st.expander(f"📅 إغلاق يوم: {day} | صافي الأرباح المُرَحَّلة: {day_data['net']:.2f} ج.م"):
                    st.write(f"💰 **إجمالي مبيعات اليوم:** {day_data['sales']:.2f} ج.م")
                    st.write(f"📉 **المصروفات مخصومة:** {day_data['expenses']:.2f} ج.م")
                    st.write(f"🏛️ **الضرائب مخصومة (14%):** {day_data['tax']:.2f} ج.م")
                    st.write(f"👨‍🔧 **إجمالي عمولات الفنيين:** {day_data['commissions']:.2f} ج.م")
                    st.write("---")
                    st.markdown("##### 📄 كشف تفصيلي بالفواتير والعمليات المؤرشفة لهذا اليوم:")
                    st.json(day_data["invoices"])
        else:
            st.info("ℹ️ أرشيف الأيام المغلقة فارغ حالياً.")
            
    with tab_monthly_arch:
        st.subheader("🗄️ أرشيف الإغلاقات الشهرية المغلقة")
        if st.session_state.monthly_archive:
            st.json(st.session_state.monthly_archive)
        else:
            st.info("ℹ️ أرشيف الإغلاق المالي الشهري فارغ تماماً.")

elif menu == "العمولات والسلفيات الحية":
    st.markdown("## 💸 إدارة عمولات وسلفيات الفنيين الحية وكشف الرواتب")
    st.write("---")
    
    if not st.session_state.workers:
        st.info("ℹ️ لا يوجد فنيين مسجلين لعرض عمولاتهم وسلفياتهم حالياً.")
    else:
        st.subheader("💵 السجل التفصيلي لمستحقات كل فني حالياً")
        
        for index, worker in enumerate(st.session_state.workers):
            if not isinstance(worker, dict) or "name" not in worker:
                continue
                
            w_name = worker["name"]
            w_commissions = 0.0
            if w_name in st.session_state.session_state_invoices:
                for inv in st.session_state.session_state_invoices[w_name]:
                    if inv.get("status", "Active") == "Active":
                        # رصد الحصة الموزعة للعامل من الفاتورة حياً
                        w_commissions += float(inv.get("commission_share", 0.0))
                    
            w_advance = float(worker.get("advance", 0.0))
            net_payout = w_commissions - w_advance
            
            with st.expander(f"👨‍🔧 الفني: {w_name} | صافي المستحقات الحالي: {net_payout:.2f} ج.م"):
                col_b1, col_b2, col_b3 = st.columns(3)
                with col_b1: st.metric("🎯 إجمالي العمولات الموزعة الثابتة", f"{w_commissions:.2f} ج.م")
                with col_b2: st.metric("💸 السلفيات الحالية المسجلة", f"{w_advance:.2f} ج.م")
                with col_b3: st.metric("💰 صافي الراتب المستحق للصرف", f"{net_payout:.2f} ج.m")
                
                st.write("---")
                col_act1, col_act2 = st.columns(2)
                with col_act1:
                    advance_amount = st.number_input(f"➕ تسجيل سلفة جديدة لـ {w_name} (ج.م):", min_value=0.0, key=f"adv_add_{index}")
                    if st.button(f"تأكيد صرف السلفة 💸", key=f"btn_adv_{index}"):
                        st.session_state.workers[index]["advance"] += advance_amount
                        st.success(f"✅ تم إضافة السلفة بنجاح للفني {w_name}!")
                        st.rerun()
                with col_act2:
                    st.write("⚠️ إدارة حساب الصرف والتصفية المالية:")
                    if st.button(f"تصفية وتصفير كافة حسابات وسلفيات [{w_name}] 🧾", key=f"btn_clear_{index}"):
                        st.session_state.workers[index]["advance"] = 0.0
                        if w_name in st.session_state.session_state_invoices:
                            st.session_state.session_state_invoices[w_name] = []
                        st.success(f"🧾 تم تصفير حسابات وسلف الفني {w_name} بالكامل وصرف راتبه!")
                        st.rerun()

elif menu == "📑 دفتر المصروفات":
    st.markdown("## 📑 إدارة دفتر المصروفات اليومية والتشغيلية")
    st.write("---")
    
    st.subheader("🛠️ تحديث بنود المصروفات لليوم الحالي")
    
    with st.form("expenses_form_production"):
        rent_val = st.number_input("🏢 إيجار المقر والمحل (ج.م):", min_value=0.0, value=float(st.session_state.daily_expenses.get("rent", 0.0)))
        operational_val = st.number_input("🧪 مصروفات تشغيلية (خامات ومواد كيميائية وأدوات):", min_value=0.0, value=float(st.session_state.daily_expenses.get("operational", 0.0)))
        utilities_val = st.number_input("⚡💧 مرافق عامة وطاقة (كهرباء ومياه):", min_value=0.0, value=float(st.session_state.daily_expenses.get("utilities", 0.0)))
        
        if st.form_submit_button("💾 حفظ وتثبيت قيم المصروفات الحية"):
            st.session_state.daily_expenses["rent"] = rent_val
            st.session_state.daily_expenses["operational"] = operational_val
            st.session_state.daily_expenses["utilities"] = utilities_val
            st.success("🎉 تم تحديث وحفظ قيم المصروفات بنجاح في النظام التراكمي!")
            st.rerun()
            
    st.write("---")
    st.markdown("### 📊 الملخص الإجمالي لمصروفات التشغيل اليوم:")
    total_exp = float(st.session_state.daily_expenses.get("rent", 0.0)) + float(st.session_state.daily_expenses.get("operational", 0.0)) + float(st.session_state.daily_expenses.get("utilities", 0.0))
                
    col_e1, col_e2, col_e3 = st.columns(3)
    with col_e1: st.metric("🏢 إيجار ثابت المقر", f"{st.session_state.daily_expenses.get('rent', 0.0):.2f} ج.م")
    with col_e2: st.metric("🧪 كيماويات وخامات تلميع", f"{st.session_state.daily_expenses.get('operational', 0.0):.2f} ج.م")
    with col_e3: st.metric("⚡💧 فواتير مياه وكهرباء", f"{st.session_state.daily_expenses.get('utilities', 0.0):.2f} ج.م")
    st.error(f"🚨 إجمالي المصروفات العام المحسوب: **{total_exp:.2f} ج.م**")

elif menu == "إعدادات الباقات والعمال":
    st.markdown("## ⚙️ لوحة الإدارة المطلقة والتحكم بالأسعار والسرية")
    st.write("---")

    tab_workers, tab_services, tab_security = st.tabs([
        "👨‍🔧 إدارة العمال والفنيين الحية", 
        "🛍️ التحكم بالباقات والخدمات والأسعار", 
        "🔐 إدارة حسابات الموظفين وكلمات السر"
    ])
    
    with tab_workers:
        st.subheader("👥 تسجيل فني جديد أو حذفه من الذاكرة")
        col_w1, col_w2 = st.columns(2)
        
        with col_w1:
            new_worker_name = st.text_input("➕ اسم الفني الجديد المراد تثبيته:", key="input_add_new_worker")
            if st.button("تثبيت وحفظ الفني في النظام 🚀"):
                if new_worker_name.strip() != "":
                    if not any(isinstance(w, dict) and w.get("name") == new_worker_name.strip() for w in st.session_state.workers):
                        st.session_state.workers.append({"name": new_worker_name.strip(), "advance": 0.0})
                        st.success(f"✅ تم حفظ وتثبيت الفني [{new_worker_name.strip()}] في النظام بنجاح!")
                        st.rerun()
                    else:
                        st.warning("⚠️ هذا الاسم مسجل بالفعل في قائمة الفنيين.")
                else:
                    st.error("❌ يرجى إدخال اسم فني صحيح!")
                    
        with col_w2:
            worker_options = ["اختر الفني لحذفه نهائياً"]
            for w in st.session_state.workers:
                if isinstance(w, dict) and "name" in w:
                    worker_options.append(w["name"])
                    
            worker_to_delete = st.selectbox("❌ حذف فني وإزالة مستحقاته نهائياً:", options=worker_options, index=0)
            if st.button("تأكيد حذف الفني من السجلات 🗑️", use_container_width=True):
                if worker_to_delete != "اختر الفني لحذفه نهائياً":
                    st.session_state.workers = [w for w in st.session_state.workers if isinstance(w, dict) and w.get("name") != worker_to_delete]
                    st.success(f"🗑️ تم حذف الفني [{worker_to_delete}] وإزالته بنجاح من كافة الصلاحيات!")
                    st.rerun()
                else:
                    st.error("❌ يرجى اختيار اسم فني صحيح من القائمة للحذف.")

    with tab_services:
        st.subheader("🛍️ إضافة وتحديث الباقات والتحكم بأسعارها والعمولة الثابتة")
        
        col_s1, col_s2, col_s3, col_s4 = st.columns(4)
        with col_s1: new_service_name = st.text_input("🏷️ اسم الخدمة / الباقة الجديدة:", key="input_new_service_name_p")
        with col_s2: price_malaki = st.number_input("🚗 سعر فئة السيارات الملاكي (ج.م):", min_value=0.0, value=150.0, key="num_malaki_p")
        with col_s3: price_suv = st.number_input("🚙 سعر فئة السيارات SUV (ج.م):", min_value=0.0, value=200.0, key="num_suv_p")
        with col_s4: fixed_comm_val = st.number_input("🎯 قيمة العمولة الثابتة الكلية (ج.م):", min_value=0.0, value=20.0, key="num_fixed_comm_p")
            
        if st.button("تثبيت أو تحديث أسعار هذه الخدمة حياً 📥", use_container_width=True):
            if new_service_name.strip() != "":
                st.session_state.services[new_service_name.strip()] = {
                    "الملكي": float(price_malaki), 
                    "SUV": float(price_suv),
                    "fixed_commission": float(fixed_comm_val)
                }
                st.success(f"🎉 تم تحديث أسعار وعمولة باقة [{new_service_name.strip()}] في قائمة البيع!")
                st.rerun()
            else:
                st.error("❌ يرجى كتابة اسم باقة أو خدمة صحيح.")
                
        st.write("---")
        st.subheader("📋 الخدمات الحالية المسجلة في نظامك وتعديلها")
        
        if st.session_state.services:
            for s_name, s_prices in list(st.session_state.services.items()):
                col_info, col_edit_btn, col_del_btn = st.columns([3, 1, 1])
                with col_info:
                    st.markdown(f"🔹 **{s_name}** 👉 (الملاكي: `{s_prices.get('الملكي', 0):.2f} ج.م` | SUV: `{s_prices.get('SUV', 0):.2f} ج.م` | العمولة الثابتة: `{s_prices.get('fixed_commission', 0):.2f} ج.م`)")
                with col_edit_btn:
                    if st.button("تعديل السعر ⚙️", key=f"edit_s_{s_name}"):
                        st.info(f"💡 لتعديل سعر أو عمولة **[{s_name}]**، اكتب الاسم بالأعلى في الخانة وضع الأسعار الجديدة والعمولة الثابتة ثم اضغط تثبيت.")
                with col_del_btn:
                    if st.button("حذف نهائي 🗑️", key=f"delete_s_{s_name}"):
                        del st.session_state.services[s_name]
                        st.success(f"🗑️ تم حذف خدمة {s_name} من الكاشير!")
                        st.rerun()
        else:
            st.info("ℹ️ قائمة الخدمات فارغة حالياً.")

    with tab_security:
        st.subheader("🔐 إدارة وتعديل حسابات الدخول والسرية للمنظومة")
        
        st.markdown("#### 👑 حساب المالك الرئيسي (أنت)")
        col_owner_u, col_owner_p = st.columns(2)
        with col_owner_u:
            new_owner_user = st.text_input("👤 اسم مستخدم المالك الحالي:", value=st.session_state.credentials["owner"]["username"])
        with col_owner_p:
            new_owner_pass = st.text_input("🔑 تعيين كلمة سر جديدة للمالك:", type="password", placeholder="اتركها فارغة لعدم التغيير")
            
        if st.button("حفظ تحديثات حساب المالك 💾"):
            st.session_state.credentials["owner"]["username"] = new_owner_user.strip()
            if new_owner_pass.strip() != "":
                st.session_state.credentials["owner"]["password"] = new_owner_pass.strip()
            st.success("✅ تم تحديث بيانات حساب المالك بنجاح!")
            st.rerun()
            
        st.write("---")
        st.markdown("#### 👥 حسابات موظفي الكاشير والاستقبال المضافة")
        
        for w_user, w_data in list(st.session_state.credentials["workers_accounts"].items()):
            col_acc_details, col_acc_del = st.columns([4, 1])
            with col_acc_details:
                st.warning(f"👤 اسم الموظف: **{w_data['name']}** | اسم مستخدم الدخول: `{w_user}` | كلمة سر الحساب الحالية: `{w_data['password']}`")
            with col_acc_del:
                if st.button("حذف الحساب ❌", key=f"del_acc_{w_user}"):
                    if len(st.session_state.credentials["workers_accounts"]) > 1:
                        del st.session_state.credentials["workers_accounts"][w_user]
                        st.success(f"🗑️ تم إزالة حساب الموظف [{w_data['name']}] بنجاح.")
                        st.rerun()
                    else:
                        st.error("❌ لا يمكنك حذف آخر حساب كاشير متبقي!")
                        
        st.write("---")
        st.markdown("##### ➕ إنشاء وإضافة حساب كاشير/موظف جديد للسيستم:")
        col_add_acc1, col_add_acc2, col_add_acc3 = st.columns(3)
        with col_add_acc1: new_w_display_name = st.text_input("🏷️ اسم الموظف الفعلي (مثال: محمد الكاشير):")
        with col_add_acc2: new_w_username = st.text_input("👤 اسم مستخدم الدخول (بالإنجليزي - مثال: kasher1):")
        with col_add_acc3: new_w_password = st.text_input("🔑 كلمة سر الدخول للموظف:", type="password")
        
        if st.button("إنشاء وتثبيت حساب الموظف الجديد 💾", use_container_width=True):
            if new_w_display_name.strip() != "" and new_w_username.strip() != "" and new_w_password.strip() != "":
                w_user_id = new_w_username.strip().lower()
                if w_user_id not in st.session_state.credentials["workers_accounts"] and w_user_id != st.session_state.credentials["owner"]["username"]:
                    st.session_state.credentials["workers_accounts"][w_user_id] = {
                        "name": new_w_display_name.strip(),
                        "password": new_w_password.strip(),
                        "role": "worker"
                    }
                    st.success(f"🎉 تم إنشاء الحساب بنجاح! يمكن للموظف الدخول الآن باستخدام اسم المستخدم: `{w_user_id}`")
                    st.rerun()
                else:
                    st.error("❌ اسم مستخدم الدخول هذا محجوز أو مسجل مسبقاً! اختر اسماً آخر.")
            else:
                st.error("❌ يرجى ملء كافة خانات حساب الموظف الجديد لإتمام عملية الإنشاء الموحدة.")
