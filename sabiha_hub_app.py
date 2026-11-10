import streamlit as st
import pandas as pd
import json
import os
import datetime

# ضبط إعدادات الصفحة لتكون عريضة ومناسبة لجميع الشاشات
st.set_page_config(page_title="Sabiha Hub", page_icon="✨", layout="wide", initial_sidebar_state="expanded")

# واجهة موحدة أكثر احترافية ومتوافقة مع الشاشات المختلفة.
st.markdown("""
<style>
:root { --sh-primary:#173b63; --sh-accent:#18a58a; --sh-bg:#f4f7fb; }
.stApp { background:var(--sh-bg); }
.block-container { padding-top:1.5rem; padding-bottom:2.5rem; max-width:1500px; }
[data-testid="stSidebar"] { background:linear-gradient(180deg,#102b49 0%,#173b63 100%); }
[data-testid="stSidebar"] * { color:#f7fbff !important; }
[data-testid="stMetric"] { background:#ffffff; border:1px solid #e7edf4; padding:16px 18px; border-radius:16px; box-shadow:0 4px 16px rgba(20,48,78,.06); }
[data-testid="stMetricLabel"] p { color:#52657a !important; font-weight:600; }
[data-testid="stMetricValue"] { color:#173b63 !important; font-weight:800; }
.stButton > button, .stDownloadButton > button { border-radius:10px; min-height:2.6rem; font-weight:650; }
.stTextInput input, .stNumberInput input, .stSelectbox div[data-baseweb="select"] { border-radius:10px; }
[data-testid="stExpander"] { border:1px solid #e4ebf2; border-radius:12px; background:#fff; }
hr { border-color:#e3eaf2; }
.sh-hero { background:linear-gradient(115deg,#123456,#1b6b78); padding:24px 28px; border-radius:18px; color:white; margin:0 0 18px 0; box-shadow:0 8px 24px rgba(18,52,86,.16); }
.sh-hero h1 { color:white; margin:0; font-size:1.8rem; }
.sh-hero p { color:#e1f2f4; margin:.4rem 0 0 0; }
@media(max-width:700px){ .block-container{padding:1rem .8rem 2rem;} .sh-hero{padding:18px;} }
</style>
""", unsafe_allow_html=True)

# ============================================================================
# 1. نظام الحفظ والتخزين السحابي الدائم لمنع ضياع الحسابات والبيانات أونلاين
# ============================================================================
DATA_FILE = "sabiha_persistent_data.json"

def load_system_data():
    """تحميل البيانات المخزنة من الملف السحابي إذا كانت موجودة، وإلا إنشاء البيانات الافتراضية"""
    default_data = {
        "credentials": {
            "owner": {"username": "owner", "password": "sabiha2026"},
            "workers_accounts": {
                "worker1": {
                    "name": "كاشير الاستقبال", 
                    "password": "pos123", 
                    "role": "worker",
                    "permissions": ["🛒 كاشير الاستقبال POS", "📑... دفتر المصروفات"]
                }
            }
        },
        "workers": [
            {"name": "أحمد مصطفى", "advance": 0.0},
            {"name": "محمد علي", "advance": 0.0}
        ],
        # نسبة عمولة الخدمات من صافي الفاتورة بعد الخصم
        "commission_rate": 10.0,
        "services": {
            "غسيل سريع": {"الملكي": 150.0, "SUV": 200.0, "fixed_commission": 20.0},
            "تلميع نانو سريع": {"الملكي": 300.0, "SUV": 400.0, "fixed_commission": 50.0},
            "تنظيف صالون عميق": {"الملكي": 250.0, "SUV": 350.0, "fixed_commission": 40.0}
        },
        "products": {
            "معطر سيارة فاخر": 30.0,
            "فوطة مايكرو فايبر": 50.0,
            "سائل ممسحة زجاج": 40.0
        },
        "session_state_invoices": {},
        "daily_sales": 0.0,
        "daily_expenses": {"rent": 0.0, "operational": 0.0, "utilities": 0.0},
        "daily_archive": {},
        "monthly_archive": {}
    }
    
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                # التأكد من دمج بنية البيانات لضمان عدم حدوث تعارض
                for key, val in default_data.items():
                    if key not in loaded:
                        loaded[key] = val
                return loaded
        except:
            return default_data
    return default_data

