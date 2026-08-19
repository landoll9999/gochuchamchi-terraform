"""Regression tests for Discord domain routing and investigation hints."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import types
import unittest


HERE = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# lambda_function creates a boto3 client at import time. The tests only exercise
# pure routing/rendering code, so a tiny stub avoids credentials and network use.
fake_boto3 = types.ModuleType("boto3")
fake_boto3.client = lambda _service, *args, **kwargs: object()
sys.modules["boto3"] = fake_boto3
os.environ.setdefault("DISCORD_SECRET_ARN", "test/discord-webhook")

notifications = load_module("notification_lambda", HERE / "lambda_function.py")
siem_discord = load_module(
    "siem_discord",
    HERE.parent / "log-archive" / "siem" / "discord_function.py",
)


class AlarmClassificationTests(unittest.TestCase):
    def test_known_alarm_routes(self):
        cases = {
            "gochuchamchi-alb-api-target-5xx": ("OPS", "P2", "Grafana"),
            "gochuchamchi-app-login-failure": ("SEC", "P2", "Athena"),
            "gochuchamchi-waf-sqli-blocked": ("SEC", "P2", "Athena"),
            "gochuchamchi-firehose-waf-delivery-error": ("PIPELINE", "P2", "CloudWatch"),
            "gochuchamchi-firehose-waf-delivery-delay": ("PIPELINE", "P3", "CloudWatch"),
            "gochuchamchi-rds-cpu-high": ("OPS", "P4", "Grafana"),
            "gochuchamchi-alerts-dlq-has-messages": ("PIPELINE", "P2", "CloudWatch"),
        }

        for alarm_name, expected in cases.items():
            with self.subTest(alarm_name=alarm_name):
                route = notifications.classify_alarm(alarm_name)
                self.assertEqual((route["domain"], route["tier"]), expected[:2])
                self.assertIn(expected[2], route["first_check"])
                self.assertTrue(route["recommended_action"])

    def test_unknown_alarm_is_visible_not_ops_p4(self):
        route = notifications.classify_alarm("gochuchamchi-new-alarm")
        self.assertEqual(route["domain"], "UNCLASSIFIED")
        self.assertEqual(route["tier"], "P3")

    def test_cloudwatch_alarm_embed_contains_routing_fields(self):
        sent = []
        notifications.get_discord_webhook_url = lambda: "https://example.invalid/webhook"
        notifications.send_discord_message = lambda _url, payload: sent.append(payload)

        result = notifications.handle_alarm_event(
            {
                "account": "123456789012",
                "region": "ap-northeast-2",
                "time": "2026-08-19T00:00:00Z",
                "detail": {
                    "alarmName": "gochuchamchi-alb-api-target-5xx",
                    "state": {"value": "ALARM", "reason": "threshold crossed"},
                    "previousState": {"value": "OK"},
                },
            }
        )

        embed = sent[0]["embeds"][0]
        self.assertIn("[OPS][P2]", embed["title"])
        self.assertIn("첫 확인", [field["name"] for field in embed["fields"]])
        self.assertIn("권장 조치", [field["name"] for field in embed["fields"]])
        self.assertEqual(result["domain"], "OPS")

    def test_explicit_plaintext_tags_are_not_duplicated(self):
        sent = []
        notifications.get_discord_webhook_url = lambda: "https://example.invalid/webhook"
        notifications.send_discord_message = lambda _url, payload: sent.append(payload)

        notifications.handle_plaintext_event(
            {
                "detail": {
                    "subject": "[PIPELINE][P2] Network compliance evaluation incomplete",
                    "message": "Config rule result missing",
                }
            }
        )

        title = sent[0]["embeds"][0]["title"]
        self.assertIn("[PIPELINE][P2]", title)
        self.assertEqual(title.count("[PIPELINE]"), 1)

    def test_guardduty_title_uses_sec_and_incident_tier(self):
        sent = []
        notifications.get_discord_webhook_url = lambda: "https://example.invalid/webhook"
        notifications.send_discord_message = lambda _url, payload: sent.append(payload)

        notifications.handle_guardduty_event(
            {
                "detail": {
                    "type": "CredentialAccess:IAMUser/AnomalousBehavior",
                    "severity": 8,
                    "title": "의심 자격증명 사용",
                    "resource": {"resourceType": "AccessKey"},
                }
            }
        )

        self.assertIn("[SEC][P1]", sent[0]["embeds"][0]["title"])


class SiemEmbedTests(unittest.TestCase):
    def test_rule_hit_uses_sec_tag_and_athena_first_check(self):
        embed = siem_discord.embed_rule_hit(
            {
                "severity": "HIGH",
                "title": "권한 상승 또는 감사 무력화 시도",
                "rule_id": "privilege-audit-tampering",
                "why": "test",
                "columns": [],
                "rows": [],
                "console_url": "https://example.invalid/athena",
                "rule_name": "22-rule-privilege-audit-tampering",
            }
        )
        self.assertIn("[SEC][HIGH]", embed["title"])
        self.assertIn("첫 확인", [field["name"] for field in embed["fields"]])

    def test_operational_alarm_uses_pipeline_tag(self):
        embed = siem_discord.embed_cloudwatch_alarm(
            {
                "AlarmName": "gochuchamchi-siem-alerts-dlq-has-messages",
                "NewStateValue": "ALARM",
            }
        )
        self.assertIn("[PIPELINE][P2]", embed["title"])
        self.assertIn("첫 확인", [field["name"] for field in embed["fields"]])


if __name__ == "__main__":
    unittest.main()
