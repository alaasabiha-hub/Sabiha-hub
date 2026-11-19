/** Pure, bounded evidence templates. No I/O, provider, environment or execution. */
export type Fact = {
  id: string;
  value: number | null;
  unit: string;
  source: string;
  count: number;
  basis: string;
};
const catalog: Record<
  string,
  { source: string; unit: string; basis: string; ar: string; en: string }
> = {
  billed_revenue: {
    source: "business_invoices",
    unit: "EGP",
    basis: "window",
    ar: "صافي قيمة الفواتير النشطة",
    en: "Net active invoice value",
  },
  cash_net: {
    source: "business_payment_events",
    unit: "EGP",
    basis: "window",
    ar: "صافي التحصيل النقدي المسجل",
    en: "Recorded net cash collections",
  },
  card_terminal_net: {
    source: "business_payment_events",
    unit: "EGP",
    basis: "window",
    ar: "صافي التحصيل المسجل على ماكينة البطاقة",
    en: "Recorded net card-terminal collections",
  },
  recorded_expenses: {
    source: "business_expenses",
    unit: "EGP",
    basis: "window",
    ar: "المصروفات المسجلة",
    en: "Recorded expenses",
  },
  bookings: {
    source: "bookings",
    unit: "count",
    basis: "window",
    ar: "الحجوزات المسجلة",
    en: "Recorded bookings",
  },
  completed_bookings: {
    source: "bookings",
    unit: "count",
    basis: "window",
    ar: "الحجوزات المكتملة المسجلة",
    en: "Recorded completed bookings",
  },
  distinct_booking_customers: {
    source: "bookings",
    unit: "count",
    basis: "window",
    ar: "العملاء المختلفون في الحجوزات",
    en: "Distinct customers in bookings",
  },
  active_products: {
    source: "business_catalog_items",
    unit: "count",
    basis: "current_snapshot",
    ar: "المنتجات النشطة حاليًا",
    en: "Currently active products",
  },
  out_of_stock_products: {
    source: "business_catalog_items",
    unit: "count",
    basis: "current_snapshot",
    ar: "منتجات نشطة برصيد مسجل صفر حاليًا",
    en: "Active products with recorded zero stock now",
  },
  average_review_stars: {
    source: "employee_service_reviews",
    unit: "stars",
    basis: "window",
    ar: "متوسط نجوم المراجعات المسجلة",
    en: "Recorded average review stars",
  },
  loyalty_movements: {
    source: "business_loyalty_transactions",
    unit: "count",
    basis: "window",
    ar: "حركات الولاء المرتبطة بطلبات الفرع",
    en: "Order-linked loyalty movements",
  },
  coupon_redemptions: {
    source: "business_coupon_redemptions",
    unit: "count",
    basis: "window",
    ar: "مرات استخدام الكوبونات المسجلة",
    en: "Recorded coupon redemptions",
  },
  active_offers: {
    source: "business_offers",
    unit: "count",
    basis: "current_snapshot",
    ar: "العروض النشطة حاليًا",
    en: "Currently active offers",
  },
  complaints_received: {
    source: "customer_complaints",
    unit: "count",
    basis: "window",
    ar: "الشكاوى المسجلة خلال الفترة",
    en: "Complaints recorded in the period",
  },
  documents_expiring_30d: {
    source: "business_documents",
    unit: "count",
    basis: "current_snapshot",
    ar: "المستندات التي تنتهي خلال 30 يومًا",
    en: "Documents expiring within 30 days",
  },
  pending_recruitment: {
    source: "private.recruitment_applications",
    unit: "count",
    basis: "window",
    ar: "طلبات التوظيف قيد المراجعة",
    en: "Recruitment applications awaiting review",
  },
  quality_pass_rate: {
    source: "private.service_quality_checks",
    unit: "percent",
    basis: "window",
    ar: "نسبة فحوص الجودة المسجلة التي اجتازت الفحص",
    en: "Recorded service-quality check pass rate",
  },
  received_purchase_costs: {
    source: "public.business_purchase_orders",
    unit: "EGP",
    basis: "window",
    ar: "تكلفة أوامر الشراء المستلمة والمسجلة",
    en: "Recorded cost of received purchase orders",
  },
};
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error("Invalid evidence");
  }
  return value as Record<string, unknown>;
}
export function factsFrom(value: unknown): Fact[] {
  const rows = object(value).metrics;
  if (!Array.isArray(rows) || rows.length > 20) throw Error("Invalid evidence");
  const facts: Fact[] = [];
  for (const raw of rows) {
    const row = object(raw);
    if (typeof row.code !== "string") throw Error("Invalid evidence");
    if (!Object.hasOwn(catalog, row.code)) continue;
    const c = catalog[row.code];
    if (
      facts.some((f) => f.id === row.code) || row.source !== c.source ||
      row.unit !== c.unit || row.basis !== c.basis ||
      !Number.isSafeInteger(row.count) || Number(row.count) < 0 ||
      !(row.value === null ||
        typeof row.value === "number" && Number.isFinite(row.value))
    ) throw Error("Invalid evidence");
    if (
      row.value !== null &&
      (c.unit === "count" &&
          (!Number.isSafeInteger(row.value) || Number(row.value) < 0) ||
        c.unit === "stars" &&
          (Number(row.value) < 1 || Number(row.value) > 5) ||
        c.unit === "percent" &&
          (Number(row.value) < 0 || Number(row.value) > 100))
    ) throw Error("Invalid evidence");
    facts.push({
      id: row.code,
      value: row.value as number | null,
      unit: c.unit,
      source: c.source,
      count: Number(row.count),
      basis: c.basis,
    });
  }
  return facts;
}
const topics = {
  summary: {
    ar: "ملخص النشاط",
    en: "Business summary",
    ids: Object.keys(catalog),
  },
  billing: {
    ar: "إجمالي الفواتير",
    en: "Invoice totals",
    ids: ["billed_revenue"],
  },
  collections: {
    ar: "التحصيل النقدي",
    en: "Cash collections",
    ids: ["cash_net"],
  },
  expenses: {
    ar: "المصروفات المسجلة",
    en: "Recorded expenses",
    ids: ["recorded_expenses"],
  },
  stock: {
    ar: "المخزون الحالي",
    en: "Current stock",
    ids: ["active_products", "out_of_stock_products"],
  },
  bookings: {
    ar: "ملخص الحجوزات",
    en: "Booking summary",
    ids: ["bookings", "completed_bookings", "distinct_booking_customers"],
  },
  reviews: {
    ar: "ملخص المراجعات",
    en: "Review summary",
    ids: ["average_review_stars"],
  },
  card_collections: {
    ar: "تحصيل ماكينة البطاقة",
    en: "Card-terminal collections",
    ids: ["card_terminal_net"],
  },
  loyalty_marketing: {
    ar: "حركة الولاء والكوبونات",
    en: "Loyalty and coupon activity",
    ids: ["loyalty_movements", "coupon_redemptions", "active_offers"],
  },
  complaints: {
    ar: "الشكاوى المسجلة",
    en: "Recorded complaints",
    ids: ["complaints_received"],
  },
  documents: {
    ar: "المستندات قريبة الانتهاء",
    en: "Upcoming document expiries",
    ids: ["documents_expiring_30d"],
  },
  recruitment: {
    ar: "طلبات التوظيف المعلقة",
    en: "Pending recruitment applications",
    ids: ["pending_recruitment"],
  },
  service_quality: {
    ar: "فحوص جودة الخدمة",
    en: "Service quality checks",
    ids: ["quality_pass_rate"],
  },
  inventory_purchases: {
    ar: "المشتريات المستلمة",
    en: "Received purchases",
    ids: ["received_purchase_costs"],
  },
  profit: {
    ar: "هل الربح الفعلي متاح؟",
    en: "Is actual profit available?",
    ids: [],
  },
  forecast: {
    ar: "هل توقع الإيرادات متاح؟",
    en: "Is a revenue forecast available?",
    ids: [],
  },
} as const;
type Topic = keyof typeof topics;
const questionAliases: Partial<Record<Topic, readonly string[]>> = {
  collections: ["how much cash did we collect", "كم حصلنا نقدًا"],
  card_collections: [
    "how much did the card terminal collect",
    "كم جمعنا على ماكينة البطاقة",
  ],
  loyalty_marketing: [
    "how many loyalty movements and coupon redemptions",
    "ما حركة الولاء واستخدام الكوبونات",
  ],
  complaints: ["how many complaints were received", "كم شكوى وردت خلال الفترة"],
  documents: ["which documents expire soon", "ما المستندات التي تنتهي قريبًا"],
  recruitment: [
    "how many applications are awaiting review",
    "كم طلب توظيف ينتظر المراجعة",
  ],
  service_quality: [
    "what share of recorded quality checks passed",
    "ما نسبة فحوص الجودة التي اجتازت الفحص",
  ],
  inventory_purchases: [
    "how much did we spend on received purchases",
    "كم تكلفة المشتريات التي استلمناها",
  ],
};
const normalize = (s: string) =>
  s.trim().toLocaleLowerCase("en").replace(/[؟?!.،,]+$/u, "").replace(
    /\s+/gu,
    " ",
  );
