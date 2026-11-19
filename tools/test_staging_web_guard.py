import base64
import json
import unittest

from staging_web_guard import StagingConfigError, make_defines


def anon_jwt() -> str:
    payload = base64.urlsafe_b64encode(b'{"role":"anon"}').decode().rstrip("=")
    return f"header.{payload}.signature"


class StagingWebGuardTest(unittest.TestCase):
    def test_accepts_distinct_qa_project_and_only_emits_qa_settings(self):
        config = make_defines(
            "https://qa-123.supabase.co/",
            "sb_publishable_qa",
            "https://prod-456.supabase.co",
        )
        self.assertEqual(config["APP_ENV"], "staging")
        self.assertEqual(config["ALLOW_REMOTE_STAGING"], "true")
        self.assertEqual(config["SUPABASE_URL"], "https://qa-123.supabase.co")
        self.assertEqual(config["SUPABASE_PUBLISHABLE_KEY"], "sb_publishable_qa")
        self.assertNotIn("PRODUCTION_SUPABASE_URL", config)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", config)

    def test_accepts_legacy_anon_jwt_key(self):
        self.assertTrue(make_defines(
            "https://qa-123.supabase.co",
            anon_jwt(),
            "https://prod-456.supabase.co",
        ))

    def test_rejects_same_project(self):
        with self.assertRaises(StagingConfigError):
            make_defines(
                "https://same.supabase.co",
                "sb_publishable_qa",
                "https://same.supabase.co/",
            )

    def test_rejects_non_supabase_and_malformed_urls(self):
        for staging, production in [
            ("http://qa.supabase.co", "https://prod.supabase.co"),
            ("https://qa.supabase.co.evil.example", "https://prod.supabase.co"),
            ("https://user@qa.supabase.co", "https://prod.supabase.co"),
            ("https://qa.supabase.co/path", "https://prod.supabase.co"),
            ("https://qa.supabase.co", "http://prod.supabase.co"),
        ]:
            with self.subTest(staging=staging, production=production):
                with self.assertRaises(StagingConfigError):
                    make_defines(staging, "sb_publishable_qa", production)

    def test_rejects_secret_or_non_publishable_keys(self):
        service_payload = base64.urlsafe_b64encode(
            json.dumps({"role": "service_role"}).encode()
        ).decode().rstrip("=")
        for key in ["", "not-a-key", "sb_secret_test", f"header.{service_payload}.signature"]:
            with self.subTest(key_type=key[:12]):
                with self.assertRaises(StagingConfigError):
                    make_defines(
                        "https://qa.supabase.co",
                        key,
                        "https://prod.supabase.co",
                    )


if __name__ == "__main__":
    unittest.main()
