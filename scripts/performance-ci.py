"""Use the ordinary Kenshou CLI from a trusted, explicitly configured CI runner."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen


def require(condition, message):
    if not condition:
        raise ValueError(message)


def settings(environ):
    request = json.loads(environ["PERF_REQUEST_JSON"])
    execution = json.loads(environ["PERF_EXECUTION_JSON"])
    labels = json.loads(environ["PERF_RUNNER_LABELS"])
    require(isinstance(request, dict), "request must be an object")
    require(request.get("schema") == "kenshou.perf-request/v1", "unsupported request")
    require(request.get("purpose", "gating") == "gating", "CI requires gating purpose")
    for field in ("baselineRevision", "candidateRevision"):
        require(re.fullmatch(r"[0-9a-f]{40}", request.get(field, "")), "immutable source revisions required")
    require(re.fullmatch(r"[0-9a-f]{40}", environ["PERF_HARNESS_REVISION"]), "immutable harness revision required")
    require(isinstance(request.get("budgetMinutes", 30), int) and 0 < request.get("budgetMinutes", 30) <= 30, "CI execution budget must be at most 30 minutes")
    require(isinstance(request.get("waitSeconds", 90), int) and 0 <= request.get("waitSeconds", 90) <= 90, "CI admission allowance must be at most 90 seconds")
    require(isinstance(labels, list) and all(isinstance(label, str) and re.fullmatch(r"[A-Za-z0-9_-]+", label) for label in labels), "invalid runner labels")
    require({"self-hosted", "Linux", "X64"}.issubset(labels) and len(set(labels) - {"self-hosted", "Linux", "X64"}) > 0, "a protected Linux X64 runner label is required")
    require(isinstance(execution, dict), "execution must be an object")
    fields = {"authMode", "gcpProject", "gcpIdentity", "workloadIdentityProvider", "allowedProjects", "controlBucket", "evidenceBaseUri", "linuxBuilder", "capabilitiesDirectory", "cacheDirectory", "start"}
    require(not set(execution) - fields, "unknown execution setting")
    for field in fields - {"workloadIdentityProvider", "start"}:
        require(field in execution, "missing execution setting: " + field)
    require(execution["authMode"] in ("preconfigured", "workload-identity"), "unsupported authentication mode")
    require(re.fullmatch(r"[a-z][a-z0-9-]+", execution["gcpProject"]), "invalid GCP project")
    require(isinstance(execution["gcpIdentity"], str) and re.fullmatch(r"[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+", execution["gcpIdentity"]), "explicit GCP identity required")
    if execution["authMode"] == "workload-identity":
        require(re.fullmatch(r"projects/[0-9]+/locations/global/workloadIdentityPools/[A-Za-z0-9_-]+/providers/[A-Za-z0-9_-]+", execution.get("workloadIdentityProvider", "")), "full workload identity provider required")
        require(execution["gcpIdentity"].endswith(".iam.gserviceaccount.com"), "federation requires a service account")
    require(isinstance(execution["allowedProjects"], list) and execution["allowedProjects"] and all(isinstance(project, str) and re.fullmatch(r"[a-z][a-z0-9-]+", project) for project in execution["allowedProjects"]), "explicit project allowlist required")
    require(execution["gcpProject"] in execution["allowedProjects"], "identity project is outside the allowlist")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]+", execution["controlBucket"]), "invalid control bucket")
    require(re.fullmatch(r"gs://[a-z0-9][a-z0-9.-]+/[A-Za-z0-9_./-]+", execution["evidenceBaseUri"]) and all(part not in (".", "..", "") for part in execution["evidenceBaseUri"][5:].split("/")), "explicit safe evidence prefix required")
    builder = execution["linuxBuilder"]
    require(isinstance(builder, str) and builder and not any(char in builder for char in "\n\r\0"), "explicit single-line Linux builder required")
    require(isinstance(execution.get("start", False), bool), "start must be boolean")
    for field in ("capabilitiesDirectory", "cacheDirectory"):
        require(isinstance(execution[field], str) and Path(execution[field]).is_absolute(), "runner-owned absolute directory required: " + field)
    require(environ["PERF_ENVIRONMENT"].strip(), "existing protected environment required")
    return request, execution


def preflight(environ):
    settings(environ)
    require(environ["GITHUB_EVENT_NAME"] in ("push", "workflow_dispatch"), "cloud execution requires a trusted push or manual dispatch")
    require(environ["GITHUB_REF"] == "refs/heads/" + environ["PERF_DEFAULT_BRANCH"], "cloud execution requires the caller's default branch")
    subprocess.run(["git", "merge-base", "--is-ancestor", environ["PERF_HARNESS_REVISION"], "HEAD"], check=True)
    endpoint = environ.get("GITHUB_API_URL", "https://api.github.com") + "/repos/" + environ["GITHUB_REPOSITORY"] + "/environments/" + quote(environ["PERF_ENVIRONMENT"], safe="")
    request = Request(endpoint, headers={"Authorization": "Bearer " + environ["GH_TOKEN"], "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"})
    with urlopen(request, timeout=30) as response:
        environment = json.load(response)
    require(environment.get("name") == environ["PERF_ENVIRONMENT"], "environment lookup differs")
    require(any(rule.get("type") == "required_reviewers" and rule.get("reviewers") for rule in environment.get("protection_rules", [])), "environment must already require reviewers")
    require(environment.get("deployment_branch_policy") is not None, "environment must restrict deployment branches")


def runner_environment(environ, execution):
    require(environ.get("RUNNER_OS") == "Linux" and environ.get("RUNNER_ARCH") == "X64", "measurement requires a Linux X64 runner")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(revision == environ["PERF_HARNESS_REVISION"], "checked-out harness differs")
    if execution["authMode"] == "preconfigured":
        identity = subprocess.check_output(["gcloud", "config", "get-value", "account"], text=True, stderr=subprocess.DEVNULL).strip()
        require(identity == execution["gcpIdentity"], "preconfigured GCP identity differs")
    else:
        credentials = json.loads(Path(environ["CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"]).read_text())
        expected = "/serviceAccounts/" + execution["gcpIdentity"] + ":generateAccessToken"
        require(credentials.get("service_account_impersonation_url", "").endswith(expected), "federated identity differs")
    subprocess.run(["gcloud", "auth", "print-access-token"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    result = dict(environ)
    result["KENSHOU_GCP_ALLOWED_PROJECTS"] = ",".join(execution["allowedProjects"])
    result["KENSHOU_CELL_CAPABILITIES_DIR"] = execution["capabilitiesDirectory"]
    require(Path(execution["capabilitiesDirectory"]).is_dir(), "runner capability directory is unavailable")
    result.pop("KENSHOU_CELL_STORE", None)
    if execution["linuxBuilder"] == "native":
        system = subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"], text=True).strip()
        require(system == "x86_64-linux", "native builder must be x86_64-linux")
        builders = ""
    else:
        builders = execution["linuxBuilder"]
    result["NIX_CONFIG"] = result.get("NIX_CONFIG", "") + "\nbuilders = " + builders + "\n"
    return result


def cli(arguments, environ, stdout):
    return subprocess.run(["nix", "develop", "-c", "cabal", "run", "-v0", "kenshou", "--", "perf", *arguments], env=environ, stdout=stdout).returncode


def prepare(environ):
    request, execution = settings(environ)
    runner = runner_environment(environ, execution)
    root = Path(environ["PERF_ROOT"])
    root.mkdir(parents=True, exist_ok=True)
    request_path = root / "request.json"
    request_path.write_text(json.dumps(request) + "\n")
    with (root / "prepare-output.json").open("w") as output:
        return cli(["prepare", "--request", str(request_path), "--out", str(root / "preparation"), "--cache", execution["cacheDirectory"], "--control-bucket", execution["controlBucket"]], runner, output)


def measure(environ):
    _, execution = settings(environ)
    runner = runner_environment(environ, execution)
    root = Path(environ["PERF_ROOT"])
    session = root / "session"
    # Build before fresh payload verification starts the measured interval.
    subprocess.run(["nix", "develop", "-c", "cabal", "build", "kenshou-cli:exe:kenshou"], env=runner, check=True)
    arguments = ["run", "--prepared", str(root / "preparation/evidence/prepared.json"), "--evidence-base-uri", execution["evidenceBaseUri"], "--out", str(session), "--control-bucket", execution["controlBucket"]]
    if execution.get("start", False):
        arguments.append("--start")
    with (root / "run-output.json").open("w") as output:
        code = cli(arguments, runner, output)
    with (root / "verify-output.json").open("w") as output:
        verification_code = cli(["verify", "--session", str(session)], runner, output)
    manifest_uri = ""
    try:
        report = json.loads((root / "verify-output.json").read_text())
        require(report["verified"] is True and report["offline"] is False, "CI needs online evidence replay")
        require(report["result"]["purpose"] == "gating", "calibration is not a CI gate")
        require(report["result"]["exitCode"] == code == verification_code and code in (0, 1, 2, 3, 4), "CLI and replay exits differ")
        if code == 0:
            require(report["result"]["gatingEligible"] is True, "pass is not gating eligible")
        manifest_uri = report["manifestUri"]
        receipt = json.loads((session / "receipt.json").read_text())
        summary = session / receipt["snapshot"] / "report.md"
        with Path(environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write(summary.read_text())
    except (OSError, ValueError, KeyError, TypeError):
        code = 4
    with Path(environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"exit-code={code}\nmanifest-uri={manifest_uri}\n")
    return code


def main():
    try:
        operation = sys.argv[1]
        require(operation in ("preflight", "prepare", "measure"), "unknown CI operation")
        return globals()[operation](os.environ) or 0
    except (ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError) as problem:
        # Avoid printing request bodies, credential files or subprocess output.
        print("Performance CI prerequisite or execution failed: " + type(problem).__name__, file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main())
