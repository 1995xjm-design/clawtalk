/**
 * Claude Bridge Server — 把 OpenClaw 网关的请求转发给 Claude
 *
 * 让 ClawTalk 能添加「Claude」频道：
 *   ClawTalk → OpenClaw Gateway(:18789) → openclaw:claude → 本桥 → Claude
 *
 * 本服务实现 OpenAI 兼容的:
 *   POST /v1/chat/completions    (Chat Completions，OpenClaw 默认用这个)
 *   POST /v1/responses           (Open Responses，可选)
 *
 * Claude 后端支持两种来源（按优先级）:
 *   1) ANTHROPIC_API_KEY 环境变量 → 直接调 Anthropic API
 *   2) 本地 claude CLI（已登录）→ spawn `claude -p`
 *
 * 用法:
 *   node claude-bridge-server.js
 *   环境变量:
 *     CLAUDE_BRIDGE_PORT   监听端口，默认 18791
 *     CLAUDE_MODEL         Claude 模型名，默认 claude-sonnet-4-6
 *     ANTHROPIC_API_KEY    Anthropic API key（可选，有则走 API）
 *     CLAUDE_CLI_PATH      claude 可执行路径（默认 claude，走 PATH）
 *
 * 认证：要求 Bearer token（与 ClawTalk 设置里的网关 token 一致），
 *      通过环境变量 CLAUDE_BRIDGE_TOKEN 设定；不设则不校验。
 */

'use strict';

const http = require('http');
const { URL } = require('url');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

// ---------- 轻量 .env 读取 ----------
try {
  const envPath = path.join(__dirname, '.env');
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
} catch (_) { /* .env 可选 */ }

const PORT = parseInt(process.env.CLAUDE_BRIDGE_PORT || '18791', 10);
const MODEL = process.env.CLAUDE_MODEL || 'claude-sonnet-4-6';
const BRIDGE_TOKEN = process.env.CLAUDE_BRIDGE_TOKEN || '';
const API_KEY = process.env.ANTHROPIC_API_KEY || '';
const CLI_PATH = process.env.CLAUDE_CLI_PATH || 'claude';
const API_BASE = process.env.ANTHROPIC_API_BASE || 'https://api.anthropic.com/v1';

function log(...args) { console.log(new Date().toISOString(), ...args); }

// ---------- Claude 后端 ----------
async function callClaude(messages, { stream = false, signal } = {}) {
  const system = messages.filter(m => m.role === 'system').map(m => m.content).join('\n');
  const conversation = messages.filter(m => m.role !== 'system');

  if (API_KEY) {
    return callAnthropicAPI(conversation, system, { stream, signal });
  }
  return callClaudeCLI(conversation, system, { stream, signal });
}

async function callAnthropicAPI(conversation, system, { stream = false, signal } = {}) {
  const body = {
    model: MODEL,
    max_tokens: 4096,
    system: system || undefined,
    messages: conversation.map(m => ({
      role: m.role === 'assistant' ? 'assistant' : 'user',
      content: Array.isArray(m.content) ? m.content.map(part => {
        if (part.type === 'text') return { type: 'text', text: part.text };
        if (part.type === 'image_url' || part.type === 'input_image') {
          const src = part.image_url?.url || part.source?.data || '';
          return { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: src.split(',')[1] || src } };
        }
        return { type: 'text', text: JSON.stringify(part) };
      }) : m.content,
    })),
  };
  if (stream) body.stream = true;

  const res = await fetch(`${API_BASE}/messages`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`anthropic ${res.status}: ${err.slice(0, 300)}`);
  }
  return res;
}

function callClaudeCLI(conversation, system, { stream = false, signal } = {}) {
  const prompt = [
    system ? `[System]\n${system}` : '',
    ...conversation.map(m => `[${m.role === 'assistant' ? 'Assistant' : 'User'}]\n${m.content}`),
    '[Assistant]\n',
  ].filter(Boolean).join('\n\n');

  const args = ['-p', prompt, '--model', MODEL];
  if (!stream) args.push('--output-format', 'text');

  const child = spawn(CLI_PATH, args, {
    env: { ...process.env },
    stdio: stream ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe'],
    shell: process.platform === 'win32',
  });
  if (signal) {
    signal.addEventListener('abort', () => child.kill('SIGTERM'), { once: true });
  }
  return child;
}

// ---------- OpenAI 兼容响应 ----------
function toOpenAIChunk(model, id, content, finishReason) {
  return {
    id,
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{
      index: 0,
      delta: content ? { content } : {},
      finish_reason: finishReason || null,
    }],
  };
}

