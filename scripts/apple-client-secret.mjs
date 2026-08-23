#!/usr/bin/env node
// 本地生成 Apple 的 client secret（一个 ES256 签名的 JWT），贴进
// Supabase → Authentication → Providers → Apple → "Secret Key (for OAuth)"。
//
// **为什么有这个脚本**：Supabase 文档页让你去一个纯浏览器端的小工具里生成，
// 那意味着把 `.p8` 私钥粘进一个网页。这把私钥能替我们的团队给任何人签发
// Apple 登录凭据，丢了只能去 Apple 后台吊销重发。所以本地跑。
//
// 零依赖 —— 只用 Node 内置的 `node:crypto`。ES256 = ECDSA / P-256 / SHA-256，
// 签名要的是裸 r‖s（64 字节），对应 `dsaEncoding: 'ieee-p1363'`；Node 默认的
// DER 编码 Apple 是不收的。
//
// 字段依据 Apple —— Creating a client secret：
//   https://developer.apple.com/documentation/AccountOrganizationalDataSharing/creating-a-client-secret
//   header  { alg: "ES256", kid: <Key ID> }
//   payload { iss: <Team ID>, iat, exp, aud: "https://appleid.apple.com", sub: <client_id> }
//   "It's an error to request an expiration time more than 15777000 seconds
//    (six months) in the future, as measured by the clock on Apple's servers."
//
// `sub` 必须是**发起请求时用的那个 client_id**。Mac 端走的是网页 OAuth，
// client_id 是 **Services ID**（不是 App ID）—— 见 docs/apple-web-oauth-research.md 第 4 节。
//
// 自测：node scripts/apple-client-secret.test.mjs

import { createPrivateKey, sign } from 'node:crypto'
import { readFileSync } from 'node:fs'

/** Apple 的硬上限：6 个月。文档原文写死了这个秒数。 */
export const APPLE_MAX_LIFETIME_SECONDS = 15777000
export const APPLE_AUDIENCE = 'https://appleid.apple.com'

const USAGE = `
用法:
  node scripts/apple-client-secret.mjs \\
    --p8 <AuthKey_XXXXXXXXXX.p8 的路径> \\
    --key-id <10 位 Key ID> \\
    --team-id <10 位 Team ID> \\
    --services-id <Services ID，例如 com.pendingname.pendingbot.web> \\
    [--days <有效天数，默认取 Apple 上限 ~182.6 天>]

四个必填项从哪来（对应 docs/apple-web-oauth-research.md 第 6 节）:
  --p8          A-4 步下载的那个文件（只能下一次）
  --key-id      A-4 步那个 Key 的 ID，也写在文件名 AuthKey_<KEYID>.p8 里
  --team-id     Apple Developer 后台右上角的 Team ID
  --services-id A-2 步新建的 Services ID —— **不是** App ID
                （必须和 Supabase 里 Client IDs 的**第一项**逐字相同）

产物走 stdout（只有 JWT 一行），说明和到期日走 stderr，所以可以直接:
  node scripts/apple-client-secret.mjs ... > /tmp/apple-secret.txt
`.trim()

function fail(message) {
  process.stderr.write(`\n✘ ${message}\n\n${USAGE}\n`)
  process.exit(1)
}

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--help' || arg === '-h') {
      process.stderr.write(`${USAGE}\n`)
      process.exit(0)
    }
    if (!arg.startsWith('--')) fail(`不认识的参数: ${arg}`)
    const key = arg.slice(2)
    const value = argv[++i]
    if (value === undefined) fail(`--${key} 后面缺值`)
    out[key] = value
  }
  return out
}

const b64url = (buf) => Buffer.from(buf).toString('base64url')

/**
 * 读 `.p8` 并断言它确实是一把 P-256 的 EC 私钥。
 *
 * 不这么查的话，拿错文件（比如 ASC API 的 key 也叫 AuthKey_*.p8、或者一把
 * RSA key）会一路签出一个格式合法、Apple 却拒收的 token —— 而 Apple 那边的
 * 报错是 `invalid_client`，跟"Services ID 填错了"长得一模一样，能查半天。
 */
export function loadSigningKey(p8Path) {
  let pem
  try {
    pem = readFileSync(p8Path, 'utf8')
  } catch (e) {
    fail(`读不到 .p8: ${p8Path}\n   ${e.message}`)
  }
  let key
  try {
    key = createPrivateKey(pem)
  } catch (e) {
    fail(`${p8Path} 不是一个能解析的私钥（PKCS#8 PEM）\n   ${e.message}`)
  }
  if (key.asymmetricKeyType !== 'ec') {
    fail(`${p8Path} 是 ${key.asymmetricKeyType.toUpperCase()} 私钥，Apple 的 ES256 要的是 EC（P-256）。\n   拿错文件了？Sign in with Apple 的 Key 在 后台 → Keys，不是 App Store Connect 的 API Key。`)
  }
  const curve = key.asymmetricKeyDetails?.namedCurve
  if (curve && curve !== 'prime256v1') {
    fail(`${p8Path} 用的是 ${curve} 曲线，ES256 要求 P-256（prime256v1）。`)
  }
  return key
}

