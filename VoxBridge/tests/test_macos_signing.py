import json
from pathlib import Path
import subprocess

import pytest

from tools import build_macos_app as packaging


@pytest.fixture
def config(monkeypatch, tmp_path):
    monkeypatch.setattr(Path, 'home', classmethod(lambda cls: tmp_path))
    monkeypatch.delenv('LINGOCOVE_SIGNING_IDENTITY', raising=False)
    path = tmp_path / 'Library/Application Support/LingoCove/build-signing.json'
    path.parent.mkdir(parents=True)
    return path


def test_saved_identity_is_reused(config):
    config.write_text(json.dumps({'version': 1, 'identity': 'A' * 40,
                                 'keychain': '/local/login.keychain-db'}))
    assert packaging.signing_configuration() == ('A' * 40, '/local/login.keychain-db')


@pytest.mark.parametrize('saved', [
    {'version': 1, 'identity': '-'}, {'version': 2, 'identity': 'A' * 40},
    {'version': 1, 'identity': None},
    {'version': 1, 'identity': 'A' * 40, 'keychain': 'relative.keychain'},
])
def test_broken_persistent_config_never_falls_back_to_adhoc(config, saved):
    config.write_text(json.dumps(saved))
    with pytest.raises(ValueError, match='Invalid signing'):
        packaging.signing_configuration()


def test_adhoc_must_be_explicit_when_identity_given(config):
    with pytest.raises(ValueError, match='--ad-hoc'):
        packaging.signing_configuration('-')
    with pytest.raises(ValueError, match='cannot be combined'):
        packaging.signing_configuration('certificate', ad_hoc=True)
    assert packaging.signing_configuration(ad_hoc=True) == ('-', None)


def test_explicit_developer_identity_overrides_local_config(config, monkeypatch):
    config.write_text(json.dumps({'version': 1, 'identity': 'A' * 40}))
    monkeypatch.setenv('LINGOCOVE_SIGNING_IDENTITY', 'Developer ID Application: Publisher')
    assert packaging.signing_configuration() == ('Developer ID Application: Publisher', None)
    assert packaging.signing_configuration('B' * 40) == ('B' * 40, None)


def test_missing_key_does_not_retry_adhoc(monkeypatch):
    calls = []
    def unavailable(command, **kwargs):
        calls.append(command)
        raise subprocess.CalledProcessError(1, command)
    monkeypatch.setattr(packaging.subprocess, 'run', unavailable)
    with pytest.raises(subprocess.CalledProcessError):
        packaging.sign_bundle(Path('test.app'), 'A' * 40, '/local/login.keychain-db')
    assert len(calls) == 1 and calls[0][calls[0].index('--sign') + 1] == 'A' * 40


@pytest.mark.parametrize('requirement', ['cdhash H"abc"', 'identifier "org.example"'])
def test_version_hash_or_identifier_only_reference_rejected(monkeypatch, requirement):
    monkeypatch.setattr(packaging.subprocess, 'run', lambda *a, **k:
                        subprocess.CompletedProcess(a[0], 0, '', 'designated => ' + requirement))
    with pytest.raises(ValueError, match='certificate-backed'):
        packaging.designated_requirement(Path('old.app'))


def test_updated_app_must_satisfy_previous_certificate_requirement(monkeypatch):
    requirement = 'identifier "org.example" and certificate leaf = H"' + 'A' * 40 + '"'
    calls = []
    def check(command, **kwargs):
        calls.append(command)
        if '-R' in command:
            raise subprocess.CalledProcessError(3, command)
        return subprocess.CompletedProcess(command, 0)
    monkeypatch.setattr(packaging.subprocess, 'run', check)
    with pytest.raises(subprocess.CalledProcessError):
        packaging.sign_bundle(Path('new.app'), 'B' * 40, None, requirement)
    assert calls[-1] == ['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, 'new.app']
