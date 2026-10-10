"""CI driver tests; any binary bytes here are synthetic, not an OCaml build."""

import io
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPOSITORY = Path(__file__).resolve().parents[1]
DRIVER = REPOSITORY / "scripts" / "build-public-cli.py"


class DriverTests(unittest.TestCase):
    def load_driver(self):
        self.assertTrue(DRIVER.is_file(), "source-only CI build driver is missing")
        spec = importlib.util.spec_from_file_location("build_public_cli", DRIVER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def synthetic_artifact(self, temporary):
        root = Path(temporary) / "checkout"
        fresh = Path(temporary) / "fresh"
        root.mkdir()
        source = fresh / "_build/default/bin/public_main.exe"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"synthetic bytes, never executed as a CLI\x00")
        source.chmod(0o755)
        return root, fresh, source

    def test_publication_refuses_unsafe_namespace_without_writing(self):
        driver = self.load_driver()
        self.assertTrue(hasattr(driver, "BuildRefusal"), "build refusal boundary is missing")
        cases = ["missing-source", "source-link", "source-parent-link", "source-hardlink",
                 "source-not-executable", "build-link", "output-link", "target-link",
                 "target-directory", "target-hardlink", "unexpected-output", "overlap"]
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root, fresh, source = self.synthetic_artifact(temporary)
                output = root / "_build/public-cli"
                if case == "missing-source":
                    source.unlink()
                elif case == "source-link":
                    other = source.with_name("other")
                    source.rename(other)
                    source.symlink_to(other)
                elif case == "source-parent-link":
                    original = source.parent
                    other = original.with_name("other")
                    original.rename(other)
                    original.symlink_to(other, target_is_directory=True)
                elif case == "source-hardlink":
                    os.link(source, source.with_name("other"))
                elif case == "source-not-executable":
                    source.chmod(0o644)
                elif case == "build-link":
                    (root / "_build").symlink_to(fresh / "_build", target_is_directory=True)
                elif case == "output-link":
                    output.parent.mkdir()
                    output.symlink_to(source.parent, target_is_directory=True)
                elif case in {"target-link", "target-directory", "target-hardlink", "unexpected-output"}:
                    output.mkdir(parents=True)
                    target = output / "tree_of_md"
                    if case == "target-link":
                        target.symlink_to(source)
                    elif case == "target-directory":
                        target.mkdir()
                    elif case == "target-hardlink":
                        os.link(source, target)
                    else:
                        (output / "unowned").write_bytes(b"do not replace")
                elif case == "overlap":
                    fresh = root
                    source = fresh / "_build/default/bin/public_main.exe"
                    source.parent.mkdir(parents=True)
                    source.write_bytes(b"stale binary")
                    source.chmod(0o755)
                before = {str(p.relative_to(root)): p.read_bytes()
                          for p in root.rglob("*") if p.is_file() and not p.is_symlink()}
                with self.assertRaises(driver.BuildRefusal):
                    driver.publish_binary(root, fresh)
                after = {str(p.relative_to(root)): p.read_bytes()
                         for p in root.rglob("*") if p.is_file() and not p.is_symlink()}
                self.assertEqual(after, before)

    def test_publication_is_byte_idempotent_and_atomic(self):
        driver = self.load_driver()
        with tempfile.TemporaryDirectory() as temporary:
            root, fresh, source = self.synthetic_artifact(temporary)
            first = driver.publish_binary(root, fresh)
            target = root / "_build/public-cli/tree_of_md"
            before = target.stat().st_ino
            second = driver.publish_binary(root, fresh)
            self.assertEqual(first, second)
            self.assertNotEqual(before, target.stat().st_ino)
            source.write_bytes(b"synthetic updated bytes")
            third = driver.publish_binary(root, fresh)
            self.assertNotEqual(second, third)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["tree_of_md"])

    def test_publishes_regular_executable_from_explicit_fresh_source(self):
        driver = self.load_driver()
        self.assertTrue(callable(getattr(driver, "publish_binary", None)),
                        "guarded binary publication is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            fresh = Path(temporary) / "fresh"
            root.mkdir()
            source = fresh / "_build/default/bin/public_main.exe"
            source.parent.mkdir(parents=True)
            content = b"synthetic artifact bytes; not a real CLI\x00"
            source.write_bytes(content)
            source.chmod(0o755)
            digest = driver.publish_binary(root, fresh)
            target = root / "_build/public-cli/tree_of_md"
            self.assertEqual(digest, hashlib.sha256(content).hexdigest())
            self.assertEqual(target.read_bytes(), content)
            self.assertFalse(target.is_symlink())
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            self.assertNotEqual(target.stat().st_ino, source.stat().st_ino)

    def source_fixture(self, temporary):
        root = Path(temporary) / "checkout"
        root.mkdir()
        files = {"dune-project": b"(lang dune 3.22)\n",
                 "dune-workspace": b"(lang dune 3.21)\n(pkg enabled)\n",
                 "tree-md.opam": b"synthetic package file\n",
                 "bin/dune": b"(executable (name public_main) (public_name tree_of_md))\n",
                 "bin/public_main.ml": b"(* synthetic source, not compiled *)\n",
                 "lib/dune": b"(library (name synthetic))\n",
                 "lib/synthetic.ml": b"let n = 1\n",
                 "dune.lock/lock.dune": b"(lang package 0.1)\n",
                 "dune.lock/synthetic.1.pkg": b"(version 1)\n"}
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        return root, files

    def test_copies_only_regular_trusted_build_inputs_and_locked_dependencies(self):
        driver = self.load_driver()
        self.assertTrue(callable(getattr(driver, "copy_sources", None)),
                        "source-only workspace copying is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root, files = self.source_fixture(temporary)
            (root / "ignored-private-canary").write_bytes(b"never copy unrelated files")
            fresh = Path(temporary) / "fresh"
            fresh.mkdir()
            manifest = driver.copy_sources(root, fresh)
            self.assertEqual(set(manifest), set(files))
            for name, content in files.items():
                self.assertEqual((fresh / name).read_bytes(), content)
                self.assertEqual(manifest[name], hashlib.sha256(content).hexdigest())
            self.assertFalse((fresh / "ignored-private-canary").exists())
            self.assertFalse((fresh / "_build").exists())

    def test_missing_dune_refuses_instead_of_using_a_stale_binary(self):
        driver = self.load_driver()
        self.assertTrue(callable(getattr(driver, "build", None)),
                        "locked source build orchestration is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root, files = self.source_fixture(temporary)
            stale = root / "_build/default/bin/public_main.exe"
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale untrusted binary must never be published")
            old_path = os.environ.get("PATH")
            os.environ["PATH"] = ""
            try:
                with self.assertRaises(driver.BuildRefusal) as caught:
                    driver.build(root)
            finally:
                if old_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = old_path
            self.assertEqual(str(caught.exception), "CB_TOOLCHAIN")
            self.assertFalse((root / "_build/public-cli").exists())
            self.assertEqual(stale.read_bytes(), b"stale untrusted binary must never be published")
            for name, content in files.items():
                self.assertEqual((root / name).read_bytes(), content)
            self.assertFalse((root / "_build/public-cli-source").exists())
            self.assertFalse((root / "_build/.public-cli-driver.lock").exists())

    def test_nested_fresh_workspace_sets_explicit_dune_root(self):
        driver = self.load_driver()
        with tempfile.TemporaryDirectory() as temporary:
            root, files = self.source_fixture(temporary)
            stage = root / "_build/public-cli-source"

            def fail_build_after_checking_workspace(argv, **kwargs):
                if argv == ["dune", "--version"]:
                    return subprocess.CompletedProcess(argv, 0, b"3.23.1\n", b"")
                self.assertEqual(argv, ["dune", "build", "@install"])
                self.assertEqual(kwargs["cwd"], stage)
                self.assertEqual(kwargs["env"].get("DUNE_ROOT"), str(stage),
                                 "nested build incorrectly inherits the outer Dune workspace")
                self.assertEqual(kwargs["env"]["DUNE_CACHE"], "disabled")
                self.assertEqual(kwargs["timeout"], 600)
                self.assertNotIn("shell", kwargs)
                self.assertFalse((stage / "_build").exists())
                for name, content in files.items():
                    self.assertEqual((stage / name).read_bytes(), content)
                # This is an explicit failed-build test, never a fake successful CLI.
                return subprocess.CompletedProcess(argv, 1, b"PRIVATE_STDOUT_CANARY", b"PRIVATE_ERROR_CANARY")

            with mock.patch.dict(os.environ, {"DUNE_ROOT": "PRIVATE_ROOT_CANARY"}), \
                 mock.patch.object(driver.subprocess, "run", side_effect=fail_build_after_checking_workspace):
                with self.assertRaises(driver.BuildRefusal) as caught:
                    driver.build(root)
            self.assertEqual(str(caught.exception), "CB_BUILD_FAILED")
            self.assertFalse(stage.exists())
            self.assertFalse((root / "_build/public-cli").exists())

    def test_failed_build_preserves_previous_binary_and_redacts_diagnostics(self):
        driver = self.load_driver()
        with tempfile.TemporaryDirectory() as temporary:
            root, _ = self.source_fixture(temporary)
            script = root / "scripts/build-public-cli.py"
            script.parent.mkdir()
            script.write_bytes(DRIVER.read_bytes())
            target = root / "_build/public-cli/tree_of_md"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"explicit synthetic previous artifact, never executed")
            target.chmod(0o755)
            before = target.read_bytes(), target.stat().st_mtime_ns, target.stat().st_ino
            stdout, stderr = io.StringIO(), io.StringIO()
            results = [subprocess.CompletedProcess(["dune", "--version"], 0, b"3.23.1\n", b""),
                       subprocess.CompletedProcess(["dune", "build", "@install"], 1,
                                                   b"PRIVATE_STDOUT_CANARY", b"PRIVATE_ERROR_CANARY")]
            with mock.patch.object(driver, "__file__", str(script)), \
                 mock.patch.object(driver.sys, "argv", [str(script)]), \
                 mock.patch.object(driver.sys, "stdout", stdout), \
                 mock.patch.object(driver.sys, "stderr", stderr), \
                 mock.patch.object(driver.subprocess, "run", side_effect=results):
                code = driver.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), "CB_BUILD_FAILED\n")
            self.assertEqual((target.read_bytes(), target.stat().st_mtime_ns, target.stat().st_ino), before)
            self.assertFalse((root / "_build/public-cli-source").exists())
            self.assertFalse((root / "_build/.public-cli-driver.lock").exists())

    def test_existing_owned_stage_and_busy_lock_are_not_deleted(self):
        driver = self.load_driver()
        for name, code in [("public-cli-source", "CB_ARTIFACT"),
                           (".public-cli-driver.lock", "CB_BUSY")]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root, _ = self.source_fixture(temporary)
                existing = root / "_build" / name
                existing.parent.mkdir()
                if name == "public-cli-source":
                    existing.mkdir()
                    (existing / "unowned").write_bytes(b"never delete")
                else:
                    existing.write_bytes(b"never delete")
                with mock.patch.object(driver.subprocess, "run") as run:
                    with self.assertRaises(driver.BuildRefusal) as caught:
                        driver.build(root)
                    run.assert_not_called()
                self.assertEqual(str(caught.exception), code)
                self.assertTrue(existing.exists())

    def test_source_symlink_and_unexpected_binary_are_refused(self):
        driver = self.load_driver()
        for name in ["symlink", "unexpected-binary", "missing-lock", "missing-entrypoint"]:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temporary:
                root, _ = self.source_fixture(temporary)
                if name == "symlink":
                    source = root / "lib/synthetic.ml"
                    source.unlink()
                    source.symlink_to(root / "bin/public_main.ml")
                elif name == "unexpected-binary":
                    (root / "bin/stale.exe").write_bytes(b"must not reuse")
                elif name == "missing-lock":
                    (root / "dune.lock/lock.dune").unlink()
                else:
                    (root / "bin/public_main.ml").unlink()
                with mock.patch.object(driver.subprocess, "run") as run:
                    with self.assertRaises(driver.BuildRefusal):
                        driver.build(root)
                    run.assert_not_called()
                self.assertFalse((root / "_build").exists())

    def test_atomic_replace_failure_preserves_previous_binary(self):
        driver = self.load_driver()
        with tempfile.TemporaryDirectory() as temporary:
            root, fresh, source = self.synthetic_artifact(temporary)
            driver.publish_binary(root, fresh)
            target = root / "_build/public-cli/tree_of_md"
            before = target.read_bytes()
            source.write_bytes(b"synthetic replacement")
            with mock.patch.object(driver.os, "replace", side_effect=OSError("PRIVATE_ERROR_CANARY")):
                with self.assertRaises(OSError):
                    driver.publish_binary(root, fresh)
            self.assertEqual(target.read_bytes(), before)
            self.assertEqual([entry.name for entry in target.parent.iterdir()], ["tree_of_md"])

    def test_interruption_never_prints_a_python_traceback(self):
        driver = self.load_driver()
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(driver.sys, "argv", [str(DRIVER)]), \
             mock.patch.object(driver.sys, "stdout", stdout), \
             mock.patch.object(driver.sys, "stderr", stderr), \
             mock.patch.object(driver, "build", side_effect=KeyboardInterrupt):
            try:
                code = driver.main()
            except KeyboardInterrupt:
                self.fail("interruption escapes the private-error boundary")
        self.assertEqual(code, 130)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "CB_INTERRUPTED\n")

    def test_driver_refuses_arguments_without_disclosing_values(self):
        self.assertTrue(DRIVER.is_file(), "source-only CI build driver is missing")
        result = subprocess.run(
            [sys.executable, str(DRIVER), "PRIVATE_ARGUMENT_CANARY"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "CB_ARGUMENTS\n")


if __name__ == "__main__":
    unittest.main()
