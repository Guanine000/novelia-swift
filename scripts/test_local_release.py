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
    def test_preferred_sources_match_runtime_versions_and_have_implementation(self):
        directory = Path(__file__).parent / "vendor-npm-sources"
        packages = [("@juggle/resize-observer", "3.4.0", "unused"), ("approx-string-match", "1.1.0", "unused")]
        self.assertEqual(len(release.verify_preferred_sources(directory, packages)), 2)
        with self.assertRaisesRegex(RuntimeError, "versions"):
            release.verify_preferred_sources(directory, [("@juggle/resize-observer", "3.5.0", "unused")])

    def test_public_source_note_points_to_exact_release_and_artifacts(self):
        note = release.public_source_note("0.12.0", "57", "novelia-0.12.0-build57-unsigned.ipa",
                                          "novelia-0.12.0-build57-source.tar.gz",
                                          "novelia-0.12.0-build57-dependencies.tar.gz")
        self.assertIn("https://github.com/Guanine000/novelia-swift/releases/tag/v0.12.0\n", note)
        for filename in ["novelia-0.12.0-build57-unsigned.ipa", "novelia-0.12.0-build57-source.tar.gz",
                         "novelia-0.12.0-build57-dependencies.tar.gz"]:
            self.assertIn(filename, note)
        self.assertNotIn("releases/latest", note)
        self.assertNotIn("novelia-ios-port", note)

    def test_modified_date_read_from_settings(self):
        self.assertEqual(release.modified_date('    static let modifiedDate = "2026-10-13"\n'), "2026-10-13")
        with self.assertRaises(RuntimeError):
            release.modified_date('static let modifiedDate = "13/10/2026"')
        settings = (Path(__file__).resolve().parents[1] / "iOSApp/Features/Settings/SettingsViews.swift").read_text()
        self.assertRegex(release.modified_date(settings), r"^\d{4}-\d{2}-\d{2}$")

    def test_npm_production_packages_and_integrity(self):
        lock = """lockfileVersion: '6.0'

packages:

  /@juggle/resize-observer@3.4.0:
    resolution: {integrity: sha512-AAAA}
    dev: false

  /babel-loader@8.4.1(@babel/core@7.29.7):
    resolution: {integrity: sha512-BBBB}
    dev: true

  /approx-string-match@1.1.0:
    resolution: {integrity: sha512-CCCC}
    dev: false
"""
        self.assertEqual(release.npm_packages(lock), [("@juggle/resize-observer", "3.4.0", "sha512-AAAA"),
                                                      ("approx-string-match", "1.1.0", "sha512-CCCC")])
        import base64, hashlib
        data = b"package"
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
        self.assertTrue(release.matches_integrity(data, integrity))
        self.assertFalse(release.matches_integrity(data + b"!", integrity))
        self.assertFalse(release.matches_integrity(data, "sha1-" + integrity[7:]))

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
