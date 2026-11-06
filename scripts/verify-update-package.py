#!/usr/bin/env python3
"""Validate the updater and local command in a staged, signed app."""
import base64
from pathlib import Path
import plistlib
import subprocess
import sys


def verify(app):
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['SUFeedURL'] == 'https://github.com/Flexxkii/notchlight/releases/latest/download/appcast.xml'
    assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
    assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
    assert info['SUAllowsAutomaticUpdates'] is False
    assert info['SUEnableAutomaticChecks'] is False
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    targets = [app, framework, app / 'Contents/Helpers/notchlight']
    targets += [framework / 'Versions/B' / name for name in [
        'Autoupdate', 'Updater.app', 'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc']]
    teams = set()
    for target in targets:
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True, capture_output=True)
        signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(target)], check=True,
                                   capture_output=True, text=True).stderr
        teams.add(next(line for line in signature.splitlines() if line.startswith('TeamIdentifier=')))
        assert 'runtime' in signature, f'{target}: missing Hardened Runtime'
    assert len(teams) == 1 and 'TeamIdentifier=not set' not in teams
    linked = subprocess.check_output(['otool', '-l', str(app / 'Contents/MacOS/Notchlight')], text=True)
    assert '@executable_path/../Frameworks' in linked
    print('Update package verified: embedded helpers, shared signing team, signed-feed policy, and framework runpath.')


if __name__ == '__main__':
    verify(sys.argv[1])
