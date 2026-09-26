#!/usr/bin/env python3
"""Exercise the enforced evidence profile with one isolated invalid field per case."""

import copy
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "docs/verification"
PROFILE = BUNDLE / "profile.dhall"
CASES = ROOT / "kenshou-evidence/test/fixtures/profile-invalid/cases.json"
CACHE = ROOT / ".tmp/xdg-cache"
RUN_ID = "01999a00-0000-7000-8000-000000000001"
COMPARISON_ID = "01999a00-0000-7000-8000-000000000002"
ATTESTATION_ID = "01999a00-0000-7000-8000-000000000003"
RUN_PATH = f"runs/selftest/2026/09/{RUN_ID}"


def generated():
    return {"by": "codex/gpt-6", "at": "2026-09-26T19:50:17Z"}


def run_record():
    return {
        "type": "Verification Run",
        "title": "Profile fixture run",
        "description": "A minimal valid run for profile rejection checks.",
        "generated": generated(),
        "runId": RUN_ID,
        "recordKind": "run",
        "purpose": "investigation",
        "scenario": "selftest/kernel/correctness/always-pass",
        "layer": "selftest",
        "component": "kernel",
        "kind": "correctness",
        "tier": "smoke",
        "placement": "local",
        "outcome": "passed",
        "startedAt": "2026-09-26T19:45:00Z",
        "finishedAt": "2026-09-26T19:46:00Z",
        "subject": "mori://shinzui/keiro-runtime-kenshou",
        "subjectKind": "project",
        "harnessRevision": "a" * 40,
        "harnessDirty": False,
        "computations": ["VC-1"],
        "data": [
            {
                "kind": kind,
                "uri": f"gs://kenshou-fixtures/runs/{RUN_ID}/{name}",
                "digest": "b" * 64,
                "mediaType": "application/json",
                "bytes": 42,
            }
            for kind, name in (
                ("run-spec", "run-spec.json"),
                ("run-result", "run-result.json"),
                ("manifest", "manifest.json"),
            )
        ],
        "cohort": "released",
        "solverPlanHash": "c" * 64,
        "components": [
            {
                "project": "mori://shinzui/keiro-runtime-kenshou",
                "package": "kenshou-core",
                "version": "0.1.0.0",
                "source": "hackage",
            }
        ],
        "environment": {
            "os": "darwin",
            "arch": "aarch64",
            "cpuModel": "fixture",
            "cores": 8,
            "memoryBytes": 17179869184,
            "ghc": "9.12.4",
            "postgres": "18.6",
        },
        "seed": 1,
        "compatibilityKey": "d" * 64,
    }


def comparison_record():
    record = run_record()
    record.update(
        runId=COMPARISON_ID,
        recordKind="comparison",
        data=[
            {
                "kind": "comparison",
                "uri": f"gs://kenshou-fixtures/runs/{COMPARISON_ID}/comparison.json",
                "digest": "e" * 64,
                "mediaType": "application/json",
                "bytes": 42,
            }
        ],
        comparison={
            "verdict": "pass",
            "factor": "harness",
            "baselineValue": "before",
            "candidateValue": "after",
            "design": "abba",
            "baselineRuns": [f"/{RUN_PATH}.md"],
            "candidateRuns": [f"/{RUN_PATH}.md"],
        },
    )
    for field in ("cohort", "solverPlanHash", "components", "environment", "seed", "compatibilityKey"):
        del record[field]
    return record


def attestation_record():
    return {
        "type": "Attestation",
        "title": "Profile fixture attestation",
        "description": "A minimal valid attestation for profile rejection checks.",
        "generated": generated(),
        "attestationId": ATTESTATION_ID,
        "run": f"/{RUN_PATH}.md",
        "attester": "process:kenshou-attester/0.1.0.0",
        "attesterRevision": "a" * 40,
        "attestedAt": "2026-09-26T19:50:00Z",
        "verdict": "confirmed",
        "checks": [
            {"name": name, "result": "passed"}
            for name in (
                "digests-match",
                "revisions-resolve",
                "cohort-matches-plan",
                "verdict-recomputed",
                "environment-captured",
                "clean-worktree",
            )
        ],
        "dataDigests": ["b" * 64],
    }


