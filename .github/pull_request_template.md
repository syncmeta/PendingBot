## 这个 PR 做了什么

<!-- 一两句话。如果有对应的 issue，写 Closes #123。 -->

## 为什么

<!-- 解决的是什么问题。小修（打字错误、明显 bug）可以留空。 -->

## 我跑了什么

<!--
如实填。跑不了的写「跑不了，因为 …」，比假装全绿有用得多。
-->

- [ ] `bun --filter='@pendingbot/edge' run typecheck`
- [ ] `cd apps/edge && ./node_modules/.bin/vitest run`（695 例）
- [ ] `bun run db:definer:test` / `bun run supabase:advisor:test`（改了数据库权限时）
- [ ] `supabase db reset --local` 通过，并重新生成了 `apps/edge/src/db/schema.ts`（改了迁移时）
- [ ] Xcode 编译通过（改了 Swift 时，iOS 和 macOS 两个目标）
- [ ] 跑不了的项目，以及为什么：

## 需要人工验的

<!--
真机签名、OAuth 授权页、推送、扫码、深链、视觉判断 —— 这些自动化盖不住。
列出该验哪些场景；没有就写「无」。
-->

---

- [ ] 我没有在改动里带进任何真实的凭据、账号坐标或个人信息
- [ ] 我同意我的贡献按本仓库的 MIT 许可分发