def save_system_data():
    """حفظ الحالة الحالية للنظام بالكامل في الملف النصي بشكل فوري لضمان الثبات"""
    to_save = {
        "credentials": st.session_state.credentials,
        "workers": st.session_state.workers,
        "commission_rate": st.session_state.commission_rate,
        "services": st.session_state.services,
        "products": st.session_state.products,
        "session_state_invoices": st.session_state.session_state_invoices,
        "daily_sales": st.session_state.daily_sales,
        "daily_expenses": st.session_state.daily_expenses,
        "daily_archive": st.session_state.daily_archive,
        "monthly_archive": st.session_state.monthly_archive
    }
    try:
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(to_save, f, ensure_ascii=False, indent=4)
    except:
        pass

# تهيئة ومزامنة البيانات مع المستودع الدائم
if "system_loaded" not in st.session_state:
    persisted = load_system_data()
    st.session_state.credentials = persisted["credentials"]
    st.session_state.workers = persisted["workers"]
    st.session_state.commission_rate = float(persisted.get("commission_rate", 10.0))
    st.session_state.services = persisted["services"]
    st.session_state.products = persisted["products"]
    st.session_state.session_state_invoices = persisted["session_state_invoices"]
    st.session_state.daily_sales = persisted["daily_sales"]
    st.session_state.daily_expenses = persisted["daily_expenses"]
    st.session_state.daily_archive = persisted["daily_archive"]
    st.session_state.monthly_archive = persisted["monthly_archive"]
    st.session_state.system_loaded = True

# صيانة الصلاحيات للحسابات القديمة منعاً لأي خطأ برمي
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

# تجميع الفواتير لليوم
all_invoices = []
seen_inv_ids = set()
for worker_name, inv_list in st.session_state.session_state_invoices.items():
    for inv in inv_list:
        if inv["id"] not in seen_inv_ids:
            seen_inv_ids.add(inv["id"])
            all_invoices.append(inv.copy())

worker_list = [w["name"] for w in st.session_state.workers if isinstance(w, dict) and "name" in w]
if not worker_list:
    worker_list = ["لا يوجد فني مسؤول"]

# ============================================================================
# 4. واجهات الصفحات والمعاملات المحاسبية
# ============================================================================

