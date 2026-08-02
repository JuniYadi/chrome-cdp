# Chrome CDP Launcher

Launch Chrome with an isolated profile and Chrome DevTools Protocol (CDP) enabled.
Useful for MCP and browser integration tests.

## Requirements

- Bash
- One installed browser: `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser`

## Usage

```bash
./start-chrome.sh <profile> [port]
```

The port defaults to `9222`. Use a different port for each running profile.

```bash
./start-chrome.sh default
./start-chrome.sh test-a 9223
./start-chrome.sh test-b 9224
```

The launcher creates each profile under `profiles/`, starts Chrome in the
background, and prints its CDP endpoint:

```text
CDP: http://127.0.0.1:9223
```

Connect MCP or another CDP client to that endpoint. Profile data and local
documentation artifacts are ignored by Git.
