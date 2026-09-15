#!/usr/bin/env python3
"""Build a fresh relocatable desktop payload, or package an already compiled App."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PYTHON_VERSION = '3.12.14'
UV_VERSION = '0.12.13'
VERSION = '1.8.0'
BUILD = '22'
MINIMUM_MACOS = '14.2'
SERVICE_FILES = (
    'VoxBridge/macos.sh', 'VoxBridge/LICENSE', 'VoxBridge/README.md',
    'VoxBridge/pyproject.toml', 'VoxBridge/tools/macos_service.py',
    'VoxBridge/tools/repair_kokoro_speed.py',
    'scripts/install_desktop.py', 'scripts/setup_assets.py',
    'scripts/runtime-assets.json', 'scripts/desktop-wheels.json', 'scripts/model-tools.lock',
    'scripts/release-runtime.lock', 'LICENSE', 'docs/THIRD_PARTY.md',
)
SKIP_NAMES = {'__pycache__', '.DS_Store', '.git', '.pytest_cache'}
MACHO_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(command, **kwargs):
    print('+ ' + ' '.join('<inline validation>' if '\n' in str(value) else str(value) for value in command), flush=True)
    try:
        return subprocess.run([str(value) for value in command], check=True, **kwargs)
    except subprocess.CalledProcessError as error:
        for output in (error.stdout, error.stderr):
            if output:
                message = output.decode(errors='replace') if isinstance(output, bytes) else output
                print(message, end='' if message.endswith('\n') else '\n', file=sys.stderr, flush=True)
        raise


def copy_public_tree(source: Path, destination: Path) -> None:
    """Source allowlists never follow symlinks into a developer's private files."""
    if source.is_symlink():
        raise ValueError(f'Source symlink is not distributable: {source}')
    if source.name in SKIP_NAMES or source.suffix in {'.pyc', '.pyo'}:
        return
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        for child in sorted(source.iterdir()):
            copy_public_tree(child, destination / child.name)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def stage_service(source: Path, destination: Path, licenses: Path) -> None:
    for relative in SERVICE_FILES:
        copy_public_tree(source / relative, destination / relative)
    copy_public_tree(source / 'VoxBridge/voxbridge', destination / 'VoxBridge/voxbridge')
    copy_public_tree(licenses, destination / 'licenses')


def make_venv_portable(venv: Path, python_home: Path) -> None:
    """Ship only Python entry points; the native App never runs activation scripts."""
    executable = venv / 'bin/python'
    executable.unlink(missing_ok=True)
    executable.symlink_to(os.path.relpath(python_home / 'bin/python3.12', executable.parent))
    # CPython resolves this against the executable directory, not the launch cwd.
    home = os.path.relpath(python_home / 'bin', venv / 'bin')
    (venv / 'pyvenv.cfg').write_text(
        f'home = {home}\nimplementation = CPython\nversion_info = {PYTHON_VERSION}\n'
        'include-system-site-packages = false\nrelocatable = true\n')
    for path in (venv / 'bin').iterdir():
        if path.name not in {'python', 'python3', 'python3.12'}:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()


def audit_payload(root: Path) -> None:
    root = root.resolve()
    for path in root.rglob('*'):
        if path.is_symlink():
            if path.readlink().is_absolute() or not path.resolve().is_relative_to(root) or not path.exists():
                raise ValueError(f'Nonportable symlink: {path} -> {path.readlink()}')
        elif path.suffix == '.pth':
            text = path.read_text()
            entries = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith('#')]
            if '__editable__' in path.name or '__editable__' in text:
                raise ValueError(f'Editable pth file: {path}')
            for entry in entries:
                if entry.startswith(('import ', 'import\t')):
                    continue
                if Path(entry).is_absolute() or not (path.parent / entry).resolve().is_relative_to(root):
                    raise ValueError(f'External pth entry in {path}: {entry}')


