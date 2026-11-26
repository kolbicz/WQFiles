#!/usr/bin/env python3
import os
import plistlib
import stat
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build.sh"


FAKE_XCRUN = r'''#!/bin/sh
set -eu
if [ "$1" = "--sdk" ] && [ "$3" = "--show-sdk-path" ]; then
    printf '%s\n' "$FAKE_SDK"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "clang" ]; then
    if [ -n "${FAKE_CLANG_ARGS:-}" ]; then printf '%s\n' "$@" > "$FAKE_CLANG_ARGS"; fi
    output=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "-o" ]; then output=$argument; fi
        previous=$argument
    done
    test -n "$output"
    printf '#!/bin/sh\nexit 0\n' > "$output"
    chmod +x "$output"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "--find" ]; then
    printf '%s\n' "$FAKE_SDK/toolchain/usr/bin/$4"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "swiftc" ]; then
    output=
    constants=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "-o" ]; then output=$argument; fi
        if [ "$previous" = "-emit-const-values-path" ]; then constants=$argument; fi
        previous=$argument
    done
    test -n "$output" && test -n "$constants"
    printf 'fixture object\n' > "$output"
    printf '[]\n' > "$constants"
    exit 0
fi
if [ "$1" = "appintentsmetadataprocessor" ]; then
    output=
    sources=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--output" ]; then output=$argument; fi
        if [ "$previous" = "--source-file-list" ]; then sources=$argument; fi
        previous=$argument
    done
    test -n "$output"
    if [ "${FAKE_NO_INTENTS:-0}" != 1 ]; then
        mkdir -p "$output/Metadata.appintents"
        if [ "${FAKE_EMPTY_INTENTS:-0}" = 1 ]; then
            printf '{"actions":{}}\n' > "$output/Metadata.appintents/extract.actionsdata"
        else
            # One entry per action the Swift source declares, like the real tool.
            sed -n 's/^struct \([A-Za-z0-9_]*\): AppIntent.*/"\1"/p' "$(cat "$sources")" > "$output/Metadata.appintents/extract.actionsdata"
        fi
    fi
    exit 0
fi
if [ "$1" = "actool" ]; then
    compile=
    partial=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--compile" ]; then compile=$argument; fi
        if [ "$previous" = "--output-partial-info-plist" ]; then partial=$argument; fi
        previous=$argument
    done
    test -n "$compile" && test -n "$partial"
    test -f "$2/AppIcon.appiconset/AppIcon1024-dark.png"
    test -f "$2/AppIcon.appiconset/AppIcon1024-tinted.png"
    printf 'fixture catalog\n' > "$compile/Assets.car"
    printf 'fixture icon\n' > "$compile/AppIcon60x60@2x.png"
    cat > "$partial" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>
<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>
</dict></plist>
PLIST
    exit 0
fi
exit 2
'''

FAKE_CODESIGN = r'''#!/bin/sh
set -eu
last=
for argument in "$@"; do last=$argument; done
if [ "$1" = "-f" ]; then
    entitlements=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--entitlements" ]; then entitlements=$argument; fi
        previous=$argument
    done
    mkdir -p "$last/_CodeSignature"
    printf 'fixture signature\n' > "$last/_CodeSignature/CodeResources"
    if [ "${FAKE_DROP_GROUP:-0}" = 1 ]; then
        printf '<plist version="1.0"><dict/></plist>\n' > "$last/.fake-entitlements.plist"
    else
        cp "$entitlements" "$last/.fake-entitlements.plist"
    fi
    exit 0
fi
if [ "$1" = "--verify" ]; then
    test -x "$last/WQFiles"
    test -f "$last/_CodeSignature/CodeResources"
    exit 0
fi
if [ "$1" = "-d" ]; then
    /usr/bin/plutil -convert xml1 -o - "$last/.fake-entitlements.plist"
    exit 0
fi
exit 2
'''

FAKE_ZIP = r'''#!/bin/sh
set -eu
if [ "${FAKE_ZIP_FAIL:-0}" = 1 ]; then
    echo 'injected zip failure' >&2
    exit 9
fi
exec /usr/bin/zip "$@"
'''

FAKE_UNZIP = r'''#!/bin/sh
set -eu
exec /usr/bin/unzip "$@"
'''


class DeclaredTypeTests(unittest.TestCase):
    def test_apps_manager_backups_are_imported_as_zip(self):
        # Import as Backup's picker offers ZIPs; an .adbk is one (issue #19).
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        adbk = [t for t in info.get("UTImportedTypeDeclarations", [])
                if "adbk" in t.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])]
        self.assertEqual(len(adbk), 1)
        self.assertIn("public.zip-archive", adbk[0]["UTTypeConformsTo"])