if menu == "📊 لوحة الداشبورد الرئيسية":
    st.markdown("""
    <section class="sh-hero">
      <h1>✨ Sabiha Hub | لوحة التحكم</h1>
      <p>نظرة موحّدة على الأداء المالي والتشغيلي ومتابعة حركة اليوم</p>
    </section>
    """, unsafe_allow_html=True)
    st.caption(f"🟢 النظام يعمل · {datetime.datetime.now().strftime('%Y-%m-%d  %H:%M')}")
    
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
            <td>{', '.join(inv.get('workers', inv.get('commission_workers', [inv.get('worker1','---'), inv.get('worker2','---')])))}</td>
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
                save_system_data()
                st.success(f"✅ تم إغلاق اليوم وترحيل حساباته بنجاح بالتاريخ: {today_str}")
                st.rerun()
                
    with col_close2:
        if st.button("📁 إغلاق الشهر الحالي وتصفير العدادات لبدء شهر جديد", use_container_width=True):
            month_str = datetime.datetime.now().strftime("%Y-%B")
            if not st.session_state.daily_archive:
                st.warning("⚠️ أرشيف الأيام فارغ، يرجى ترحيل الأيام أولاً قبل إغلاق الشهر.")
            else:
                st.session_state.monthly_archive[month_str] = json.loads(json.dumps(st.session_state.daily_archive))
                st.session_state.daily_archive = {}
                save_system_data()
                st.success(f"🎉 تم ترحيل وأرشفة الشهر بالكامل بنجاح داخل الذاكرة التراكمية [{month_str}]!")
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
                            save_system_data()
                            st.error(f"↩️ تم تسجيل مرتجع للفاتورة [{inv['id']}].")
                            st.rerun()
                else:
                    st.button("تم ردها مسبقاً 🔒", disabled=True, key=f"dash_ref_dis_{inv['id']}_{index}")
    else:
        st.info("ℹ️ لا توجد فواتير أو عمليات مسجلة لليوم حتى الآن.")

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
                service_options = ["لا توجد خدمات"]
            selected_item_name = st.selectbox("🛍️ اختر الخدمة المعتمدة:", options=service_options)
            
            selected_workers = st.multiselect(
                "👨‍🔧 الفنيون المشاركون في السيارة:",
                options=worker_list,
                default=[worker_list[0]] if worker_list else [],
                key="pos_workers_multi",
                help="اختر كل الفنيين المشاركين. تُحسب العمولة الإجمالية مرة واحدة ثم تُقسّم بالتساوي بينهم."
            )
            selected_worker1 = selected_workers[0] if selected_workers else "مبيعات مباشرة"
            selected_worker2 = selected_workers[1] if len(selected_workers) > 1 else "لا يوجد"
            
            if selected_item_name in st.session_state.services:
                base_price = float(st.session_state.services[selected_item_name].get(car_key, 0.0))
                fixed_comm = 0.0
            st.markdown(f"ℹ️ **السعر التلقائي المحفوظ:** `{base_price:.2f} ج.م` | **نسبة عمولة الفنيين:** `{st.session_state.commission_rate:.2f}%` من صافي الفاتورة")
            
        else:
            is_product = True
            product_options = list(st.session_state.products.keys())
            if not product_options:
                product_options = ["لا توجد منتجات مضافة"]
            selected_item_name = st.selectbox("📦 اختر المنتج المراد بيعه:", options=product_options)
            
            selected_worker1 = st.selectbox("👤 الموظف المسؤول عن البيع المباشر:", options=["مبيعات مباشرة"] + worker_list, key="pos_prod_w1")
            selected_worker2 = "لا يوجد"
            
            if selected_item_name in st.session_state.products:
                base_price = float(st.session_state.products[selected_item_name])
            fixed_comm = 0.0  
            st.markdown(f"ℹ️ **سعر بيع المنتج الحالي المحفوظ:** `{base_price:.2f} ج.م`")
            
        payment_method = st.radio("💵 وسيلة السداد:", options=["كاش", "فيزا"], horizontal=True)
        custom_price = st.number_input("💰 القيمة الأساسية المعتمدة للمعاملة (ج.م):", min_value=0.0, value=base_price, disabled=True)
        customer_discount = st.number_input("📉 إدخال خصم إضافي للعميل إذا رغبت (ج.م):", min_value=0.0, value=0.0, key="pos_discount_input")
        
        final_calculated_total = custom_price - customer_discount
        if final_calculated_total < 0:
            final_calculated_total = 0.0
            
        st.markdown(f"### 💵 الإجمالي الصافي المطلوب تحصيله: <span style='color:green;'>{final_calculated_total:.2f} ج.م</span>", unsafe_allow_html=True)
        
        # العمولة نسبة من صافي قيمة الخدمة بعد الخصم، ولا تُحتسب على المنتجات
        commission_total = (final_calculated_total * st.session_state.commission_rate / 100.0) if not is_product else 0.0
        assigned_workers = []
        if not is_product:
            # دعم عدد غير محدود من الفنيين المختارين مع منع تكرار الاسم.
            assigned_workers = list(dict.fromkeys(
                name for name in (selected_workers if "selected_workers" in locals() else [])
                if name and name != "لا يوجد"
            ))
        elif selected_worker1 and selected_worker1 != "مبيعات مباشرة":
            assigned_workers.append(selected_worker1)
        commission_per_worker = commission_total / len(assigned_workers) if assigned_workers else 0.0
        
        st.caption(f"العمولة الإجمالية: {commission_total:.2f} | عدد الفنيين المشاركين: {len(assigned_workers)} | نصيب كل فني: {commission_per_worker:.2f}")
        
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
                    "workers": assigned_workers,
                    "commission_rate": float(st.session_state.commission_rate) if not is_product else 0.0,
                    "commission_total": commission_total,
                    "commission_share": commission_per_worker,
                    "commission_workers": assigned_workers,
                    "payment": payment_method,
                    "status": "Active",
                    "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                }
                
                invoice_workers = assigned_workers if assigned_workers else [selected_worker1 or "مبيعات مباشرة"]
                for assigned_worker in invoice_workers:
                    if assigned_worker not in st.session_state.session_state_invoices:
                        st.session_state.session_state_invoices[assigned_worker] = []
                    st.session_state.session_state_invoices[assigned_worker].append(invoice_data.copy())
                
                save_system_data()
                st.success(f"🎉 تم إصدار الفاتورة بنجاح برقم [{invoice_id}]!")
                st.balloons()
                st.rerun()

    st.write("---")
    st.subheader("📋 فواتير اليوم الحالية وإدارة المرتجعات (POS Refund)")
    
    if all_invoices:
        for index, inv in enumerate(all_invoices):
            col_pos1, col_pos2, col_pos3, col_pos_actions = st.columns([3, 2, 2, 3.5])
            with col_pos1: 
                status_icon = "🟢" if inv.get("status", "Active") == "Active" else "↩️ مرتجع"
                st.write(f"🧾 {status_icon} **{inv['id']}** | اللوحة: `({inv.get('plate_number', '---')})`")
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
                            st.error("❌ خطأ: يرجى اختيار الفني!")
                        else:
                            for w_key, w_invs in st.session_state.session_state_invoices.items():
                                for item in w_invs:
                                    if item["id"] == inv["id"]:
                                        item["status"] = "Refunded"
                                        item["refund_reason"] = pos_reason.strip()
                                        item["cancelled_by"] = pos_cancel_worker
                            save_system_data()
                            st.rerun()
                else:
                    st.button("تم رد العملية 🔒", disabled=True, key=f"pos_dis_btn_{inv['id']}_{index}")
    else:
        st.info("ℹ️ لا توجد فواتير صادرة لليوم حتى الآن.")

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
        if st.session_state.daily_archive:
            for day, day_data in st.session_state.daily_archive.items():
                with st.expander(f"📅 إغلاق يوم: {day} | صافي الأرباح: {day_data['net']:.2f} ج.م"):
                    st.json(day_data)
        else:
            st.info("ℹ️ أرشيف الأيام المغلقة فارغ حالياً.")
    with tab_monthly_arch:
        if st.session_state.monthly_archive:
            st.json(st.session_state.monthly_archive)
        else:
            st.info("ℹ️ أرشيف الإغلاق المالي الشهري فارغ تماماً.")

