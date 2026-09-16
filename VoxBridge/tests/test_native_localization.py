from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
LOCALES = {'zh', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi'}


def test_native_catalogs_have_complete_messages_and_matching_arguments():
    for name in ('native', 'native-errors', 'model-manager'):
        catalog = json.loads((ROOT / 'voxbridge/ui_locales' / f'{name}.json').read_text())
        assert catalog['version'] == 1
        assert catalog['messages']
        for source, translations in catalog['messages'].items():
            assert set(translations) == LOCALES, source
            assert translations['zh'] == source
            placeholders = sorted(re.findall(r'\{\d+\}', source))
            for locale, translated in translations.items():
                assert translated.strip(), (source, locale)
                assert sorted(re.findall(r'\{\d+\}', translated)) == placeholders, (source, locale)


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
@pytest.mark.parametrize('check', ['NativeLocalizationChecks', 'NativeLocalizedViewsChecks'])
def test_native_localization_behavior(check, tmp_path):
    source = ROOT / 'deploy/macos/app'
    files = [source / 'NativeLocalization.swift']
    if check == 'NativeLocalizedViewsChecks':
        files.append(source / 'NativeLocalizedViews.swift')
    executable = tmp_path / check
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-framework', 'AppKit',
                    *map(str, files), str(ROOT / 'tests/macos' / f'{check}.swift'),
                    '-o', str(executable)], check=True, capture_output=True, text=True)
    subprocess.run([str(executable)], check=True, capture_output=True, text=True)
