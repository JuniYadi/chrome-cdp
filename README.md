# Chrome CDP Launcher

Launch Playwright's bundled Chromium with an isolated profile and Chrome
DevTools Protocol (CDP) enabled for MCP and browser integration tests.

## Requirements

- Node.js and npm

## Setup

```bash
npm install
npx playwright install chromium
```

Remove the old Snap Chromium after setup:

```bash
sudo snap remove chromium
```

## Usage

```bash
npm start -- <profile> [port] [--background]
```

Chromium runs visibly in the foreground by default so you can complete login
and other interactive setup. Add `--background` after setup to return
immediately.

```bash
# First run: visible Chromium for login
npm start -- default

# Later run: start same profile without holding the terminal
npm start -- default 9222 --background

# Multiple profiles need separate ports
npm start -- test-a 9223 --background
npm start -- test-b 9224 --background
```

The launcher creates each profile under `profiles/` and prints its CDP
endpoint:

```text
CDP: http://127.0.0.1:9223
```

Connect MCP or another CDP client to that endpoint. Profile data and local
documentation artifacts are ignored by Git.
