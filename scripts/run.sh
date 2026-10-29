#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in
    debug|Debug) configuration_dir=Debug ;;
    release|Release) configuration_dir=Release ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac

"$project_dir/scripts/build.sh" "$configuration"
app_dir="$project_dir/build/$configuration_dir/Pastes Dev.app"
executable="$app_dir/Contents/MacOS/pastes"

# Restart only this checkout's development app so the new binary is used.
# The installed /Applications/pastes.app and other checkouts are unaffected.
while IFS= read -r dev_pid; do
    [[ -n "$dev_pid" ]] || continue
    kill -TERM "$dev_pid" 2>/dev/null || continue
    for ((attempt = 0; attempt < 50; attempt++)); do
        kill -0 "$dev_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$dev_pid" 2>/dev/null; then
        printf 'Pastes Dev did not exit. Quit it and run this command again.\n' >&2
        exit 1
    fi
done < <(/bin/ps -axo pid=,comm= | /usr/bin/awk -v executable="$executable" \
    '{pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid}')

/usr/bin/open "$app_dir"
