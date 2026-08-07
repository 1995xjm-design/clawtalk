/**
 * ClawTalk Bridge — 薄代理服务器（零第三方依赖，Node 18+）
 *
 * 为 ClawTalk 键盘扩展提供 M4 规范的两个自定义端点，并把其余请求
 * 反向代理到 OpenClaw 网关，实现"单端点访问"：
 *
 *   GET  /contacts            -> 本地 profiles/contacts.json
 *   POST /api/reply-suggest   -> 透传 Bearer -> 网关 chat/completions 生成候选
 *   其他路径                   -> 反向代理到 GATEWAY_UPSTREAM（默认 http://127.0.0.1:18789）
 *
 * 认证：透传客户端 Authorization 头到网关，本服务不持有任何密钥。
 *
 * 配置（环境变量，支持 .env 文件）：
 *   BRIDGE_PORT      监听端口，默认 18790
 *   GATEWAY_UPSTREAM 上游 OpenClaw 网关，默认 http://127.0.0.1:18789
 *   AGENT_ID         目标 agent，默认 main（model 拼 openclaw:main）
 *   PROFILES_DIR     联系人档案目录，默认 ./profiles
 *
 * 运行：node server.js
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

// ---------- 轻量 .env 读取（不引第三方依赖） ----------
try {
  const envPath = path.join(__dirname, '.env');
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
} catch (_) { /* .env 可选 */ }

const PORT = parseInt(process.env.BRIDGE_PORT || '18790', 10);
const UPSTREAM = process.env.GATEWAY_UPSTREAM || 'http://127.0.0.1:18789';
const AGENT_ID = process.env.AGENT_ID || 'main';
const PROFILES_DIR = path.resolve(__dirname, process.env.PROFILES_DIR || 'profiles');
const CONTACTS_FILE = path.join(PROFILES_DIR, 'contacts.json');

// ---------- 联系人档案 ----------
function loadContacts() {
  try {
    const raw = fs.readFileSync(CONTACTS_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    const arr = Array.isArray(parsed) ? parsed : parsed.contacts;
    if (!Array.isArray(arr)) return [];
    return arr.filter(c => c && typeof c.id === 'string' && c.id.length > 0);
  } catch (_) {
    return [];
  }
}

function findProfile(contactId) {
  if (!contactId) return null;
  const p = path.join(PROFILES_DIR, `${contactId}.json`);
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (_) {
    const c = loadContacts().find(x => x.id === contactId);
    return c || null;
  }
}

// ---------- 调用 OpenClaw 网关 chat/completions ----------
async function callGateway(messages, authHeader, count) {
  const url = new URL(`${UPSTREAM}/v1/chat/completions`);
  const body = JSON.stringify({
    model: `openclaw:${AGENT_ID}`,
    messages,
    stream: false,
    max_tokens: 800,
  });

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader || '',
    },
    body,
    signal: AbortSignal.timeout(60000),
  });

  if (!res.ok) {
    const errText = (await res.text()).slice(0, 300);
    const err = new Error(`gateway ${res.status}: ${errText}`);
    err.status = res.status;
    throw err;
  }

  const data = await res.json();
  const content = data?.choices?.[0]?.message?.content || '';
  return parseSuggestions(content, count);
}

