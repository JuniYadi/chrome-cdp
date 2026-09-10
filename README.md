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

## Tailscale Remote Access on Windows (Public IP Safe)

If running on a Windows machine with a Public IP address, **never expose CDP to `0.0.0.0` or the public interface**. Use the interactive PowerShell manager to safely bridge ports to your Tailscale IP:

```powershell
# Run PowerShell as Administrator
.\manage-cdp-tailscale.ps1
```

### Menu Features
1. **List Port & Status Keamanan**: View active port forwards, check if Chrome is running, and verify that sockets are isolated to localhost / Tailscale.
2. **Add Port to Tailscale**: Automatically configures `netsh portproxy` (`<Tailscale_IP>:<Port> -> 127.0.0.1:<Port>`) and creates a strict Windows Firewall rule for Tailscale's CGNAT subnet (`100.64.0.0/10`).
3. **Remove Port from Tailscale**: Deletes the proxy and cleans up firewall rules.
4. **Diagnostik & Test Endpoint**: Verifies `/json/version` over Localhost & Tailscale while testing for Public IP leakage.
5. **Jalankan Chrome Instance**: Helper to launch foreground or background profiles.
