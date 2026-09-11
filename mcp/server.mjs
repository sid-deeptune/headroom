#!/usr/bin/env node
// headroom: a 1-tool MCP server that reports subscription quota headroom across
// providers. No dependencies — raw JSON-RPC 2.0 over stdio.
//
// It reads only the cache file the Headroom menu bar app writes after each poll. It
// never calls a provider endpoint, so calling this tool costs no quota and cannot
// contribute to rate limiting, however often it runs.

import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const SNAPSHOT_PATH =
  process.env.HEADROOM_USAGE_FILE || join(homedir(), '.cache/headroom/usage.json');

// The app polls every 15 minutes. Two missed polls means it is probably not running,
// and the numbers below should not be trusted for a routing decision.
const STALE_AFTER_MS = 30 * 60 * 1000;

const TOOLS = [
  {
    name: 'headroom_usage',
    description:
      'Report how much subscription quota is left across every AI provider tracked by ' +
      'the Headroom menu bar app: two Claude accounts (Claude Deeptune, Claude Mercor), ' +
      'Codex (OpenAI), and Kimi. Returns each rolling ' +
      'window with its percent used and reset time. Reads a local cache written by the ' +
      'app — it makes no network calls and consumes no quota, so it is safe to call ' +
      'freely. Call it before delegating work across providers, before a long or highly ' +
      'parallel run, and whenever you need to choose the provider with the most capacity.',
    inputSchema: { type: 'object', properties: {} },
  },
];

// "3d 1h", "2h 10m", "45s" — two units at most, which is all a routing decision needs.
function duration(ms) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  const units = [
    ['d', 86400],
    ['h', 3600],
    ['m', 60],
    ['s', 1],
  ];
  const parts = [];
  let rest = seconds;
  for (const [suffix, size] of units) {
    const n = Math.floor(rest / size);
    rest -= n * size;
    if (n) parts.push(`${n}${suffix}`);
    if (parts.length === 2) break;
  }
  return parts.length ? parts.join(' ') : '0s';
}

function resetText(resetsAt, now) {
  if (!resetsAt) return '';
  const at = Date.parse(resetsAt);
  if (Number.isNaN(at)) return '';
  return at <= now ? 'reset due' : `resets in ${duration(at - now)}`;
}

function render(snapshot, now) {
  const lines = [];
  const age = now - Date.parse(snapshot.updatedAt);
  lines.push(`Headroom snapshot ${duration(age)} old (${snapshot.updatedAt})`);
  if (age > STALE_AFTER_MS) {
    lines.push(
      'STALE: Headroom polls every 15 minutes, so the app is probably not running. ' +
        'Treat these numbers as a lower bound on usage and open Headroom.app to refresh.'
    );
  }
  lines.push('');

  const providers = Object.entries(snapshot.providers || {}).sort(([a], [b]) => a.localeCompare(b));
  let tightest = null;

  for (const [name, state] of providers) {
    const windows = state.windows || [];
    if (!windows.length) {
      lines.push(`${name}: no data${state.error ? ` — ${state.error}` : ''}`);
      continue;
    }
    for (const window of windows) {
      const reset = resetText(window.resetsAt, now);
      lines.push(
        `${name} ${window.label} — ${Math.round(window.percent)}% used${reset ? `, ${reset}` : ''}`
      );
      if (!tightest || window.percent > tightest.percent) {
        tightest = { name, label: window.label, percent: window.percent };
      }
    }
    // A provider that errored still shows its last good windows, exactly as the menu
    // does. Say so, or the numbers read as current.
    if (state.error) {
      lines.push(`${name}: last refresh failed — ${state.error}. Values above are older.`);
    }
  }

  lines.push('');
  lines.push(
    tightest
      ? `Tightest window: ${tightest.name} ${tightest.label} at ${Math.round(tightest.percent)}%.`
      : 'No usage data for any provider.'
  );
  return lines.join('\n');
}

async function callTool(name) {
  if (name !== 'headroom_usage') return { text: `Unknown tool: ${name}`, isError: true };

  let raw;
  try {
    raw = await readFile(SNAPSHOT_PATH, 'utf8');
  } catch (err) {
    const missing = err.code === 'ENOENT';
    return {
      text: missing
        ? `No Headroom snapshot at ${SNAPSHOT_PATH}. The Headroom menu bar app writes it ` +
          `on every poll — start Headroom.app and try again.`
        : `Cannot read ${SNAPSHOT_PATH}: ${err.message}`,
      isError: true,
    };
  }

  let snapshot;
  try {
    snapshot = JSON.parse(raw);
  } catch {
    return { text: `${SNAPSHOT_PATH} is not valid JSON.`, isError: true };
  }

  return { text: render(snapshot, Date.now()), isError: false };
}

// ---- JSON-RPC 2.0 over stdio ----

const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

async function handle(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;

  switch (method) {
    case 'initialize':
      return reply(id, {
        protocolVersion: params?.protocolVersion || '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: {
          name: 'headroom',
          version: '1.0.0',
          description:
            'Reports remaining subscription quota across two Claude accounts, Codex, and Kimi, read ' +
            'from the Headroom menu bar app cache. No network calls, no quota cost.',
        },
      });
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return;
    case 'ping':
      return reply(id, {});
    case 'tools/list':
      return reply(id, { tools: TOOLS });
    case 'tools/call': {
      const { text, isError } = await callTool(params?.name);
      return reply(id, { content: [{ type: 'text', text }], isError });
    }
    default:
      if (isRequest) fail(id, -32601, `Method not found: ${method}`);
  }
}

let buf = '';
process.stdin.on('data', async (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    try {
      await handle(msg);
    } catch (err) {
      if (msg.id !== undefined && msg.id !== null) fail(msg.id, -32603, String(err?.message || err));
    }
  }
});

// No explicit exit on stdin end: the process has no other handles, so Node exits once
// the last in-flight call has replied. `process.exit()` here would drop that reply.
process.stderr.write('headroom MCP server started\n');
