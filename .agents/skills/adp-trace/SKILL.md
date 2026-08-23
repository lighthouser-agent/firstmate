---
name: adp-trace
description: >-
  只读获取芯片超人 ADP 平台运行信息：按 webim traceinfo 链接 / sessionid / questionId 拉取
  对话 trace 全量记录（GetMsgRecord，含 AgentThought、工具入出参、token 归因）；读取线上
  Agent prompt、变量绑定、session token 成本。分析 ADP bad case、验证工具调用链、
  或需要把 questionId 换成 providerConversationId 时使用。
---

# ADP 平台只读取数

ID 语义、留存期、questionId→providerConversationId 换取链路的权威参考：
`/Users/chips/ai/firstmate/data/adp-conversation-trace-api-reference.md`。本 skill 只写
那里没有的执行知识。

## 凭据

本项目根目录的 gitignored `.env` 是本机 ADP 工具配置源，在当前安装中路径为 `/Users/chips/ai/firstmate/.env`：

- `AI_ADP_UNIFIED_APP_KEY` → ADP 统一应用 AppKey
- `AI_TOOL_API_KEY` → 工具网关调用密钥
- `AI_TOOL_AUTH_SECRET` → 工具网关鉴权密钥

本机执行需要这些变量的只读命令时，在同一个子 shell 中加载项目 env，不要打印值或把整个文件复制进报告：

```bash
(
  set -a
  # shellcheck disable=SC1091 -- local, gitignored project env
  . /Users/chips/ai/firstmate/.env
  set +a
  command-that-needs-the-project-env
)
```

读取前只检查变量是否存在；本地 `.env` 建议使用 `0600` 权限。
`AI_TOOL_API_KEY` 和 `AI_TOOL_AUTH_SECRET` 只在工具网关命令需要时使用，不要无关地注入 trace 容器。

腾讯云 TC3 凭据仍在测试机 `root@8.159.148.185`（ssh 免密直连）：

- `/data/service/superman-api/.env.eval` → `AI_ADP_SECRET_ID` / `AI_ADP_SECRET_KEY`
- `/data/service/superman-api/.env.ai` → 远端 trace 所需的 `AI_ADP_UNIFIED_APP_KEY` 备用来源

在测试机上运行取数，把结果 JSON scp 回来；凭据值不进报告、不进日志。
测试机宿主 node 因 GLIBC 过旧不可用，统一走 `docker run node:22-bookworm`。

## 拉对话 trace

1. 定位 SessionId。webim 链接 `.../traceinfo?...&recordid=X&sessionid=Y` 中的 `sessionid`
   就是 `GetMsgRecord` 的 `SessionId`，`recordid` 与返回的 `Records[].RecordId` 同形可对位。
   只有业务 questionId（UUID 之外的数字形态 id 也算业务侧）时，按参考文档走管理端
   `GET /admin/ai/internal-retrieval/list?keyword=<questionId>` 换 `providerConversationId`。
2. 把两个文件 scp 到测试机 `/tmp/adp-trace-work/`：icsuper-admin 仓库的
   `script/ai/adp-tool-endpoint.mjs` 和本 skill 的
   [`scripts/fetch-msg-records.mjs`](scripts/fetch-msg-records.mjs)。
3. 运行并取回：

   ```bash
   ssh root@8.159.148.185 'cd /tmp/adp-trace-work && \
     grep -hE "^AI_ADP_(SECRET_ID|SECRET_KEY|UNIFIED_APP_KEY)=" \
       /data/service/superman-api/.env.eval /data/service/superman-api/.env.ai > .envfile && \
     docker run --rm --env-file .envfile -v "$PWD":/work -w /work \
       node:22-bookworm node fetch-msg-records.mjs <sessionId...>'
   scp 'root@8.159.148.185:/tmp/adp-trace-work/out/trace-*.json' <本地目录>
   ssh root@8.159.148.185 'rm -rf /tmp/adp-trace-work'
   ```

   脚本首行输出 `appKey belongs to BotBizId`——先核对它就是目标应用，再解读记录；
   AppKey 指错应用时 GetMsgRecord 只会安静地返回空。

## 读 trace 的两个陷阱

- **同一问题两条 bot 记录、时间戳相差几秒 ≠ 用户追问**：那是后端 MISSING_AGENT_PLAN
  修复重试。2026-08-16（PR #124）起一级修复在**同会话**追加一条 `<system_reminder>`
  纠正消息（同 session 多一对 user/bot 记录），仅二级兜底才换新 ConversationId 并携带
  草稿引用；更早的 trace 则是旧行为——隔离新会话 + `[上一版正文，仅作草稿]` 拼接，且
  禁止再调 AgenticRAGSearch。读 trace 先看时间是否在 8/16 之后再套口径。
- 工具入出参在 `Records[].AgentThought.Procedures[].Debugging.Content`（JSON 字符串）；
  `Name=thought` 的条目是模型思考。`relevanceScore` 两档量纲不同：语义档门槛 0.35、
  纯词法档 0.16，分数 <0.35 的候选必然只有词法证据。

## 其他只读命令（CLI 自带）

在测试机上同法注入环境变量后，`node adp-tool-endpoint.mjs <command>`：

- `describe-agent-prompt` — 线上起始 Agent 的完整 prompt（比对 prompt 快照时用）
- `inspect-agent-bindings` — API 变量与插件绑定
- `describe-session-cost --session <id>` — token 成本安全投影（不含正文）

只用上面这些 Describe/Get 类命令；`apply`、`reconcile-test` 是写路径，取数任务不碰。