elif menu == "العمولات والسلفيات الحية":
    st.markdown("## 💸 إدارة عمولات وسلفيات الفنيين الحية وكشف الرواتب")
    st.write("---")
    
    for index, worker in enumerate(st.session_state.workers):
        if not isinstance(worker, dict) or "name" not in worker: continue
        w_name = worker["name"]
        w_commissions = 0.0
        if w_name in st.session_state.session_state_invoices:
            for inv in st.session_state.session_state_invoices[w_name]:
                if inv.get("status", "Active") == "Active":
                    w_commissions += float(inv.get("commission_share", 0.0))
        w_advance = float(worker.get("advance", 0.0))
        net_payout = w_commissions - w_advance
        
        with st.expander(f"👨‍🔧 الفني: {w_name} | صافي المستحقات: {net_payout:.2f} ج.م"):
            col_b1, col_b2, col_b3 = st.columns(3)
            with col_b1: st.metric("🎯 إجمالي العمولات الموزعة", f"{w_commissions:.2f} ج.م")
            with col_b2: st.metric("💸 السلفيات الحالية", f"{w_advance:.2f} ج.م")
            with col_b3: st.metric("💰 صافي الراتب المستحق", f"{net_payout:.2f} ج.م")
            
            col_act1, col_act2 = st.columns(2)
            with col_act1:
                advance_amount = st.number_input(f"➕ تسجيل سلفة لـ {w_name}:", min_value=0.0, key=f"adv_add_{index}")
                if st.button(f"تأكيد صرف السلفة 💸", key=f"btn_adv_{index}"):
                    st.session_state.workers[index]["advance"] += advance_amount
                    save_system_data()
                    st.rerun()
            with col_act2:
                if st.button(f"تصفية حسابات [{w_name}] 🧾", key=f"btn_clear_{index}"):
                    st.session_state.workers[index]["advance"] = 0.0
                    if w_name in st.session_state.session_state_invoices:
                        st.session_state.session_state_invoices[w_name] = []
                    save_system_data()
                    st.rerun()

elif menu == "📑 دفتر المصروفات":
    st.markdown("## 📑 إدارة دفتر المصروفات اليومية والتشغيلية")
    st.write("---")
    with st.form("expenses_form_production"):
        rent_val = st.number_input("🏢 إيجار المقر والمحل (ج.م):", min_value=0.0, value=float(st.session_state.daily_expenses.get("rent", 0.0)))
        operational_val = st.number_input("🧪 مصروفات تشغيلية:", min_value=0.0, value=float(st.session_state.daily_expenses.get("operational", 0.0)))
        utilities_val = st.number_input("⚡💧 مرافق عامة وطاقة:", min_value=0.0, value=float(st.session_state.daily_expenses.get("utilities", 0.0)))
        if st.form_submit_button("💾 حفظ وتثبيت قيم المصروفات"):
            st.session_state.daily_expenses["rent"] = rent_val
            st.session_state.daily_expenses["operational"] = operational_val
            st.session_state.daily_expenses["utilities"] = utilities_val
            save_system_data()
            st.success("🎉 تم حفظ المصروفات!")
            st.rerun()

