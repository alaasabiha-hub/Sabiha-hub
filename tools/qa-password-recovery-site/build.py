#!/usr/bin/env python3
"""Assemble the standalone QA password-recovery page without committing config."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys


QA_URL = "https://aspijgoujajgyfgvdcav.supabase.co"
SOURCE = Path(__file__).resolve().parent
PUBLIC_FILES = ("index.html", "styles.css", "recovery.js", "_headers")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: build.py OUTPUT_DIRECTORY", file=sys.stderr)
        return 2
    output = Path(sys.argv[1]).expanduser().resolve()
    url = os.environ.get("SABIHA_QA_SUPABASE_URL", "").strip().rstrip("/")
    key = os.environ.get("SABIHA_QA_SUPABASE_PUBLISHABLE_KEY", "").strip()
    if url != QA_URL:
        print("Refusing build: SABIHA_QA_SUPABASE_URL must be the dedicated QA URL.", file=sys.stderr)
        return 2
    if not key.startswith("sb_publishable_"):
        print("Refusing build: provide the QA publishable key (never a service key).", file=sys.stderr)
        return 2
    if output == SOURCE or SOURCE in output.parents:
        print("Refusing build: output must be outside the source directory.", file=sys.stderr)
        return 2

    output.mkdir(parents=True, exist_ok=True)
    for filename in PUBLIC_FILES:
        shutil.copy2(SOURCE / filename, output / filename)
    config = {
        "supabaseUrl": QA_URL,
        "publishableKey": key,
    }
    (output / "config.js").write_text(
        "window.SABIHA_RECOVERY_CONFIG = "
        + json.dumps(config, ensure_ascii=True, separators=(",", ":"))
        + ";\n",
        encoding="utf-8",
    )
    print("QA recovery page assembled. Publishable configuration value was not printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
