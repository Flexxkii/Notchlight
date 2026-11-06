#!/usr/bin/env python3
"""Check release metadata and cryptographically verify both update signatures."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def verify(feed, archive):
    root = Path(__file__).resolve().parent.parent
    feed, archive = Path(feed), Path(archive)
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    items = ET.parse(feed).findall('./channel/item')
    assert len(items) == 1, 'Expected exactly the prepared release'
    item = items[0]
    enclosure = item.find('enclosure')
    assert enclosure is not None
    assert item.findtext(namespace + 'version') == info['CFBundleVersion']
    assert item.findtext(namespace + 'shortVersionString') == info['CFBundleShortVersionString']
    assert item.findtext(namespace + 'minimumSystemVersion') == info['LSMinimumSystemVersion']
    assert int(enclosure.attrib['length']) == archive.stat().st_size
    expected = f"https://github.com/Flexxkii/notchlight/releases/download/v{info['CFBundleShortVersionString']}/{archive.name}"
    assert enclosure.attrib['url'] == expected
    tool = root / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    account = os.environ.get('NOTCHLIGHT_UPDATE_KEY_ACCOUNT', 'com.teodor.Notchlight.updates')
    public = subprocess.check_output([str(tool.with_name('generate_keys')), '--account', account, '-p'], text=True).strip()
    assert public == info['SUPublicEDKey'], 'The signing key must match the public key embedded in the app'
    subprocess.run([str(tool), '--account', account, '--verify', str(feed)], check=True)
    subprocess.run([str(tool), '--account', account, '--verify', str(archive), enclosure.attrib[namespace + 'edSignature']], check=True)
    print('Appcast verified: release metadata, archive length, embedded public key, feed signature, and archive signature.')


if __name__ == '__main__':
    verify(*sys.argv[1:])
