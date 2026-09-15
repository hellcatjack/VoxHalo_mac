"""Build a native service console; reuse the existing local model installation."""
from __future__ import annotations

import argparse
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


def build(destination: Path, desktop_link: bool):
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
                        '-framework', 'CoreAudio', '-framework', 'CoreImage',
                        *[str(SOURCES/name) for name in ('ServiceClient.swift', 'NativePreferences.swift',
                           'AudioDevices.swift', 'AudioCapture.swift', 'SystemAudioTap.swift', 'NativeSpeechPlayer.swift',
                           'SubtitleState.swift', 'SubtitlePlayback.swift', 'SubtitlePreferences.swift', 'SubtitleOverlay.swift', 'SubtitleSettings.swift', 'NativeSession.swift', 'main.swift')],
                        '-o', str(executable_dir/'VoxBridgeConsole')], check=True)
        iconset = staging/'AppIcon.iconset'
        icon_builder = staging/'make-icon'
        subprocess.run(['xcrun', 'swiftc', str(SOURCES/'make-icon.swift'), '-o', str(icon_builder)], check=True)
        subprocess.run([str(icon_builder), str(iconset)], check=True)
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(resources/'AppIcon.icns')], check=True)
        shutil.copy2(ROOT/'voxbridge/language_catalog.json', resources/'language_catalog.json')
        (resources/'installation.json').write_text(json.dumps({'service_root': str(ROOT)}, ensure_ascii=False))
        info = {
            'CFBundleIdentifier': BUNDLE_ID,
            'CFBundleName': '同声传译',
            'CFBundleDisplayName': '同声传译',
            'CFBundleExecutable': 'VoxBridgeConsole',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.6.0',
            'CFBundleVersion': '18',
            'CFBundleIconFile': 'AppIcon',
            'LSMinimumSystemVersion': '14.0',
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
    print(f'本地模型与服务：{ROOT}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path('/Applications')/APP_NAME)
    parser.add_argument('--desktop-link', action='store_true')
    args = parser.parse_args()
    build(args.destination, args.desktop_link)


if __name__ == '__main__':
    main()
