#!/usr/bin/env node
// Standalone MCP client for the Godot Editor MCP service.
//
// Answers one question from a plain shell, with no AI client involved:
//   "is the service up, and is the Godot editor actually attached to it?"
//
// Usage:
//   node scripts/godot-mcp-probe.mjs                 # service + bridge status
//   node scripts/godot-mcp-probe.mjs --tools         # also count godot_* tools
//   node scripts/godot-mcp-probe.mjs --require-bridge # exit 3 if no editor attached
//
// Environment:
//   GODOT_MCP_URL         full MCP endpoint (default http://127.0.0.1:<port>/mcp)
//   GODOT_MCP_HTTP_PORT   default 9090
//
// Exit codes: 0 = service reachable, 2 = service unreachable, 3 = no bridge (with
// --require-bridge only). A reachable service with bridge_connected=false means
// the server is fine and Godot is not: open the project, check the addon.

const PORT = process.env.GODOT_MCP_HTTP_PORT || '9090';
const BASE = process.env.GODOT_MCP_URL || `http://127.0.0.1:${PORT}/mcp`;
const wantTools = process.argv.includes('--tools');
const requireBridge = process.argv.includes('--require-bridge');

let sid = null;

function headers() {
  const h = {
    'content-type': 'application/json',
    'accept': 'application/json, text/event-stream',
  };
  if (sid) h['mcp-session-id'] = sid;
  return h;
}

async function rpc(method, params, id) {
  const res = await fetch(BASE, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
  });
  const s = res.headers.get('mcp-session-id');
  if (s) sid = s;
  const text = await res.text();
  const line = text.split(/\r?\n/).find((l) => l.startsWith('data:'));
  if (line) return JSON.parse(line.slice(5).trim());
  return text.trim() ? JSON.parse(text) : null;
}

async function notify(method, params) {
  await fetch(BASE, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({ jsonrpc: '2.0', method, params }),
  });
}

const t0 = Date.now();

let init;
try {
  init = await rpc('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'godot-mcp-probe', version: '1.0' },
  }, 1);
} catch (err) {
  console.error(`service      : UNREACHABLE at ${BASE}`);
  console.error(`               ${err?.cause?.code || err?.message || err}`);
  console.error('               start it: scripts\\godot-mcp-service.cmd');
  process.exit(2);
}

console.log('endpoint     :', BASE);
console.log('initialize   :', init?.result?.serverInfo
  ? `${init.result.serverInfo.name} ${init.result.serverInfo.version}`
  : JSON.stringify(init)?.slice(0, 200));
console.log('session id   :', sid ? 'assigned' : '(none)');

await notify('notifications/initialized', {});

const list = await rpc('tools/list', {}, 2);
const names = (list?.result?.tools ?? []).map((t) => t.name);
console.log('tools/list   :', names.length, 'tools');

const health = await rpc('tools/call', { name: 'godot_health_check', arguments: {} }, 3);
const payload = health?.result?.content?.[0]?.text ?? JSON.stringify(health);
let parsed;
try { parsed = JSON.parse(payload); } catch { parsed = { raw: payload?.slice(0, 300) }; }
console.log('health       :', JSON.stringify({
  bridge_connected: parsed.bridge_connected,
  addon_version: parsed.addon_version,
  transport: parsed.transport,
}));

if (wantTools) {
  console.log('godot tools  :', names.filter((n) => n.startsWith('godot_')).length);
}
console.log('elapsed      :', Date.now() - t0, 'ms');

if (requireBridge && parsed.bridge_connected !== true) {
  console.error('bridge       : NOT CONNECTED - is the project open in the Godot editor?');
  process.exit(3);
}
