"""Build a native service console; reuse the existing local model installation."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'deploy/macos/app'
APP_NAME = '同声传译.app'
BUNDLE_ID = 'org.pccs.voxbridge.console'
APP_VERSION = '1.8.0'
APP_BUILD = '22'


def release_metadata(directory: Path) -> dict:
    """Refuse mismatched/incomplete distribution payloads before compiling an App."""
    metadata = json.loads((directory / 'release.json').read_text())
    if metadata.get('version') != APP_VERSION or str(metadata.get('build')) != APP_BUILD:
        raise ValueError('Release payload version does not match the native App.')
    with (directory / 'runtime.tar.gz').open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    if metadata.get('runtime_sha256') != checksum:
        raise ValueError('Release runtime SHA-256 does not match.')
    if not (directory / 'licenses/HY-MT-LICENSE.txt').is_file():
        raise ValueError('The bundled HY-MT license is required for first-run review.')
    return metadata


def build(destination: Path, desktop_link: bool, release_payload: Path | None = None):
    metadata = release_metadata(release_payload) if release_payload else None
    destination = destination.expanduser().absolute()
    if destination.suffix != '.app':
        raise ValueError('目标路径必须以 .app 结尾。')
    if destination.is_symlink():
        raise ValueError('安装目标不能是符号链接。')
    if destination.exists():
        try:
            info = plistlib.loads((destination/'Contents/Info.plist').read_bytes())
        except (OSError, ValueError):
            raise ValueError('目标已存在且不是此应用，未覆盖。') from None
        if info.get('CFBundleIdentifier') != BUNDLE_ID:
            raise ValueError('目标已被其他应用占用，未覆盖。')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.voxbridge-build-', dir=destination.parent) as directory:
        staging = Path(directory)
        bundle = staging/APP_NAME
        contents = bundle/'Contents'
        executable_dir = contents/'MacOS'
        resources = contents/'Resources'
        executable_dir.mkdir(parents=True)
        resources.mkdir()
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macosx14.0',
                        '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'ScreenCaptureKit',
                        '-framework', 'CoreAudio', '-framework', 'CoreImage', '-framework', 'Carbon',
                        *[str(SOURCES/name) for name in ('NativeLocalization.swift', 'NativeLocalizedViews.swift', 'ServiceClient.swift', 'NativePreferences.swift',
                           'AudioDevices.swift', 'AudioCapture.swift', 'SystemAudioTap.swift', 'NativeSpeechPlayer.swift',
                           'SubtitleState.swift', 'SubtitlePlayback.swift', 'SubtitlePreferences.swift', 'SubtitleShortcuts.swift', 'SubtitleHotKeys.swift',
                           'SubtitleOverlay.swift', 'SubtitleShortcutSettings.swift', 'SubtitleSettings.swift', 'NativeSession.swift',
                           'DesktopInstallation.swift', 'InstallationWindow.swift', 'main.swift')],
                        '-o', str(executable_dir/'VoxBridgeConsole')], check=True)
        iconset = staging/'AppIcon.iconset'
        icon_builder = staging/'make-icon'
        subprocess.run(['xcrun', 'swiftc', str(SOURCES/'make-icon.swift'), '-o', str(icon_builder)], check=True)
        subprocess.run([str(icon_builder), str(iconset)], check=True)
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(resources/'AppIcon.icns')], check=True)
        shutil.copy2(ROOT/'voxbridge/language_catalog.json', resources/'language_catalog.json')
        (resources/'ui_locales').mkdir()
        for catalog in ('native.json', 'native-errors.json', 'installer.json'):
            shutil.copy2(ROOT/'voxbridge/ui_locales'/catalog, resources/'ui_locales'/catalog)
        translations = json.loads((resources/'ui_locales/native.json').read_text())['messages']
        for locale in ('zh', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi'):
            localized = resources / f'{"zh-Hans" if locale == "zh" else locale}.lproj'
            localized.mkdir()
            strings = {
                'CFBundleName': translations['同声传译'][locale],
                'CFBundleDisplayName': translations['同声传译'][locale],
                'NSMicrophoneUsageDescription': translations['采集所选麦克风的语音，在本机执行识别和翻译。'][locale],
                'NSAudioCaptureUsageDescription': translations['采集系统播放声音，在本机执行识别和翻译，并排除本 App 的朗读。'][locale],
            }
            (localized/'InfoPlist.strings').write_text('\n'.join(
                f'{json.dumps(key)} = {json.dumps(value, ensure_ascii=False)};' for key, value in strings.items()) + '\n')
        if release_payload:
            for name in ('runtime.tar.gz', 'release.json'):
                shutil.copy2(release_payload / name, resources / name)
            shutil.copytree(release_payload / 'licenses', resources / 'licenses')
        else:
            (resources/'installation.json').write_text(json.dumps({'service_root': str(ROOT)}, ensure_ascii=False))
        info = {
            'CFBundleIdentifier': BUNDLE_ID,
            'CFBundleName': '同声传译',
            'CFBundleDisplayName': '同声传译',
            'CFBundleExecutable': 'VoxBridgeConsole',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': APP_VERSION,
            'CFBundleVersion': APP_BUILD,
            'CFBundleDevelopmentRegion': 'en',
            'CFBundleLocalizations': ['zh-Hans', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi'],
            'CFBundleIconFile': 'AppIcon',
            'LSMinimumSystemVersion': '14.2' if metadata else '14.0',
            'LSMultipleInstancesProhibited': True,
            'NSHighResolutionCapable': True,
            'NSPrincipalClass': 'NSApplication',
            'NSMicrophoneUsageDescription': '采集所选麦克风的语音，在本机执行识别和翻译。',
            'NSAudioCaptureUsageDescription': '采集系统播放声音，在本机执行识别和翻译，并排除本 App 的朗读。',
            'NSHumanReadableCopyright': 'PCCS · Local interpretation',
        }
        (contents/'Info.plist').write_bytes(plistlib.dumps(info))
        (contents/'PkgInfo').write_bytes(b'APPL????')
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(bundle)], check=True)
        previous = staging/'previous.app'
        if destination.exists():
            destination.rename(previous)
        try:
            bundle.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
    if desktop_link:
        link = Path.home()/'Desktop'/APP_NAME
        if os.path.lexists(link):
            if not link.is_symlink() or link.resolve() != destination.resolve():
                raise ValueError(f'应用已安装，但桌面同名文件已存在，未覆盖：{link}')
        else:
            link.symlink_to(destination, target_is_directory=True)
    print(f'已安装：{destination}')
    print('首次打开后在 App 内安装模型。' if metadata else f'本地模型与服务：{ROOT}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path('/Applications')/APP_NAME)
    parser.add_argument('--desktop-link', action='store_true')
    parser.add_argument('--release-payload', type=Path,
                        help='Verified standalone runtime.tar.gz, release.json and licenses directory')
    args = parser.parse_args()
    build(args.destination, args.desktop_link, args.release_payload)


if __name__ == '__main__':
    main()
