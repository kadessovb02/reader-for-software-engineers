#!/bin/zsh
set -euo pipefail

LIST_PROJECT_DIR="${0:A:h:h}"
LIST_APP_NAME="Лист — Reader for Engineers.app"
LIST_ARCH="${LIST_ARCH:-$(/usr/bin/uname -m)}"
"$LIST_PROJECT_DIR/build.sh"
LIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LIST_PROJECT_DIR/Info.plist")"
LIST_ARCHIVE="$LIST_PROJECT_DIR/dist/Reader-for-Engineers-$LIST_VERSION-$LIST_ARCH.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$LIST_PROJECT_DIR/dist/$LIST_APP_NAME" "$LIST_ARCHIVE"
print "Архив: $LIST_ARCHIVE"
