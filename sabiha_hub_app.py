import streamlit as st
import pandas as pd
from datetime import datetime
import json, os, urllib.parse

st.set_page_config(page_title="Sabiha Hub", page_icon="🚗", layout="wide")
DB_FILE = "sabiha_settings.json"
INV_FILE = "sabiha_invoices.json"

def load_db():
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if "users" not in data:
                    data["users"] = {"owner_email": "alaasabiha633@gmail.com", "owner_pass": "Sabiha2026", "cashier_email": "cashier@sabiha.com", "cashier_pass": "123456"}
                return data
        except: pass
    return {
        "users": {"owner_email": "alaasabiha633@gmail.com", "owner_pass": "Sabiha2026", "cashier_email": "cashier@sabiha.com", "cashier_pass": "123456"},
        "workers": {"أحمد مصطفى": {"سلفيات": 0, "عمولات": 0}, "كريم رأفت": {"سلفيات": 0, "عمولات": 0}, "هاني محمود": {"سلفيات": 0, "عمولات": 0}},
        "services": {"غسيل سريع": {"سعر_ملاكي": 100, "سعر_suv": 130, "عمولة": 20}, "غسيل فاخر وبستم": {"سعر_ملاكي": 200, "سعر_suv": 250, "عمولة": 25}},
        "expenses": {"إيجار": 0.0, "مشتريات": 0.0, "مصروفات_أخرى": 0.0},
        "monthly_history": []
    }

def load_invoices():
    if os.path.exists(INV_FILE):
        try:
            with open(INV_FILE, "r", encoding="utf-8") as f: return json.load(f)
        except: pass
    return []

def save_db(data):
    with open(DB_FILE, "w", encoding="utf-8") as f: json.dump(data, f, ensure_ascii=False, indent=4)

def save_invoices(data):
    with open(INV_FILE, "w", encoding="utf-8") as f: json.dump(data, f, ensure_ascii=False, indent=4)

if 'db' not in st.session_state: st.session_state.db = load_db()

st.markdown("""<style>.stApp { background-color: #0A192F; color: #ffffff; } input, select, textarea, div[data-baseweb="select"], .stNumberInput input, .stTextInput input { background-color: #FFFFFF !important; color: #000000 !important; border: 2px solid #FF0033 !important; font-weight: bold !important; border-radius: 6px !important; } .metric-card { background-color: #1E293B; padding: 20px; border-radius: 12px; text-align: center; border: 2px solid #FF0033; } div.stTabs { direction: rtl; } .stNumberInput, .stTextInput, .stSelectbox { text-align: right; direction: rtl; }</style>""", unsafe_allow_html=True)

if 'logged_in' not in st.session_state:
    st.session_state.logged_in = os.path.exists("sabiha_session_active.txt")
    if st.session_state.logged_in:
        try:
            with open("sabiha_session_active.txt", "r", encoding="utf-8") as sf: st.session_state.role = sf.read().strip()
        except: st.session_state.role = "owner"
    else: st.session_state.role = ""

if not st.session_state.logged_in:
    st.title("🔒 تسجيل الدخول لمركز صبيحة")
    u_email = st.text_input("البريد الإلكتروني الإداري:")
    u_pass = st.text_input("كلمة المرور السرية:", type="password")
    if st.button("🔑 تسجيل الدخول"):
        if u_email == st.session_state.db["users"]["owner_email"] and u_pass == st.session_state.db["users"]["owner_pass"]:
            st.session_state.logged_in, st.session_state.role = True, "owner"
            with open("sabiha_session_active.txt", "w", encoding="utf-8") as sf: sf.write("owner")
            st.rerun()
        elif u_email == st.session_state.db["users"]["cashier_email"] and u_pass == st.session_state.db["users"]["cashier_pass"]:
            st.session_state.logged_in, st.session_state.role = True, "cashier"
            with open("sabiha_session_active.txt", "w", encoding="utf-8") as sf: sf.write("cashier")
            st.rerun()
        else: st.error("❌ البيانات خاطئة!")
    st.stop()

if st.sidebar.button("🚨 تسجيل الخروج من النظام"):
    if os.path.exists("sabiha_session_active.txt"): os.remove("sabiha_session_active.txt")
    st.session_state.logged_in, st.session_state.role = False, ""
    st.rerun()