// 从 LLM 输出中抽取候选：优先 JSON 数组 / 行号列表 / 纯文本按行切
function parseSuggestions(content, count) {
  const cleaned = content.trim();
  if (!cleaned) return [];

  let candidates = [];

  // JSON 数组形式：["...", "..."]
  const jsonMatch = cleaned.match(/\[[\s\S]*\]/);
  if (jsonMatch) {
    try {
      const arr = JSON.parse(jsonMatch[0]);
      if (Array.isArray(arr)) candidates = arr.filter(x => typeof x === 'string');
    } catch (_) { /* 落到文本解析 */ }
  }

  // 行号列表形式：1. xxx / - xxx / **1. xxx**
  if (candidates.length === 0) {
    candidates = cleaned
      .split(/\r?\n/)
      .map(l => l.replace(/^\s*(?:\d+[.)、]|[-*•]|#+|\*\*)?\s*/, '').trim())
      .filter(l => l.length > 2 && l.length < 200 && !/^(回复|候选|建议|suggestion)/i.test(l));
  }

  // 去重 + 截断
  const seen = new Set();
  const out = [];
  for (const s of candidates) {
    const key = s.replace(/[，。！？!?,. ]/g, '');
    if (key.length < 3 || seen.has(key)) continue;
    seen.add(key);
    out.push(s);
    if (out.length >= count) break;
  }
  return out;
}

// 组装数字孪生推演 prompt
function buildPrompt(profile, text, style) {
  const name = profile?.name || '对方';
  const profileText = profile?.profile
    ? `\n【${name}的画像】\n${profile.profile}`
    : `\n【${name}的画像】暂无档案，请按通用高情商处理。`;

  const styleLine = style ? `\n【语气要求】${style}` : '';
  const system = [
    `你是 ${name} 的恋爱参谋，擅长高情商回复。`,
    `先扮演 ${name} 数字孪生，推演"我这句话该怎么回最能打动 TA"，再生成候选。`,
    profileText,
    styleLine,
    `\n要求：输出 ${text ? '' : '最多'}5 条候选，每条一句话，自然口语、不油腻、不重复、不要任何解释或编号以外的格式。`,
  ].join('\n');

  return [
    { role: 'system', content: system },
    { role: 'user', content: text || '（对方没有具体输入，给我几句通用的高情商开场/回复）' },
  ];
}

// ---------- HTTP 服务 ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const auth = req.headers.authorization || '';
  const method = req.method || 'GET';

  const sendJson = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  };

  try {
    // GET /contacts
    if (method === 'GET' && url.pathname === '/contacts') {
      const contacts = loadContacts().map(c => ({
        id: c.id,
        name: c.name || c.id,
        profileScore: typeof c.profileScore === 'number' ? c.profileScore : 0.0,
        lastActive: c.lastActive || '',
      }));
      return sendJson(200, { contacts });
    }

    // POST /api/reply-suggest
    if (method === 'POST' && url.pathname === '/api/reply-suggest') {
      let body = {};
      try {
        body = JSON.parse(await readBody(req));
      } catch (_) {
        return sendJson(400, { error: 'invalid JSON body' });
      }

      const text = (body.text || '').trim();
      if (!text) return sendJson(400, { error: 'text is required' });

      const count = Math.min(Math.max(parseInt(body.count, 10) || 5, 1), 10);
      const style = typeof body.style === 'string' && body.style.trim() ? body.style.trim() : null;
      const profile = findProfile(body.contact_id);

      const messages = buildPrompt(profile, text, style);
      const suggestions = await callGateway(messages, auth, count);
      return sendJson(200, { suggestions });
    }

    // 反向代理：其余所有路径转发到 OpenClaw 网关
    const upstreamUrl = new URL(url.pathname + url.search, UPSTREAM);
    const upstreamRes = await fetch(upstreamUrl, {
      method,
      headers: filterHopHeaders(req.headers),
      body: ['GET', 'HEAD'].includes(method) ? undefined : await readBody(req),
      signal: AbortSignal.timeout(90000),
    });

    const respBody = await upstreamRes.arrayBuffer();
    const respHeaders = {};
    for (const [k, v] of upstreamRes.headers) {
      if (!/^(transfer-encoding|connection|keep-alive|content-encoding)$/i.test(k)) respHeaders[k] = v;
    }
    res.writeHead(upstreamRes.status, respHeaders);
    res.end(Buffer.from(respBody));
  } catch (err) {
    const status = err.status || 500;
    if (status === 401) {
      return sendJson(401, { error: 'unauthorized: gateway rejected token' });
    }
    if (status === 502 || err.code === 'ECONNREFUSED') {
      return sendJson(502, { error: `gateway unreachable at ${UPSTREAM}` });
    }
    if (err.name === 'TimeoutError' || err.name === 'AbortError') {
      return sendJson(504, { error: 'gateway timeout' });
    }
    sendJson(500, { error: String(err.message || err).slice(0, 300) });
  }
});

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function filterHopHeaders(headers) {
  const out = {};
  for (const [k, v] of Object.entries(headers)) {
    if (!/^(host|connection|keep-alive|transfer-encoding|content-length)$/i.test(k)) out[k] = v;
  }
  return out;
}

server.listen(PORT, () => {
  console.log(`[clawtalk-bridge] listening on http://0.0.0.0:${PORT}`);
  console.log(`[clawtalk-bridge] upstream  -> ${UPSTREAM}`);
  console.log(`[clawtalk-bridge] agent     -> openclaw:${AGENT_ID}`);
  console.log(`[clawtalk-bridge] contacts  -> ${CONTACTS_FILE} (${loadContacts().length} 个档案)`);
});
