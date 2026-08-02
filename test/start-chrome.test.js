import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const launcher = join(root, 'start-chrome.js');

function run(...args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [launcher, ...args], { cwd: root });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (data) => { stdout += data; });
    child.stderr.on('data', (data) => { stderr += data; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

test('prints usage for --help', async () => {
  const result = await run('--help');
  assert.equal(result.code, 0);
  assert.match(result.stdout, /Usage: start-chrome\.js <profile> \[port\] \[--background\]/);
});

test('rejects unsafe profile names before launching', async () => {
  const result = await run('../escape');
  assert.equal(result.code, 2);
  assert.match(result.stderr, /Invalid profile name/);
});
