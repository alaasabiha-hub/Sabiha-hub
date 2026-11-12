"""Compatibility entry point for Streamlit Cloud.

The full, maintained Streamlit application lives in sabiha_hub_app.py.
Use runpy so Streamlit reruns execute the app module on every interaction.
"""
import runpy

runpy.run_path("sabiha_hub_app.py", run_name="__main__")
