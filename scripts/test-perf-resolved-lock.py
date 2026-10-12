"""Offline controls for authenticated-index resolution; no registry downloads."""

import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

loader = importlib.util.spec_from_file_location("resolved_lock", Path(__file__).with_name("perf-resolved-lock.py"))
resolved = importlib.util.module_from_spec(loader)
loader.loader.exec_module(resolved)


class ResolvedLockTests(unittest.TestCase):
    def test_compiler_libraries_require_unambiguous_pre_existing_plan_units(self):
        builtin = {"type": "pre-existing", "pkg-name": "base", "pkg-version": "4.21.0.0"}
        registry = {"type": "configured", "pkg-name": "aeson", "pkg-version": "2.2.5.1"}
        self.assertEqual(resolved.compiler_packages({"install-plan": [builtin, builtin, registry]}), {"base": "4.21.0.0"})
        with self.assertRaisesRegex(ValueError, "ambiguous compiler"):
            resolved.compiler_packages({"install-plan": [builtin, builtin | {"pkg-version": "4.20.0.0"}]})
        with self.assertRaisesRegex(ValueError, "unsafe compiler"):
            resolved.compiler_packages({"install-plan": [builtin | {"pkg-name": "../base"}]})

    def test_selected_older_description_is_pinned_by_hash(self):
        old = b"name: example\nversion: 1.0\n"
        new = old + b"x-revision: 1\n"
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "index.tar"
            with tarfile.open(index, "w") as archive:
                for content in (old, new):
                    member = tarfile.TarInfo("example/1.0/example.cabal")
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
            def package(content):
                return {"example": {"version": "1.0", "descriptionSha256": hashlib.sha256(content).hexdigest()}}
            self.assertEqual(resolved.description_revisions(index, package(old)), {"example": 0})
            self.assertEqual(resolved.description_revisions(index, package(new)), {"example": 1})
            with self.assertRaisesRegex(ValueError, "not found"):
                resolved.description_revisions(index, package(b"corruption"))

    def test_link_is_not_used_as_an_authenticated_description(self):
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "index.tar"
            with tarfile.open(index, "w") as archive:
                member = tarfile.TarInfo("example/1.0/example.cabal")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../elsewhere"
                archive.addfile(member)
            with self.assertRaisesRegex(ValueError, "not found"):
                resolved.description_revisions(index, {"example": {"version": "1.0", "descriptionSha256": "0" * 64}})

    def test_rejects_ambiguous_flags_sources_and_unknown_registries(self):
        unit = {"pkg-name": "example", "pkg-version": "1.0", "pkg-cabal-sha256": "a" * 64, "pkg-src-sha256": "b" * 64, "pkg-src": {"type": "repo-tar", "repo": {"type": "secure-repo", "uri": "https://hackage.haskell.org/"}}, "flags": {"fast": True}}
        packages, flags = resolved.selected_packages({"install-plan": [unit, unit]})
        self.assertEqual(packages["example"]["version"], "1.0")
        self.assertEqual(flags, {"example": {"fast": True}})
        with self.assertRaisesRegex(ValueError, "ambiguous flags"):
            resolved.selected_packages({"install-plan": [unit, unit | {"flags": {"fast": False}}]})
        with self.assertRaisesRegex(ValueError, "ambiguous Hackage"):
            resolved.selected_packages({"install-plan": [unit, unit | {"pkg-version": "1.1"}]})
        with self.assertRaisesRegex(ValueError, "authenticated Hackage"):
            resolved.selected_packages({"install-plan": [unit | {"pkg-src": {"type": "repo-tar", "repo": {"type": "secure-repo", "uri": "https://elsewhere.invalid/"}}}]})


if __name__ == "__main__":
    unittest.main()