export const supportedQuestions = Object.entries(topics).map(([topic, t]) => ({
  topic,
  ar: t.ar,
  en: t.en,
}));
export const limitations = [
  "active_default_branch_only",
  "incomplete_costs_no_actual_profit",
  "gateway_fees_unavailable",
  "stock_is_current_not_historical",
  "workload_is_booking_count_not_employee_productivity",
  "reviews_may_be_small_or_unrepresentative",
  "no_marketing_attribution",
  "no_forecast_or_causal_inference",
  "documents_are_company_wide",
  "loyalty_metrics_cover_order_linked_movements",
  "quality_checks_are_not_employee_scores",
  "purchases_are_received_records_not_recommendations",
];
export function answerEvidence(
  raw: unknown,
  question: string,
  language: "ar" | "en",
) {
  if (question.length > 500) return null;
  const key = normalize(question);
  const topic = (Object.keys(topics) as Topic[]).find((k) =>
    [k, topics[k].ar, topics[k].en, ...(questionAliases[k] ?? [])].some((s) =>
      normalize(s) === key
    )
  );
  if (!topic) return null;
  const facts = factsFrom(raw);
  if (facts.length === 0) return null; // No claimed capability without actual authorized evidence.
  const required = topics[topic].ids as readonly string[];
  if (required.some((id) => !facts.some((f) => f.id === id))) return null;
  const used = facts.filter((f) => required.includes(f.id));
  const ar = language === "ar";
  const unavailable = ar
    ? "غير متاح من الأدلة الحالية"
    : "Unavailable from current evidence";
  const lines = used.map((f) => {
    const c = catalog[f.id];
    const unit = f.unit === "EGP"
      ? (ar ? "جنيه مصري" : "EGP")
      : f.unit === "stars"
      ? (ar ? "نجوم" : "stars")
      : f.unit === "percent"
      ? "%"
      : "";
    const value = f.value === null
      ? unavailable
      : new Intl.NumberFormat(ar ? "ar-EG" : "en-GB", {
        maximumFractionDigits: 20,
      }).format(f.value) + (unit ? " " + unit : "");
    const basis = f.basis === "current_snapshot"
      ? (ar
        ? "لقطة حالية وليست بيانات تاريخية"
        : "current snapshot, not historical")
      : (ar ? "الفترة المختارة" : "selected period");
    return `${ar ? c.ar : c.en}: ${value} (${basis}).`;
  });
  if (topic === "profit") {
    lines.push(
      ar
        ? "الربح الفعلي غير متاح لأن التكاليف غير مكتملة. الفواتير والتحصيل النقدي والمصروفات المسجلة لا تكفي لحساب الربح."
        : "Actual profit is unavailable because costs are incomplete. Invoice totals, cash collections and recorded expenses are insufficient to calculate profit.",
    );
  } else if (topic === "forecast") {
    lines.push(
      ar
        ? "لا يتوفر توقع موثوق للإيرادات. البيانات الحالية وصفية ولا تثبت اتجاهًا أو سببية أو عائدًا مستقبليًا."
        : "A reliable revenue forecast is unavailable. Current evidence is descriptive and does not establish a trend, causality or future returns.",
    );
  } else if (topic === "stock") {
    lines.push(
      ar
        ? "تحقق من الجرد الفعلي قبل أي قرار شراء. هذه ليست توقعات للطلب."
        : "Verify physical stock before purchasing. This is not a demand forecast.",
    );
  } else if (topic === "bookings") {
    lines.push(
      ar
        ? "عدد الحجوزات لا يقيس إنتاجية الموظفين، ولا يشمل جميع زيارات الاستقبال المباشر."
        : "Booking counts do not measure employee productivity or include every walk-in visit.",
    );
  } else if (topic === "reviews") {
    lines.push(
      ar
        ? "قد تكون المراجعات قليلة أو غير ممثلة لجميع العملاء؛ لا تستنتج منها أداء كل موظف."
        : "Reviews may be few or unrepresentative; do not infer each employee's performance.",
    );
  } else if (topic === "loyalty_marketing") {
    lines.push(
      ar
        ? "هذه أعداد حركات واستخدامات مسجلة فقط؛ لا تثبت ولاء العملاء أو أثر الحملة على الإيراد."
        : "These are recorded movement and usage counts only; they do not prove customer retention or campaign revenue impact.",
    );
  } else if (topic === "documents") {
    lines.push(
      ar
        ? "هذا عدّ على مستوى الشركة حتى وقت القراءة، وليس تنبيهًا قانونيًا أو إثباتًا لصلاحية المستند."
        : "This is a company-wide count at read time, not a legal alert or proof of document validity.",
    );
  } else if (topic === "recruitment") {
    lines.push(
      ar
        ? "العدد لا يتضمن بيانات المتقدمين ولا يقيّم أهليتهم."
        : "The count excludes applicant details and does not assess candidate suitability.",
    );
  } else if (topic === "service_quality") {
    lines.push(
      ar
        ? "النسبة تصف فحوص الجودة المسجلة فقط؛ ولا تقيم أداء كل موظف."
        : "The rate describes recorded quality checks only; it does not score individual employee performance.",
    );
  } else if (topic === "inventory_purchases") {
    lines.push(
      ar
        ? "هذه تكلفة أوامر تم استلامها فقط؛ لا تتضمن توقع احتياج أو توصية شراء."
        : "This covers received orders only; it is not a demand forecast or purchasing recommendation.",
    );
  } else {lines.push(
      ar
        ? "الفوترة والتحصيل قياسان مختلفان؛ هذه الأرقام ليست الربح الفعلي."
        : "Billing and collections are different measures; these figures are not actual profit.",
    );}
  return {
    state: topic === "profit" || topic === "forecast" ||
        used.some((f) => f.value === null)
      ? "missing_data"
      : "answer",
    topic,
    answer: lines.join("\n"),
    facts: used,
    citations: used.map((f) => ({
      evidence_id: f.id,
      source: f.source,
      basis: f.basis,
      count: f.count,
    })),
    mode: "free_evidence_templates",
    paid_provider_allowed: false,
    limitations,
    requires_owner_review: true,
    execution_supported: false,
  };
}
