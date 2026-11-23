"""Portable source/configuration checks; this does NOT compile Swift or run native tests."""
from pathlib import Path
import json
import plistlib
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]

def validate():
    project = json.loads((ROOT / 'project.json').read_text(encoding='utf-8'))
    assert project['settings']['base']['SWIFT_VERSION'] == '6.0'
    assert project['settings']['base']['CODE_SIGNING_ALLOWED'] == 'NO'
    assert project['options']['deploymentTarget']['iOS'] == '17.0'
    for target in project['targets'].values():
        for source in target['sources']:
            assert (ROOT / (source if isinstance(source, str) else source['path'])).exists(), source
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    orientations = {'UIInterfaceOrientation' + side for side in ('Portrait', 'PortraitUpsideDown', 'LandscapeLeft', 'LandscapeRight')}
    for key in ('UISupportedInterfaceOrientations', 'UISupportedInterfaceOrientations~ipad'):
        assert set(info[key]) == orientations
    assert project['targets']['EclipseReader']['settings']['base'].get('TARGETED_DEVICE_FAMILY',
        project['settings']['base']['TARGETED_DEVICE_FAMILY']) == '1,2'
    assert project['settings']['base']['APP_DISPLAY_NAME'] == 'eclipsereader'
    assert not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)
    assert not list(ROOT.rglob('*.mobileprovision'))
    assert not list(ROOT.rglob('*.p12'))
    privacy = plistlib.loads((ROOT / 'Resources/PrivacyInfo.xcprivacy').read_bytes())
    assert privacy['NSPrivacyTracking'] is False
    path = ROOT / 'Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack_from('>II', data, 16) == (1024, 1024)
    assert data[25] == 2, 'Icon must be RGB without alpha'
    offset = 8
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        content = data[offset + 4:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        assert zlib.crc32(content) & 0xffffffff == crc
        offset += length + 12
    assert offset == len(data)
    for path in ROOT.rglob('*.json'):
        if '.build' not in path.parts and '.tools' not in path.parts:
            json.loads(path.read_text(encoding='utf-8'))
    source = (ROOT / 'Sources/Core/SourceParser.swift').read_text(encoding='utf-8')
    patterns = re.findall(r'#"(.*?)"#', source)
    for pattern in patterns:
        re.compile(pattern) # Cross-engine sanity check only; native ICU tests run in CI.
    swift_files = list((ROOT / 'Sources').rglob('*.swift'))
    assert len(swift_files) >= 10
    print(f'PASS: project paths, JSON, plists, {len(patterns)} regex syntax checks, RGB icon dimensions/CRCs, unsigned configuration')
    print(f'Inspected {len(swift_files)} Swift source files. Swift compilation and native tests require the macOS workflow.')

if __name__ == '__main__':
    validate()
