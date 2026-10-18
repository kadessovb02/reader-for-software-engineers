#!/bin/bash
# Local diagnostics only: does not install, sign in, run code or inspect tokens.
set -u
LIST_REQUIRED_FAILED=0
LIST_CODEX=""

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: ./scripts/doctor.sh [path/to/codex]
Checks macOS/build tools, Codex CLI isolation flags and optional Docker installation.
Missing Codex or Docker does not prevent reading books.
HELP
    exit 0
fi

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'ERROR: Лист requires macOS 14 or newer.\n'
    exit 1
fi
LIST_OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$LIST_OS_MAJOR" -lt 14 ]]; then
    printf 'ERROR: macOS 14 or newer is required.\n'
    LIST_REQUIRED_FAILED=1
else
    printf 'OK: macOS %s (%s)\n' "$(sw_vers -productVersion)" "$(uname -m)"
fi
if xcrun --find swiftc >/dev/null 2>&1; then
    printf 'OK: Swift compiler available\n'
else
    printf 'ERROR: Install Apple Command Line Tools: xcode-select --install\n'
    LIST_REQUIRED_FAILED=1
fi

if [[ -n "${1:-}" ]]; then
    LIST_CODEX="$1"
elif command -v codex >/dev/null 2>&1; then
    LIST_CODEX="$(command -v codex)"
else
    for LIST_CANDIDATE in /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.local/bin/codex"; do
        if [[ -x "$LIST_CANDIDATE" && ! -d "$LIST_CANDIDATE" ]]; then
            LIST_CODEX="$LIST_CANDIDATE"
            break
        fi
    done
fi
if [[ -n "$LIST_CODEX" && -x "$LIST_CODEX" && ! -d "$LIST_CODEX" ]]; then
    printf 'Codex: %s\n' "$("$LIST_CODEX" --version 2>/dev/null || printf 'version unavailable')"
    LIST_GLOBAL_HELP="$("$LIST_CODEX" --help 2>/dev/null)"
    LIST_EXEC_HELP="$("$LIST_CODEX" exec --help 2>/dev/null)"
    LIST_MISSING=""
    for LIST_FLAG in --no-daemon --ask-for-approval --config; do
        if ! /usr/bin/grep -Eq -- "(^|[[:space:],])${LIST_FLAG}([[:space:],=]|$)" <<< "$LIST_GLOBAL_HELP"; then
            LIST_MISSING="$LIST_MISSING $LIST_FLAG"
        fi
    done
    for LIST_FLAG in --ignore-user-config --ignore-rules --ephemeral --sandbox --skip-git-repo-check --color --json --output-last-message --output-schema; do
        if ! /usr/bin/grep -Eq -- "(^|[[:space:],])${LIST_FLAG}([[:space:],=]|$)" <<< "$LIST_EXEC_HELP"; then
            LIST_MISSING="$LIST_MISSING $LIST_FLAG"
        fi
    done
    if [[ -z "$LIST_MISSING" ]]; then
        printf 'OK: Codex supports the required isolated chat mode\n'
        printf 'Sign in with your account in Лист → Настройки → ChatGPT, or run codex login.\n'
    else
        printf 'AI SETUP: Update Codex; missing flags:%s\n' "$LIST_MISSING"
        printf '  npm install -g @openai/codex@latest\n'
    fi
else
    printf 'AI SETUP (optional): Install Codex CLI and sign in with your ChatGPT account.\n'
    printf '  npm install -g @openai/codex@latest\n'
    printf '  https://learn.chatgpt.com/docs/codex/cli\n'
fi

if command -v docker >/dev/null 2>&1 || [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    printf 'OK: Docker CLI found. In Лист → Настройки use «Проверить среду» to check the running engine.\n'
else
    printf 'PRACTICE (optional): Install Docker Desktop only to execute exercise code.\n'
    printf '  https://docs.docker.com/desktop/setup/install/mac-install/\n'
fi
exit "$LIST_REQUIRED_FAILED"
