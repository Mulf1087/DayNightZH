#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app="$project_dir/Dist/昼夜外观.app"
if [[ ! -d "$app" ]]; then
    print -u2 '请先运行 ./build.sh 构建应用。'
    exit 1
fi

staging=$(mktemp -d "$project_dir/Dist/.dmg-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/昼夜外观.app"
cp "$project_dir/README.md" "$staging/使用说明.md"
ln -s /Applications "$staging/应用程序"

image="$project_dir/Dist/昼夜外观.dmg"
hdiutil create -ov -volname "昼夜外观" -srcfolder "$staging" -format UDZO "$image"
hdiutil verify "$image"
