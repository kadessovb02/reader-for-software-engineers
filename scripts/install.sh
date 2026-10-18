#!/bin/zsh
set -euo pipefail

LIST_PROJECT_DIR="${0:A:h:h}"
LIST_APP_NAME="Лист — Reader for Engineers.app"
LIST_BUILD_APP="$LIST_PROJECT_DIR/dist/$LIST_APP_NAME"
LIST_INSTALL_DIR="$HOME/Applications"
LIST_INSTALL_APP="$LIST_INSTALL_DIR/$LIST_APP_NAME"

"$LIST_PROJECT_DIR/build.sh"
mkdir -p "$LIST_INSTALL_DIR"
if [[ -e "$LIST_INSTALL_APP" ]]; then
  LIST_EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LIST_INSTALL_APP/Contents/Info.plist" 2>/dev/null || true)"
  LIST_BUILD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LIST_BUILD_APP/Contents/Info.plist")"
  if [[ -z "$LIST_EXISTING_ID" || "$LIST_EXISTING_ID" != "$LIST_BUILD_ID" ]]; then
    print -u2 "Installation stopped: a different app already uses $LIST_INSTALL_APP"
    exit 1
  fi
  if /usr/bin/pgrep -f "$LIST_INSTALL_APP/Contents/MacOS/ListReader" >/dev/null; then
    print -u2 "Quit Reader for Engineers and run this installer again."
    exit 1
  fi
fi

# Stage the copy before replacing this public build. Library data lives elsewhere.
LIST_INSTALL_STAGE="$(/usr/bin/mktemp -d "$LIST_INSTALL_DIR/.reader-install.XXXXXX")"
trap '/bin/rm -rf "$LIST_INSTALL_STAGE"' EXIT
/usr/bin/ditto "$LIST_BUILD_APP" "$LIST_INSTALL_STAGE/$LIST_APP_NAME"
/usr/bin/codesign --verify --deep --strict "$LIST_INSTALL_STAGE/$LIST_APP_NAME"
if [[ -e "$LIST_INSTALL_APP" ]]; then /bin/rm -rf "$LIST_INSTALL_APP"; fi
/bin/mv "$LIST_INSTALL_STAGE/$LIST_APP_NAME" "$LIST_INSTALL_APP"
print "Установлено: $LIST_INSTALL_APP"
print "Открыть: open \"$LIST_INSTALL_APP\""