def write_concept(bundle, relative, document):
    path = bundle / (relative + ".md")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("---\n" + json.dumps(document, ensure_ascii=False) + "\n---\n\n# Fixture\n")


def pointer(document, path):
    parts = [part.replace("~1", "/").replace("~0", "~") for part in path.strip("/").split("/")]
    current = document
    for part in parts[:-1]:
        current = current[int(part)] if isinstance(current, list) else current[part]
    return current, parts[-1]


def mutate(document, case):
    op = case["op"]
    parent, key = pointer(document, case["path"])
    if op == "remove":
        if isinstance(parent, list):
            del parent[int(key)]
        else:
            del parent[key]
    elif op == "set":
        if isinstance(parent, list):
            parent[int(key)] = case["value"]
        else:
            parent[key] = case["value"]
    elif op == "copy":
        source_parent, source_key = pointer(document, case["from"])
        value = copy.deepcopy(source_parent[int(source_key)] if isinstance(source_parent, list) else source_parent[source_key])
        if isinstance(parent, list):
            parent.append(value)
        else:
            parent[key] = value
    else:
        raise ValueError(f"unknown fixture op: {op}")


def validate(bundle):
    CACHE.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["XDG_CACHE_HOME"] = str(CACHE)
    return subprocess.run(
        ["okf", "validate", str(bundle), "--strict", "--profile", str(PROFILE), "--profile-enforce", "--log-enforce"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
        check=False,
    )


def main():
    base = validate(BUNDLE)
    if base.returncode:
        raise SystemExit(f"base bundle failed validation:\n{base.stdout}")
    cases = json.loads(CASES.read_text())
    with tempfile.TemporaryDirectory(prefix="kenshou-profile-") as scratch:
        missing_attester = Path(scratch) / "missing-attester-resource"
        shutil.copytree(BUNDLE, missing_attester)
        (missing_attester / "references/attesters/kenshou-attest.sh").unlink()
        missing_result = validate(missing_attester)
        expected_missing = "attester.resource references /references/attesters/kenshou-attest.sh, which does not exist in this bundle"
        if missing_result.returncode == 0 or expected_missing not in missing_result.stdout:
            raise SystemExit(f"missing-attester-resource: expected {expected_missing!r}, got:\n{missing_result.stdout}")
        print("missing-attester-resource: rejected as expected")
        for target, document, relative in (
            ("run", run_record(), RUN_PATH),
            ("comparison", comparison_record(), f"runs/selftest/2026/09/{COMPARISON_ID}"),
            ("attestation", attestation_record(), f"attestations/2026/09/{ATTESTATION_ID}"),
        ):
            bundle = Path(scratch) / f"valid-{target}"
            shutil.copytree(BUNDLE, bundle)
            if target != "run":
                write_concept(bundle, RUN_PATH, run_record())
            write_concept(bundle, relative, document)
            result = validate(bundle)
            if result.returncode:
                raise SystemExit(f"valid {target} fixture failed:\n{result.stdout}")
        for case in cases:
            bundle = Path(scratch) / case["name"]
            shutil.copytree(BUNDLE, bundle)
            target = case["target"]
            relative = {
                "run": RUN_PATH,
                "comparison": f"runs/selftest/2026/09/{COMPARISON_ID}",
                "attestation": f"attestations/2026/09/{ATTESTATION_ID}",
            }[target]
            run = run_record()
            if target != "run":
                write_concept(bundle, RUN_PATH, run)
            document = {"run": run, "comparison": comparison_record(), "attestation": attestation_record()}[target]
            mutate(document, case)
            write_concept(bundle, case.get("file", relative), document)
            result = validate(bundle)
            if result.returncode == 0 or case["expect"] not in result.stdout:
                raise SystemExit(f"{case['name']}: expected {case['expect']!r}, got:\n{result.stdout}")
            print(f"{case['name']}: rejected as expected")


if __name__ == "__main__":
    main()