if st.session_state.role == "owner":
    menu = st.sidebar.radio("👑 لوحة المالك:", ["📊 لوحة الداشبورد الرئيسية", "📅 تقرير الحسابات الشهرية", "📥 كاشير الاستقبال والـ POS", "👥 العمولات والسلفيات الحية", "💸 دفتر المصروفات", "⚙️ إعدادات الباقات والعمال"])
else:
    menu = st.sidebar.radio("📥 لوحة الموظف:", ["📥 كاشير الاستقبال والـ POS"])

active_invoices = load_invoices() if load_invoices() is not None else []

if menu == "📊 لوحة الداشبورد الرئيسية":
    st.title("📊 الأداء المالي والتشغيلي لليوم")
    now = datetime.now()
    st.write(f"📅 التاريخ: {now.strftime('%Y-%m-%d')} | ⏱️ الساعة: {now.strftime('%H:%M')}")
    df_inv = pd.DataFrame(active_invoices)
    total_sales = int(df_inv["الحساب"].sum()) if not df_inv.empty else 0
    cash_sales = int(df_inv[df_inv["طريقة_الدفع"] == "كاش"]["الحساب"].sum()) if not df_inv.empty else 0
    visa_sales = int(df_inv[df_inv["طريقة_الدفع"] == "فيزا"]["الحساب"].sum()) if not df_inv.empty else 0
    tax_amount = int(total_sales * 0.14)
    total_commissions = int(df_inv["العمولة_الكلية"].sum()) if not df_inv.empty else 0
    total_expenses = int(st.session_state.db["expenses"]["إيجار"] + st.session_state.db["expenses"]["مشتريات"] + st.session_state.db["expenses"]["مصروفات_أخرى"])
    net_profit = total_sales - tax_amount - total_commissions - total_expenses
    
    col1, col2, col3, col4, col5 = st.columns(5)
    with col1: st.markdown(f"<div class='metric-card'><h5>💵 مبيعات كاش</h5><h2 style='color:#00ff66;'>{cash_sales:,}</h2></div>", unsafe_allow_html=True)
    with col2: st.markdown(f"<div class='metric-card'><h5>💳 مبيعات فيزا</h5><h2 style='color:#3b82f6;'>{visa_sales:,}</h2></div>", unsafe_allow_html=True)
    with col3: st.markdown(f"<div class='metric-card'><h5>🧾 ضريبة 14%</h5><h2 style='color:#ff0033;'>{tax_amount:,}</h2></div>", unsafe_allow_html=True)
    with col4: st.markdown(f"<div class='metric-card'><h5>👥 عمولات العمال</h5><h2 style='color:#ffaa00;'>{total_commissions:,}</h2></div>", unsafe_allow_html=True)
    with col5: st.markdown(f"<div class='metric-card'><h5>📈 صافي الأرباح</h5><h2>{net_profit:,}</h2></div>", unsafe_allow_html=True)
    
    st.markdown("---")
    days_ar = {"Monday": "الإثنين", "Tuesday": "الثلاثاء", "Wednesday": "الأربعاء", "Thursday": "الخميس", "Friday": "الجمعة", "Saturday": "السبت", "Sunday": "الأحد"}
    day_ar = days_ar.get(now.strftime("%A"), now.strftime("%A"))
    report_text = f"📊 تقرير شفت لمركز Sabiha Hub\n📅 التاريخ: {now.strftime('%Y-%m-%d')} ({day_ar})\n\n💵 كاش: {cash_sales:,} ج.م\n💳 فيزا: {visa_sales:,} ج.م\n🧾 الضريبة 14%: {tax_amount:,} ج.م\n👥 العمولات: {total_commissions:,} ج.م\n📈 صافي الأرباح: {net_profit:,} ج.م"
    encoded_report = urllib.parse.quote(report_text)
    whatsapp_url = f"https://whatsapp.com{encoded_report}"
    
    if st.button("🚨 إنهاء اليوم الحالي وترحيل البيانات"):
        if total_sales > 0: st.session_state.db["monthly_history"].append({"التاريخ": now.strftime("%Y-%m-%d"), "اليوم": day_ar, "كاش": cash_sales, "فيزا": visa_sales, "إيراد كلي": total_sales, "ضريبة": tax_amount, "عمولات": total_commissions, "مصاريف": total_expenses, "صافي": net_profit})
        save_invoices([])
        for w in st.session_state.db["workers"]: st.session_state.db["workers"][w]["عمولات"] = 0; st.session_state.db["workers"][w]["سلفيات"] = 0
        save_db(st.session_state.db)
        st.success("🔒 تم ترحيل الحسابات وتصفير العدادات بنجاح!")
        st.markdown(f'📲 [اضغط هنا لفتح المحادثة وإرسال التقرير للمالك على الواتساب]({whatsapp_url})')

