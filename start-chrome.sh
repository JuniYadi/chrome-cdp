#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s <profile> [port] [--background]\n' "${0##*/}" >&2
  exit 2
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
fi
[[ $# -ge 1 && $# -le 3 ]] || usage

profile=$1
port=9222
background=false
if [[ ${2:-} == "--background" ]]; then
  background=true
elif [[ -n ${2:-} ]]; then
  port=$2
fi
if [[ ${3:-} == "--background" ]]; then
  background=true
elif [[ -n ${3:-} ]]; then
  usage
fi

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

chrome_args=(
  "--user-data-dir=$profile_dir"
  --remote-debugging-address=127.0.0.1
  "--remote-debugging-port=$port"
  --remote-allow-origins='*'
  --no-first-run
  --no-default-browser-check
)

mode=foreground
if [[ $background == true ]]; then
  mode=background
fi
printf 'Browser: %s\nProfile: %s\nCDP: http://127.0.0.1:%s\nMode: %s\n' \
  "$browser" "$profile" "$port" "$mode"

if [[ $background == true ]]; then
  "$browser" "${chrome_args[@]}" >/dev/null 2>&1 &
  printf 'PID: %s\n' "$!"
else
  exec "$browser" "${chrome_args[@]}"
fi
