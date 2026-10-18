#!/bin/bash
set -euo pipefail
LIST_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST_PROJECT_DIR="$(cd "$LIST_SCRIPT_DIR/.." && pwd)"
LIST_WITH_AI=0
LIST_OPEN_APP=0

for LIST_OPTION in "$@"; do
    case "$LIST_OPTION" in
        --with-ai) LIST_WITH_AI=1 ;;
        --open) LIST_OPEN_APP=1 ;;
        --help|-h)
            cat <<'HELP'
Usage: ./scripts/setup.sh [--with-ai] [--open]
Builds the app in dist and checks local requirements. No books or account data are copied.
  --with-ai  Install missing official Codex CLI with npm, then open its ChatGPT browser login.
             Requires Node.js/npm. Existing CLI installations are not replaced automatically.
  --open     Open the built application after setup.
Reading requires neither Codex nor Docker. Docker Desktop is optional for running practice code.
HELP
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$LIST_OPTION" >&2; exit 2 ;;
    esac
done

"$LIST_SCRIPT_DIR/doctor.sh"
if [[ "$LIST_WITH_AI" -eq 1 ]]; then
    if ! command -v codex >/dev/null 2>&1; then
        if ! command -v npm >/dev/null 2>&1; then
            printf 'Install Node.js/npm first, or follow https://learn.chatgpt.com/docs/codex/cli\n' >&2
            exit 1
        fi
        npm install -g @openai/codex@latest
    fi
    # Official CLI handles the browser flow and stores this user's own credentials.
    codex login
fi
"$LIST_PROJECT_DIR/build.sh"
printf '\nNext: open «dist/Лист — Reader for Engineers.app», add a book with ⌘O, and connect ChatGPT in Настройки.\n'
if [[ "$LIST_OPEN_APP" -eq 1 ]]; then
    open "$LIST_PROJECT_DIR/dist/Лист — Reader for Engineers.app"
fi
