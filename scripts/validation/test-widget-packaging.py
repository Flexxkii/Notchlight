#!/usr/bin/env python3
"""Packaging contract tests; no signing identity or production app is needed."""

import copy
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("widget_package", SCRIPTS / "verify-widget-package.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class WidgetPackagingTests(unittest.TestCase):
    def setUp(self):
        group = "TESTTEAM.com.teodor.Notchlight.shared"
        info = {"CFBundleIdentifier": "com.teodor.Notchlight", "NotchlightAppGroup": group,
                "CFBundleShortVersionString": "1.2.1", "CFBundleVersion": "8"}
        entitlements = {"com.apple.security.application-groups": [group]}
        self.host = (info, entitlements, "TESTTEAM")
        self.extension = copy.deepcopy(self.host)
        self.extension[0]["CFBundleIdentifier"] += ".Widgets"
        self.extension[1]["com.apple.security.app-sandbox"] = True

    def test_complete_configuration_passes(self):
        PACKAGE.validate_configuration(self.host, self.extension)

    def test_missing_or_wrong_group_fails_for_either_bundle(self):
        for index in (0, 1):
            for group in (None, "OTHERTEAM.com.teodor.Notchlight.shared"):
                with self.subTest(bundle=index, group=group):
                    bundles = copy.deepcopy([self.host, self.extension])
                    bundles[index][0]["NotchlightAppGroup"] = group
                    with self.assertRaisesRegex(PACKAGE.PackageError, "NotchlightAppGroup"):
                        PACKAGE.validate_configuration(*bundles)

    def test_missing_or_wrong_signed_entitlements_fail(self):
        for index in (0, 1):
            for groups in (None, [], ["OTHERTEAM.com.teodor.Notchlight.shared"]):
                with self.subTest(bundle=index, groups=groups):
                    bundles = copy.deepcopy([self.host, self.extension])
                    bundles[index][1]["com.apple.security.application-groups"] = groups
                    with self.assertRaisesRegex(PACKAGE.PackageError, "signed app-group entitlement"):
                        PACKAGE.validate_configuration(*bundles)

    def test_mismatched_team_fails(self):
        extension = (*self.extension[:2], "OTHERTEAM")
        with self.assertRaisesRegex(PACKAGE.PackageError, "same team"):
            PACKAGE.validate_configuration(self.host, extension)

    def test_sandbox_is_required(self):
        self.extension[1].pop("com.apple.security.app-sandbox")
        with self.assertRaisesRegex(PACKAGE.PackageError, "sandbox"):
            PACKAGE.validate_configuration(self.host, self.extension)

    def test_version_mismatch_fails(self):
        self.extension[0]["CFBundleVersion"] = "7"
        with self.assertRaisesRegex(PACKAGE.PackageError, "CFBundleVersion"):
            PACKAGE.validate_configuration(self.host, self.extension)

    def test_missing_identity_preserves_existing_bundle(self):
        # Run the real entry points in an isolated layout. These must fail
        # before compilation or staging, even if a previous app is present.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            app = root / "build/Notchlight.app"
            app.mkdir(parents=True)
            sentinel = app / "preserve-me"
            sentinel.write_text("previous working bundle")
            for script in ("build-app.sh", "build-widgets.sh", "package-release.sh"):
                shutil.copy2(SCRIPTS / script, scripts / script)
            for script in ("build-app.sh", "build-widgets.sh", "package-release.sh"):
                for identity in (None, "", "-"):
                    with self.subTest(script=script, identity=identity):
                        environment = dict(os.environ)
                        environment.pop("NOTCHLIGHT_SIGNING_IDENTITY", None)
                        if identity is not None:
                            environment["NOTCHLIGHT_SIGNING_IDENTITY"] = identity
                        arguments = [str(scripts / script)]
                        if script == "build-widgets.sh":
                            arguments.append(str(app))
                        result = subprocess.run(arguments, env=environment, capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("NOTCHLIGHT_SIGNING_IDENTITY", result.stderr)
                        self.assertEqual(sentinel.read_text(), "previous working bundle")
                        self.assertEqual(list(root.joinpath("build").iterdir()), [app])


if __name__ == "__main__":
    unittest.main()
