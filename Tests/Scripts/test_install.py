"""Exercise replacement and rollback using isolated bundles and command doubles."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallTests(unittest.TestCase):
    def run_install(self, failure=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            destination = root / "Applications" / "Oil Find.app"
            destination.mkdir(parents=True)
            (destination / "old-only").write_text("old")
            source = root / "build" / "Oil Find.app"
            source.mkdir(parents=True)
            (source / "new-only").write_text("new")
            script = (ROOT / "scripts/install.sh").read_text().replace("/Applications", str(root / "Applications"))
            (scripts / "install.sh").write_text(script)
            (scripts / "build-app.sh").write_text("#!/bin/bash\nexit 0\n")
            (scripts / "build-app.sh").chmod(0o755)
            binary = root / "bin"
            binary.mkdir()
            stub = binary / "stub"
            stub.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f: f.write(name + " " + " ".join(args) + "\\n")
failure = os.environ.get("FAILURE")
if name == "ditto": shutil.copytree(*args)
if name == "codesign":
    if "-d" in args: print('designated => identifier "com.oiloil.find"')
    if "--test-requirement" in args:
        if not args[args.index("--test-requirement") + 1].startswith("="): sys.exit(2)
        if failure == "signature": sys.exit(1)
if name == "swift" and failure == "quit" and "--verify-launch" not in args: sys.exit(1)
if name == "swift" and failure == "launch" and "--verify-launch" in args: sys.exit(1)
''')
            stub.chmod(0o755)
            for name in ("codesign", "ditto", "swift", "open"):
                (binary / name).symlink_to(stub)
            log = root / "calls"
            result = subprocess.run(["bash", str(scripts / "install.sh")], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"],
                                             CALLS=str(log), FAILURE=failure))
            files = {p.name for p in destination.iterdir()}
            calls = log.read_text()
            leftovers = list(destination.parent.glob(".oilfind-install.*"))
            return result, files, calls, leftovers

    def test_replacement_removes_old_bundle_files(self):
        result, files, calls, leftovers = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {"new-only"})
        self.assertIn("--verify-launch", calls)
        self.assertFalse(leftovers)

    def test_identity_mismatch_leaves_running_app_untouched(self):
        result, files, calls, leftovers = self.run_install("signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {"old-only"})
        self.assertNotIn("swift ", calls)
        self.assertFalse(leftovers)

    def test_quit_failure_preserves_original(self):
        result, files, calls, leftovers = self.run_install("quit")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {"old-only"})
        self.assertNotIn("open ", calls)
        self.assertFalse(leftovers)

    def test_launch_failure_restores_original(self):
        result, files, calls, leftovers = self.run_install("launch")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {"old-only"})
        self.assertEqual(calls.count("open "), 2)
        self.assertFalse(leftovers)


if __name__ == "__main__":
    unittest.main()
