#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${1:-${PROJECT_DIR}/dist/OLM Browser.app}"
CONTENTS="${APP_PATH}/Contents"
ICON_WORK="$(mktemp -d /private/tmp/olm-browser-icon.XXXXXX)"
ICONSET="${ICON_WORK}/AppIcon.iconset"
trap 'rm -rf "${ICON_WORK}"' EXIT

case "${APP_PATH}" in
  "${PROJECT_DIR}"/*) ;;
  *) print -u2 "Output must stay inside ${PROJECT_DIR}"; exit 2 ;;
esac

cd "${PROJECT_DIR}"
swift build -c release --product OLMBrowser

rm -rf "${APP_PATH}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${ICONSET}"
cp "AppResources/Info.plist" "${CONTENTS}/Info.plist"
cp ".build/release/OLMBrowser" "${CONTENTS}/MacOS/OLMBrowser"
chmod 755 "${CONTENTS}/MacOS/OLMBrowser"

sips -s format png "AppResources/AppIcon.svg" --out "${ICON_WORK}/base.png" >/dev/null
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" \
            "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" \
            "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" \
            "1024:icon_512x512@2x.png"; do
  size="${spec%%:*}"
  name="${spec#*:}"
  sips -z "${size}" "${size}" "${ICON_WORK}/base.png" --out "${ICONSET}/${name}" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${CONTENTS}/Resources/AppIcon.icns"
codesign --force --deep --sign - "${APP_PATH}"
print "Built ${APP_PATH}"