class StagedBuildTests(unittest.TestCase):
    def _fake_environment(self, directory: Path):
        fake_bin = directory / "bin"
        fake_bin.mkdir()
        fake_sdk = directory / "sdk"
        fake_sdk.mkdir()
        for name, content in {
            "xcrun": FAKE_XCRUN,
            "codesign": FAKE_CODESIGN,
            "zip": FAKE_ZIP,
            "unzip": FAKE_UNZIP,
        }.items():
            path = fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["FAKE_SDK"] = str(fake_sdk)
        environment["WQ_SKIP_PREFLIGHT"] = "1"
        return environment

    def test_default_output_stays_in_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "project"
            project.mkdir()
            for name in ("build.sh", "Info.plist", "entitlements.plist", "WQShortcuts.swift"):
                shutil.copy2(ROOT / name, project / name)
            (project / "icons").mkdir()
            for name in ("AppIcon1024.png", "AppIcon1024-dark.png", "AppIcon1024-tinted.png"):
                (project / "icons" / name).write_bytes(b"fixture icon")
            environment = self._fake_environment(root)
            environment.pop("WQFILES_FINAL_IPA", None)
            result = subprocess.run(
                [str(project / "build.sh")], cwd=project, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((project / "WQFiles.ipa").is_file())
            self.assertFalse((root / "WQFiles.ipa").exists())

    def _project_copy(self, root: Path, runner: str | None, executable: bool = True) -> Path:
        project = root / "project"
        project.mkdir()
        for name in ("build.sh", "Info.plist", "entitlements.plist", "WQShortcuts.swift"):
            shutil.copy2(ROOT / name, project / name)
        (project / "icons").mkdir()
        for name in ("AppIcon1024.png", "AppIcon1024-dark.png", "AppIcon1024-tinted.png"):
            (project / "icons" / name).write_bytes(b"fixture icon")
        (project / "tests").mkdir()
        if runner is not None:
            path = project / "tests" / "run_all_tests.sh"
            path.write_text(runner, encoding="utf-8")
            mode = path.stat().st_mode
            path.chmod(mode | stat.S_IXUSR if executable else mode & ~(stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        return project

    def _run_preflight_case(self, runner, executable=True, skip=False):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        project = self._project_copy(root, runner, executable)
        environment = self._fake_environment(root)
        environment.pop("WQFILES_FINAL_IPA", None)
        if skip:
            environment["WQ_SKIP_PREFLIGHT"] = "1"
        else:
            environment.pop("WQ_SKIP_PREFLIGHT", None)
        environment["PREFLIGHT_MARKER"] = str(root / "preflight-ran")
        result = subprocess.run(
            [str(project / "build.sh")], cwd=project, env=environment,
            text=True, capture_output=True, check=False, timeout=120,
        )
        return result, project, root / "preflight-ran"

    MARKER_RUNNER = '#!/usr/bin/env bash\ntouch "$PREFLIGHT_MARKER"\n'

    def test_missing_preflight_runner_fails_closed(self):
        result, project, marker = self._run_preflight_case(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preflight runner missing", result.stderr)
        self.assertFalse((project / "WQFiles.ipa").exists())

    def test_non_executable_preflight_runner_still_runs(self):
        result, project, marker = self._run_preflight_case(self.MARKER_RUNNER, executable=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists(), "non-executable runner was skipped")
        self.assertTrue((project / "WQFiles.ipa").is_file())

    def test_executable_preflight_runner_runs(self):
        result, project, marker = self._run_preflight_case(self.MARKER_RUNNER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists())
        self.assertTrue((project / "WQFiles.ipa").is_file())

    def test_failing_preflight_runner_blocks_build(self):
        result, project, marker = self._run_preflight_case('#!/usr/bin/env bash\nexit 3\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preflight failed", result.stderr)
        self.assertFalse((project / "WQFiles.ipa").exists())

    def test_explicit_skip_bypasses_preflight_with_warning(self):
        for runner in (None, self.MARKER_RUNNER):
            with self.subTest(runner=runner is not None):
                result, project, marker = self._run_preflight_case(runner, skip=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn("preflight SKIPPED", result.stderr)
                self.assertTrue((project / "WQFiles.ipa").is_file())

    def test_compiles_for_the_info_plist_minimum_os(self):
        # Executable policy check: the deployment target build.sh actually
        # passes to clang must equal the documented 26.0 and Info.plist.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "out" / "WQFiles.ipa"
            final.parent.mkdir()
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment["FAKE_CLANG_ARGS"] = str(root / "clang-args")
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False, timeout=120,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = (root / "clang-args").read_text(encoding="utf-8").splitlines()
            with (ROOT / "Info.plist").open("rb") as plist_file:
                minimum = plistlib.load(plist_file)["MinimumOSVersion"]
            self.assertEqual(minimum, "26.0")
            targets = [a for a in arguments if a.startswith("-miphoneos-version-min=")]
            self.assertEqual(targets, ["-miphoneos-version-min=26.0"])

    def test_success_publishes_only_a_validated_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            final.write_bytes(b"previous release")
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(final.read_bytes(), b"previous release")
            with zipfile.ZipFile(final) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn("Payload/WQFiles.app/WQFiles", archive.namelist())
                self.assertIn("Payload/WQFiles.app/Info.plist", archive.namelist())
                self.assertIn("Payload/WQFiles.app/Assets.car", archive.namelist())
                info = plistlib.loads(archive.read("Payload/WQFiles.app/Info.plist"))
                self.assertEqual(info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"], "AppIcon")
                self.assertNotIn("CFBundleIcons~ipad", info)

    def test_zip_failure_preserves_existing_final_ipa_and_cleans_siblings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment["FAKE_ZIP_FAIL"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)
            self.assertEqual(list(final.parent.glob(".WQFiles.ipa.*")), [])
            self.assertEqual(list(final.parent.glob(".WQFiles-build.*")), [])

    def test_missing_signed_app_group_preserves_existing_final_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment["FAKE_DROP_GROUP"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)

    def _build_with(self, variable):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment[variable] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            return result, final.exists()

    def test_missing_shortcuts_metadata_fails_the_build(self):
        result, published = self._build_with("FAKE_NO_INTENTS")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Shortcuts metadata", result.stderr + result.stdout)
        self.assertFalse(published)

    def test_shortcuts_metadata_without_the_actions_fails_the_build(self):
        result, published = self._build_with("FAKE_EMPTY_INTENTS")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not list", result.stderr + result.stdout)
        self.assertFalse(published)


if __name__ == "__main__":
    unittest.main()