function toOpenAIComplete(model, id, content, usage) {
  return {
    id,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
    usage: usage || { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
}

// ---------- HTTP 服务 ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const auth = req.headers.authorization || '';
  const bearer = auth.replace(/^Bearer\s+/i, '').trim();

  if (BRIDGE_TOKEN && bearer !== BRIDGE_TOKEN) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'unauthorized' }));
  }

  const sendJson = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  };

  try {
    // Chat Completions
    if (req.method === 'POST' && url.pathname === '/v1/chat/completions') {
      const body = JSON.parse(await readBody(req));
      const messages = body.messages || [];
      const stream = body.stream === true;
      const id = `chatcmpl-${Date.now()}`;

      log(`chat/completions stream=${stream} msgs=${messages.length}`);

      if (!stream) {
        const text = await collectClaudeText(messages);
        return sendJson(200, toOpenAIComplete(MODEL, id, text));
      }

      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      });
      res.write(`data: ${JSON.stringify(toOpenAIChunk(MODEL, id, '', null))}\n\n`);

      const child = await callClaude(messages, { stream: true });
      let buffer = '';
      const onData = (chunk) => {
        buffer += chunk.toString();
        // 按行分割，把 Claude 的 text_delta 转成 OpenAI chunk
        let idx;
        while ((idx = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, idx).trim();
          buffer = buffer.slice(idx + 1);
          if (!line) continue;
          try {
            const evt = JSON.parse(line);
            if (evt.type === 'content_block_delta' && evt.delta?.type === 'text_delta') {
              res.write(`data: ${JSON.stringify(toOpenAIChunk(MODEL, id, evt.delta.text, null))}\n\n`);
            }
          } catch (_) { /* 忽略非 JSON 行 */ }
        }
      };
      child.stdout?.on('data', onData);
      child.stderr?.on('data', (d) => log('claude stderr:', d.toString().slice(0, 200)));
      child.on('close', () => {
        try {
          res.write(`data: ${JSON.stringify(toOpenAIChunk(MODEL, id, '', 'stop'))}\n\n`);
          res.write('data: [DONE]\n\n');
        } catch (_) {}
        res.end();
      });
      child.on('error', (e) => {
        try {
          res.write(`data: ${JSON.stringify({ error: String(e) })}\n\n`);
        } catch (_) {}
        res.end();
      });
      return;
    }

    // Open Responses (简化，返回单个输出文本)
    if (req.method === 'POST' && url.pathname === '/v1/responses') {
      const body = JSON.parse(await readBody(req));
      const messages = body.input || [];
      const normalized = Array.isArray(messages) ? messages : [messages];
      const msgs = normalized.map(m => typeof m === 'string' ? { role: 'user', content: m } : m);
      const text = await collectClaudeText(msgs);
      return sendJson(200, {
        id: `resp-${Date.now()}`,
        object: 'response',
        created_at: Math.floor(Date.now() / 1000),
        status: 'completed',
        model: MODEL,
        output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }],
        usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
      });
    }

    // 健康检查
    if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/')) {
      return sendJson(200, { ok: true, service: 'claude-bridge', model: MODEL, backend: API_KEY ? 'anthropic-api' : 'claude-cli' });
    }

    sendJson(404, { error: 'not found' });
  } catch (err) {
    log('error:', err);
    sendJson(500, { error: String(err.message || err).slice(0, 300) });
  }
});

function collectClaudeText(messages) {
  return new Promise((resolve, reject) => {
    if (API_KEY) {
      callAnthropicAPI(messages, '', { stream: false })
        .then(async (res) => {
          const data = await res.json();
          const text = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('');
          resolve(text || '(empty)');
        })
        .catch(reject);
      return;
    }
    const child = callClaudeCLI(messages, '', { stream: false });
    let out = '', err = '';
    child.stdout.on('data', d => out += d.toString());
    child.stderr.on('data', d => err += d.toString());
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(`claude exited ${code}: ${err.slice(0, 200)}`));
      resolve(out.trim() || '(empty)');
    });
    child.on('error', reject);
  });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

server.listen(PORT, () => {
  log(`[claude-bridge] listening on http://127.0.0.1:${PORT}`);
  log(`[claude-bridge] model=${MODEL} backend=${API_KEY ? 'anthropic-api' : 'claude-cli'}`);
  if (!API_KEY && !BRIDGE_TOKEN) {
    log('[claude-bridge] ⚠️ 未设置 CLAUDE_BRIDGE_TOKEN，任何人可访问本服务');
  }
  if (!API_KEY) {
    log('[claude-bridge] ⚠️ 未设置 ANTHROPIC_API_KEY，将尝试调用本地 claude CLI（需已登录）');
  }
});