elif menu == "إعدادات الباقات والعمال":
    st.markdown("## ⚙️ لوحة الإدارة المطلقة والتحكم بالأسعار والسرية")
    st.write("---")
    tab_workers, tab_services, tab_security = st.tabs(["👨‍🔧 إدارة العمال", "🛍️ الباقات والمنتجات والأسعار", "🔐 إدارة الحسابات والصلاحيات"])
    
    with tab_workers:
        col_w1, col_w2 = st.columns(2)
        with col_w1:
            new_worker_name = st.text_input("➕ اسم الفني الجديد:", key="input_add_new_worker")
            if st.button("تثبيت وحفظ الفني 🚀"):
                if new_worker_name.strip() != "":
                    st.session_state.workers.append({"name": new_worker_name.strip(), "advance": 0.0})
                    save_system_data()
                    st.rerun()
        with col_w2:
            worker_options = ["اختر فني لحذفه"] + [w["name"] for w in st.session_state.workers if isinstance(w, dict)]
            worker_to_delete = st.selectbox("❌ حذف فني نهائياً:", options=worker_options)
            if st.button("تأكيد حذف الفني 🗑️"):
                if worker_to_delete != "اختر فني لحذفه":
                    st.session_state.workers = [w for w in st.session_state.workers if w.get("name") != worker_to_delete]
                    save_system_data()
                    st.rerun()

    with tab_services:
        st.subheader("🎯 إعدادات عمولة الفنيين")
        st.caption("تُحسب العمولة كنسبة من صافي قيمة الخدمة بعد الخصم، ثم تُقسّم بالتساوي على الفنيين المشاركين. لا تُحتسب عمولة على بيع المنتجات.")
        col_rate, col_rate_btn = st.columns([2, 1])
        with col_rate:
            new_commission_rate = st.number_input("نسبة العمولة الإجمالية للخدمات (%):", min_value=0.0, max_value=100.0, value=float(st.session_state.commission_rate), step=0.5, key="global_commission_rate_input")
        with col_rate_btn:
            st.write("")
            st.write("")
            if st.button("💾 حفظ نسبة العمولة", key="save_global_commission_rate"):
                st.session_state.commission_rate = float(new_commission_rate)
                save_system_data()
                st.success("تم حفظ نسبة العمولة الجديدة")
                st.rerun()
        st.write("---")
        st.subheader("🛠️ إضافة باقة أو خدمة جديدة")
        col_s1, col_s2, col_s3 = st.columns(3)
        with col_s1: new_service_name = st.text_input("🏷️ اسم الخدمة:")
        with col_s2: price_malaki = st.number_input("🚗 سعر الملاكي:", min_value=0.0, value=150.0)
        with col_s3: price_suv = st.number_input("🚙 سعر SUV:", min_value=0.0, value=200.0)
        fixed_comm_val = 0.0
        if st.button("تثبيت باقة جديدة 📥"):
            if new_service_name.strip() != "":
                st.session_state.services[new_service_name.strip()] = {"الملكي": float(price_malaki), "SUV": float(price_suv), "fixed_commission": float(fixed_comm_val)}
                save_system_data()
                st.rerun()
                
        st.write("---")
        st.subheader("✏️ تعديل أسعار وعمولة الخدمات الحالية")
        selected_edit_s = st.selectbox("🎯 اختر الخدمة للتعديل:", options=["اختر خدمة"] + list(st.session_state.services.keys()))
        if selected_edit_s != "اختر خدمة":
            s_current_data = st.session_state.services[selected_edit_s]
            col_ed1, col_ed2 = st.columns(2)
            with col_ed1: updated_price_malaki = st.number_input("🚗 سعر الملاكي المحدث:", min_value=0.0, value=float(s_current_data.get("الملكي", 0.0)))
            with col_ed2: updated_price_suv = st.number_input("🚙 سعر SUV المحدث:", min_value=0.0, value=float(s_current_data.get("SUV", 0.0)))
            updated_fixed_comm = float(s_current_data.get("fixed_commission", 0.0))
            if st.button(f"💾 حفظ الأسعار لـ [{selected_edit_s}]"):
                st.session_state.services[selected_edit_s] = {"الملكي": updated_price_malaki, "SUV": updated_price_suv, "fixed_commission": updated_fixed_comm}
                save_system_data()
                st.rerun()

        st.write("---")
        st.subheader("📦 إضافة وتحديث المنتجات")
        col_p1, col_p2 = st.columns(2)
        with col_p1: new_prod_name = st.text_input("🏷️ اسم المنتج الجديد:")
        with col_p2: price_prod = st.number_input("💰 سعر بيع المنتج:", min_value=0.0, value=30.0)
        if st.button("تثبيت المنتج بالكاشير 📥"):
            if new_prod_name.strip() != "":
                st.session_state.products[new_prod_name.strip()] = float(price_prod)
                save_system_data()
                st.rerun()

        st.write("---")
        st.subheader("📋 كشف مسح البنود الحالية")
        col_l1, col_l2 = st.columns(2)
        with col_l1:
            for s_name in list(st.session_state.services.keys()):
                if st.button(f"حذف الخدمة: {s_name} 🗑️"):
                    del st.session_state.services[s_name]
                    save_system_data()
                    st.rerun()
        with col_l2:
            for p_name in list(st.session_state.products.keys()):
                if st.button(f"حذف المنتج: {p_name} 🗑️"):
                    del st.session_state.products[p_name]
                    save_system_data()
                    st.rerun()

    with tab_security:
        st.subheader("🔐 إدارة الحسابات والصلاحيات الحية")
        st.markdown("#### 👑 حساب المالك")
        col_o_u, col_o_p = st.columns(2)
        with col_o_u: new_owner_user = st.text_input("👤 اسم مستخدم المالك:", value=st.session_state.credentials["owner"]["username"])
        with col_o_p: new_owner_pass = st.text_input("🔑 كلمة سر المالك الجديدة:", type="password", placeholder="اتركها فارغة لعدم التغيير")
        if st.button("حفظ حساب المالك 💾"):
            st.session_state.credentials["owner"]["username"] = new_owner_user.strip()
            if new_owner_pass.strip() != "": st.session_state.credentials["owner"]["password"] = new_owner_pass.strip()
            save_system_data()
            st.success("✅ تم التحديث!")
            st.rerun()
            
        st.write("---")
        st.markdown("#### 👥 حسابات موظفي الكاشير والصلاحيات")
        for w_user, w_data in list(st.session_state.credentials["workers_accounts"].items()):
            st.warning(f"👤 الموظف: {w_data['name']} | الحساب: `{w_user}` | السر: `{w_data['password']}`")
            updated_perms = st.multiselect(f"⚙️ صلاحيات صفحات [{w_data['name']}]:", options=all_possible_pages, default=w_data.get("permissions", []), key=f"live_edit_perms_{w_user}")
            st.session_state.credentials["workers_accounts"][w_user]["permissions"] = updated_perms
            if st.button("حذف الحساب ❌", key=f"del_acc_{w_user}"):
                if len(st.session_state.credentials["workers_accounts"]) > 1:
                    del st.session_state.credentials["workers_accounts"][w_user]
                    save_system_data()
                    st.rerun()
                    
        st.write("---")
        st.markdown("##### ➕ إنشاء حساب كاشير/موظف جديد للسيستم:")
        col_add_acc1, col_add_acc2, col_add_acc3 = st.columns(3)
        with col_add_acc1: new_w_display_name = st.text_input("display name:")
        with col_add_acc2: new_w_username = st.text_input("username:")
        with col_add_acc3: new_w_password = st.text_input("password:")
        new_worker_initial_perms = st.multiselect("صلاحيات الحساب الجديد:", options=all_possible_pages, default=["🛒 كاشير الاستقبال POS"])
        
        if st.button("إنشاء وتثبيت حساب الموظف الجديد 💾"):
            if new_w_display_name.strip() != "" and new_w_username.strip() != "" and new_w_password.strip() != "":
                w_user_id = new_w_username.strip().lower()
                st.session_state.credentials["workers_accounts"][w_user_id] = {
                    "name": new_w_display_name.strip(), "password": new_w_password.strip(), "role": "worker", "permissions": new_worker_initial_perms
                }
                save_system_data()
                st.success("🎉 تم الحفظ الدائم للحساب الجديد!")
                st.rerun()
