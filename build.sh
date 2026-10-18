#!/bin/zsh
set -euo pipefail

LIST_PROJECT_DIR="${0:A:h}"
LIST_OUTPUT_DIR="${1:-"$LIST_PROJECT_DIR/dist"}"
LIST_ARCH="${LIST_ARCH:-$(/usr/bin/uname -m)}"
LIST_APP_NAME="Лист — Reader for Engineers.app"

case "$LIST_ARCH" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported architecture: $LIST_ARCH (use arm64 or x86_64)"; exit 1 ;;
esac

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  print -u2 "This app requires macOS 14 or later and Xcode Command Line Tools."
  exit 1
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 "Install Xcode Command Line Tools first: xcode-select --install"
  exit 1
fi

mkdir -p "$LIST_OUTPUT_DIR"
LIST_OUTPUT_DIR="${LIST_OUTPUT_DIR:A}"
LIST_STAGE_DIR="$(/usr/bin/mktemp -d "$LIST_OUTPUT_DIR/.reader-build.XXXXXX")"
trap '/bin/rm -rf "$LIST_STAGE_DIR"' EXIT
LIST_STAGE_APP="$LIST_STAGE_DIR/$LIST_APP_NAME"
LIST_APP_PATH="$LIST_OUTPUT_DIR/$LIST_APP_NAME"
mkdir -p "$LIST_STAGE_APP/Contents/MacOS" "$LIST_STAGE_APP/Contents/Resources"

/usr/bin/xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -parse-as-library -target "$LIST_ARCH-apple-macosx14.0" \
  "$LIST_PROJECT_DIR"/Sources/*.swift \
  -o "$LIST_STAGE_APP/Contents/MacOS/ListReader" \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework WebKit -framework Carbon
/bin/cp "$LIST_PROJECT_DIR/Info.plist" "$LIST_STAGE_APP/Contents/Info.plist"
for LIST_RESOURCE in "$LIST_PROJECT_DIR"/Resources/*(N); do
  /bin/cp -R "$LIST_RESOURCE" "$LIST_STAGE_APP/Contents/Resources/"
done
/usr/bin/codesign --force --deep --sign - "$LIST_STAGE_APP"
/usr/bin/codesign --verify --deep --strict "$LIST_STAGE_APP"

# The separate public app name keeps personal builds of Лист.app untouched.
if [[ -e "$LIST_APP_PATH" ]]; then /bin/rm -rf "$LIST_APP_PATH"; fi
/bin/mv "$LIST_STAGE_APP" "$LIST_APP_PATH"
print "Готово: $LIST_APP_PATH ($LIST_ARCH, macOS 14+)"
