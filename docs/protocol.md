# Hanako 移动端协议逆向文档

> 逆向自官方移动端 JS bundle（`http://<server>:<port>/mobile/assets/*.js`），用于鸿蒙原生客户端开发。
> 逆向日期：2026-08-07。协议无官方文档，随服务端版本变化，开发时以实际响应为准。

## 1. 连接与鉴权

### 1.1 连接形态

服务端通过 `GET /api/server/identity` 返回连接身份信息，含 `kind`（local / lan / custom_remote / relay / cloud）、`serverId`、`userId`、`capabilities`、`serverProtocol`。

| kind | 说明 | 凭证 |
|---|---|---|
| local | 本机回环 | loopback_token |
| lan | 可信局域网 | device_credential / user_session |
| relay / cloud | 官方中继 | user_session |

移动端（浏览器/壳）走 lan 形态：`http://<ip>:<port>/mobile/`。

### 1.2 登录（访问密钥）

```
POST /api/web-auth/login
Content-Type: application/json
credentials: include
body: {"credential": "<访问密钥>"}
```
成功后服务端种 HttpOnly 会话 cookie，后续请求带 cookie 即可。

```
GET /api/server/identity
Authorization: Bearer <访问密钥>
```
返回 `{serverId, userId, serverNodeId, studioId, version, capabilities, ...}`。

其他：`GET /api/web-auth/session`（会话状态）、`POST /api/web-auth/logout`（登出）。

### 1.3 移动端引导

```
GET /api/mobile/bootstrap
```
返回：`{appearance, editor, chat, locale, agentName, currentAgentId, userName, agentYuan, agents: [{id, name, yuan, ...}]}`。

## 2. WebSocket 实时通道

### 2.1 连接建立

1. `POST /api/ws-ticket`（带 cookie / Bearer）→ `{"ticket": "..."}`
2. 连接 `ws(s)://<host>/ws?wsTicket=<ticket>`
3. 连接成功后客户端发送：
```json
{"type":"context_usage","sessionPath":"<path>","sessionId":"<id>"}
```
4. 若有正在流式输出的会话，发送 `resume_stream` 恢复。

### 2.2 重连策略（客户端侧）

指数退避：1s → 2s → 4s … 上限 30s；连续失败 20 次后固定 60s。重连后对 streaming 会话发 `resume_stream`，并对 `resource-io` 做 catch-up（`GET /api/resource-io/events?since=<seq>`）。

### 2.3 消息帧

所有 WS 消息为 JSON。服务端→客户端事件可能携带 `seq`（流式序列号，用于断线恢复去重）与 `sessionPath` / `sessionId`。

## 3. WebSocket 事件（服务端 → 客户端）

### 3.1 流式事件（chat streaming）

| type | 字段 | 说明 |
|---|---|---|
| `text_delta` | delta | 正文增量，累积渲染 |
| `thinking_start` | — | 开始思考块 |
| `thinking_delta` | delta | 思考增量 |
| `thinking_end` | — | 结束思考块 |
| `mood_start` | — | 开始 mood 块 |
| `mood_text` | delta | mood 增量 |
| `mood_end` | — | 结束 mood 块 |
| `card_start` | attrs {type, plugin, route, title} | 插件卡片开始 |
| `card_text` | delta | 卡片描述增量 |
| `card_end` | — | 卡片结束 |
| `tool_start` | {id, name, args} | 工具开始 |
| `tool_end` | {id, name, success, status, error, details} | 工具结束 |
| `content_block` | block | 完整内容块（file / session_confirmation 等） |
| `turn_end` | turnInputEntryId, userEntryId, assistantEntryId | 一轮结束 |
| `compaction_start` / `compaction_end` | — | 上下文压缩 |
| `status` | isStreaming, streamId, turnId | 流式状态 |
| `abort_result` | status | 中止结果 |
| `error` | sessionPath, code, message | 错误 |

### 3.2 状态事件

