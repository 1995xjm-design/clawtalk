# ClawTalk Bridge（M4 后端薄代理）

为 ClawTalk 键盘扩展提供 M4 规范的两个自定义端点，并反向代理 OpenClaw 网关。
零第三方依赖，Node 18+ 即可运行（本机 Node v22 已验证）。

## 运行

```bash
cd server/bridge
node server.js
# 默认监听 0.0.0.0:18790，上游 http://127.0.0.1:18789，agent 固定 openclaw:main
```

配置可用环境变量或 `.env`（复制 `.env.example` 改名）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `BRIDGE_PORT` | `18790` | 监听端口 |
| `GATEWAY_UPSTREAM` | `http://127.0.0.1:18789` | 上游 OpenClaw 网关 |
| `AGENT_ID` | `main` | 目标 agent，拼成 model `openclaw:<id>` |
| `PROFILES_DIR` | `./profiles` | 联系人档案目录 |

## 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/contacts` | 返回 `{contacts:[{id,name,profileScore,lastActive}]}`，无档案返回空数组 |
| POST | `/api/reply-suggest` | body `{contact_id,text,count,style}` → `{suggestions:[...]}`，最多 10 条 |
| 任意 | 其他路径 | 反向代理到 OpenClaw 网关（保留 Authorization，/v1/chat/completions 等原样转发） |

认证：透传客户端 `Authorization: Bearer <token>` 到网关，本服务不持有密钥。

## 联系人档案

- `profiles/contacts.json` — 联系人列表（键盘「选对象」数据源）
- `profiles/<id>.json` — 可选画像详情（喂给 LLM 做数字孪生推演），缺省时用列表条目兜底

画像字段：`id` / `name` / `profileScore`(0~1) / `lastActive` / `profile`(自由文本画像，喂 prompt)。

## 冒烟验证

```bash
# 1. 联系人列表（无档案应返回空数组）
curl -s http://127.0.0.1:18790/contacts

# 2. 生成回复候选（token 与 ClawTalk 设置里一致）
curl -s -X POST http://127.0.0.1:18790/api/reply-suggest \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <gateway-token>" \
  -d '{"contact_id":"mengyao","text":"今天好累啊","count":5,"style":"温柔"}'

# 3. 反向代理透传（验证 ClawTalk 原有聊天链路）
curl -s -X POST http://127.0.0.1:18790/v1/chat/completions \
  -H "Authorization: Bearer <gateway-token>" \
  -H "Content-Type: application/json" \
  -d '{"model":"openclaw:main","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## 联调配置

ClawTalk App 设置里的 gateway_url 直接填桥接地址（如 `http://192.168.x.x:18790` 或 Tailscale 地址），
键盘的 /contacts、/api/reply-suggest 和主 App 的 /v1/chat/completions 走同一入口。
