#!/bin/sh
# Сверка Rectify.swift с эталоном на Python (Checks/rectify_cases.json): собираем для Mac и гоняем случаи
here="$(cd "$(dirname "$0")" && pwd)"
dir="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/rectify-check"
mkdir -p "$dir"
dev="${DEVELOPER_DIR:-$(xcode-select -p)}"
if ! env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" DEVELOPER_DIR="$dev" \
     xcrun --sdk macosx swiftc -O "$here/../Sources/Rectify.swift" "$here/main.swift" -o "$dir/check" > "$dir/build.log" 2>&1; then
  echo "warning: сверка выпрямления не собралась"
  cat "$dir/build.log"
  exit 0
fi
"$dir/check" "$here/rectify_cases.json"