def check_macho_output(path: Path, loads: str, libraries: str, minimum: str) -> None:
    maximum = tuple(map(int, minimum.split('.')))
    versions = re.findall(r'^\s*minos\s+(\d+\.\d+(?:\.\d+)?)\s*$', loads, re.M)
    for block in re.split(r'Load command \d+', loads):
        if 'cmd LC_VERSION_MIN_MACOSX' in block:
            versions.extend(re.findall(r'^\s*version\s+(\d+\.\d+(?:\.\d+)?)\s*$', block, re.M))
    for version in versions:
        observed = tuple(map(int, version.split('.')))
        if (observed + (0, 0))[:3] > (maximum + (0, 0))[:3]:
            raise ValueError(f'{path} requires macOS {version}; release minimum is {minimum}')
    for dependency in re.findall(r'^\s+(.+?)\s+\(compatibility version', libraries, re.M):
        if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise ValueError(f'{path} links an external developer library: {dependency}')
    for rpath in re.findall(r'^\s*path (.+?) \(offset \d+\)', loads, re.M):
        if rpath.startswith('/') and not rpath.startswith(('/usr/lib/', '/System/Library/')):
            raise ValueError(f'{path} has an external runtime search path: {rpath}')


def audit_native_libraries(root: Path, minimum: str = MINIMUM_MACOS) -> dict:
    count = 0
    for path in root.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        # Inspect the shipped Apple Silicon slice of universal binaries.
        loads = subprocess.run(['/usr/bin/otool', '-arch', 'arm64', '-l', str(path)],
                               check=True, capture_output=True, text=True).stdout
        libraries = subprocess.run(['/usr/bin/otool', '-arch', 'arm64', '-L', str(path)],
                                   check=True, capture_output=True, text=True).stdout
        check_macho_output(path.relative_to(root), loads, libraries, minimum)
        count += 1
    return {'checked_macho_files': count, 'minimum_macos': minimum}


def repair_native_paths(root: Path) -> None:
    """Drop wheel-builder search directories while preserving bundled relative paths."""
    for path in root.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        loads = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-l', str(path)], text=True)
        rpaths = re.findall(r'^\s*path (.+?) \(offset \d+\)', loads, re.M)
        removed = [value for value in rpaths if value.startswith('/') and not value.startswith(('/usr/lib/', '/System/Library/'))]
        if removed:
            command = ['/usr/bin/install_name_tool']
            for value in dict.fromkeys(removed):
                command.extend(['-delete_rpath', value])
            run([*command, path])
            run(['/usr/bin/codesign', '--force', '--sign', '-', path])


def clean_bytecode(root: Path) -> None:
    for path in root.rglob('__pycache__'):
        if path.is_dir():
            shutil.rmtree(path)
    for path in root.rglob('*.pyc'):
        path.unlink()


def prepare_python(python_home: Path, target: Path) -> None:
    actual = subprocess.check_output([str(python_home / 'bin/python3.12'), '-I', '-c',
                                      'import platform; print(platform.python_version())'], text=True).strip()
    if actual != PYTHON_VERSION:
        raise ValueError(f'Expected managed Python {PYTHON_VERSION}, found {actual}')
    shutil.copytree(python_home, target, symlinks=True)
    # uv rewrites this install ID to its managed installation's absolute path.
    # The interpreter is standalone; make the optional shared library portable too.
    library = target / 'lib/libpython3.12.dylib'
    if library.exists():
        run(['/usr/bin/install_name_tool', '-id', '@rpath/libpython3.12.dylib', library])
        run(['/usr/bin/codesign', '--force', '--sign', '-', library])
    for path in (target / 'bin').iterdir():
        if path.name not in {'python', 'python3', 'python3.12'}:
            path.unlink()
    clean_bytecode(target)


