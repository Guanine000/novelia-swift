#!/usr/bin/env python3
"""离线检查本地发布脚本的安全关卡。"""
import importlib.util
from pathlib import Path
import sys
import unittest
import tempfile
import subprocess
from unittest import mock
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("local_release", Path(__file__).with_name("build_local_release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class LocalReleaseTests(unittest.TestCase):
    def test_stage_timing_recognizes_cache_hit_after_toolchain_banner(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'stage.log'
            release.run([sys.executable, '-c', "print('toolchain banner'); print('Validation cache: HIT; exact source, environment and command matched')"], log=log)
            self.assertTrue(release.TIMINGS[-1]['reused'])

    def test_main_dispatches_to_build_with_persistent_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "NoveliaIOS.xcodeproj").mkdir()
            (root / "NoveliaIOS.xcodeproj/project.pbxproj").write_text("MARKETING_VERSION = 1.1.0; CURRENT_PROJECT_VERSION = 101;\n" * 2)
            settings = root / "iOSApp/Features/Settings/SettingsViews.swift"
            settings.parent.mkdir(parents=True)
            settings.write_text('static let modifiedDate = "2026-10-22"')
            with mock.patch.object(release, "ROOT", root), mock.patch.object(release, "git", return_value="dirty"), \
                 mock.patch.object(release.cache, "cache_directory", return_value=root / "cache"), \
                 mock.patch.object(release, "perform_build") as build, \
                 mock.patch.object(sys, "argv", ["build_local_release.py", "--allow-dirty"]):
                release.main()
                self.assertEqual(build.call_args.args[1:3], ("1.1.0", "101"))
                self.assertEqual(build.call_args.args[5], (root / "cache/release-derived").resolve())

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


class ValidationCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.source = self.root / "input.txt"
        self.source.write_text("one")
        self.cache = Path(self.temporary.name) / "cache"
        self.log = Path(self.temporary.name) / "test.log"
        self.counter = Path(self.temporary.name) / "counter"
        self.command = [sys.executable, "-c", "from pathlib import Path; p=Path(__import__('sys').argv[1]); p.write_text(p.read_text()+'x' if p.exists() else 'x'); print('passed')", str(self.counter)]

    def tearDown(self):
        self.temporary.cleanup()

    def checks(self, identity="toolchain-one", force=False):
        return release.cache.Checks(self.root, self.cache, identity, force)

    def test_exact_input_reuses_success_but_source_command_and_toolchain_changes_do_not(self):
        self.checks().run(self.command, self.log)
        checks = self.checks()
        checks.run(self.command, self.log)
        self.assertTrue(checks.results[0]["reused"])
        self.assertEqual(self.counter.read_text(), "x")
        self.source.write_text("two")
        self.checks().run(self.command, self.log)
        self.checks(identity="toolchain-two").run(self.command, self.log)
        self.checks(identity="toolchain-two").run(self.command + ["-only-testing:subset"], self.log)
        self.assertEqual(self.counter.read_text(), "xxxx")

    def test_executor_call_metadata_does_not_invalidate_success(self):
        with mock.patch.dict('os.environ', {'CODEX_TOOL_CALL_ID':'one'}):
            self.checks().run(self.command, self.log)
        with mock.patch.dict('os.environ', {'CODEX_TOOL_CALL_ID':'two'}):
            self.checks().run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), 'x')

    def test_environment_change_invalidates_success(self):
        self.checks().run(self.command, self.log)
        with mock.patch.dict("os.environ", {"SDKROOT": "different-sdk"}):
            self.checks().run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xx")

    def test_corrupt_or_missing_log_reexecutes(self):
        self.checks().run(self.command, self.log)
        next(self.cache.glob("*/output.log")).write_text("forged success")
        self.checks().run(self.command, self.log)
        next(self.cache.glob("*/output.log")).unlink()
        self.checks().run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xxx")

    def test_force_reruns_and_failure_cannot_reuse_earlier_success(self):
        self.checks().run(self.command, self.log)
        self.checks(force=True).run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xx")
        real_run = subprocess.run
        def fail_only_check(command, *args, **kwargs):
            if command == self.command: return subprocess.CompletedProcess(command, 1)
            return real_run(command, *args, **kwargs)
        with mock.patch.object(release.cache.subprocess, "run", side_effect=fail_only_check):
            with self.assertRaisesRegex(RuntimeError, "failed"):
                self.checks(force=True).run(self.command, self.log)
        self.assertFalse(list(self.cache.glob("*/success.json")))
        self.checks().run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xxx")

    def test_source_mutation_during_check_is_not_saved(self):
        checks = self.checks()
        command = [sys.executable, "-c", "from pathlib import Path; Path('input.txt').write_text('changed')"]
        with self.assertRaisesRegex(RuntimeError, "changed during"):
            checks.run(command, self.log)
        self.assertFalse(list(self.cache.glob("*/success.json")))

    def test_expired_receipt_is_not_reused(self):
        import json
        self.checks().run(self.command, self.log)
        receipt = next(self.cache.glob("*/success.json"))
        data = json.loads(receipt.read_text())
        data['completedAt'] -= 24 * 60 * 60 + 1
        receipt.write_text(json.dumps(data))
        self.checks().run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xx")

    def test_dependency_validation_is_required_before_reuse_and_before_saving(self):
        checks = release.cache.Checks(self.root, self.cache, "identity", validator=lambda: True)
        checks.run(self.command, self.log)
        checks = release.cache.Checks(self.root, self.cache, "identity", validator=lambda: False)
        with self.assertRaisesRegex(RuntimeError, "pinned revisions"):
            checks.run(self.command, self.log)
        self.assertFalse(list(self.cache.glob("*/success.json")))
        self.assertEqual(self.counter.read_text(), "xx")

    def test_concurrent_identical_checks_run_once(self):
        helper = Path(release.cache.__file__)
        command = self.command.copy()
        command[2] = "import time; time.sleep(0.2); " + command[2]
        code = "import importlib.util,sys,json; from pathlib import Path; s=importlib.util.spec_from_file_location('cache',sys.argv[1]); c=importlib.util.module_from_spec(s); s.loader.exec_module(c); c.Checks(Path(sys.argv[2]),Path(sys.argv[3]),'same').run(json.loads(sys.argv[5]),Path(sys.argv[4]))"
        args = [sys.executable, '-I', '-B', '-c', code, str(helper), str(self.root), str(self.cache), str(self.log)]
        import json
        first = subprocess.Popen(args + [json.dumps(command)], stdout=subprocess.DEVNULL)
        second = subprocess.Popen(args + [json.dumps(command)], stdout=subprocess.DEVNULL)
        self.assertEqual(first.wait(timeout=10), 0)
        self.assertEqual(second.wait(timeout=10), 0)
        self.assertEqual(self.counter.read_text(), 'x')

    def test_modified_dependency_is_rejected_and_wrong_revision_is_not_ready(self):
        import json
        directory = Path(self.temporary.name) / 'checkouts'
        checkout = directory / 'example'
        checkout.mkdir(parents=True)
        pinfile = Path(self.temporary.name) / 'pins.json'
        pinfile.write_text(json.dumps({'pins':[{'location':'https://example.test/example.git','state':{'revision':'missing'}}]}))
        subprocess.run(['git','init','-q',str(checkout)],check=True)
        (checkout/'file').write_text('one')
        subprocess.run(['git','add','file'],cwd=checkout,check=True)
        subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.test','commit','-qm','fixture'],cwd=checkout,check=True)
        self.assertFalse(release.cache.checkouts_ready(directory,pinfile))
        head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=checkout,text=True).strip()
        pinfile.write_text(json.dumps({'pins':[{'location':'https://example.test/example.git','state':{'revision':head}}]}))
        self.assertTrue(release.cache.checkouts_ready(directory,pinfile))
        (checkout/'file').write_text('changed')
        with self.assertRaisesRegex(RuntimeError,'modified'):
            release.cache.checkouts_ready(directory,pinfile)

    def test_checkout_cache_is_stable_and_isolated(self):
        self.assertEqual(release.cache.cache_directory(self.root), release.cache.cache_directory(self.root))
        self.assertNotEqual(release.cache.cache_directory(self.root), release.cache.cache_directory(self.root / "other"))
        release.check_derived_data(release.cache.cache_directory(self.root))

    def test_filtered_checks_and_runtime_identity_do_not_satisfy_full_suite(self):
        self.checks(identity={"runtime": "one"}).run(self.command + ["subset"], self.log)
        self.checks(identity={"runtime": "one"}).run(self.command, self.log)
        self.checks(identity={"runtime": "two"}).run(self.command, self.log)
        self.assertEqual(self.counter.read_text(), "xxx")


if __name__ == "__main__":
    unittest.main()
