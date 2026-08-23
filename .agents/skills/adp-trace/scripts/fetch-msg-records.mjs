// 在测试机 docker node:22 里运行：按 SessionId 拉 ADP GetMsgRecord 全量记录。
// 用法: node fetch-msg-records.mjs <sessionId> [sessionId...]
// 需要同目录有 icsuper-admin 的 script/ai/adp-tool-endpoint.mjs，
// 环境变量 AI_ADP_SECRET_ID / AI_ADP_SECRET_KEY / AI_ADP_UNIFIED_APP_KEY。
import { callLegacyLke } from './adp-tool-endpoint.mjs'
import fs from 'node:fs'

const config = {
  secretId: process.env.AI_ADP_SECRET_ID,
  secretKey: process.env.AI_ADP_SECRET_KEY,
  token: '',
  region: 'ap-guangzhou',
}
const appKey = process.env.AI_ADP_UNIFIED_APP_KEY
const sessions = process.argv.slice(2)
if (!sessions.length) {
  console.error('usage: node fetch-msg-records.mjs <sessionId> [sessionId...]')
  process.exit(1)
}

// 先证明 AppKey 属于哪个应用，再解读任何记录。
const who = await callLegacyLke(
  'DescribeRobotBizIDByAppKey', { AppKey: appKey }, config,
)
console.log('appKey belongs to BotBizId:', who.BotBizId)

fs.mkdirSync('./out', { recursive: true })
for (const sessionId of sessions) {
  try {
    const response = await callLegacyLke('GetMsgRecord', {
      Count: 30,
      SessionId: sessionId,
      BotAppKey: appKey,
      Type: 5,
    }, config)
    const records = response?.Records ?? []
    fs.writeFileSync(
      `./out/trace-${sessionId}.json`, JSON.stringify(response, null, 2),
    )
    console.log(`${sessionId}: records=${records.length}`)
  } catch (error) {
    console.log(`${sessionId}: FAILED ${error.message}`)
  }
}
