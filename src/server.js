// HTTP entry point.
//
//   GET  /api/here      parking rules at ?lat=&lon= (or ?address=)
//   GET  /api/nearby    nearest legal parking
//        add ?format=text to either for a plain-text answer (handy for Siri Shortcuts)
//   GET  /openapi.json  OpenAPI spec for a ChatGPT custom GPT Action
//   POST /mcp           MCP (Streamable HTTP) endpoint for ChatGPT connectors / Claude
//
// Set API_KEY to require a key, sent as `X-API-Key`, `Authorization: Bearer`,
// or `?key=` (the last one is for MCP clients that only take a URL).

import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createMcpServer } from './mcp.js';
import { openApiSpec } from './openapi.js';
import { UserError, nearestParking, parkingRulesHere } from './tools.js';

const API_KEY = process.env.API_KEY || '';

function authorized(req, url) {
  if (!API_KEY) return true;
  const given =
    req.headers['x-api-key'] ||
    req.headers.authorization?.replace(/^Bearer\s+/i, '') ||
    url.searchParams.get('key') ||
    '';
  const a = Buffer.from(String(given));
  const b = Buffer.from(API_KEY);
  return a.length === b.length && timingSafeEqual(a, b);
}

function send(res, status, body, type = 'application/json') {
  const text = type === 'application/json' ? JSON.stringify(body, null, 2) : String(body);
  res.writeHead(status, { 'content-type': `${type}; charset=utf-8` });
  res.end(text);
}

function baseUrl(req) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL.replace(/\/$/, '');
  const proto = req.headers['x-forwarded-proto'] ?? 'http';
  return `${proto}://${req.headers['x-forwarded-host'] ?? req.headers.host}`;
}

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : undefined;
}

async function handleMcp(req, res) {
  if (req.method !== 'POST') {
    // Stateless server: no standalone SSE stream or sessions to delete.
    return send(res, 405, { jsonrpc: '2.0', error: { code: -32000, message: 'Method not allowed' }, id: null });
  }
  const server = createMcpServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on('close', () => {
    transport.close();
    server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, await readJson(req));
}

async function handleApi(fn, url, res) {
  const args = Object.fromEntries(url.searchParams);
  try {
    const result = await fn(args);
    if (url.searchParams.get('format') === 'text') return send(res, 200, result.speech, 'text/plain');
    return send(res, 200, result);
  } catch (err) {
    const status = err instanceof UserError ? 400 : 502;
    const message = err instanceof UserError ? err.message : `Parking lookup failed: ${err.message}`;
    if (url.searchParams.get('format') === 'text') return send(res, status, message, 'text/plain');
    return send(res, status, { error: message, speech: message });
  }
}

export function createApp() {
  return createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (url.pathname === '/healthz') return send(res, 200, { ok: true });
      if (url.pathname === '/openapi.json') return send(res, 200, openApiSpec(baseUrl(req), { requireKey: Boolean(API_KEY) }));
      if (url.pathname === '/') {
        return send(res, 200, 'Seattle parking API. See /openapi.json, /api/here, /api/nearby and /mcp.', 'text/plain');
      }
      if (!authorized(req, url)) return send(res, 401, { error: 'Missing or invalid API key' });
      if (url.pathname === '/mcp') return await handleMcp(req, res);
      if (req.method === 'GET' && url.pathname === '/api/here') return await handleApi(parkingRulesHere, url, res);
      if (req.method === 'GET' && url.pathname === '/api/nearby') return await handleApi(nearestParking, url, res);
      return send(res, 404, { error: 'Not found' });
    } catch (err) {
      console.error(err);
      if (!res.headersSent) send(res, 500, { error: 'Internal error' });
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 3000);
  createApp().listen(port, () => {
    console.log(`Seattle parking listening on :${port}${API_KEY ? ' (API key required)' : ''}`);
  });
}