def create_environment(uv: Path, root: Path, location: str, lock: Path, cache: Path | None) -> None:
    python = root / 'runtime/python/bin/python3.12'
    target = root / location
    environment = os.environ.copy()
    environment.update({'UV_NO_CONFIG': '1', 'UV_PYTHON_DOWNLOADS': 'never',
                        'UV_LINK_MODE': 'copy', 'MACOSX_DEPLOYMENT_TARGET': MINIMUM_MACOS})
    if cache:
        environment['UV_CACHE_DIR'] = str(cache)
    run([uv, 'venv', '--relocatable', '--no-project', '--no-python-downloads',
         '--python', python, target], env=environment)
    run([uv, 'pip', 'sync', '--python', target / 'bin/python', '--no-managed-python',
         '--link-mode', 'copy', '--no-python-downloads', lock], env=environment)
    make_venv_portable(target, root / 'runtime/python')


def collect_notices(root: Path) -> None:
    """Retain package notices and provide a browsable index outside site-packages."""
    inventory = []
    shutil.copy2(root / 'runtime/python/lib/python3.12/LICENSE.txt', root / 'licenses/Python-LICENSE.txt')
    for environment in (root / '.venv', root / 'runtime/model-tools'):
        site = environment / 'lib/python3.12/site-packages'
        for info in sorted(site.glob('*.dist-info')):
            metadata = info / 'METADATA'
            text = metadata.read_text(errors='replace') if metadata.exists() else ''
            record = {'distribution': info.name, 'environment': str(environment.relative_to(root))}
            for key in ('Name', 'Version', 'License-Expression', 'Home-page'):
                found = re.search(r'^' + re.escape(key) + r': (.+)$', text, re.M)
                if found:
                    record[key] = found.group(1)
            inventory.append(record)
            for notice in info.rglob('*'):
                if notice.is_file() and any(token in notice.name.lower() for token in ('license', 'copying', 'notice', 'author')):
                    destination = root / 'licenses/python-packages' / info.name / notice.relative_to(info)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(notice, destination)
    (root / 'licenses/python-distributions.json').write_text(json.dumps(inventory, indent=2) + '\n')
    command = ('import imageio_ffmpeg, subprocess; '
               'subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-version"], check=True); '
               'subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-buildconf"], check=True)')
    result = subprocess.run([str(root / '.venv/bin/python'), '-c', command],
                            check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (root / 'licenses/FFmpeg-build-configuration.txt').write_text(result.stdout)


def remove_downloaded_components(root: Path) -> None:
    """First-run obtains these exact upstream wheels; do not redistribute their binaries."""
    site = root / '.venv/lib/python3.12/site-packages'
    for name in ('imageio_ffmpeg', 'espeakng_loader'):
        paths = [site / name, *site.glob(name + '-*.dist-info')]
        for path in paths:
            if path.is_dir():
                shutil.rmtree(path)


MLX_VALIDATION = r'''
# metal.is_available() only reports that the wheel was compiled with Metal.
metal_available = mx.is_available(mx.gpu)
if not metal_available and not allow_no_metal:
    raise RuntimeError('Metal is unavailable; use --allow-no-metal only for CI import validation')
mlx_report = {'metal_available': metal_available, 'mlx_evaluation': False, 'cpu_evaluation': False}
if metal_available:
    mx.set_default_device(mx.gpu)
    mx.eval(mx.array([1, 2]) + 1)
    mlx_report['mlx_evaluation'] = True
else:
    # The shipped Metal wheel also needs a GPU for its CPU array allocator.
    mlx_report['evaluation_skipped_reason'] = 'no_metal_device'
'''


VALIDATION = r'''
import importlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
assert sys.version_info[:3] == (3, 12, 14), sys.version
assert pathlib.Path(sys.prefix).resolve() == root / '.venv', sys.prefix
assert pathlib.Path(sys.base_prefix).resolve() == root / 'runtime/python', sys.base_prefix
for value in sys.path:
    if value:
        assert pathlib.Path(value).resolve().is_relative_to(root), value
modules = ['voxbridge', 'mlx.core', 'mlx_qwen3_asr', 'onnxruntime', 'misaki',
           'pyopenjtalk', 'soundfile', 'fastapi', 'uvicorn', 'numpy', 'sherpa_onnx']
if sys.argv[2] == 'full':
    modules.extend(['kokoro_onnx', 'espeakng_loader', 'imageio_ffmpeg'])
for name in modules:
    module = importlib.import_module(name)
    if getattr(module, '__file__', None):
        assert pathlib.Path(module.__file__).resolve().is_relative_to(root), module.__file__
import mlx.core as mx
allow_no_metal = sys.argv[3] == 'allow-no-metal'
''' + MLX_VALIDATION + r'''
if sys.argv[2] == 'full':
    import espeakng_loader
    assert espeakng_loader.load_library() is not None
print(json.dumps({'python': sys.version.split()[0], 'relocated_imports': modules, **mlx_report}))
'''


def validate_relocation(root: Path, *, include_downloaded: bool = True, allow_no_metal: bool = False) -> dict:
    """Rename the workspace so original absolute build paths cannot accidentally work."""
    relocated = root.with_name(root.name + ' relocated with spaces')
    if relocated.exists():
        raise ValueError(f'Relocation target already exists: {relocated}')
    root.rename(relocated)
    try:
        with tempfile.TemporaryDirectory(prefix='voxhalo-clean-home-') as home:
            env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': home, 'TMPDIR': home,
                   'LANG': 'en_US.UTF-8', 'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1',
                   'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1'}
            result = run([relocated / '.venv/bin/python', '-s', '-c', VALIDATION, relocated,
                          'full' if include_downloaded else 'bundled',
                          'allow-no-metal' if allow_no_metal else 'require-metal'],
                         cwd=relocated, env=env, capture_output=True, text=True)
            run([relocated / 'runtime/model-tools/bin/python', '-s', '-c',
                 'import onnx, numpy, ml_dtypes; print(onnx.__version__)'],
                cwd=relocated, env=env, capture_output=True, text=True)
            print(result.stdout, flush=True)
            return json.loads(result.stdout.strip().splitlines()[-1])
    finally:
        relocated.rename(root)


