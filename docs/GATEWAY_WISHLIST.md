# OpenClaw Gateway — Server-Side Changes for ClawTalk

Changes needed in the OpenClaw gateway to unlock full ClawTalk functionality.
Items are ordered by impact — #1 unlocks several downstream features.

---

## 1. Session Persistence for HTTP/WS API

**Status:** Not implemented
**Impact:** High — unlocks cron scheduling, SOUL.md injection, tool use, memory writes

Currently only auto-reply flows (Telegram, Discord) call `updateSessionStore()` to persist sessions. HTTP and WebSocket chat requests don't persist, which means:

- No SOUL.md system prompt injection
- No mid-conversation tool use (agent can't call tools between turns)
- No memory writes during conversation
- Sessions don't appear in the sessions list
- ClawTalk can't be treated as a channel for cron/scheduled messages

**Workaround:** ClawTalk sends full conversation history with every request.

**Fix:** Call `updateSessionStore()` after HTTP/WS agent command execution.

**Gateway files:**
- `src/gateway/openai-http.ts`
- `src/gateway/openresponses-http.ts`
- `src/gateway/server-methods/chat.ts`
- `src/commands/agent.ts` (lines 737-752)
- `src/config/sessions/store.ts` (lines 115-154)

---

## 2. HTTP `/v1/models` Endpoint

**Status:** Not implemented
**Impact:** Medium — model picker currently requires WebSocket

Gateway only supports `models.list` via WebSocket RPC. There is no HTTP equivalent, so ClawTalk's model picker only works when WebSocket is connected.

**Workaround:** Model picker hidden when WebSocket is off.

**Fix:** Add `GET /v1/models` handler returning the same data as the WebSocket RPC.

---

## 3. Expose Coding Tools in `/tools/invoke`

**Status:** Not implemented
**Impact:** Medium — File Read in Tools dashboard doesn't work

The `/tools/invoke` endpoint only exposes core OpenClaw tools. Coding tools (`read`, `write`, `edit`, `exec`) are only available during full agent execution, so they can't be invoked directly from the Tools dashboard.

**Workaround:** File Read tool shows as unavailable in the dashboard.

**Fix:** Add `createOpenClawCodingTools()` call to the tool invocation handler.

**Gateway file:** `src/gateway/tools-invoke-http.ts` (~line 249)

---

## 4. Fix `input_tokens` in Open Responses API

**Status:** Bug
**Impact:** Low — token display shows incorrect input count

`response.completed` events report incorrect `input_tokens`. `output_tokens` and `total_tokens` appear accurate.

**Workaround:** Token usage display works but input count is wrong.

**Gateway file:** `src/gateway/openresponses-http.ts`

---

## 5. WebSocket Chat Events: Model Name and Token Usage

**Status:** Not implemented
**Impact:** Medium — model name and token count unavailable in WebSocket mode

WebSocket chat push events don't include the model name or token usage data. The schema has a `usage` field but it's never populated.

**Workaround:** Model name and token usage display are disabled when WebSocket mode is active.

**Gateway files:**
- `src/gateway/server-chat.ts` (lines 341-477) — chat event emission
- `src/gateway/protocol/schema/logs-chat.ts` (lines 64-81) — chat event schema

---

## 6. v3 Device Auth Payload

**Status:** In source, not released
**Impact:** Low — v3 adds device metadata (platform, device family)

The deployed gateway npm package only supports v1/v2 auth payload format. v3 adds `|platform|deviceFamily` fields which would let the gateway distinguish device types (iPhone vs iPad, iOS vs Android).

**Workaround:** ClawTalk uses v2 format. v3 code is ready and will activate when the gateway is updated.

**Gateway file:** `src/client` — `buildDeviceAuthPayload` / `buildDeviceAuthPayloadV3`

---

## 7. Cron / Scheduled Messages to ClawTalk

**Status:** Blocked by #1
**Impact:** High — enables proactive agent-to-user messaging

If sessions are persisted (#1), ClawTalk channels could be treated like Telegram/Discord channels. This would enable:

- Cron-scheduled agent messages pushed to the phone
- Proactive notifications from the agent
- Scheduled reminders and check-ins
- Background task results delivered to the conversation

**Requires:** Session persistence (#1) + treating ClawTalk as a named channel target for cron jobs.

---

## 8. Memory/Tools via WebSocket RPC

**Status:** Not implemented
**Impact:** Low — optimization, not a blocker

Currently the Tools dashboard uses HTTP `POST /tools/invoke` even when WebSocket is connected. Routing `memory.search`, `tools.catalog`, and other tool calls through WebSocket RPC would reduce latency and reuse the existing connection.

**Workaround:** HTTP fallback works fine, just adds an extra connection.

---

## Dependencies

```
#1 Session Persistence
 └── #7 Cron / Scheduled Messages (blocked by #1)

#5 WS Model/Token Data
 └── removes need for #2 HTTP /v1/models (partially)
```

## Quick Reference: Current Workarounds in ClawTalk

| Gap | Workaround |
|-----|-----------|
| No session persistence | Send full conversation history every request |
| No HTTP `/v1/models` | Model picker only in WebSocket mode |
| No coding tools in `/tools/invoke` | File Read shows as unavailable |
| Wrong `input_tokens` | Display is inaccurate but functional |
| No model/tokens on WebSocket | Display disabled in WS mode |
| v3 auth not deployed | Use v2 payload format |
| No cron to ClawTalk | Not possible yet |
| Tools via HTTP only | Works, slightly higher latency |
