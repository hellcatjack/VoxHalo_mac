"""Release App must not silently embed the wrong runtime or omit model terms."""
import hashlib
import json

import pytest

from tools.build_macos_app import APP_BUILD, APP_VERSION, release_metadata


def payload(tmp_path):
    (tmp_path / 'runtime.tar.gz').write_bytes(b'verified-fixture')
    value = {'version': APP_VERSION, 'build': APP_BUILD,
             'runtime_sha256': hashlib.sha256(b'verified-fixture').hexdigest()}
    (tmp_path / 'release.json').write_text(json.dumps(value))
    (tmp_path / 'licenses').mkdir()
    (tmp_path / 'licenses/HY-MT-LICENSE.txt').write_text('fixture license')
    return value


def test_matching_payload(tmp_path):
    value = payload(tmp_path)
    assert release_metadata(tmp_path) == value


def test_tampered_runtime_rejected(tmp_path):
    payload(tmp_path)
    (tmp_path / 'runtime.tar.gz').write_bytes(b'changed')
    with pytest.raises(ValueError, match='SHA-256'):
        release_metadata(tmp_path)


def test_wrong_release_rejected(tmp_path):
    value = payload(tmp_path)
    value['version'] = '0.0.0'
    (tmp_path / 'release.json').write_text(json.dumps(value))
    with pytest.raises(ValueError, match='version'):
        release_metadata(tmp_path)


def test_license_required(tmp_path):
    payload(tmp_path)
    (tmp_path / 'licenses/HY-MT-LICENSE.txt').unlink()
    with pytest.raises(ValueError, match='license'):
        release_metadata(tmp_path)