| type | 关键字段 | 说明 |
|---|---|---|
| `session_user_message` | sessionPath, message, clientMessageId | 用户消息落盘确认（乐观更新匹配用） |
| `session_title` | path, title | 会话标题更新 |
| `session_created` | — | 新会话 |
| `session_metadata_updated` | sessionPath, sessionId, metadata {pinnedAt, pinOrder, projectId, thinkingLevel} | 会话元数据 |
| `session_branch_reset` | sessionPath, clientMessageId, messageId, projectionMessageId, todos | 分支重置 |
| `stream_resume` | events[], nextSeq, isStreaming, runtimeIsStreaming, truncated, reset | 断线恢复重放 |
| `block_update` | taskId, patch, sessionPath | 内容块增量补丁 |
| `context_usage` | tokens, window, percent | 上下文占用 |
| `todo_update` | sessionPath, todos[] | 待办更新 |
| `activity_update` / `agent_activity` | activity / entry | 活动流 |
| `notification` | title, body, agentId | 通知（可做本地推送） |
| `channel_new_message` | channelName, message | 频道新消息 |
| `channel_created` | — | 频道创建 |
| `dm_new_message` | — | 私信新消息 |
| `browser_status` / `browser_bg_status` | sessionPath, running, url, thumbnail | 浏览器状态 |
| `computer_overlay` | sessionPath, phase, action, agentId | 电脑操控覆盖层 |
| `confirmation_resolved` | confirmId, action | 确认结果 |
| `plan_mode` / `permission_mode` / `access_mode` | mode / enabled / readOnly | 模式切换 |
| `resource.changed` / `resource.deleted` / `resource.renamed` | sequence, ref | 文件系统事件 |
| `bridge_status` / `bridge_message` | — | 桥接 |
| `app_event` | event.type, payload | 应用事件 |
| `apply_frontend_setting` | key, value | 前端设置（theme 等） |

## 4. WebSocket 消息（客户端 → 服务端）

```json
// 发送用户消息（type: prompt / interject）
{
  "type": "prompt",
  "clientMessageId": "<uuid>",
  "text": "消息文本",
  "sessionId": "<id>",
  "sessionPath": "<path>",
  "uiContext": {},
  "displayMessage": {},
  "sessionFileRefs": [{"fileId":"...","path":"..."}],   // 可选
  "images": [], "videos": [], "audios": [],              // 可选
  "skills": [], "sessionRefs": [], "agentReviewRequests": []  // 可选
}
```

```json
// 断线恢复
{"type":"resume_stream","sessionPath":"<path>","sessionId":"<id>","streamId":"...","sinceSeq":123}

// 上下文占用上报
{"type":"context_usage","sessionPath":"<path>","sessionId":"<id>"}
```

## 5. 数据模型

### 5.1 Session（会话）

```
path: string（唯一，如 "2026-08-07/xxxx"）
sessionId: string
title: string
agentId?: string
pinnedAt?: string | null
pinOrder?: number | null
projectId?: string | null
hasSummary?: boolean
lastMessage?: string
lastTimestamp?: string
```

### 5.2 Message（消息）

```
id: string
clientMessageId?: string
sourceEntryId?: string
role: "user" | "assistant"
text: string
textHtml?: string        // user 消息由 markdown 转 HTML
timestamp: number | string
attachments?: [{fileId, path, name, isDir, mimeType, ...}]
sendStatus?: "pending" | "confirmed" | "failed"
blocks?: Block[]          // assistant 消息
quotedText?, skills?, sessionRefs?, agentMentions?, agentReview?
```

### 5.3 Block（assistant 消息内容块）

| type | 结构 |
|---|---|
| `text` | {type, html, source} |
| `thinking` | {type, content, sealed} |
| `mood` | {type, yuan, text} |
| `tool_group` | {type, tools: [{id, name, args, done, success, status, error, details}], collapsed} |
| `plugin_card` | {type, card: {type, pluginId, route, title, description}} |
| `file` | {type, fileId, filePath, label, ext, mime, size, status, ...} |
| `media_generation` | {type, taskId, status} |
| `session_confirmation` | {type, confirmId, status, surface, ...} |
| `interlude` | {type, ...} |

### 5.4 Channel / DM

```
id: string（DM 为 "dm:<peerId>"）
name: string
members: string[]
lastMessage / lastSender / lastTimestamp
newMessageCount / messageCount
isDM: boolean
dmOwnerId?, peerId?, peerName?
```

## 6. REST API 清单（88 端点）

### 会话
- `GET /api/sessions` 会话列表（**返回数组**，非 `{sessions}`）；字段：path(jsonl 完整路径)、sessionId(sess_xxx)、title、firstMessage、modified(ISO)、revision、messageCount、cwd、agentId、agentName、permissionMode、pinnedAt、pinOrder、hasSummary 等
- `GET /api/sessions/messages?sessionId=<id>&limit=200&offset=0` 会话历史消息（**实测确认**，分页用 limit+offset）；返回 `{messages:[{id, sourceIndex, entryId, role, content, thinking, toolCalls:[{id,name,args,status,success}], timestamp, turnInputEntryId, turnInputVisible}]}`，user 的 content 为纯文本，assistant 的 content 为 markdown、thinking 为思考 markdown
- `POST /api/sessions/switch` 切换会话
- `POST /api/sessions/rename` 重命名
- `POST /api/sessions/pin` / `pin-order` 置顶
- `POST /api/sessions/archive` / `GET /api/sessions/archived` / `restore` / `archived/delete` 归档
- `POST /api/sessions/new-detached` 新建分离会话
- `POST /api/sessions/cleanup` 清理
- `GET /api/sessions/summary?path=` 会话摘要
- `GET /api/sessions/search?q=&phase=title|content&limit=` 搜索
- `GET /api/sessions/find?path=&q=` 会话内查找
- `POST /api/sessions/todos/complete` 待办完成
- `GET /api/sessions/fresh-compact` / `continue-deleted-agent`

