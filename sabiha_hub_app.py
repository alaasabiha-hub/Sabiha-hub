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
    
    # الحسابات الافتراضية الافتتاحية للمنظومة مع تحديد الصلاحيات الافتراضية
    if "credentials" not in st.session_state:
        st.session_state.credentials = {
            "owner": {"username": "owner", "password": "sabiha2026"},
            "workers_accounts": {
                "worker1": {
                    "name": "كاشير الاستقبال", 
                    "password": "pos123", 
                    "role": "worker",
                    "permissions": ["🛒 كاشير الاستقبال POS", "📑... دفتر المصروفات"]
                }
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
        
    # قائمة المنتجات والأسعار الافتتاحية (بيع بدون عمولة)
    if "products" not in st.session_state:
        st.session_state.products = {
            "معطر سيارة فاخر": 30.0,
            "فوطة مايكرو فايبر": 50.0,
            "سائل ممسحة زجاج": 40.0
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

# التأكد من وجود مفتاح الصلاحيات لجميع الحسابات القديمة تفادياً لأي أخطاء
for w_user, w_data in st.session_state.credentials["workers_accounts"].items():
    if "permissions" not in w_data:
        st.session_state.credentials["workers_accounts"][w_user]["permissions"] = ["🛒 كاشير الاستقبال POS", "📑... دفتر المصروفات"]

# ============================================================================
# 2. نظام تسجيل الدخول وإدارة الصلاحيات وحماية الواجهة
# ============================================================================
if "logged_in" not in st.session_state:
    st.session_state.logged_in = False
if "user_role" not in st.session_state:
    st.session_state.user_role = None
if "current_user" not in st.session_state:
    st.session_state.current_user = None
if "current_user_id" not in st.session_state:
    st.session_state.current_user_id = None

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
                st.session_state.current_user_id = "owner"
                st.success("🎉 أهلاً بك يا مالك المنظومة، تم تسجيل الدخول بنجاح!")
                st.rerun()
            else:
                login_success = False
                for w_id, w_info in st.session_state.credentials["workers_accounts"].items():
                    if input_user == w_id and input_pass == w_info["password"]:
                        st.session_state.logged_in = True
                        st.session_state.user_role = "worker"
                        st.session_state.current_user = w_info["name"]
                        st.session_state.current_user_id = w_id
                        login_success = True
                        st.success(f"🎉 تم تسجيل دخول الموظف: {w_info['name']}")
                        st.rerun()
                        break
                if not login_success:
                    st.error("❌ بيانات الدخول غير صحيحة، يرجى التحقق وإعادة المحاولة.")
    st.stop()

# ============================================================================
# 3. شريط التنقل الجانبي (Sidebar) وتطهير خيارات الصلاحيات ديناميكياً
# ============================================================================
st.sidebar.markdown(f"### 🚪 مرحباً: **{st.session_state.current_user}**")
st.sidebar.markdown(f"💼 صلاحية الحساب: `{st.session_state.user_role}`")
st.sidebar.write("---")

if st.sidebar.button("تسجيل الخروج 🔓", use_container_width=True):
    st.session_state.logged_in = False
    st.session_state.user_role = None
    st.session_state.current_user = None
    st.session_state.current_user_id = None
    st.rerun()

if st.sidebar.button("🔄 مزامنة وتحديث البيانات لحظياً", use_container_width=True):
    st.rerun()

# القائمة الكاملة للصفحات المتاحة في النظام الموحد
all_possible_pages = [
    "📊 لوحة الداشبورد الرئيسية",
    "🛒 كاشير الاستقبال POS",
    "📉 تقرير الحسابات والأرشيف",
    "💸 العمولات والسلفيات الحية",
    "📑... دفتر المصروفات",
    "⚙️ إعدادات الباقات والعمال"
]

if st.session_state.user_role == "owner":
    menu_options = all_possible_pages
else:
    current_uid = st.session_state.current_user_id
    user_account_data = st.session_state.credentials["workers_accounts"].get(current_uid, {})
    menu_options = user_account_data.get("permissions", ["🛒 كاشير الاستقبال POS"])
    
    if not menu_options:
        menu_options = ["🛒 كاشير الاستقبال POS"]

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

# دالة لتوليد كود طباعة الفاتورة الفردية للعميل كـ PDF
def generate_receipt_pdf_trigger(inv, key_suffix):
    status_str = "نشطة" if inv.get("status", "Active") == "Active" else f"مرتجع (السبب: {inv.get('refund_reason', 'غير محدد')})"
    type_label = "منتج" if inv.get("sale_type") == "product" else "خدمة"
    discount_display = f"<tr><td><b>الخصم الممنوح:</b></td><td>{inv.get('discount', 0.0):.2f} ج.م</td></tr>" if inv.get('discount', 0.0) > 0 else ""
    receipt_script = f"""
    <script>
    function printReceipt_{key_suffix}() {{
        var win = window.open("", "", "height=500,width=400");
        win.document.write("<html><head><title>فاتورة عميل - Sabiha Hub</title>");
        win.document.write("<style>body{{font-family:sans-serif;direction:rtl;padding:10px;text-align:center;}} .ticket{{width:100%;max-width:300px;margin:auto;}} .header{{margin-bottom:15px;}} table{{width:100%;border-collapse:collapse;margin-top:10px;}} td{{padding:6px;text-align:right;font-size:14px;}} .total{{font-size:18px;font-weight:bold;margin-top:15px;border-top:1px dashed #000;padding-top:10px;}}</style>");
        win.document.write("</head><body>");
        win.document.write("<div class='ticket'>");
        win.document.write("<div class='header'><h2>✨ Sabiha Hub ✨</h2><p>مركز صبيحة للعناية بالسيارات</p></div>");
        win.document.write("<hr style='border-top:1px dashed #000;'>");
        win.document.write("<table>");
        win.document.write("<tr><td><b>رقم الفاتورة:</b></td><td>{inv['id']}</td></tr>");
        win.document.write("<tr><td><b>التاريخ:</b></td><td>{inv['time']}</td></tr>");
        win.document.write("<tr><td><b>نوع العملية:</b></td><td>{type_label}</td></tr>");
        win.document.write("<tr><td><b>رقم اللوحة:</b></td><td>{inv.get('plate_number', '---')}</td></tr>");
        win.document.write("<tr><td><b>البيان / البند:</b></td><td>{inv['service']}</td></tr>");
        win.document.write("<tr><td><b>الفئة / الحجم:</b></td><td>{inv.get('car_type', '---')}</td></tr>");
        win.document.write("<tr><td><b>وسيلة الدفع:</b></td><td>{inv.get('payment','كاش')}</td></tr>");
        win.document.write(`{discount_display}`);
        win.document.write("<tr><td><b>الحالة:</b></td><td>{status_str}</td></tr>");
        win.document.write("</table>");
        win.document.write("<div class='total'><p>الإجمالي النهائي: {inv['total']:.2f} ج.م</p></div>");
        win.document.write("<hr style='border-top:1px dashed #000;'>");
        win.document.write("<p style='font-size:12px;'>شكراً لزيارتكم لـ Sabiha Hub 😊</p>");
        win.document.write("</div>");
        win.document.write("</body></html>");
        win.document.close();
        win.print();
    }}
    </script>
    <button onclick="printReceipt_{key_suffix}()" style="background-color:#10B981;color:white;padding:6px 12px;border:none;border-radius:4px;cursor:pointer;font-size:13px;width:100%;">🖨️ طباعة الفاتورة للعميل (PDF)</button>
    """
    st.components.v1.html(receipt_script, height=35)

# ============================================================================
# 4. بناء الأقسام البرمجية والشاشات التفاعلية وحفظها التلقائي
# ============================================================================

# تجميع الفواتير غير المكررة لليوم لاستخدامها في الداشبورد والكاشير
all_invoices = []
seen_inv_ids = set()
for worker_name, inv_list in st.session_state.session_state_invoices.items():
    for inv in inv_list:
        if inv["id"] not in seen_inv_ids:
            seen_inv_ids.add(inv["id"])
            unique_inv = inv.copy()
            all_invoices.append(unique_inv)

# قائمة الفنيين العامة لاستخدامها في منسدلات الكنسلة والبيع
worker_list = [w["name"] for w in st.session_state.workers if isinstance(w, dict) and "name" in w]
if not worker_list:
    worker_list = ["لا يوجد فني مسؤول"]

if menu == "📊 لوحة الداشبورد الرئيسية":
    st.markdown("## 📊 لوحة الأداء المالي والتشغيلي لليوم الحالي (مزامنة حية 🟢)")
    st.write("---")
    
    calculated_sales = 0.0
    total_commissions = 0.0
    active_invoices_count = 0
    canceled_invoices_total = 0.0  
    active_cars_count = 0          
    
    for inv in all_invoices:
        if inv.get("status", "Active") == "Active":
            calculated_sales += float(inv.get("total", 0.0))
            total_commissions += float(inv.get("commission_total", 0.0))
            active_invoices_count += 1
            if inv.get("sale_type", "service") == "service":
                active_cars_count += 1
        else:
            canceled_invoices_total += float(inv.get("total", 0.0))
            
    st.session_state.daily_sales = calculated_sales
    tax_14 = st.session_state.daily_sales * 0.14
    total_expenses_today = float(st.session_state.daily_expenses.get("rent", 0.0)) + \
                         float(st.session_state.daily_expenses.get("operational", 0.0)) + \
                         float(st.session_state.daily_expenses.get("utilities", 0.0))
                         
    net_profit = st.session_state.daily_sales - total_expenses_today - tax_14 - total_commissions

    col_m1, col_m2, col_m3, col_cars = st.columns(4)
    with col_m1: st.metric("💰 إجمالي المبيعات المحصلة", f"{st.session_state.daily_sales:.2f} ج.م", delta=f"{active_invoices_count} فاتورة إجمالية")
    with col_m2: st.metric("📉 إجمالي مصروفات اليوم", f"{total_expenses_today:.2f} ج.م")
    with col_m3: st.metric("🏛️ ضريبة القيمة المضافة 14%", f"{tax_14:.2f} ج.م")
    with col_cars: st.metric("🚗 عدد السيارات اليوم الحالية", f"{active_cars_count} سيارة")
    
    col_m4, col_m5, col_canceled = st.columns(3)
    with col_m4: st.metric("👨‍🔧 عمولات الفنيين الحية", f"{total_commissions:.2f} ج.م")
    with col_m5: st.metric("🟩 صافي المبيعات / الأرباح الحالي", f"{net_profit:.2f} ج.م")
    with col_canceled: st.metric("🚨 إجمالي الفواتير الملغاة (Refunded)", f"{canceled_invoices_total:.2f} ج.م")
    
    st.write("---")
    st.subheader("📥 تحميل وطباعة التقارير والملخصات للمالك")
    
    invoices_html_rows = ""
    for inv in all_invoices:
        status_text = "نشطة" if inv.get("status", "Active") == "Active" else f"مرتجع (بواسطة: {inv.get('cancelled_by','---')} | السبب: {inv.get('refund_reason', 'غير محدد')})"
        item_type = "منتج" if inv.get("sale_type") == "product" else "خدمة"
        invoices_html_rows += f"""
        <tr>
            <td>{inv['id']}</td>
            <td>{inv.get('plate_number', '---')}</td>
            <td>{item_type}</td>
            <td>{inv['service']}</td>
            <td>{inv.get('car_type', '---')}</td>
            <td>{inv['total']:.2f} ج.م</td>
            <td>{inv.get('discount', 0.0):.2f} ج.م</td>
            <td>{inv.get('worker1','---')} & {inv.get('worker2','---')}</td>
            <td>{status_text}</td>
        </tr>
        """

    pdf_script = f"""
    <script>
    function printReport() {{
        var win = window.open("", "", "height=700,width=900");
        win.document.write("<html><head><title>Sabiha Hub - التقرير اليومي</title>");
        win.document.write("<style>body{{font-family:sans-serif;direction:rtl;padding:20px;}} table{{width:100%;border-collapse:collapse;margin-top:20px;}} th,td{{border:1px solid #ddd;padding:10px;text-align:right;font-size:14px;}} th{{background-color:#f4f4f4;}} .summary{{margin-bottom:30px;background:#f9f9f9;padding:15px;border-radius:8px;}}</style>");
        win.document.write("</head><body>");
        win.document.write("<h2>📊 التقرير المالي والتشغيلي اليومي - Sabiha Hub</h2>");
        win.document.write("<p><b>التاريخ:</b> {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>");
        win.document.write("<div class='summary'>");
        win.document.write("<h3>💰 الملخص المالي اليومي:</h3>");
        win.document.write("<p><b>إجمالي المبيعات:</b> {st.session_state.daily_sales:.2f} ج.م</p>");
        win.document.write("<p><b>إجمالي المصروفات:</b> {total_expenses_today:.2f} ج.م</p>");
        win.document.write("<p><b>ضريبة القيمة المضافة 14%:</b> {tax_14:.2f} ج.م</p>");
        win.document.write("<p><b>عمولات العمال والفنيين:</b> {total_commissions:.2f} ج.م</p>");
        win.document.write("<p><b>عدد السيارات المخدومة:</b> {active_cars_count} سيارة</p>");
        win.document.write("<p><b>إجمالي المبالغ الملغاة/المرتجعة:</b> {canceled_invoices_total:.2f} ج.م</p>");
        win.document.write("<p><b>صافي المبيعات والأرباح:</b> {net_profit:.2f} ج.م</p>");
        win.document.write("</div>");
        win.document.write("<h3>📋 كشف الفواتير والعمليات المُرَحَّلة:</h3>");
        win.document.write("<table><thead><tr><th>رقم الفاتورة</th><th>رقم اللوحة</th><th>النوع</th><th>البيان</th><th>الفئة</th><th>المبلغ</th><th>الخصم</th><th>الفنيين</th><th>الحالة</th></tr></thead><tbody>");
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
                    "commissions": total_commissions,
                    "cars_count": active_cars_count,
                    "canceled_total": canceled_invoices_total,
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
    
    if all_invoices:
        for index, inv in enumerate(all_invoices):
            col_i1, col_i2, col_i3, col_i4, col_refund = st.columns([2, 2, 2, 2, 2])
            with col_i1: 
                type_badge = "📦 منتج" if inv.get("sale_type") == "product" else "🛠️ خدمة"
                st.write(f"🧾 رقم: **{inv['id']}** | النوع: `{type_badge}` | اللوحة: `({inv.get('plate_number', '---')})`")
            with col_i2: 
                st.write(f"🛍️ البيان: *{inv['service']}* | الخصم: `{inv.get('discount', 0.0):.2f} ج.م`")
                if inv.get("status") == "Refunded":
                    st.markdown(f"<span style='color:red; font-size:12px;'>💬 الملغي بواسطة: {inv.get('cancelled_by','---')} | السبب: {inv.get('refund_reason','---')}</span>", unsafe_allow_html=True)
            with col_i3: st.write(f"💵 القيمة النهائية: `{inv['total']:.2f} ج.م` | العمولة: `{inv.get('commission_total', 0.0):.2f} ج.م`")
            with col_i4: 
                if inv.get("status", "Active") == "Active":
                    st.markdown("🟢 **الفاتورة نشطة**")
                else:
                    st.markdown("<span style='color:red;'>↩️ **تم الاسترجاع (Refunded)**</span>", unsafe_allow_html=True)
            with col_refund:
                if inv.get("status", "Active") == "Active":
                    refund_reason_input = st.text_input("سبب الإلغاء 📝", key=f"dash_reason_{inv['id']}_{index}", placeholder="اكتب سبب التراجع أولاً...")
                    cancelled_by_worker = st.selectbox("الفني المسؤول عن الكنسلة 👨‍🔧", options=["اختر الفني"] + worker_list, key=f"dash_cancel_worker_{inv['id']}_{index}")
                    if st.button("إرجاع الفاتورة ↩️", key=f"dash_ref_btn_{inv['id']}_{index}"):
                        if refund_reason_input.strip() == "":
                            st.error("❌ خطأ: يجب كتابة سبب الإلغاء لإتمام العملية!")
                        elif cancelled_by_worker == "اختر الفني":
                            st.error("❌ خطأ: يجب اختيار الفني القائم بالكنسلة!")
                        else:
                            for w_key, w_invs in st.session_state.session_state_invoices.items():
                                for item in w_invs:
                                    if item["id"] == inv["id"]:
                                        item["status"] = "Refunded"
                                        item["refund_reason"] = refund_reason_input.strip()
                                        item["cancelled_by"] = cancelled_by_worker
                            st.error(f"↩️ تم تسجيل مرتجع للفاتورة [{inv['id']}] وحفظ السبب بنجاح.")
                            st.rerun()
                else:
                    st.button("تم ردها مسبقاً 🔒", disabled=True, key=f"dash_ref_dis_{inv['id']}_{index}")
    else:
        st.info("ℹ️ لا توجد فواتير أو عمليات مسجلة لليوم حتى الآن.")

# ----------------------------------------------------------------------------
# قسم كاشير الاستقبال (POS) - نظام مبيعات مغلق السعر للكاشير (التغيير فقط من إعدادات الباقات)
# ----------------------------------------------------------------------------
elif menu == "كاشير الاستقبال POS":
    st.markdown("<h2 style='text-align: center;'>📥 كاشير الاستقبال وتسجيل الفواتير</h2>", unsafe_allow_html=True)
    st.write("---")
    
    with st.container():
        sale_type_selection = st.radio("📦 حدد تصنيف عملية البيع الحالية:", options=["بيع خدمة مركز 🛠️", "بيع منتج / إكسسوار 📦"], horizontal=True)
        
        base_price = 0.0
        fixed_comm = 0.0
        plate_number = "---"
        car_type = "---"
        selected_worker1 = "مبيعات مباشرة"
        selected_worker2 = "مبيعات مباشرة"
        selected_item_name = ""
        is_product = False

        if sale_type_selection == "بيع خدمة مركز 🛠️":
            plate_number = st.text_input("🔢 رقم لوحة السيارة:", key="pos_plate_number_input").strip()
            car_type = st.selectbox("🚗 فئة حجم السيارة للتسعير الآلي المعتمد أولياً:", options=["ملاكي / سيدان", "SUV"])
            car_key = "الملكي" if car_type == "ملاكي / سيدان" else "SUV"
            
            service_options = list(st.session_state.services.keys())
            if not service_options:
                st.error("❌ لا توجد خدمات مسجلة في النظام.")
                service_options = ["لا توجد خدمات"]
            selected_item_name = st.selectbox("🛍️ اختر الخدمة المعتمدة:", options=service_options)
            
            selected_worker1 = st.selectbox("👨‍🔧 فني حارة الغسيل (العامل الأول):", options=worker_list, key="pos_w1")
            selected_worker2 = st.selectbox("🧽 أخصائي الديتيلينج / التجهيز (العامل الثاني):", options=worker_list, key="pos_w2")
            
            if selected_item_name in st.session_state.services:
                base_price = float(st.session_state.services[selected_item_name].get(car_key, 0.0))
                fixed_comm = float(st.session_state.services[selected_item_name].get("fixed_commission", 0.0))
            st.markdown(f"ℹ️ **السعر التلقائي المحفوظ:** `{base_price:.2f} ج.م` | **العمولة الثابتة المقررة للخدمة:** `{fixed_comm:.2f} ج.م`")
            
        else:
            is_product = True
            product_options = list(st.session_state.products.keys())
            if not product_options:
                st.error("❌ لا توجد منتجات مسجلة في الإعدادات للبيع حالياً.")
                product_options = ["لا توجد منتجات مضافة"]
            selected_item_name = st.selectbox("📦 اختر المنتج المراد بيعه:", options=product_options)
            
            selected_worker1 = st.selectbox("👤 الموظف المسؤول عن البيع المباشر:", options=["مبيعات مباشرة"] + worker_list, key="pos_prod_w1")
            selected_worker2 = "لا يوجد"
            
            if selected_item_name in st.session_state.products:
                base_price = float(st.session_state.products[selected_item_name])
            fixed_comm = 0.0  
            st.markdown(f"ℹ️ **سعر بيع المنتج الحالي المحفوظ:** `{base_price:.2f} ج.م` | **العمولة المقررة:** `0.00 ج.م (بدون عمولة فنية)`")
            
        payment_method = st.radio("💵 وسيلة السداد:", options=["كاش", "فيزا"], horizontal=True)
        
        # قفل خانة القيمة الأساسية وجعلها مخصصة للقراءة فقط ومنع الكاشير من تعديلها نهائياً (disabled=True) لضمان تحكم المالك فقط من الإعدادات
        custom_price = st.number_input("💰 القيمة الأساسية المعتمدة للمعاملة (ج.م):", min_value=0.0, value=base_price, disabled=True, help="لا يمكن تعديل السعر من واجهة الكاشير، التغيير يتم فقط من لوحة الإدارة")
        
        # خانة الخصم الخاصة بالعملاء
        customer_discount = st.number_input("📉 إدخال خصم إضافي للعميل إذا رغبت (ج.م):", min_value=0.0, value=0.0, key="pos_discount_input")
        
        final_calculated_total = custom_price - customer_discount
        if final_calculated_total < 0:
            final_calculated_total = 0.0
            
        st.markdown(f"### 💵 الإجمالي الصافي المطلوب تحصيله: <span style='color:green;'>{final_calculated_total:.2f} ج.م</span>", unsafe_allow_html=True)
        
        share_commission = fixed_comm / 2
        if not is_product:
            st.write(f"📊 نصيب كل عامل من العمولة الثابتة (توزيع متساوي): **{share_commission:.2f} ج.م**")
        
        if st.button("🟢 إتمام المعاملة وإصدار الفاتورة حياً", use_container_width=True):
            if selected_item_name in ["لا توجد خدمات", "لا توجد منتجات مضافة"] or (not is_product and plate_number == ""):
                st.error("❌ خطأ: يرجى التحقق من استكمال البيانات الأساسية وعملية الإدخال ورقم اللوحة.")
            else:
                invoice_id = f"INV-{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
                
                invoice_data = {
                    "id": invoice_id,
                    "plate_number": plate_number,
                    "service": selected_item_name,
                    "car_type": car_type,
                    "total": final_calculated_total,
                    "discount": customer_discount,
                    "sale_type": "product" if is_product else "service",
                    "worker1": selected_worker1,
                    "worker2": selected_worker2,
                    "commission_total": fixed_comm,
                    "commission_share": share_commission,
                    "payment": payment_method,
                    "status": "Active",
                    "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                }
                
                w1_key = selected_worker1 if selected_worker1 else "مبيعات مباشرة"
                if w1_key not in st.session_state.session_state_invoices:
                    st.session_state.session_state_invoices[w1_key] = []
                st.session_state.session_state_invoices[w1_key].append(invoice_data)
                
                if not is_product and selected_worker2 != "لا يوجد":
                    if selected_worker2 not in st.session_state.session_state_invoices:
                        st.session_state.session_state_invoices[selected_worker2] = []
                    st.session_state.session_state_invoices[selected_worker2].append(invoice_data)
                
                st.success(f"🎉 تم إصدار الفاتورة والمستند المالي بنجاح برقم [{invoice_id}]!")
                st.balloons()
                st.rerun()

    st.write("---")
    st.subheader("📋 فواتير اليوم الحالية وإدارة المرتجعات / طباعة إيصال العميل (POS Refund)")
    
    if all_invoices:
        for index, inv in enumerate(all_invoices):
            col_pos1, col_pos2, col_pos3, col_pos_actions = st.columns([3, 2, 2, 3.5])
            with col_pos1: 
                status_icon = "🟢" if inv.get("status", "Active") == "Active" else "↩️ مرتجع"
                type_lbl = "📦 منتج" if inv.get("sale_type") == "product" else "🛠️ خدمة"
                st.write(f"🧾 {status_icon} **{inv['id']}** | النوع: `{type_lbl}` | اللوحة: `({inv.get('plate_number', '---')})`")
            with col_pos2: 
                st.write(f"🛍️ {inv['service']} | خصم: `{inv.get('discount', 0.0):.2f} ج.م`")
                if inv.get("status") == "Refunded":
                    st.markdown(f"<span style='color:red; font-size:11px;'>💬 الملغي بواسطة: {inv.get('cancelled_by','---')} | السبب: {inv.get('refund_reason','---')}</span>", unsafe_allow_html=True)
            with col_pos3: st.write(f"💵 الصافي: `{inv['total']:.2f} ج.م` | `{inv.get('payment','كاش')}`")
            with col_pos_actions:
                generate_receipt_pdf_trigger(inv, f"pos_sheet_{index}")
                
                if inv.get("status", "Active") == "Active":
                    pos_reason = st.text_input("سبب الكنسلة 📝", key=f"pos_reason_inp_{inv['id']}_{index}", placeholder="اكتب سبب إلغاء الفاتورة...")
                    pos_cancel_worker = st.selectbox("الفني القائم بالكنسلة 👨‍🔧", options=["اختر الفني"] + worker_list, key=f"pos_worker_sel_{inv['id']}_{index}")
                    
                    if st.button("إرجاع الفاتورة ↩️", key=f"pos_refund_btn_{inv['id']}_{index}", use_container_width=True):
                        if pos_reason.strip() == "":
                            st.error("❌ خطأ: يرجى كتابة سبب الإلغاء أولاً!")
                        elif pos_cancel_worker == "اختر الفني":
                            st.error("❌ خطأ: يرجى اختيار الفني القائم بالكنسلة لتوزيع المسؤولية!")
                        else:
                            for w_key, w_invs in st.session_state.session_state_invoices.items():
                                for item in w_invs:
                                    if item["id"] == inv["id"]:
                                        item["status"] = "Refunded"
                                        item["refund_reason"] = pos_reason.strip()
                                        item["cancelled_by"] = pos_cancel_worker
                            st.error(f"↩️ تم بنجاح إلغاء الفاتورة وتوثيق العملية بواسطة [{pos_cancel_worker}].")
                            st.rerun()
                else:
                    st.button("تم رد العملية 🔒", disabled=True, key=f"pos_dis_btn_{inv['id']}_{index}")
    else:
        st.info("ℹ️ لا توجد فواتير صادرة لليوم حتى الآن بمستندات الكاشير.")

# ----------------------------------------------------------------------------
# تقرير الحسابات والأرشيف المالي الشامل - ميزة تحميل وطباعة كشوف الأرشيف PDF
# ----------------------------------------------------------------------------
elif menu == "تقرير الحسابات والأرشيف":
    st.markdown("## 📉 تقرير الحسابات والأرشيف المالي الشامل")
    st.write("---")
    
    st.subheader("📥 تحميل وطباعة أرشيف الحسابات كـ PDF")
    
    archive_html_rows = ""
    if st.session_state.daily_archive:
        for day, day_data in st.session_state.daily_archive.items():
            archive_html_rows += f"""
            <tr>
                <td>{day}</td>
                <td>{day_data['sales']:.2f} ج.م</td>
                <td>{day_data['expenses']:.2f} ج.م</td>
                <td>{day_data['tax']:.2f} ج.م</td>
                <td>{day_data['commissions']:.2f} ج.م</td>
                <td>{day_data.get('cars_count', 0)}</td>
                <td>{day_data.get('canceled_total', 0.0):.2f} ج.م</td>
                <td>{day_data['net']:.2f} ج.م</td>
            </tr>
            """
    else:
        archive_html_rows = "<tr><td colspan='8' style='text-align:center;'>لا توجد أيام مغلقة ومؤرشفة حالياً في النظام</td></tr>"

    archive_pdf_script = f"""
    <script>
    function printArchiveReport() {{
        var win = window.open("", "", "height=700,width=1000");
        win.document.write("<html><head><title>Sabiha Hub - تقرير الأرشيف المالي</title>");
        win.document.write("<style>body{{font-family:sans-serif;direction:rtl;padding:20px;}} table{{width:100%;border-collapse:collapse;margin-top:20px;}} th,td{{border:1px solid #ddd;padding:10px;text-align:right;font-size:14px;}} th{{background-color:#f4f4f4;}}</style>");
        win.document.write("</head><body>");
        win.document.write("<h2>📉 تقرير أرشيف الحسابات المالي الشامل - Sabiha Hub</h2>");
        win.document.write("<p><b>تاريخ الاستخراج:</b> {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>");
        win.document.write("<table><thead><tr><th>اليوم والتاريخ</th><th>إجمالي المبيعات</th><th>المصروفات</th><th>الضرائب 14%</th><th>عمولات الفنيين</th><th>عدد السيارات</th><th>الملغى</th><th>صافي الأرباح</th></tr></thead><tbody>");
        win.document.write(`{archive_html_rows}`);
        win.document.write("</tbody></table>");
        win.document.close();
        win.print();
    }}
    </script>
    <button onclick="printArchiveReport()" style="background-color:#1E3A8A;color:white;padding:12px 24px;border:none;border-radius:6px;cursor:pointer;font-size:16px;width:100%;">📥 تحميل وطباعة تقرير الأرشيف الشامل كـ PDF</button>
    """
    st.components.v1.html(archive_pdf_script, height=60)
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
                    st.write(f"🚗 **عدد السيارات المسجلة:** {day_data.get('cars_count', 0)} سيارة")
                    st.write(f"🚨 **إجمالي المبالغ الملغاة:** {day_data.get('canceled_total', 0.0):.2f} ج.م")
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
                        w_commissions += float(inv.get("commission_share", 0.0))
                    
            w_advance = float(worker.get("advance", 0.0))
            net_payout = w_commissions - w_advance
            
            with st.expander(f"👨‍🔧 الفني: {w_name} | صافي المستحقات الحالي: {net_payout:.2f} ج.م"):
                col_b1, col_b2, col_b3 = st.columns(3)
                with col_b1: st.metric("🎯 إجمالي العمولات الموزعة الثابتة", f"{w_commissions:.2f} ج.م")
                with col_b2: st.metric("💸 السلفيات الحالية المسجلة", f"{w_advance:.2f} ج.م")
                with col_b3: st.metric("💰 صافي الراتب المستحق للصرف", f"{net_payout:.2f} ج.م")
                
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
        "🛍️ التحكم بالباقات والخدمات والمنتجات والأسعار", 
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
        st.subheader("🛠️ أولاً: إضافة باقة أو خدمة جديدة (مع العمولة)")
        
        col_s1, col_s2, col_s3, col_s4 = st.columns(4)
        with col_s1: new_service_name = st.text_input("🏷️ اسم الخدمة / الباقة الجديدة:", key="input_new_service_name_p")
        with col_s2: price_malaki = st.number_input("🚗 سعر فئة السيارات الملاكي (ج.م):", min_value=0.0, value=150.0, key="num_malaki_p")
        with col_s3: price_suv = st.number_input("🚙 سعر فئة السيارات SUV (ج.م):", min_value=0.0, value=200.0, key="num_suv_p")
        with col_s4: fixed_comm_val = st.number_input("🎯 قيمة العمولة الثابتة الكلية (ج.م):", min_value=0.0, value=20.0, key="num_fixed_comm_p")
            
        if st.button("تثبيت باقة جديدة 📥", use_container_width=True):
            if new_service_name.strip() != "":
                st.session_state.services[new_service_name.strip()] = {
                    "الملكي": float(price_malaki), 
                    "SUV": float(price_suv),
                    "fixed_commission": float(fixed_comm_val)
                }
                st.success(f"🎉 تم حفظ باقة [{new_service_name.strip()}] في قائمة البيع!")
                st.rerun()
            else:
                st.error("❌ يرجى كتابة اسم باقة أو خدمة صحيح.")
                
        st.write("---")
        st.subheader("✏️ ثانياً: تعديل أسعار وعمولة الباقات والخدمات المسجلة حالياً (هنا يتم التغيير المعتمد للمالك)")
        edit_service_dropdown = ["اختر خدمة لتعديل أسعارها فوراً"] + list(st.session_state.services.keys())
        selected_edit_s = st.selectbox("🎯 اختر الخدمة المراد تعديل قيمها حالياً لتنعكس في الكاشير:", options=edit_service_dropdown, key="dropdown_edit_services_pos")
        
        if selected_edit_s != "اختر خدمة لتعديل أسعارها فوراً":
            s_current_data = st.session_state.services[selected_edit_s]
            col_ed1, col_ed2, col_ed3 = st.columns(3)
            with col_ed1: updated_price_malaki = st.number_input("🚗 سعر الملاكي المحدث (ج.م):", min_value=0.0, value=float(s_current_data.get("الملكي", 0.0)), key="edit_m_val")
            with col_ed2: updated_price_suv = st.number_input("🚙 سعر SUV المحدث (ج.م):", min_value=0.0, value=float(s_current_data.get("SUV", 0.0)), key="edit_s_val")
            with col_ed3: updated_fixed_comm = st.number_input("🎯 العمولة الثابتة المحدثة (ج.م):", min_value=0.0, value=float(s_current_data.get("fixed_commission", 0.0)), key="edit_c_val")
            
            if st.button(f"💾 حفظ الأسعار الجديدة لخدمة [{selected_edit_s}]", use_container_width=True):
                st.session_state.services[selected_edit_s] = {
                    "الملكي": updated_price_malaki,
                    "SUV": updated_price_suv,
                    "fixed_commission": updated_fixed_comm
                }
                st.success(f"🎉 تم تحديث أسعار وعمولة باقة [{selected_edit_s}] بنجاح في نظام الكاشير!")
                st.rerun()

        st.write("---")
        st.subheader("📦 ثالثاً: إضافة وتحديث المنتجات والتحكم بأسعارها (بيع بدون عمولة)")
        
        col_p1, col_p2 = st.columns(2)
        with col_p1: new_prod_name = st.text_input("🏷️ اسم المنتج الجديد لبيعه بالكاشير:", key="input_new_prod_name_p")
        with col_p2: price_prod = st.number_input("💰 سعر بيع المنتج للجمهور (ج.م):", min_value=0.0, value=30.0, key="num_prod_price_p")
        
        if st.button("تثبيت أو تحديث سعر المنتج في قائمة الكاشير 📥", use_container_width=True):
            if new_prod_name.strip() != "":
                st.session_state.products[new_prod_name.strip()] = float(price_prod)
                st.success(f"🎉 تم حفظ وتثبيت منتج [{new_prod_name.strip()}] بسعر {price_prod:.2f} ج.م بنجاح بدون عمولة!")
                st.rerun()
            else:
                st.error("❌ يرجى كتابة اسم منتج صحيح.")
                
        st.write("---")
        st.subheader("📋 الخدمات والمنتجات الحالية المسجلة في نظامك وتعديلها")
        
        col_list1, col_list2 = st.columns(2)
        with col_list1:
            st.markdown("##### 🛠️ باقات الخدمات الحالية:")
            if st.session_state.services:
                for s_name, s_prices in list(st.session_state.services.items()):
                    col_info, col_del_btn = st.columns([4, 1])
                    with col_info:
                        st.markdown(f"🔹 **{s_name}** 👉 (الملاكي: `{s_prices.get('الملكي', 0):.2f}` | SUV: `{s_prices.get('SUV', 0):.2f}` | العمولة: `{s_prices.get('fixed_commission', 0):.2f}`)")
                    with col_del_btn:
                        if st.button("حذف 🗑️", key=f"delete_s_{s_name}"):
                            del st.session_state.services[s_name]
                            st.rerun()
            else:
                st.info("ℹ️ لا توجد خدمات مسجلة.")
                
        with col_list2:
            st.markdown("##### 📦 المنتجات والإكسسوارات الحالية:")
            if st.session_state.products:
                for p_name, p_price in list(st.session_state.products.items()):
                    col_p_info, col_p_del = st.columns([4, 1])
                    with col_p_info:
                        st.markdown(f"🔸 **{p_name}** 👉 السعر المعتمد: `{p_price:.2f} ج.م` *(بدون عمولة)*")
                    with col_p_del:
                        if st.button("حذف 🗑️", key=f"delete_p_{p_name}"):
                            del st.session_state.products[p_name]
                            st.rerun()
            else:
                st.info("ℹ️ لا توجد منتجات مسجلة حالياً.")

    # ------------------------------------------------------------------------
    # واجهة التحكم المتقدمة في حسابات الموظفين وإدارة الصلاحيات
    # ------------------------------------------------------------------------
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
        st.markdown("#### 👥 حسابات موظفي الكاشير وتعديل الصلاحيات المباشرة حياً")
        
        for w_user, w_data in list(st.session_state.credentials["workers_accounts"].items()):
            col_acc_details, col_acc_del = st.columns([4, 1])
            with col_acc_details:
                st.warning(f"👤 اسم الموظف: **{w_data['name']}** | اسم مستخدم الدخول: `{w_user}` | كلمة سر الحساب الحالية: `{w_data['password']}`")
                
                current_perms = w_data.get("permissions", ["🛒 كاشير الاستقبال POS", "📑... دفتر المصروفات"])
                updated_perms = st.multiselect(
                    f"⚙️ حدد الصفحات المسموح لـ [{w_data['name']}] برؤيتها بالظبط داخل شريط التنقل الجانبي:",
                    options=all_possible_pages,
                    default=current_perms,
                    key=f"live_edit_perms_{w_user}"
                )
                st.session_state.credentials["workers_accounts"][w_user]["permissions"] = updated_perms
                
            with col_acc_del:
                if st.button("حذف الحساب ❌", key=f"del_acc_{w_user}"):
                    if len(st.session_state.credentials["workers_accounts"]) > 1:
                        del st.session_state.credentials["workers_accounts"][w_user]
                        st.success(f"🗑️ تم إزالة حساب الموظف [{w_data['name']}] بنجاح.")
                        st.rerun()
                    else:
                        st.error("❌ لا يمكنك حذف آخر حساب كاشير متبقي!")
                        
        st.write("---")
        st.markdown("##### ➕ إنشاء وإضافة حساب كاشير/موظف جديد للسيستم مع الصلاحيات:")
        col_add_acc1, col_add_acc2, col_add_acc3 = st.columns(3)
        with col_add_acc1: new_w_display_name = st.text_input("🏷️ اسم الموظف الفعلي (مثال: محمد الكاشير):")
        with col_add_acc2: new_w_username = st.text_input("👤 اسم مستخدم الدخول (بالإنجليزي - مثال: kasher1):")
        with col_add_acc3: new_w_password = st.text_input("🔑 كلمة سر الدخول للموظف:", type="password")
        
        new_worker_initial_perms = st.multiselect(
            "📋 حدد صلاحيات رؤية الصفحات لهذا الحساب الجديد أولياً:",
            options=all_possible_pages,
            default=["🛒 كاشير الاستقبال POS", "📑... دفتر المصروفات"],
            key="new_worker_perms_selector"
        )
        
        if st.button("إنشاء وتثبيت حساب الموظف الجديد 💾", use_container_width=True):
            if new_w_display_name.strip() != "" and new_w_username.strip() != "" and new_w_password.strip() != "":
                w_user_id = new_w_username.strip().lower()
                if w_user_id not in st.session_state.credentials["workers_accounts"] and w_user_id != st.session_state.credentials["owner"]["username"]:
                    st.session_state.credentials["workers_accounts"][w_user_id] = {
                        "name": new_w_display_name.strip(),
                        "password": new_w_password.strip(),
                        "role": "worker",
                        "permissions": new_worker_initial_perms
                    }
                    st.success(f"🎉 تم إنشاء الحساب بنجاح وصلاحياته المقررة! يمكن للموظف الدخول الآن باستخدام اسم المستخدم: `{w_user_id}`")
                    st.rerun()
                else:
                    st.error("❌ اسم مستخدم الدخول هذا محجوز أو مسجل مسبقاً! اختر اسماً آخر.")
            else:
                st.error("❌ يرجى ملء كافة خانات حساب الموظف الجديد لإتمام عملية الإنشاء الموحدة.")
