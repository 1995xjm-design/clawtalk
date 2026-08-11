# 把 Claude 接入 ClawTalk — 桥接方案指南

> 创建：2026-08-10
> 目标：让 ClawTalk App 里能添加「Claude」频道，跟 Claude 对话。
> 原理：ClawTalk → OpenClaw 网关(:18789) → `openclaw:claude` → 本地桥 → Claude。

---

## 一、链路说明

```
ClawTalk(iPhone)
   │  HTTPS
   ▼
OpenClaw 网关 127.0.0.1:18789
   │  model = "openclaw:claude"  （路由到 claude agent）
   ▼
claude agent（在 openclaw.json 里新建，模型绑定 claude-bridge provider）
   │
   ▼
Claude Bridge Server  http://127.0.0.1:18791/v1   ← 本方案的桥
   │
   ▼
Claude（Anthropic API 或本地 claude CLI）
```

---

## 二、需要准备什么

- Node.js 18+（Windows 上跑桥，ClawTalk 工程 server 目录里已有 node 环境）
- Claude 后端两种方式**二选一**：
  - **方式 A（推荐）**：Anthropic API key（`sk-ant-...`），最稳定
  - **方式 B**：本地已登录的 claude CLI（Claude Code），不额外用 key

---

## 三、部署步骤

### 第 1 步：启动 Claude 桥

```bash
cd ClawTalk/server
copy .env.example .env
# 编辑 .env：
#   - 填 ANTHROPIC_API_KEY（方式A）  或 留空走本地 claude CLI（方式B）
#   - 建议设 CLAUDE_BRIDGE_TOKEN=<与网关一致或自定义>
node claude-bridge-server.js
```

验证：
```bash
curl http://127.0.0.1:18791/health
# → {"ok":true,"service":"claude-bridge",...}
```

### 第 2 步：在 OpenClaw 注册 claude provider

编辑 `C:\Users\Youhome\.openclaw-autoclaw\openclaw.json`，
在 `models.providers` 里新增：

```json
"claude-bridge": {
  "baseUrl": "http://127.0.0.1:18791/v1",
  "apiKey": "<CLAUDE_BRIDGE_TOKEN，若桥没设 token 可留空>",
  "api": "openai-completions",
  "models": [
    { "id": "claude", "name": "Claude", "contextWindow": 200000, "maxTokens": 32000, "reasoning": true }
  ]
}
```

### 第 3 步：新建 claude agent

在 `agents.list` 里新增：

```json
{
  "id": "claude",
  "name": "Claude",
  "model": "claude-bridge/claude"
}
```

（`model` 格式：`<providerId>/<modelId>`）

### 第 4 步：重启 OpenClaw 网关

```bash
openclaw gateway restart
# 或重启 AutoClaw / 托盘里的 OpenClaw
```

### 第 5 步：在 ClawTalk 添加 Claude 频道

1. 打开 ClawTalk → 频道列表 → 添加频道
2. 智能体列表里应出现 **claude**（来自网关 `agents_list`）
3. 选中 → 命名 → 添加
4. 开始对话

---

## 四、验证链路

```bash
# 1. 桥直接可用（非流式）
curl -X POST http://127.0.0.1:18791/v1/chat/completions \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude","messages":[{"role":"user","content":"你好"}],"stream":false}'

# 2. 经 OpenClaw 网关（模拟 ClawTalk 实际路径）
curl -X POST http://127.0.0.1:18789/v1/chat/completions \
  -H "Authorization: Bearer <gateway-token>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openclaw:claude","messages":[{"role":"user","content":"你好"}],"stream":false}'
```

---

## 五、注意事项

1. **桥与网关必须同一台机器**：Claude 桥监听 `127.0.0.1:18791`，OpenClaw 网关在同机才能访问。
2. **Token 建议设置**：`CLAUDE_BRIDGE_TOKEN` 不设则任何人可访问桥，建议至少与网关 token 一致。
3. **方式 B 依赖本地 claude CLI 已登录**：`claude auth status` 显示 `loggedIn: true` 才行；未登录会报错。
4. **模型名**：ClawTalk 的 agent 路由始终是 `openclaw:<agentId>`，模型的真正名字由 provider 决定，ClawTalk 端无需关心。
5. **会话持久化**：OpenClaw HTTP API 默认不持久化会话，ClawTalk 每次带全量历史（符合当前网关行为）。
6. **端口冲突**：若 18791 被占，改 `.env` 的 `CLAUDE_BRIDGE_PORT`，并同步 openclaw.json 的 `baseUrl`。

---

## 六、文件清单

| 文件 | 说明 |
|---|---|
| `server/claude-bridge-server.js` | Claude 桥接服务（本方案核心） |
| `server/.env.example` | 桥的环境变量模板 |
| 本文件 `CLAUDE-BRIDGE-GUIDE.md` | 接入指南 |