### 频道 / 私信
- `GET /api/channels` / `POST /api/channels` 列表/创建
- `GET /api/channels/{id}` / `DELETE /api/channels/{id}` 详情/删除
- `POST /api/channels/{id}/messages` body `{body}` → `{ok, timestamp}` 发消息
- `POST /api/channels/{id}/read` body `{timestamp}` 标记已读
- `GET/POST /api/channels/{id}/members` / `DELETE /api/channels/{id}/members/{memberId}`
- `POST /api/channels/toggle` body `{enabled}`
- `GET /api/dm` / `GET /api/dm/{peerId}` 私信

### 会话对话（多 agent / 电话模式）
- `GET /api/conversations/{id}/agent-activities`
- `GET/POST /api/conversations/{id}/agent-phone-settings`（mode, replyMinChars, proactiveEnabled, modelOverride...）
- `GET /api/conversations/{id}/export`（导出 md）

### 工作台 / 文件
- `GET /api/workbench/content` / `files` / `search` / `upload`
- `POST /api/upload` / `POST /api/upload-blob`
- `GET /api/desk/files` / `desk/search-files` / `desk/jian` / `desk/cron`
- `GET /api/diary/write`
- `POST /api/resource-io/subscribe` body `{purpose, resources:[{kind, mountId, path}]}` → `{subscriptionId}`
- `DELETE /api/resource-io/subscriptions/{id}`
- `GET /api/resource-io/events?since=<seq>` → `{events[], latestSequence, stale}`

### 模型 / 设置
- `GET /api/models` / `POST /api/models/set` / `switch`
- `GET /api/models/auxiliary-vision`
- `GET/POST /api/preferences/models` / `session-permission-default` / `sidebar-ui` / `workspace-ui-state`
- `GET/POST /api/session-thinking-level`
- `GET /api/session-permission-mode`

### 其他
- `GET /api/agents` / `GET /api/agents/{id}/avatar`
- `GET /api/avatar/user`
- `GET /api/skills` / `POST /api/skills/install`
- `GET /api/mcp/connectors/{id}` / `mcp/session-permissions` / `mcp/state`
- `GET /api/health`
- `GET /api/input-drafts`
- `POST /api/diary/write`
- `GET /api/session-projects`（项目/文件夹结构）
- `GET /api/studio/workspaces` / `{id}`
- `POST /api/confirm/{id}`（确认动作）
- `POST /api/workbench/actions`
- `GET /api/commands` / `POST /api/commands/{id}`
- `GET /api/config/workspaces/recent`
- `GET /api/browser/session-states` / `open-session` / `close-session`

## 7. 原生客户端最小可行实现建议

**Phase 1（地基）**：
1. `POST /api/web-auth/login`（访问密钥）+ cookie 持久化（ArkTS http 的 cookie 管理）
2. `GET /api/mobile/bootstrap` + `GET /api/sessions`
3. WebSocket：`/api/ws-ticket` → `/ws?wsTicket=` → 收 `session_user_message` / `text_delta` / `turn_end`

**Phase 2（聊天闭环）**：
4. 发送 `{type:"prompt", clientMessageId, text, sessionPath}` + 乐观消息 + `session_user_message` 确认
5. 流式渲染：text_delta 累积 → 按 Block 渲染（text / thinking / mood / tool_group）
6. `resume_stream` 断线恢复（sinceSeq 去重）

**Phase 3（体验）**：
7. 会话列表/搜索/置顶/归档、频道、工作台文件浏览
8. 推送：后台 WS + `notification` 事件 → 本地通知
9. markdown 渲染（ArkUI 自研或三方库）

## 8. 脆弱点与风险

- 无官方 API 文档，端点/字段随版本变化
- `stream_resume` / `sequence` 机制是流式可靠性的关键，原生端必须实现 seq 去重与断线重放
- 消息发送 type（prompt / interject）与 uiContext 结构待实测确认
- 服务端 cookie 有效期未知，401 时需要重新登录
