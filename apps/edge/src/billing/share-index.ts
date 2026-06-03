// 纯 share-index 数学(DeFi 质押池模型)。见 docs/billing-v2-design.md §9。
// 无 DB / 外部依赖 —— 群钱包(group-wallet.ts)与对账复用这两个函数。
//
// 模型:每笔注资快照当时的 share_index。群消费时 share_index 按比例缩减,
// 所有 active 注资的"我那份"自然按比例缩水,无需逐行 update。退款时
//   share_now = contributed × (当前 share_index / join 时 share_index)
// 早注资者 join 时 index 高 → 当前比值小 → 历史消耗吃得多(公平性)。

/**
 * 一笔注资当前还能退多少 micros(立刻退群的话)。
 * 用 floor(不 round/ceil)确保永不超过池子(丢失的零头留在群里,任何现实规模都可忽略)。
 */
export function computeShareNow(
  contributedPncMicros: number,
  shareIndexAtJoin: number,
  currentShareIndex: number,
): number {
  if (!Number.isFinite(shareIndexAtJoin) || shareIndexAtJoin <= 0) return 0;
  if (!Number.isFinite(currentShareIndex) || currentShareIndex < 0) return 0;
  if (contributedPncMicros <= 0) return 0;
  return Math.max(0, Math.floor(contributedPncMicros * (currentShareIndex / shareIndexAtJoin)));
}

/**
 * 群消费后的新 share_index。池空(newTotal<=0)时重置 1.0,
 * 避免未来注资的退款数学除以约 0。
 */
export function decayShareIndex(oldTotal: number, newTotal: number, oldShareIndex: number): number {
  if (newTotal <= 0) return 1;
  if (oldTotal <= 0) return oldShareIndex;
  return (oldShareIndex * newTotal) / oldTotal;
}
