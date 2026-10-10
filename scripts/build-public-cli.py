#!/usr/bin/env python3
"""Build the canonical public converter from a trusted, locked source checkout."""

import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


class BuildRefusal(Exception):
    """Only a stable generic code may cross the command-line boundary."""


def checked(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise BuildRefusal("CB_PATH")
    for parent in reversed(path.parents):
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise BuildRefusal("CB_PATH")
    info = path.lstat()
    if directory:
        valid = stat.S_ISDIR(info.st_mode)
    else:
        valid = stat.S_ISREG(info.st_mode) and info.st_nlink == 1
    if not valid:
        raise BuildRefusal("CB_PATH")
    return info


def output_namespace(root, temporary=None):
    checked(root, directory=True)
    build = root / "_build"
    output = build / "public-cli"
    for directory in (build, output):
        if os.path.lexists(directory):
            checked(directory, directory=True)
    if os.path.lexists(output):
        allowed = {"tree_of_md"}
        if temporary is not None:
            allowed.add(temporary.name)
        if any(entry.name not in allowed for entry in output.iterdir()):
            raise BuildRefusal("CB_ARTIFACT")
        target = output / "tree_of_md"
        if os.path.lexists(target):
            checked(target)
    return output


def publish_binary(root, fresh):
    root, fresh = Path(root), Path(fresh)
    if root == fresh or root.is_relative_to(fresh):
        raise BuildRefusal("CB_OVERLAP")
    source = fresh / "_build/default/bin/public_main.exe"
    try:
        info = checked(source)
    except FileNotFoundError:
        raise BuildRefusal("CB_BINARY") from None
    if not info.st_mode & 0o111:
        raise BuildRefusal("CB_BINARY")
    output = output_namespace(root)
    output.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".tree_of_md-", dir=output)
    temporary = Path(name)
    try:
        with source.open("rb") as input_file, os.fdopen(descriptor, "wb") as output_file:
            shutil.copyfileobj(input_file, output_file)
            output_file.flush()
            os.fchmod(output_file.fileno(), 0o755)
            os.fsync(output_file.fileno())
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        os.replace(temporary, output / "tree_of_md")
        return digest
    finally:
        temporary.unlink(missing_ok=True)


def source_manifest(root):
    checked(root, directory=True)
    paths = [root / name for name in ("dune-project", "dune-workspace", "tree-md.opam")]
    for name in ("bin", "lib", "dune.lock"):
        directory = root / name
        checked(directory, directory=True)
        for path in sorted(directory.rglob("*")):
            if stat.S_ISDIR(path.lstat().st_mode):
                checked(path, directory=True)
            else:
                checked(path)
                if name == "dune.lock":
                    allowed = path.name == "lock.dune" or path.suffix == ".pkg"
                else:
                    allowed = path.name == "dune" or path.suffix in {".ml", ".mli"}
                if not allowed:
                    raise BuildRefusal("CB_SOURCE")
                paths.append(path)
    required = [root / "bin/dune", root / "bin/public_main.ml", root / "dune.lock/lock.dune"]
    if any(path not in paths for path in required):
        raise BuildRefusal("CB_SOURCE")
    result = {}
    for path in paths:
        checked(path)
        result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def copy_sources(root, fresh):
    manifest = source_manifest(root)
    checked(fresh, directory=True)
    if any(fresh.iterdir()):
        raise BuildRefusal("CB_ARTIFACT")
    for name, expected in manifest.items():
        content = (root / name).read_bytes()
        if hashlib.sha256(content).hexdigest() != expected:
            raise BuildRefusal("CB_SOURCE_CHANGED")
        target = fresh / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(content)
    return manifest


def build(root):
    root = Path(root)
    try:
        before = source_manifest(root)
    except FileNotFoundError:
        raise BuildRefusal("CB_SOURCE") from None
    output_namespace(root)
    stage = root / "_build/public-cli-source"
    lock = root / "_build/.public-cli-driver.lock"
    if os.path.lexists(stage):
        raise BuildRefusal("CB_ARTIFACT")
    if os.path.lexists(lock):
        raise BuildRefusal("CB_BUSY")
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("DUNE_", "OPAM", "OCAML", "CAML"))}
    environment["DUNE_CACHE"] = "disabled"
    try:
        version = subprocess.run(["dune", "--version"], capture_output=True,
                                 env=environment, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise BuildRefusal("CB_TOOLCHAIN") from None
    if version.returncode != 0 or version.stdout.strip() != b"3.23.1":
        raise BuildRefusal("CB_TOOLCHAIN")
    stage.parent.mkdir(exist_ok=True)
    try:
        descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise BuildRefusal("CB_BUSY") from None
    os.close(descriptor)
    created = False
    try:
        stage.mkdir()
        created = True
        if copy_sources(root, stage) != before:
            raise BuildRefusal("CB_SOURCE_CHANGED")
        environment["DUNE_ROOT"] = str(stage)
        try:
            result = subprocess.run(["dune", "build", "@install"], cwd=stage,
                                    env=environment, capture_output=True,
                                    timeout=600, check=False)
        except subprocess.TimeoutExpired:
            raise BuildRefusal("CB_BUILD_TIMEOUT") from None
        except OSError:
            raise BuildRefusal("CB_BUILD_FAILED") from None
        if result.returncode != 0:
            raise BuildRefusal("CB_BUILD_FAILED")
        if source_manifest(root) != before or source_manifest(stage) != before:
            raise BuildRefusal("CB_SOURCE_CHANGED")
        return publish_binary(root, stage)
    finally:
        if created:
            shutil.rmtree(stage)
        lock.unlink()


def main():
    if len(sys.argv) != 1:
        print("CB_ARGUMENTS", file=sys.stderr)
        return 2
    try:
        script = Path(__file__).absolute()
        checked(script)
        digest = build(script.parents[1])
    except BuildRefusal as error:
        print(str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("CB_INTERRUPTED", file=sys.stderr)
        return 130
    except Exception:
        print("CB_INTERNAL", file=sys.stderr)
        return 1
    print("CB_OK " + digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
