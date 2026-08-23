#!/usr/bin/env node
// scripts/apple-client-secret.mjs 的自测。
//
//     node scripts/apple-client-secret.test.mjs
//
// 生成一把**临时** P-256 私钥（跑完即删，永远不碰真的 .p8），把脚本当子进程
// 跑一遍，再把产出的 JWT 解回来逐条断言。关键的两条是：
//   ① 签名能被对应公钥验过（证明签的是 ES256 裸 r‖s，不是 Node 默认的 DER）；
//   ② 篡改 payload 后验签必须失败（证明第 ① 条不是空断言）。
// 没有第 ② 条的话，一个永远返回 true 的验签也能让第 ① 条过。

import { generateKeyPairSync, verify } from 'node:crypto'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { APPLE_AUDIENCE, APPLE_MAX_LIFETIME_SECONDS } from './apple-client-secret.mjs'

const SCRIPT = fileURLToPath(new URL('./apple-client-secret.mjs', import.meta.url))
const KEY_ID = 'ABC123DEFG'
const TEAM_ID = 'M42BKJN82S'
const SERVICES_ID = 'com.pendingname.pendingbot.web'

let checks = 0
let failures = 0

function ok(cond, what) {
  checks++
  if (cond) return
  failures++
  console.error(`✘ ${what}`)
}

function eq(actual, expected, what) {
  checks++
  if (actual === expected) return
  failures++
  console.error(`✘ ${what}\n    expected: ${JSON.stringify(expected)}\n    actual:   ${JSON.stringify(actual)}`)
}

const decode = (segment) => JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'))
const run = (args) => spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8' })

const dir = mkdtempSync(join(tmpdir(), 'apple-secret-test-'))
try {
  // ── 一把临时的 P-256 私钥，形状和 Apple 发的 .p8 一致（PKCS#8 PEM）────
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  const p8 = join(dir, `AuthKey_${KEY_ID}.p8`)
  writeFileSync(p8, privateKey.export({ type: 'pkcs8', format: 'pem' }))

  // ── 正常路径 ──────────────────────────────────────────────────────────
  const before = Math.floor(Date.now() / 1000)
  const res = run(['--p8', p8, '--key-id', KEY_ID, '--team-id', TEAM_ID, '--services-id', SERVICES_ID])
  const after = Math.floor(Date.now() / 1000)

  eq(res.status, 0, `默认参数应当成功退出（stderr: ${res.stderr?.trim()}）`)

  const jwt = res.stdout.trim()
  const parts = jwt.split('.')
  eq(parts.length, 3, 'JWT 应有 header.payload.signature 三段')

  const [rawHeader, rawPayload, rawSignature] = parts
  const header = decode(rawHeader)
  const payload = decode(rawPayload)

  // header —— 逐字对 Apple 文档的样例
  eq(header.alg, 'ES256', 'header.alg 必须是 ES256')
  eq(header.kid, KEY_ID, 'header.kid 必须是 Key ID')
  eq(Object.keys(header).sort().join(','), 'alg,kid', 'header 不应多出别的字段')

  // payload —— Apple: iss=Team ID, sub=client_id(=Services ID), aud=appleid
  eq(payload.iss, TEAM_ID, 'payload.iss 必须是 Team ID')
  eq(payload.sub, SERVICES_ID, 'payload.sub 必须是 Services ID（不是 App ID）')
  eq(payload.aud, APPLE_AUDIENCE, 'payload.aud 必须是 https://appleid.apple.com')
  ok(payload.iat >= before && payload.iat <= after, `payload.iat 应落在本次运行的时刻区间（得到 ${payload.iat}）`)
  eq(payload.exp - payload.iat, APPLE_MAX_LIFETIME_SECONDS, '默认有效期应正好取 Apple 上限 6 个月')
  eq(Object.keys(payload).sort().join(','), 'aud,exp,iat,iss,sub', 'payload 不应多出别的字段')

  // ① 签名可验 —— 这条同时证明用的是 JWS 要的裸 r‖s 而不是 DER
  const signingInput = Buffer.from(`${rawHeader}.${rawPayload}`)
  const signature = Buffer.from(rawSignature, 'base64url')
  eq(signature.length, 64, 'ES256 签名应为 64 字节裸 r‖s（DER 编码会是 70 上下且长度不定）')
  ok(
    verify('sha256', signingInput, { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature),
    '签名应能被对应公钥验过',
  )

  // ② 反证：篡改 payload 后必须验不过，否则上面那条是空断言
  const tampered = Buffer.from(`${rawHeader}.${rawPayload.slice(0, -1)}X`)
  ok(
    !verify('sha256', tampered, { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature),
    '篡改过的 payload 必须验签失败（证明上一条不是永真）',
  )

  // ── --days 生效，且上限被挡住 ────────────────────────────────────────
  const short = run(['--p8', p8, '--key-id', KEY_ID, '--team-id', TEAM_ID, '--services-id', SERVICES_ID, '--days', '30'])
  eq(short.status, 0, '--days 30 应当成功')
  const shortPayload = decode(short.stdout.trim().split('.')[1])
  eq(shortPayload.exp - shortPayload.iat, 30 * 86400, '--days 30 应产出 30 天有效期')

  const tooLong = run(['--p8', p8, '--key-id', KEY_ID, '--team-id', TEAM_ID, '--services-id', SERVICES_ID, '--days', '200'])
  ok(tooLong.status !== 0, '--days 200 超过 Apple 6 个月上限，必须拒绝而不是签出一个会被拒收的 token')

  // ── 拿错 key 类型必须当场报错，而不是签出个 invalid_client ──────────
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 })
  const rsaPath = join(dir, 'AuthKey_RSA.p8')
  writeFileSync(rsaPath, rsa.privateKey.export({ type: 'pkcs8', format: 'pem' }))
  const wrongKey = run(['--p8', rsaPath, '--key-id', KEY_ID, '--team-id', TEAM_ID, '--services-id', SERVICES_ID])
  ok(wrongKey.status !== 0, 'RSA 私钥必须被拒绝（Apple 的 ES256 只收 P-256 EC）')
  ok(/RSA/.test(wrongKey.stderr), 'RSA 的报错要点明是 key 类型不对')

  // ── 参数校验 ─────────────────────────────────────────────────────────
  ok(run(['--p8', p8, '--key-id', KEY_ID, '--team-id', TEAM_ID]).status !== 0, '缺 --services-id 必须报错')
  ok(
    run(['--p8', p8, '--key-id', 'short', '--team-id', TEAM_ID, '--services-id', SERVICES_ID]).status !== 0,
    '不像 Key ID 的 --key-id 必须被挡（否则只会在 Apple 那边回一个 invalid_client）',
  )
  ok(
    run(['--p8', p8, '--key-id', KEY_ID, '--team-id', TEAM_ID, '--services-id', 'nodots']).status !== 0,
    '不像反向域名的 --services-id 必须被挡',
  )

  // ── 到期日必须真的打印出来（作者要照着记日历）────────────────────────
  ok(/到期时间/.test(res.stderr), 'stderr 里必须写明到期时间')
  ok(res.stderr.includes(new Date(payload.exp * 1000).toISOString()), '打印的 UTC 到期时刻应与 payload.exp 一致')
  eq(res.stdout.trim().split('\n').length, 1, 'stdout 只能有 JWT 一行（方便重定向进文件）')
} finally {
  rmSync(dir, { recursive: true, force: true })
}

console.log(`${failures === 0 ? '✓' : '✘'} ${checks - failures}/${checks} 条断言通过`)
process.exit(failures === 0 ? 0 : 1)
