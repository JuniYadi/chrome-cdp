#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s <profile> [port]\n' "${0##*/}" >&2
  exit 2
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
fi
[[ $# -ge 1 && $# -le 2 ]] || usage

profile=$1
port=${2:-9222}
[[ $profile =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid profile name: %s\n' "$profile" >&2
  exit 2
}
[[ $port =~ ^[0-9]+$ ]] || {
  printf 'Invalid port: %s\n' "$port" >&2
  exit 2
}
port=$((10#$port))
(( port >= 1 && port <= 65535 )) || {
  printf 'Port out of range: %s\n' "$port" >&2
  exit 2
}

browser=''
for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
  if browser=$(command -v "$candidate"); then
    break
  fi
done
[[ -n $browser ]] || {
  printf 'No supported Chrome/Chromium executable found.\n' >&2
  exit 1
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
profile_dir=$root/profiles/$profile
mkdir -p "$profile_dir"

"$browser" \
  --user-data-dir="$profile_dir" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$port" \
  --remote-allow-origins='*' \
  --no-first-run \
  --no-default-browser-check \
  >/dev/null 2>&1 &
pid=$!

printf 'Browser: %s\nProfile: %s\nPID: %s\nCDP: http://127.0.0.1:%s\n' \
  "$browser" "$profile" "$pid" "$port"
