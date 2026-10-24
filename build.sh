#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app="$project_dir/Dist/昼夜外观.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -target arm64-apple-macos13.0 -framework AppKit -o "$app/Contents/MacOS/DayNightZH" "$project_dir/Sources/main.swift"
cp "$project_dir/Assets/DayNight.icns" "$app/Contents/Resources/DayNight.icns"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

info = {
    'CFBundleIdentifier': 'cn.liming.daynightzh',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleDevelopmentRegion': 'zh_CN',
    'CFBundleName': '昼夜外观',
    'CFBundleDisplayName': '昼夜外观',
    'CFBundleExecutable': 'DayNightZH',
    'CFBundleIconFile': 'DayNight',
    'CFBundlePackageType': 'APPL',
    'NSPrincipalClass': 'NSApplication',
    'CFBundleShortVersionString': '1.2.0',
    'CFBundleVersion': '3',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSAppleEventsUsageDescription': '用于切换 macOS 的浅色和深色外观。',
    'NSHumanReadableCopyright': '© 2026 昼夜外观',
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
