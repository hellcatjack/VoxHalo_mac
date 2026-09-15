"""The release payload must be independent of developer paths and private data."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import subprocess
import sys
import tarfile
from types import SimpleNamespace

import pytest

BUILDER = Path(__file__).resolve().parents[2] / 'scripts/build_desktop_release.py'


def builder():
    assert BUILDER.is_file(), 'A portable desktop release builder is required'
    spec = importlib.util.spec_from_file_location('build_desktop_release', BUILDER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write(root, name, content='public'):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


def source_fixture(root):
    for name in (
        'VoxBridge/voxbridge/__init__.py', 'VoxBridge/voxbridge/language_catalog.json',
        'VoxBridge/voxbridge/tts/vendor/hls.LICENSE.txt',
        'VoxBridge/tools/macos_service.py', 'VoxBridge/tools/repair_kokoro_speed.py',
        'VoxBridge/macos.sh', 'VoxBridge/LICENSE', 'VoxBridge/README.md',
        'VoxBridge/pyproject.toml', 'scripts/install_desktop.py',
        'scripts/setup_assets.py', 'scripts/runtime-assets.json', 'scripts/desktop-wheels.json',
        'scripts/model-tools.lock', 'scripts/release-runtime.lock', 'LICENSE',
        'docs/THIRD_PARTY.md', 'licenses/HY-MT-LICENSE.txt',
    ):
        write(root, name)


def test_service_staging_does_not_distribute_private_or_generated_files(tmp_path):
    source, target = tmp_path / 'source', tmp_path / 'payload'
    source_fixture(source)
    forbidden = (
        'VoxBridge/logs/service.log', 'VoxBridge/artifacts/auth.json',
        'VoxBridge/models/large.onnx', '.env', 'VoxBridge/config/private.json',
        'VoxBridge/voxbridge/__pycache__/engine.pyc', 'VoxBridge/tests/test_engine.py',
        'VoxBridge/tools/build_macos_app.py', 'runtime/model-tools/private.pth',
    )
    for name in forbidden:
        write(source, name, 'PRIVATE')
    builder().stage_service(source, target, source / 'licenses')
    assert (target / 'VoxBridge/tools/macos_service.py').read_text() == 'public'
    assert (target / 'VoxBridge/voxbridge/tts/vendor/hls.LICENSE.txt').exists()
    assert (target / 'scripts/install_desktop.py').exists()
    assert (target / 'licenses/HY-MT-LICENSE.txt').exists()
    assert all(not (target / name).exists() for name in forbidden)
    assert all('PRIVATE' not in path.read_text() for path in target.rglob('*') if path.is_file())


def test_staging_rejects_source_symlink_to_private_file(tmp_path):
    source_fixture(tmp_path / 'source')
    private = write(tmp_path, 'secret.json', 'PRIVATE')
    (tmp_path / 'source/VoxBridge/voxbridge/secrets.py').symlink_to(private)
    with pytest.raises(ValueError, match='symlink'):
        builder().stage_service(tmp_path / 'source', tmp_path / 'payload', tmp_path / 'source/licenses')


def test_venv_portability_replaces_external_interpreter_and_home(tmp_path):
    root = tmp_path / 'a path with spaces'
    python = write(root, 'runtime/python/bin/python3.12')
    venv = root / '.venv'
    write(venv, 'pyvenv.cfg', 'home = /developer/private/python/bin\ninclude-system-site-packages = false\n')
    write(venv, 'bin/activate', 'VIRTUAL_ENV=/developer/private')
    (venv / 'bin/python').symlink_to('/developer/private/python3.12')
    (venv / 'bin/python3').symlink_to('python')
    builder().make_venv_portable(venv, root / 'runtime/python')
    assert (venv / 'bin/python').readlink() == Path('../../runtime/python/bin/python3.12')
    assert (venv / 'bin/python').resolve() == python.resolve()
    assert '/developer/' not in (venv / 'pyvenv.cfg').read_text()
    assert not (venv / 'bin/activate').exists()


@pytest.mark.parametrize('path,content', [
    ('.venv/lib/python3.12/site-packages/local.pth', '/Users/developer/project\n'),
    ('.venv/lib/python3.12/site-packages/__editable__.package.pth', 'import __editable___package_finder\n'),
])
def test_payload_audit_rejects_external_and_editable_pth_files(tmp_path, path, content):
    write(tmp_path, path, content)
    with pytest.raises(ValueError, match='pth'):
        builder().audit_payload(tmp_path)


def test_payload_audit_rejects_links_outside_archive(tmp_path):
    (tmp_path / 'escape').symlink_to('../secret')
    with pytest.raises(ValueError, match='symlink'):
        builder().audit_payload(tmp_path)


def test_archive_is_self_contained_and_metadata_matches_actual_bytes(tmp_path):
    root = tmp_path / 'payload'
    write(root, 'VoxBridge/voxbridge/__init__.py', 'abc')
    manifest = write(root, 'scripts/runtime-assets.json', json.dumps({
        'assets': [{'size': 5}, {'size': 7}], 'generated': {'path': 'unused'},
    }))
    output = tmp_path / 'release'
    metadata = builder().archive_payload(root, output, version='1.8.0', build='22')
    archive = output / 'runtime.tar.gz'
    assert metadata['runtime_sha256'] == hashlib.sha256(archive.read_bytes()).hexdigest()
    assert metadata['runtime_size'] == archive.stat().st_size
    assert metadata['runtime_unpacked_bytes'] == 3 + manifest.stat().st_size
    assert metadata['model_bytes'] == 12
    assert metadata['manifest_sha256'] == hashlib.sha256(manifest.read_bytes()).hexdigest()
    assert metadata['version'] == '1.8.0' and metadata['build'] == '22'
    assert json.loads((output / 'release.json').read_text()) == metadata
    with tarfile.open(archive) as stream:
        stream.extractall(tmp_path / 'relocated copy', filter='data')
    assert (tmp_path / 'relocated copy/VoxBridge/voxbridge/__init__.py').read_text() == 'abc'


@pytest.mark.parametrize('loads,libraries,reason', [
    ('cmd LC_BUILD_VERSION\n minos 26.0\n', '', 'requires macOS'),
    ('cmd LC_VERSION_MIN_MACOSX\n version 14.0\n', '\t/opt/homebrew/lib/libvoice.dylib (compatibility version 1.0.0, current version 1.0.0)', 'external developer library'),
    ('cmd LC_RPATH\n path /Users/developer/build/lib (offset 12)\n', '', 'external runtime search path'),
])
def test_native_audit_rejects_unsupported_minimum_or_developer_libraries(loads, libraries, reason):
    with pytest.raises(ValueError, match=reason):
        builder().check_macho_output(Path('engine.so'), loads, libraries, '14.2')


def test_native_audit_allows_system_and_relative_libraries():
    builder().check_macho_output(Path('engine.so'), 'cmd LC_BUILD_VERSION\n minos 14.0\n tool CLANG\n version 22.1.3\n',
                                '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
                                '\t@loader_path/libvoice.dylib (compatibility version 1.0.0)', '14.2')


def test_downloaded_components_are_absent_from_distributed_payload(tmp_path):
    site = tmp_path / '.venv/lib/python3.12/site-packages'
    for name in ('imageio_ffmpeg/binaries/ffmpeg', 'imageio_ffmpeg-0.6.0.dist-info/METADATA',
                 'espeakng_loader/libespeak-ng.dylib', 'espeakng_loader-0.2.4.dist-info/METADATA',
                 'numpy/__init__.py'):
        write(site, name)
    builder().remove_downloaded_components(tmp_path)
    assert (site / 'numpy/__init__.py').exists()
    assert not list(site.glob('imageio_ffmpeg*'))
    assert not list(site.glob('espeakng_loader*'))


@pytest.mark.skipif(platform.system() != 'Darwin', reason='Mac release binary repair')
def test_native_repair_removes_build_rpath_and_retains_portable_rpath(tmp_path):
    source = write(tmp_path, 'tiny.c', 'int meaning(void) { return 42; }\n')
    library = tmp_path / 'libtiny.dylib'
    subprocess.run(['/usr/bin/clang', '-dynamiclib', '-arch', 'arm64', str(source),
                    '-Wl,-rpath,/Users/developer/private/lib', '-Wl,-rpath,@loader_path',
                    '-Wl,-install_name,@rpath/libtiny.dylib', '-o', str(library)], check=True)
    builder().repair_native_paths(tmp_path)
    loads = subprocess.check_output(['/usr/bin/otool', '-l', str(library)], text=True)
    assert '/Users/developer/private/lib' not in loads
    assert '@loader_path' in loads
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(library)], check=True)


@pytest.mark.parametrize('metal_available,allow_no_metal', [(True, False), (True, True), (False, True)])
def test_mlx_validation_reports_the_device_actually_evaluated(metal_available, allow_no_metal):
    evaluated = []
    selected = []
    mx = SimpleNamespace(metal=SimpleNamespace(is_available=lambda: metal_available),
                         gpu='gpu', cpu='cpu', set_default_device=selected.append,
                         array=lambda values: sum(values), eval=evaluated.append)
    namespace = {'mx': mx, 'allow_no_metal': allow_no_metal}
    exec(builder().MLX_VALIDATION, namespace)
    assert selected == ['gpu' if metal_available else 'cpu']
    assert evaluated == [4]
    assert namespace['mlx_report'] == {'metal_available': metal_available,
                                       'mlx_evaluation': metal_available,
                                       'cpu_evaluation': not metal_available}


def test_mlx_validation_requires_metal_without_explicit_ci_opt_in():
    mx = SimpleNamespace(metal=SimpleNamespace(is_available=lambda: False))
    with pytest.raises(RuntimeError, match='--allow-no-metal'):
        exec(builder().MLX_VALIDATION, {'mx': mx, 'allow_no_metal': False})


@pytest.mark.parametrize('extra,expected', [([], False), (['--allow-no-metal'], True)])
def test_payload_cli_accepts_explicit_no_metal_opt_in(monkeypatch, extra, expected):
    module = builder()
    received = []
    monkeypatch.setattr(module, 'build_payload', received.append)
    monkeypatch.setattr(sys, 'argv', ['builder', 'payload', '--uv', '/uv',
                                    '--python-home', '/python', *extra])
    module.main()
    assert received[0].allow_no_metal is expected
