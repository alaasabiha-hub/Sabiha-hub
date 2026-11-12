"""Optional owner-only AI business advisor for Sabiha Hub.

The OpenAI API key is read only from server-side Streamlit Secrets or environment
variables. No customer names, phone numbers, email addresses, or license plates
should be sent to the model.
"""
from __future__ import annotations

import json
import os
from typing import Any


def get_openai_config() -> tuple[str, str]:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    model = os.environ.get("OPENAI_MODEL", "").strip()
    try:
        import streamlit as st
        config = st.secrets.get("openai", {})
        api_key = api_key or str(config.get("api_key", "")).strip()
        model = model or str(config.get("model", "")).strip()
    except Exception:
        pass
    return api_key, model or "gpt-6-luna"


def analyze_business(
    api_key: str,
    model: str,
    snapshot: dict[str, Any],
    question: str,
) -> str:
    """Ask the Responses API for practical advice based on aggregate metrics only."""
    from openai import OpenAI

    client = OpenAI(api_key=api_key, timeout=45.0, max_retries=1)
    system_instructions = (
        "أنت مستشار تشغيل وتحليل أعمال لمركز Sabiha Hub لخدمات السيارات. "
        "حلّل الأرقام المقدمة فقط، ولا تخترع بيانات أو تفترض أسباباً غير مثبتة. "
        "قدّم الرد بالعربية المصرية الواضحة، بعناوين قصيرة ونقاط عملية. "
        "ميّز بين الأرقام الفعلية والتقديرات، ولا تعتبر الضريبة أو صافي الربح "
        "استشارة محاسبية أو ضريبية نهائية. إذا كانت البيانات غير كافية فقل ذلك. "
        "لا تطلب ولا تستنتج بيانات شخصية للعملاء. لا تنفذ أي عمليات أو تغييرات "
        "في النظام؛ قدّم توصيات فقط."
    )
    user_input = (
        "هذه مؤشرات تشغيلية مجمعة بعد إزالة أي بيانات تعريفية. "
        "حللها وأجب عن سؤال المالك:\n"
        f"السؤال: {question.strip() or 'حلل الأداء الحالي واقترح أهم 3 تحسينات.'}\n\n"
        "المؤشرات:\n"
        + json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"))
    )
    response = client.responses.create(
        model=model,
        input=[
            {"role": "system", "content": system_instructions},
            {"role": "user", "content": user_input},
        ],
        max_output_tokens=900,
    )
    answer = (response.output_text or "").strip()
    if not answer:
        raise RuntimeError("لم يرجع المساعد الذكي إجابة نصية.")
    return answer
