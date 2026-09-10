import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { createProxy, getTailscaleIPv4 } from '../tailscale-proxy.js';

test('tailscale-proxy exports getTailscaleIPv4 and createProxy', () => {
  assert.equal(typeof getTailscaleIPv4, 'function');
  assert.equal(typeof createProxy, 'function');
});

test('createProxy forwards TCP streams correctly', async () => {
  // 1. Dummy target server
  const targetServer = net.createServer((socket) => {
    socket.on('data', (data) => {
      socket.write(`echo:${data.toString()}`);
    });
  });

  await new Promise((resolve) => targetServer.listen(0, '127.0.0.1', resolve));
  const targetPort = targetServer.address().port;

  // 2. Proxy server listening on 127.0.0.1 (simulating specific IP)
  const proxy = createProxy('127.0.0.1', 0, '127.0.0.1', targetPort);
  await new Promise((resolve) => proxy.on('listening', resolve));
  const proxyPort = proxy.address().port;

  // 3. Client connects to proxy
  const client = net.connect({ host: '127.0.0.1', port: proxyPort });
  const response = await new Promise((resolve) => {
    client.on('connect', () => {
      client.write('hello-cdp');
    });
    client.on('data', (data) => {
      resolve(data.toString());
    });
  });

  assert.equal(response, 'echo:hello-cdp');

  client.destroy();
  proxy.close();
  targetServer.close();
});
