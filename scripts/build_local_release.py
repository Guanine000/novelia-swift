#!/usr/bin/env python3
"""Build a local unsigned iPhoneOS distribution with matching source and notices.

Does not change versions, commit, push or publish. Update the project version first.
Existing output directories are rejected so previously delivered builds stay immutable.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PIN_FILE = Path("NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
NOTICES = Path("iOSApp/Resources/ThirdPartyLicenses")


def run(command, *, cwd=ROOT, log=None):
    if log:
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"Check/build failed; see {log.name}")
    else:
        subprocess.run(command, cwd=cwd, check=True)


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", *args], cwd=cwd).decode().strip()


def source_files():
    names = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    result = []
    for name in sorted(set(filter(None, names))):
        file = ROOT / name
        if file.is_symlink():
            raise RuntimeError(f"Source symlinks require review: {name}")
        if not file.is_file():
            continue  # staged/unstaged deleted files are not shipped
        if file.name.startswith(".env") or file.suffix in {".p12", ".p8", ".mobileprovision"}:
            raise RuntimeError(f"Credential-like source file requires review: {name}")
        result.append((name, file))
    return result


def fingerprint(files):
    return {name: hashlib.sha256(file.read_bytes()).hexdigest() for name, file in files}


def project_version(text):
    versions = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
    builds = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)
    if len(versions) != 2 or len(set(versions)) != 1 or len(builds) != 2 or len(set(builds)) != 1:
        raise RuntimeError("Debug/Release versions or build numbers differ")
    if not re.fullmatch(r"\d+\.\d+\.\d+", versions[0]) or not re.fullmatch(r"[1-9]\d*", builds[0]):
        raise RuntimeError("Invalid project version/build number")
    return versions[0], builds[0]


def check_derived_data(path):
    # The unstripped Release binary records object-file paths under derived data (debug map),
    # so a derived data directory under a home folder fails the IPA privacy check.
    if re.match(r"/(?:Users|home)/[^/]+/", str(path) + "/"):
        raise RuntimeError("Derived data must be outside home folders (Release binary records its object-file paths)")
    return path


def validate_ipa(ipa, version, build):
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("IPA ZIP verification failed")
        names = archive.namelist()
        info = plistlib.loads(archive.read("Payload/Novelia.app/Info.plist"))
        if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (version, build):
            raise RuntimeError("Built IPA version does not match project")
        if info["MinimumOSVersion"] != "17.0":
            raise RuntimeError("Unexpected minimum iOS version")
        if any("/_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names):
            raise RuntimeError("Expected an unsigned IPA")
        for file in (ROOT / NOTICES).iterdir():
            if not file.is_file():
                continue
            matches = [name for name in names if name.endswith("/ThirdPartyLicenses/" + file.name)]
            if len(matches) != 1 or archive.read(matches[0]) != file.read_bytes():
                raise RuntimeError(f"Missing/mismatched bundled notice: {file.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-dirty", action="store_true", help="Explicitly package the current uncommitted source snapshot")
    parser.add_argument("--simulator", default="iPhone 18 Pro Max", help="Swift package test simulator name or UDID; no UI tests")
    parser.add_argument("--derived-data", type=Path,
                        help="Xcode derived data outside home folders; default is a fresh system temp directory removed after success")
    parser.add_argument("--output", type=Path, help="New ignored directory under this repository's build/ directory")
    args = parser.parse_args()
    version, build = project_version((ROOT / "NoveliaIOS.xcodeproj/project.pbxproj").read_text())
    status = git("status", "--porcelain=v1")
    if status and not args.allow_dirty:
        parser.error("Worktree is dirty; commit first or explicitly use --allow-dirty")
    out = (args.output or ROOT / f"build/local-releases/{version}-{build}").resolve()
    if not out.is_relative_to((ROOT / "build").resolve()):
        parser.error("Output must be under the ignored repository build/ directory")
    if out.exists():
        parser.error("Output already exists; use a new build number/directory instead of replacing it")
    try:
        derived = check_derived_data((args.derived_data or Path(tempfile.gettempdir())).resolve())
    except RuntimeError as error:
        parser.error(str(error))
    if not args.derived_data:
        derived = Path(tempfile.mkdtemp(prefix="novelia-derived-")).resolve()
    out.mkdir(parents=True)
    files = source_files()
    before = fingerprint(files)
    prefix = f"novelia-{version}-test-build{build}" if status else f"novelia-{version}-build{build}"
    try:
        run(["python3", "-I", "scripts/test_local_release.py"], log=out / "packaging-tests.log")
        run(["git", "diff", "--check"])
        run(["git", "diff", "--cached", "--check"])
        run([str(ROOT / "scripts/run_package_tests.sh"), args.simulator,
             "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120"], log=out / "package-tests.log")
        for script in ["test_forum_filters.py", "test_unified_login.py", "test_auth_login_bridge.py", "test_webdav_manifest.py"]:
            run(["python3", "-I", str(ROOT / "scripts" / script)], log=out / f"{script}.log")
        run(["xcodebuild", "-project", "NoveliaIOS.xcodeproj", "-scheme", "Novelia", "-configuration", "Release",
             "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", str(derived),
             "CODE_SIGNING_ALLOWED=NO", "build"], log=out / "release-build.log")
        checkouts = derived / "SourcePackages/checkouts"
        run(["python3", "-I", "scripts/verify_third_party_notices.py", "--source-packages", str(checkouts)], log=out / "licenses.log")
        if before != fingerprint(source_files()):
            raise RuntimeError("Source changed during the build; do not distribute this output")
        ipa = out / f"{prefix}-unsigned.ipa"
        with tempfile.TemporaryDirectory(prefix="novelia-ipa-") as stage:
            payload = Path(stage) / "Payload"
            payload.mkdir()
            run(["ditto", str(derived / "Build/Products/Release-iphoneos/Novelia.app"), str(payload / "Novelia.app")])
            run(["zip", "-qry", str(ipa), "Payload"], cwd=stage)
        validate_ipa(ipa, version, build)
        run(["python3", "-I", "scripts/verify_release_privacy.py", str(ipa)], log=out / "privacy.log")
        source = out / f"{prefix}-source.tar.gz"
        with tarfile.open(source, "w:gz") as archive:
            for name, file in files:
                archive.add(file, arcname="novelia/" + name, recursive=False)
        dependencies = out / f"{prefix}-dependencies.tar.gz"
        pins = json.loads((ROOT / PIN_FILE).read_text())["pins"]
        with tarfile.open(dependencies, "w:gz") as archive:
            for pin in pins:
                # SwiftPM checks a package out under its repository name.
                name = pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
                checkout = checkouts / name
                if git("rev-parse", "HEAD", cwd=checkout) != pin["state"]["revision"]:
                    raise RuntimeError(f"Dependency revision mismatch: {name}")
                names = subprocess.check_output(["git", "ls-files", "-z"], cwd=checkout).decode().split("\0")
                for relative in filter(None, names):
                    archive.add(checkout / relative, arcname=name + "/" + relative, recursive=False)
            archive.add(ROOT / NOTICES, arcname="ThirdPartyLicenses")
            archive.add(ROOT / PIN_FILE, arcname="Package.resolved")
        for file in [source, dependencies]:
            with tarfile.open(file) as archive:
                for member in archive:
                    if member.isfile():
                        archive.extractfile(member).read()
        if before != fingerprint(source_files()):
            raise RuntimeError("Source changed during packaging; do not distribute this output")
        metadata = out / "BUILD.json"
        metadata.write_text(json.dumps({"version": version, "build": build, "configuration": "iPhoneOS Release unsigned",
                                       "commit": git("rev-parse", "HEAD"), "dirty": bool(status), "source": "uncommitted worktree snapshot" if status else "commit",
                                       "source_fingerprint": hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(),
                                       "pins": pins}, indent=2) + "\n")
        artifacts = [ipa, source, dependencies, metadata]
        (out / "SHA256SUMS").write_text("".join(hashlib.sha256(file.read_bytes()).hexdigest() + "  " + file.name + "\n" for file in artifacts))
        (out / "SUCCESS").write_text("All checks passed. IPA, source, dependencies and SHA256SUMS are ready.\n")
        if not args.derived_data:
            shutil.rmtree(derived)
        print(f"Local unsigned build ready: {out}")
    except Exception:
        (out / "FAILED-DO-NOT-DISTRIBUTE").write_text("Build/check failed. This folder is not a distribution. Inspect local logs.\n")
        print(f"Derived data kept for inspection: {derived}")
        raise


if __name__ == "__main__":
    main()
