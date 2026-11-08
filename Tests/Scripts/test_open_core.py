from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE = "OilFind" + "Pro"


class OpenCoreTests(unittest.TestCase):
    def test_personal_build_includes_content_search(self):
        self.assertTrue((ROOT / "Pro" / "Sources" / MODULE / "ContentSearchManager.swift").is_file())
        manifest = (ROOT / "Package.swift").read_text()
        self.assertIn(f'dependencies: ["OilFindApp", "{MODULE}"]', manifest)

    def test_public_module_boundary(self):
        allowed = {"Package.swift", "Sources/OilFind/main.swift"}
        # Include new source files before they have been staged. Never inspect secrets or build products.
        paths = [ROOT / "Package.swift"]
        for directory in ("Sources", "Tests", "scripts", ".github", "Resources"):
            paths.extend(path for path in (ROOT / directory).rglob("*")
                         if path.is_file() and not path.name.startswith(".env"))
        offenders = []
        for path in paths:
            if path.relative_to(ROOT).as_posix() in allowed:
                continue
            try:
                if MODULE in path.read_text():
                    offenders.append(path.relative_to(ROOT).as_posix())
            except UnicodeDecodeError:
                continue
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
