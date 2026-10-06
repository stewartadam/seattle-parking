import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/server.js';

let server;
let base;

before(async () => {
  server = createApp();
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test('health and OpenAPI endpoints respond', async () => {
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  const spec = await (await fetch(`${base}/openapi.json`)).json();
  assert.ok(spec.paths['/api/here']);
  assert.ok(spec.paths['/api/nearby']);
});

test('API rejects requests without a location', async () => {
  const res = await fetch(`${base}/api/here`);
  assert.equal(res.status, 400);
  assert.match((await res.json()).speech, /lat and lon, or an address/);
});

test('MCP endpoint lists both tools', async () => {
  const res = await fetch(`${base}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
  });
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.match(text, /parking_rules_here/);
  assert.match(text, /find_nearest_parking/);
});