/**
 * 造出并签名 client secret。纯函数（除了签名本身），给自测直接调。
 * @returns {{ jwt: string, header: object, payload: object }}
 */
export function buildClientSecret({ key, keyId, teamId, servicesId, lifetimeSeconds, now }) {
  if (lifetimeSeconds > APPLE_MAX_LIFETIME_SECONDS) {
    fail(`有效期 ${lifetimeSeconds}s 超过 Apple 的上限 ${APPLE_MAX_LIFETIME_SECONDS}s（6 个月）。Apple 会直接拒收。`)
  }
  if (lifetimeSeconds <= 0) fail('有效期必须为正。')

  const iat = Math.floor(now / 1000)
  // header 严格照 Apple 文档的样例，不多塞 `typ` —— 没必要，也就没有猜错的余地。
  const header = { alg: 'ES256', kid: keyId }
  const payload = {
    iss: teamId,
    iat,
    exp: iat + lifetimeSeconds,
    aud: APPLE_AUDIENCE,
    sub: servicesId,
  }

  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`
  // ieee-p1363 = 裸 r‖s（64 字节）。Node 默认输出 DER，JWS 不认。
  const signature = sign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' })

  return { jwt: `${signingInput}.${b64url(signature)}`, header, payload }
}

function main() {
  const args = parseArgs(process.argv.slice(2))

  for (const required of ['p8', 'key-id', 'team-id', 'services-id']) {
    if (!args[required]) fail(`缺 --${required}`)
  }

  const keyId = args['key-id'].trim()
  const teamId = args['team-id'].trim()
  const servicesId = args['services-id'].trim()

  // Apple 的 Key ID / Team ID 都是 10 位。填错了签出来照样是合法 JWT，
  // 但 Apple 只会回一个 `invalid_client`，不告诉你错在哪一项 —— 所以在这里挡。
  if (!/^[A-Z0-9]{10}$/.test(keyId)) fail(`--key-id "${keyId}" 不像 Key ID（应为 10 位大写字母/数字）。`)
  if (!/^[A-Z0-9]{10}$/.test(teamId)) fail(`--team-id "${teamId}" 不像 Team ID（应为 10 位大写字母/数字）。`)
  if (!servicesId.includes('.')) fail(`--services-id "${servicesId}" 不像反向域名形式的标识符。`)

  let lifetimeSeconds = APPLE_MAX_LIFETIME_SECONDS
  if (args.days !== undefined) {
    const days = Number(args.days)
    if (!Number.isFinite(days) || days <= 0) fail(`--days "${args.days}" 不是正数。`)
    lifetimeSeconds = Math.round(days * 86400)
  }

  const key = loadSigningKey(args.p8)
  const now = Date.now()
  const { jwt, payload } = buildClientSecret({ key, keyId, teamId, servicesId, lifetimeSeconds, now })

  const expiresAt = new Date(payload.exp * 1000)
  const days = (lifetimeSeconds / 86400).toFixed(1)

  process.stderr.write(`
✓ client secret 已生成（stdout 里那一行就是，可直接粘进 Supabase）

   Team ID      (iss)  ${payload.iss}
   Key ID       (kid)  ${keyId}
   Services ID  (sub)  ${payload.sub}
   Audience     (aud)  ${payload.aud}

   ⚠️ Services ID 必须和 Supabase → Authentication → Providers → Apple 的
      "Client IDs" 里**第一项**逐字相同，否则 Mac 网页登录会被 Apple 拒
      （报 invalid_client）。iOS 原生登录不受影响。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   🗓  到期时间（${days} 天后 —— Apple 硬上限 6 个月，没法更久）

       本地   ${expiresAt.toLocaleString('sv-SE', { timeZoneName: 'short' })}
       UTC    ${expiresAt.toISOString()}

   **现在就把这个日期记进日历，往前挪两周提醒。**
   到期当天 Mac 端 Apple 登录会毫无预兆地全部失败（iOS 原生登录不受影响，
   它走 JWKS 验签，根本不用这个 secret）。续期 = 用同一把 .p8 重跑本脚本，
   把新 JWT 换进 Supabase，不需要碰 Apple 后台。见 docs/tech-debt.md。
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

`)

  process.stdout.write(`${jwt}\n`)
}

// 被 import 时（自测）不跑 main。
if (import.meta.url === `file://${process.argv[1]}`) main()
