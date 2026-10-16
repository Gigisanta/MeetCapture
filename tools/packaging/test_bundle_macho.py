"""Exercise relocation with real Mach-O files, without installed packages."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bundle_macho", Path(__file__).with_name("bundle_macho.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@unittest.skipUnless(sys.platform == "darwin", "Mach-O tools require macOS")
class BundleTests(unittest.TestCase):
    def test_relocates_dependencies_without_resolving_or_changing_library_identity(self):
        with tempfile.TemporaryDirectory(prefix="meetcapture-bundle-") as directory:
            root = Path(directory)
            library = root / "libanswer.dylib"
            identity = "@rpath/identity-with-no-file.dylib"
            (root / "answer.c").write_text("int answer(void) { return 42; }\n")
            (root / "main.c").write_text(
                '#include <stdio.h>\nint answer(void);\nint main(void) { printf("%d", answer()); }\n')
            subprocess.run(["clang", "-dynamiclib", str(root / "answer.c"),
                            "-install_name", identity, "-o", str(library)], check=True)
            executable = root / "probe"
            subprocess.run(["clang", str(root / "main.c"), str(library),
                            "-Wl,-headerpad_max_install_names",
                            "-o", str(executable)], check=True)
            subprocess.run(["install_name_tool", "-change", identity, str(library), str(executable)], check=True)
            original = library.read_bytes()
            bundled = root / "App/Contents/Resources/probe"
            frameworks = root / "App/Contents/Frameworks"
            module.bundle(executable, bundled, frameworks, "-")
            self.assertEqual(library.read_bytes(), original)
            library.unlink()  # The relocated app must no longer need the source.
            self.assertEqual(subprocess.check_output([str(bundled)], text=True), "42")
            self.assertEqual(module.dylib_identity(frameworks / library.name), identity)


if __name__ == "__main__":
    unittest.main()
