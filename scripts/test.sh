#!/bin/zsh
set -euo pipefail

# Offline checks use only generated fixtures and disposable library directories.
# No ChatGPT authorization, Docker daemon, or user book files are needed.
if (( $# > 1 )); then print -u2 "Use one option at a time. Try --help."; exit 2; fi
LIST_RUN_IMPORTER=0
case "${1:-}" in
  "")
    LIST_TESTS=(CodexSetupSmoke ChatAssistantSmoke ChatBookSearchSmoke LibraryManagementSmoke)
    LIST_RUN_IMPORTER=1
    ;;
  --ui) LIST_TESTS=(PaperPDFSmoke PracticeSplitSmoke) ;;
  --live-chat) LIST_TESTS=(ChatSearchLiveSmoke) ;;
  --live-coach) LIST_TESTS=(PracticeCoachSmoke) ;;
  --docker) LIST_TESTS=(PracticeRunnerSmoke) ;;
  --help|-h)
    cat <<'HELP'
Usage: ./scripts/test.sh [option]
  (no option)   Five offline suites. No login, network, Docker, or personal books.
  --ui          Synthetic PDF appearance and practice split views; a macOS GUI session is required.
  --live-chat   Make real requests with your signed-in Codex account using a synthetic book.
  --live-coach  Make real requests with your signed-in Codex account using synthetic practice material.
  --docker      Execute synthetic exercises in Docker; requires a running engine and may pull images.
Live AI checks use account quota. Each optional group must be selected explicitly.
HELP
    exit 0 ;;
  *) print -u2 "Unknown option: $1. Try --help."; exit 2 ;;
esac

LIST_PROJECT_DIR="${0:A:h:h}"
LIST_TEST_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/reader-tests.XXXXXX")"
trap '/bin/rm -rf "$LIST_TEST_DIR"' EXIT
LIST_ARCH="$(/usr/bin/uname -m)"
LIST_TARGET="$LIST_ARCH-apple-macosx14.0"
LIST_CORE_SOURCES=()
for LIST_SOURCE in "$LIST_PROJECT_DIR"/Sources/*.swift; do
  [[ "${LIST_SOURCE:t}" == AppMain.swift ]] || LIST_CORE_SOURCES+=("$LIST_SOURCE")
done

print "Building test module…"
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -enable-testing \
  -target "$LIST_TARGET" -emit-library -emit-module -module-name ListReaderCore \
  -emit-module-path "$LIST_TEST_DIR/ListReaderCore.swiftmodule" \
  "${LIST_CORE_SOURCES[@]}" -o "$LIST_TEST_DIR/libListReaderCore.dylib" \
  -Xlinker -install_name -Xlinker '@rpath/libListReaderCore.dylib' \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework WebKit -framework Carbon

for LIST_TEST in "${LIST_TESTS[@]}"; do
  print "Running $LIST_TEST…"
  /usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -D TEST_MODULE \
    -target "$LIST_TARGET" -I "$LIST_TEST_DIR" -L "$LIST_TEST_DIR" -lListReaderCore \
    -Xlinker -rpath -Xlinker "$LIST_TEST_DIR" \
    "$LIST_PROJECT_DIR/Tests/$LIST_TEST.swift" -o "$LIST_TEST_DIR/$LIST_TEST"
  "$LIST_TEST_DIR/$LIST_TEST"
done

if (( LIST_RUN_IMPORTER )); then
  print "Running importer checks…"
  python3 "$LIST_PROJECT_DIR/Tests/importer/make_fixtures.py" "$LIST_TEST_DIR/importer"
  /usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target "$LIST_TARGET" "$LIST_PROJECT_DIR/Sources/BookImporter.swift" \
    "$LIST_PROJECT_DIR/Tests/importer/ImporterTests.swift" -o "$LIST_TEST_DIR/ImporterTests"
  "$LIST_TEST_DIR/ImporterTests" "$LIST_TEST_DIR/importer"
  print "All five offline suites passed."
else
  print "Selected optional checks passed."
fi
