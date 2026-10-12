"""Pin Cabal's selected Hackage descriptions and tarballs for a strict Nix build.

The authenticated Cabal index is authoritative. Match each selected description
by its plan digest, including older revisions, instead of fetching a mutable
latest description. No archive members are extracted to the filesystem.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile


def selected_packages(plan):
    packages = {}
    flags = {}
    for unit in plan["install-plan"]:
        name = unit["pkg-name"]
        version = unit["pkg-version"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", name) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            raise ValueError("unsafe package name or version")
        chosen_flags = unit.get("flags", {})
        if not isinstance(chosen_flags, dict) or any(
            not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", flag) or not isinstance(enabled, bool)
            for flag, enabled in chosen_flags.items()
        ):
            raise ValueError("invalid selected Cabal flags")
        if name in flags and flags[name] != chosen_flags:
            raise ValueError(f"ambiguous flags for {name}")
        flags[name] = chosen_flags
        source = unit.get("pkg-src", {})
        if source.get("type") != "repo-tar":
            continue
        repo = source["repo"]
        if repo.get("type") != "secure-repo" or repo.get("uri") not in ("http://hackage.haskell.org/", "https://hackage.haskell.org/"):
            raise ValueError("only the authenticated Hackage repository is supported")
        record = {"version": version, "descriptionSha256": unit["pkg-cabal-sha256"], "tarballSha256": unit["pkg-src-sha256"]}
        if name in packages and packages[name] != record:
            raise ValueError(f"ambiguous Hackage identity for {name}")
        if any(not re.fullmatch(r"[0-9a-f]{64}", record[key]) for key in ("descriptionSha256", "tarballSha256")):
            raise ValueError("invalid selected Hackage digest")
        packages[name] = record
    return packages, flags


def compiler_packages(plan):
    packages = {}
    for unit in plan["install-plan"]:
        if unit.get("type") != "pre-existing":
            continue
        name, version = unit["pkg-name"], unit["pkg-version"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", name) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            raise ValueError("unsafe compiler package name or version")
        if name in packages and packages[name] != version:
            raise ValueError(f"ambiguous compiler package identity for {name}")
        packages[name] = version
    return packages


def description_revisions(index_path, packages):
    wanted = {f"{name}/{entry['version']}/{name}.cabal": name for name, entry in packages.items()}
    found = {}
    with tarfile.open(index_path, mode="r|*") as archive:
        for member in archive:
            name = wanted.get(member.name)
            if name is None or not member.isfile():
                continue
            if member.size > 4 * 1024 * 1024:
                raise ValueError("oversized package description")
            content = archive.extractfile(member).read()
            if hashlib.sha256(content).hexdigest() != packages[name]["descriptionSha256"]:
                continue
            revisions = re.findall(rb"^x-revision\s*:\s*([0-9]+)\s*$", content, re.I | re.M)
            if len(revisions) > 1:
                raise ValueError("ambiguous description revision")
            found[name] = int(revisions[0]) if revisions else 0
    if set(found) != set(packages):
        raise ValueError(f"selected description not found in authenticated index: {sorted(set(packages) - set(found))}")
    return found


def nix(*arguments):
    return subprocess.run(arguments, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--cohort-lock", required=True)
    parser.add_argument("--out", required=True)
    options = parser.parse_args()
    plan = json.loads(Path(options.plan).read_text())
    packages, flags = selected_packages(plan)
    revisions = description_revisions(options.index, packages)
    cohort = json.loads(Path(options.cohort_lock).read_text())["packages"]
    for name, entry in sorted(packages.items()):
        pin = cohort.get(name)
        if pin is not None:
            if pin["source"] != "hackage" or pin["version"] != entry["version"] or pin["tarballSha256"] != entry["tarballSha256"]:
                raise ValueError(f"cohort source lock differs from selected Hackage source: {name}")
            entry["sha256"] = pin["sha256"]
        else:
            version = entry["version"]
            url = f"https://hackage.haskell.org/package/{name}-{version}/{name}-{version}.tar.gz"
            flat = nix("nix-prefetch-url", "--type", "sha256", url)
            actual = nix("nix", "hash", "convert", "--hash-algo", "sha256", "--from", "nix32", "--to", "base16", flat)
            if actual != entry["tarballSha256"]:
                raise ValueError(f"registry tarball differs from authenticated plan: {name}")
            unpacked = nix("nix-prefetch-url", "--type", "sha256", "--unpack", url)
            entry["sha256"] = nix("nix", "hash", "convert", "--hash-algo", "sha256", "--from", "nix32", "--to", "sri", unpacked)
        entry["descriptionRevision"] = revisions[name]
    output = {"schema": "kenshou.perf-resolved-lock/v1", "packages": packages, "flags": flags,
              "compilerPackages": compiler_packages(plan)}
    Path(options.out).write_text(json.dumps(output, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
