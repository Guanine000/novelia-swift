#!/usr/bin/env python3
"""Offline checks for the local release script's safety gates."""
import importlib.util
from pathlib import Path
import sys
import unittest
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("local_release", Path(__file__).with_name("build_local_release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class LocalReleaseTests(unittest.TestCase):
    def test_matching_debug_and_release(self):
        text = "MARKETING_VERSION = 0.11.3; CURRENT_PROJECT_VERSION = 49;\n" * 2
        self.assertEqual(release.project_version(text), ("0.11.3", "49"))

    def test_mismatch_and_unsafe_version_rejected(self):
        for text in [
            "MARKETING_VERSION = 0.11.3; CURRENT_PROJECT_VERSION = 49;",
            "MARKETING_VERSION = 0.11.3; CURRENT_PROJECT_VERSION = 49; MARKETING_VERSION = 0.11.2; CURRENT_PROJECT_VERSION = 49;",
            "MARKETING_VERSION = ../../bad; CURRENT_PROJECT_VERSION = 49;" * 2,
            "MARKETING_VERSION = 0.11.3; CURRENT_PROJECT_VERSION = 0;" * 2,
        ]:
            with self.assertRaises(RuntimeError):
                release.project_version(text)

    def test_derived_data_outside_home_folders(self):
        for path in ["/Users/dev/project/build/local-release-cache", "/Users/dev", "/home/dev/cache"]:
            with self.assertRaisesRegex(RuntimeError, "home"):
                release.check_derived_data(Path(path))
        for path in ["/private/var/folders/ab/xyz/T/novelia-derived-1", "/private/tmp/novelia-derived"]:
            self.assertEqual(release.check_derived_data(Path(path)), Path(path))
        import tempfile
        release.check_derived_data(Path(tempfile.gettempdir()).resolve())

    def test_missing_notice_or_wrong_version_rejected(self):
        import plistlib
        import tempfile
        import zipfile
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "test.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/Novelia.app/Info.plist", plistlib.dumps({
                    "CFBundleShortVersionString": "0.11.3", "CFBundleVersion": "49", "MinimumOSVersion": "17.0"}))
            with self.assertRaisesRegex(RuntimeError, "notice"):
                release.validate_ipa(ipa, "0.11.3", "49")
            with self.assertRaisesRegex(RuntimeError, "version"):
                release.validate_ipa(ipa, "0.11.3", "50")


if __name__ == "__main__":
    unittest.main()
