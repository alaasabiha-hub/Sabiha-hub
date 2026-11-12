"""Compatibility entry point for Streamlit Cloud.

The full, maintained Streamlit application lives in sabiha_hub_app.py.
Keeping app.py as a thin launcher ensures deployments configured with the
default Streamlit file path run the secure Supabase-backed application.
"""
import sabiha_hub_app  # noqa: F401
