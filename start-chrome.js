#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const usage = `Usage: start-chrome.js <profile> [port] [--background]`;

function parseArgs(args) {
  if (args.length === 1 && (args[0] === '-h' || args[0] === '--help')) {
    return { help: true };
  }
  if (args.length < 1 || args.length > 3) {
    throw new Error(usage);
  }

  const [profile, ...rest] = args;
  let port = 9222;
  let background = false;
  for (const value of rest) {
    if (value === '--background') {
      background = true;
    } else if (/^\d+$/.test(value) && port === 9222) {
      port = Number(value);
    } else {
      throw new Error(usage);
    }
  }

  if (!/^[A-Za-z0-9._-]+$/.test(profile)) {
    throw new Error(`Invalid profile name: ${profile}`);
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Port out of range: ${port}`);
  }
  return { profile, port, background };
}

function launchBrowser(executablePath, profileDir, port, background) {
  const args = [
    `--user-data-dir=${profileDir}`,
    '--remote-debugging-address=127.0.0.1',
    `--remote-debugging-port=${port}`,
    '--remote-allow-origins=*',
    '--no-first-run',
    '--no-default-browser-check',
  ];
  const child = spawn(executablePath, args, {
    detached: background,
    stdio: background ? 'ignore' : 'inherit',
  });
  if (background) {
    child.unref();
  }
  return child;
}

let options;
try {
  options = parseArgs(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 2;
}

if (options?.help) {
  console.log(usage);
} else if (options) {
  const root = dirname(fileURLToPath(import.meta.url));
  const profileDir = join(root, 'profiles', options.profile);
  await mkdir(profileDir, { recursive: true });

  try {
    const executablePath = chromium.executablePath();
    const child = launchBrowser(
      executablePath,
      profileDir,
      options.port,
      options.background,
    );
    console.log(`Browser: ${executablePath}`);
    console.log(`Profile: ${options.profile}`);
    console.log(`CDP: http://127.0.0.1:${options.port}`);
    console.log(`Mode: ${options.background ? 'background' : 'foreground'}`);
    if (options.background) {
      console.log(`PID: ${child.pid}`);
    } else {
      await new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('exit', resolve);
      });
    }
  } catch (error) {
    console.error(`Failed to launch Chromium: ${error.message}`);
    process.exitCode = 1;
  }
}
