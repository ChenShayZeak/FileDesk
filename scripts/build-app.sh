#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' '请在 macOS 14 或更新版本上运行此脚本。' >&2
    exit 1
fi

if ! xcrun --find swift >/dev/null 2>&1; then
    printf '%s\n' '请先运行 xcode-select --install 安装命令行工具。' >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p dist
stage="$(mktemp -d "$project_dir/dist/.build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

bundle="$stage/文件桌.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$binary_dir/FileDesk" "$bundle/Contents/MacOS/FileDesk"
install -m 644 "$project_dir/scripts/Info.plist" "$bundle/Contents/Info.plist"
version="${FILEDESK_VERSION:-$(git describe --tags --exact-match HEAD 2>/dev/null || true)}"
if [[ "$version" =~ ^v?((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BASH_REMATCH[1]}" "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BASH_REMATCH[1]}" "$bundle/Contents/Info.plist"
fi
install -m 644 "$project_dir/scripts/FileDesk.icns" "$bundle/Contents/Resources/FileDesk.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

destination="$project_dir/dist/文件桌.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$stage/previous.app"
fi
if ! mv "$bundle" "$destination"; then
    if [[ -e "$stage/previous.app" ]]; then
        mv "$stage/previous.app" "$destination"
    fi
    exit 1
fi

printf '\n已生成 %s\n' "$destination"
