#!/usr/bin/env node
import net from 'node:net';
import os from 'node:os';
import { execSync } from 'node:child_process';

/**
 * Detect Tailscale IPv4 address (100.64.0.0/10 CGNAT range or Tailscale interface)
 */
export function getTailscaleIPv4() {
  const interfaces = os.networkInterfaces();

  // 1. Search by interface name
  for (const [name, addrs] of Object.entries(interfaces)) {
    if (/tailscale|wintun/i.test(name)) {
      for (const addr of addrs || []) {
        if (addr.family === 'IPv4' && !addr.internal) {
          return addr.address;
        }
      }
    }
  }

  // 2. Search by Tailscale CGNAT subnet (100.64.0.0/10)
  for (const addrs of Object.values(interfaces)) {
    for (const addr of addrs || []) {
      if (addr.family === 'IPv4' && !addr.internal) {
        const parts = addr.address.split('.').map(Number);
        if (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) {
          return addr.address;
        }
      }
    }
  }

  // 3. Fallback to tailscale CLI
  try {
    const out = execSync('tailscale ip -4', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (out) return out;
  } catch {}

  return null;
}

/**
 * Create a secure TCP proxy bound strictly to the Tailscale IP
 */
export function createProxy(tailscaleIP, port, targetHost = '127.0.0.1', targetPort = port) {
  const server = net.createServer({ pauseOnConnect: false }, (clientSocket) => {
    const targetSocket = net.connect({ host: targetHost, port: targetPort }, () => {
      clientSocket.pipe(targetSocket);
      targetSocket.pipe(clientSocket);
    });

    clientSocket.on('error', () => targetSocket.destroy());
    targetSocket.on('error', () => clientSocket.destroy());
    clientSocket.on('close', () => targetSocket.destroy());
    targetSocket.on('close', () => clientSocket.destroy());
  });

  server.on('error', (err) => {
    console.error(`[Proxy Error Port ${port}]:`, err.message);
  });

  server.listen(port, tailscaleIP, () => {
    console.log(`[SECURE PROXY] Listening on ${tailscaleIP}:${port} -> ${targetHost}:${targetPort}`);
    console.log(`               Public IP is completely isolated (NOT listening on 0.0.0.0).`);
  });

  return server;
}

// CLI execution
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/'))) {
  const args = process.argv.slice(2);
  const ports = args.map(Number).filter((p) => Number.isInteger(p) && p >= 1 && p <= 65535);

  if (ports.length === 0) {
    console.log('Usage: node tailscale-proxy.js <port1> [port2] ...');
    console.log('Example: node tailscale-proxy.js 9222 9223');
    process.exit(1);
  }

  const tsIP = getTailscaleIPv4();
  if (!tsIP) {
    console.error('Error: Tailscale IPv4 address not detected. Make sure Tailscale is connected.');
    process.exit(1);
  }

  console.log(`Detected Tailscale IP: ${tsIP}`);
  const servers = ports.map((port) => createProxy(tsIP, port));

  process.on('SIGINT', () => {
    console.log('\nShutting down proxies...');
    servers.forEach((s) => s.close());
    process.exit(0);
  });
}