elif menu == "📅 تقرير الحسابات الشهرية":
    st.title("📅 لوحة الأرباح والمبيعات التراكمية الشهرية")
    df_m = pd.DataFrame(st.session_state.db["monthly_history"])
    if not df_m.empty:
        col1, col2, col3 = st.columns(3)
        with col1: st.metric("📊 مبيعات الشهر الكلية", f"{int(df_m['إيراد كلي'].sum()):,} ج.م")
        with col2: st.metric("🧾 ضرائب الشهر الكلية", f"{int(df_m['ضريبة'].sum()):,} ج.م")
        with col3: st.metric("💎 صافي أرباح الشهر الصافية", f"{int(df_m['صافي'].sum()):,} ج.م")
        st.dataframe(df_m, use_container_width=True)
    else: st.info("لا توجد بيانات مرحّلة حتى الآن.")

elif menu == "📥 كاشير الاستقبال والـ POS":
    st.title("📥 كاشير الاستقبال وتسجيل الفواتير")
    with st.form("بون"):
        plate = st.text_input("رقم لوحة السيارة:")
        size = st.selectbox("فئة حجم السيارة للتسعير الآلي:", ["ملاكي / سيدان", "SUV / جيب / نقل"])
        service = st.selectbox("اختر الخدمة المعتمدة:", list(st.session_state.db["services"].keys()))
        w_wash = st.selectbox("فني حارة الغسيل:", list(st.session_state.db["workers"].keys()))
        w_det = st.selectbox("أخصائي الديتيلينج:", list(st.session_state.db["workers"].keys()))
        pay_method = st.radio("وسيلة السداد:", ["كاش", "فيزا"], horizontal=True)
        if st.form_submit_button("🟢 إغلاق الفاتورة") and plate:
            price = int(st.session_state.db["services"][service].get("سعر_ملاكي", 100)) if size == "ملاكي / سيدان" else int(st.session_state.db["services"][service].get("سعر_suv", 130))
            full_comm = int(st.session_state.db["services"][service]["عمولة"])
            st.session_state.db["workers"][w_wash]["عمولات"] += int(full_comm/2)
            st.session_state.db["workers"][w_det]["عمولات"] += int(full_comm/2)
            active_invoices.append({"الوقت": datetime.now().strftime("%H:%M"), "اللوحة": plate, "الخدمة": service, "الحساب": price, "طاقم العمل": f"{w_wash} + {w_det}", "العمولة_الكلية": full_comm, "طريقة_الدفع": pay_method})
            save_invoices(active_invoices); save_db(st.session_state.db)
            st.success("✅ تم فتح البون وحفظه مركزيًا بنجاح!")
            st.rerun()
    if active_invoices: st.dataframe(pd.DataFrame(active_invoices), use_container_width=True)

elif menu == "👥 العمولات والسلفيات الحية":
    st.title("👥 كشف حساب العمولات والسلفيات للعمال")
    with st.form("سلفة"):
        w_target = st.selectbox("اسم الفني لربط سلفة:", list(st.session_state.db["workers"].keys()))
        s_amount = st.number_input("مبلغ السلفة الخصم (ج.م):", min_value=0, step=10)
        if st.form_submit_button("❌ تأكيد الخصم"):
            st.session_state.db["workers"][w_target]["سلفيات"] += int(s_amount)
            save_db(st.session_state.db); st.error("تم خصم السلفة بنجاح."); st.rerun()
    t_data = [{"اسم الفني": n, "العمولات المكتسبة": f"{int(i['عمولات'])} ج.م", "السلفيات المسحوبة": f"{int(i['سلفيات'])} ج.م", "صافي المستحق للصرف": f"{int(i['عمولات']-i['سلفيات'])} ج.م"} for n, i in st.session_state.db["workers"].items()]
    st.table(pd.DataFrame(t_data))