def archive_payload(root: Path, output: Path, version: str = VERSION, build: str = BUILD) -> dict:
    audit_payload(root)
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / 'runtime.tar.gz'
    partial = output / 'runtime.tar.gz.part'
    def normalized(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        info.mtime = 0
        info.pax_headers = {}
        return info
    with partial.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(root.rglob('*')):
                archive.add(path, arcname=path.relative_to(root), recursive=False, filter=normalized)
    partial.replace(archive_path)
    manifest = root / 'scripts/runtime-assets.json'
    assets = json.loads(manifest.read_text())
    metadata = {'version': version, 'build': str(build), 'python_version': PYTHON_VERSION,
                'runtime_sha256': digest(archive_path), 'runtime_size': archive_path.stat().st_size,
                'runtime_unpacked_bytes': sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink()),
                'model_bytes': sum(asset.get('size', 0) for asset in assets['assets']),
                'manifest_sha256': digest(manifest), 'minimum_macos': MINIMUM_MACOS,
                'architecture': 'arm64', 'bundle_identifier': 'org.pccs.voxbridge.console'}
    wheels = root / 'scripts/desktop-wheels.json'
    if wheels.exists():
        metadata['desktop_wheels_sha256'] = digest(wheels)
        metadata['model_bytes'] += sum(asset['size'] for asset in json.loads(wheels.read_text())['assets'])
    (output / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    if (root / 'licenses').exists():
        shutil.copytree(root / 'licenses', output / 'licenses', dirs_exist_ok=True)
    return metadata


def build_payload(args) -> None:
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Build the Apple Silicon payload on native arm64 macOS')
    uv_version = subprocess.check_output([str(args.uv), '--version'], text=True).split()[1]
    if uv_version != UV_VERSION:
        raise ValueError(f'Expected uv {UV_VERSION}, found {uv_version}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.payload-build-', dir=output.parent) as temporary:
        root = Path(temporary) / 'workspace'
        root.mkdir()
        stage_service(args.source.resolve(), root, args.licenses_dir.resolve())
        prepare_python(args.python_home.resolve(), root / 'runtime/python')
        create_environment(args.uv, root, '.venv', args.source / 'scripts/release-runtime.lock', args.cache_dir)
        create_environment(args.uv, root, 'runtime/model-tools', args.source / 'scripts/model-tools.lock', args.cache_dir)
        site = root / '.venv/lib/python3.12/site-packages'
        (site / 'voxhalo-service.pth').write_text('../../../../VoxBridge\n')
        collect_notices(root)
        audit_payload(root)
        relocation_report = validate_relocation(root, allow_no_metal=args.allow_no_metal)
        remove_downloaded_components(root)
        repair_native_paths(root)
        native_report = audit_native_libraries(root)
        bundled_report = validate_relocation(root, include_downloaded=False, allow_no_metal=args.allow_no_metal)
        clean_bytecode(root)
        metadata = archive_payload(root, output, args.version, args.build)
        report = {'native': native_report, 'relocation': relocation_report, 'bundled_relocation': bundled_report}
        (output / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
        if args.keep_workspace:
            kept = output / 'workspace'
            if kept.exists():
                raise ValueError(f'Kept workspace already exists: {kept}')
            shutil.move(root, kept)
        print(json.dumps(metadata, indent=2), flush=True)


def package_app(app: Path, output: Path) -> None:
    """Use the App's embedded metadata so artifact names cannot drift from its version."""
    app = app.resolve()
    metadata = json.loads((app / 'Contents/Resources/release.json').read_text())
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleShortVersionString') != metadata['version'] or str(info.get('CFBundleVersion')) != str(metadata['build']):
        raise ValueError('App Info.plist and embedded release.json version/build disagree')
    if digest(app / 'Contents/Resources/runtime.tar.gz') != metadata['runtime_sha256']:
        raise ValueError('App embeds a runtime payload with a different SHA256')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
    output.mkdir(parents=True, exist_ok=True)
    stem = f"VoxHalo-{metadata['version']}-macOS-arm64"
    zip_path, dmg_path = output / f'{stem}.zip', output / f'{stem}.dmg'
    if zip_path.exists() or dmg_path.exists():
        raise ValueError('Release ZIP or DMG already exists; choose a fresh output directory')
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zip_path])
    with tempfile.TemporaryDirectory(prefix='.dmg-', dir=output) as directory:
        volume = Path(directory)
        shutil.copytree(app, volume / app.name, symlinks=True)
        (volume / 'Applications').symlink_to('/Applications')
        run(['/usr/bin/hdiutil', 'create', '-volname', f"VoxHalo {metadata['version']}",
             '-srcfolder', volume, '-ov', '-format', 'UDZO', dmg_path])
    run(['/usr/bin/hdiutil', 'verify', dmg_path])
    (output / 'SHA256SUMS.txt').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in (zip_path, dmg_path)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    payload = commands.add_parser('payload', help='Build fresh dependencies and a relocatable runtime archive')
    payload.add_argument('--source', type=Path, default=ROOT)
    payload.add_argument('--output', type=Path, default=ROOT / 'dist/release-payload')
    payload.add_argument('--uv', type=Path, required=True)
    payload.add_argument('--python-home', type=Path, required=True)
    payload.add_argument('--cache-dir', type=Path)
    payload.add_argument('--licenses-dir', type=Path, default=ROOT / 'scripts/licenses')
    payload.add_argument('--version', default=VERSION)
    payload.add_argument('--build', default=BUILD)
    payload.add_argument('--keep-workspace', action='store_true')
    payload.add_argument('--allow-no-metal', action='store_true',
                         help='Permit import-only validation on CI hosts without Metal; does not validate inference')
    package = commands.add_parser('package', help='Package a precompiled, signed standalone App')
    package.add_argument('--app', type=Path, required=True)
    package.add_argument('--output', type=Path, default=ROOT / 'dist/release')
    args = parser.parse_args()
    if args.command == 'payload':
        build_payload(args)
    else:
        package_app(args.app, args.output.resolve())


if __name__ == '__main__':
    main()
