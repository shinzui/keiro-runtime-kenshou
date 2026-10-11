"""Offline controls for privileged CI admission and fail-closed evidence gating."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("performance_ci", Path(__file__).with_name("performance-ci.py"))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


def fixture(root):
    request = {"schema": "kenshou.perf-request/v1", "baselineRevision": "a" * 40, "candidateRevision": "b" * 40, "purpose": "gating"}
    execution = {"authMode": "preconfigured", "gcpProject": "fixture-project", "gcpIdentity": "operator@example.invalid", "allowedProjects": ["fixture-project"], "controlBucket": "fixture-control", "evidenceBaseUri": "gs://fixture-evidence/performance", "linuxBuilder": "native", "capabilitiesDirectory": str(root / "capabilities"), "cacheDirectory": str(root / "cache")}
    environ = {"PERF_REQUEST_JSON": json.dumps(request), "PERF_EXECUTION_JSON": json.dumps(execution), "PERF_HARNESS_REVISION": "c" * 40, "PERF_RUNNER_LABELS": '["self-hosted", "Linux", "X64", "protected-performance"]', "PERF_ENVIRONMENT": "protected-performance", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/master", "PERF_DEFAULT_BRANCH": "master", "GITHUB_REPOSITORY": "fixture/project", "GH_TOKEN": "fixture", "PERF_ROOT": str(root), "GITHUB_OUTPUT": str(root / "outputs"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
    return request, execution, environ


class CiControls(unittest.TestCase):
    def test_rejects_exploratory_or_ambiguous_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            request, execution, environ = fixture(Path(directory))
            ci.settings(environ)
            for changed in (dict(request, purpose="calibration"), dict(request, baselineRevision="HEAD"), dict(request, budgetMinutes=31), dict(request, waitSeconds=91)):
                with self.assertRaises(ValueError):
                    ci.settings(dict(environ, PERF_REQUEST_JSON=json.dumps(changed)))
            for changed in (dict(execution, linuxBuilder="builder\nbuilders = evil"), dict(execution, authMode="workload-identity"), dict(execution, evidenceBaseUri="gs://fixture-evidence/../wrong"), dict(execution, allowedProjects=["other-project"])):
                with self.assertRaises(ValueError):
                    ci.settings(dict(environ, PERF_EXECUTION_JSON=json.dumps(changed)))
            with self.assertRaises(ValueError):
                ci.settings(dict(environ, PERF_RUNNER_LABELS='["ubuntu-latest"]'))

    def test_rejects_untrusted_events_before_any_external_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            _, _, environ = fixture(Path(directory))
            with patch.object(ci.subprocess, "run") as command, patch.object(ci, "urlopen") as api:
                for event in ("pull_request", "pull_request_target", "workflow_run"):
                    with self.assertRaises(ValueError):
                        ci.preflight(dict(environ, GITHUB_EVENT_NAME=event))
                with self.assertRaises(ValueError):
                    ci.preflight(dict(environ, GITHUB_REF="refs/heads/untrusted"))
                command.assert_not_called()
                api.assert_not_called()

    def test_fails_gate_when_online_replay_is_missing_or_disagrees(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, environ = fixture(root)
            reports = [None, {"verified": True, "offline": True, "result": {"purpose": "gating", "exitCode": 0, "gatingEligible": True}}, {"verified": True, "offline": False, "result": {"purpose": "calibration", "exitCode": 0}}, {"verified": True, "offline": False, "result": {"purpose": "gating", "exitCode": 1}, "manifestUri": "gs://fixture/report"}]
            for report in reports:
                def fake_cli(arguments, runner, output):
                    if arguments[0] == "verify" and report is not None:
                        json.dump(report, output)
                    return 0

                with patch.object(ci, "runner_environment", return_value=environ), patch.object(ci.subprocess, "run"), patch.object(ci, "cli", side_effect=fake_cli):
                    self.assertEqual(ci.measure(environ), 4)
                self.assertIn("exit-code=4", (root / "outputs").read_text())

    def test_preserves_verified_statistics_and_runtime_gate_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, environ = fixture(root)
            snapshot = root / "session/snapshots/fixture"
            snapshot.mkdir(parents=True)
            (snapshot / "report.md").write_text("retained report\n")
            (root / "session/receipt.json").write_text(json.dumps({"snapshot": "snapshots/fixture"}))
            for code in (0, 1, 3, 4):
                def fake_cli(arguments, runner, output):
                    if arguments[0] == "verify":
                        json.dump({"verified": True, "offline": False, "manifestUri": "gs://fixture-evidence/performance/manifest.json", "result": {"purpose": "gating", "exitCode": code, "gatingEligible": True}}, output)
                    return code

                with patch.object(ci, "runner_environment", return_value=environ), patch.object(ci.subprocess, "run"), patch.object(ci, "cli", side_effect=fake_cli):
                    self.assertEqual(ci.measure(environ), code)
            self.assertIn("retained report", (root / "summary").read_text())


if __name__ == "__main__":
    unittest.main()