elif menu == "💸 دفتر المصروفات":
    st.title("💸 إدارة المصروفات اليومية")
    with st.form("المصاريف"):
        rent = st.number_input("تكلفة الإيجار اليومي:", value=float(st.session_state.db["expenses"]["إيجار"]))
        purchases = st.number_input("تكلفة المشتريات الكيميائيات:", value=float(st.session_state.db["expenses"]["مشتريات"]))
        others = st.number_input("مصروفات أخرى:", value=float(st.session_state.db["expenses"]["مصروفات_أخرى"]))
        if st.form_submit_button("💾 حفظ"):
            st.session_state.db["expenses"] = {"إيجار": float(rent), "مشتريات": float(purchases), "مصروفات_أخرى": float(others)}
            save_db(st.session_state.db); st.success("✅ تم تحديث المصروفات!"); st.rerun()

else:
    st.title("⚙️ لوحة الإدارة وتحديث الباقات والسرية")
    with st.expander("🔒 تحرير وإدارة بيانات تسجيل الدخول السرية للمنظومة"):
        col_u1, col_u2 = st.columns(2)
        with col_u1:
            st.markdown("##### 👑 حساب المالك")
            st.session_state.db["users"]["owner_email"] = st.text_input("إيميل المالك:", value=st.session_state.db["users"]["owner_email"])
            st.session_state.db["users"]["owner_pass"] = st.text_input("باسورد المالك:", value=st.session_state.db["users"]["owner_pass"], type="password")
        with col_u2:
            st.markdown("##### 📥 حساب الكاشير / العمال")
            st.session_state.db["users"]["cashier_email"] = st.text_input("إيميل الكاشير:", value=st.session_state.db["users"]["cashier_email"])
            st.session_state.db["users"]["cashier_pass"] = st.text_input("باسورد الكاشير:", value=st.session_state.db["users"]["cashier_pass"], type="password")
        if st.button("💾 حفظ الحسابات السرية"):
            save_db(st.session_state.db); st.success("✅ تم تحديث التشفير!"); st.rerun()

    st.markdown("---")
    col1, col2 = st.columns(2)
    with col1:
        new_w = st.text_input("اسم الفني الجديد:")
        if st.button("➕ تثبيت فني جديد") and new_w: st.session_state.db["workers"][new_w] = {"سلفيات": 0, "عمولات": 0}; save_db(st.session_state.db); st.success("✅ تم الحفظ!"); st.rerun()
    with col2:
        rem_w = st.selectbox("حذف عامل نهائياً:", [""] + list(st.session_state.db["workers"].keys()))
        if st.button("❌ حذف الفني") and rem_w: del st.session_state.db["workers"][rem_w]; save_db(st.session_state.db); st.rerun()

    st.markdown("---")
    with st.form("إضافة باقة"):
        add_name = st.text_input("اسم الخدمة الجديدة:")
        add_m, add_s, add_c = st.number_input("سعر فئة الملاكي:", min_value=0, value=100), st.number_input("سعر فئة SUV:", min_value=0, value=150), st.number_input("إجمالي العمولة ليتم تقسيمها:", min_value=0, value=20)
        if st.form_submit_button("🚀 نشر الباقة"):
            if add_name and add_name not in st.session_state.db["services"]: st.session_state.db["services"][add_name] = {"سعر_ملاكي": int(add_m), "سعر_suv": int(add_s), "عمولة": int(add_c)}; save_db(st.session_state.db); st.success("🎉 تم تنشيط الباقة بنجاح!"); st.rerun()

    st.markdown("---")
    st.markdown("##### ⚙️ تعديل وتحديث أسعار باقات الخدمات الحالية وعمولاتها حياً")
    for s_name, s_info in list(st.session_state.db["services"].items()):
        with st.expander(f"⚙️ تعديل وتحديث أسعار: {s_name}"):
            st.session_state.db["services"][s_name]["سعر_ملاكي"] = int(st.number_input("سعر الملاكي:", value=int(s_info.get("سعر_ملاكي", 100)), key=f"pm_{s_name}"))
            st.session_state.db["services"][s_name]["سعر_suv"] = int(st.number_input("سعر SUV / جيب:", value=int(s_info.get("سعر_suv", 130)), key=f"ps_{s_name}"))
            st.session_state.db["services"][s_name]["عمولة"] = int(st.number_input("إجمالي عمولة الباقة ج.م:", value=int(s_info["عمولة"]), key=f"c_{s_name}"))
    if st.button("💾 حفظ كافة التعديلات الحالية"): save_db(st.session_state.db); st.success("✅ تم حفظ الباقات والأسعار الجديدة!"); st.rerun()
