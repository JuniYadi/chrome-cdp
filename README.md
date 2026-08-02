# Chrome CDP Launcher

Launch Chrome with an isolated profile and Chrome DevTools Protocol (CDP) enabled.
Useful for MCP and browser integration tests.

## Requirements

- Bash
- One installed browser: `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser`

## Usage

```bash
./start-chrome.sh <profile> [port] [--background]
```

Chrome runs in the foreground by default so you can complete login and other
interactive setup. Add `--background` after setup to return immediately.

```bash
# First run: visible Chrome for login
./start-chrome.sh default

# Later run: start same profile without holding the terminal
./start-chrome.sh default 9222 --background

# Multiple profiles need separate ports
./start-chrome.sh test-a 9223 --background
./start-chrome.sh test-b 9224 --background
```

The launcher creates each profile under `profiles/` and prints its CDP endpoint:

```text
CDP: http://127.0.0.1:9223
```

Connect MCP or another CDP client to that endpoint. Profile data and local
documentation artifacts are ignored by Git.
