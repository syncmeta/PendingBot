import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { logoutAction } from './login/actions';

export default async function HomePage() {
  const admin = await requireAdmin();

  return (
    <main className="container py-12">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">大绿豆 Admin</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            登录为 <span className="font-medium">{admin.display_name}</span>
            {admin.email && <> ({admin.email})</>}
          </p>
        </div>
        <form action={logoutAction}>
          <button
            type="submit"
            className="rounded-md border border-input px-3 py-1.5 text-sm hover:bg-accent"
          >
            退出
          </button>
        </form>
      </header>

      <section className="mt-12 grid gap-4 sm:grid-cols-2">
        <Card
          href="/audit"
          title="Audit Explorer"
          desc="按 user / bot / task / provider / model 看 token 用量与花费"
        />
        <Card
          href="/arbitrage"
          title="Arbitrage"
          desc="实际花费 vs 若全走 OpenRouter — 看七折省了多少"
        />
        <Card
          href="/providers"
          title="Providers"
          desc="OpenRouter / WorldRouter 等 gateway 启停、密钥引用、健康"
        />
        <Card
          href="/models"
          title="Models"
          desc="canonical 模型注册（slug, capabilities, EOL）"
        />
        <Card
          href="/aliases"
          title="Aliases"
          desc="(model × provider) 映射 + 价格 + 路由权重"
        />
        <Card
          href="/app-stats"
          title="App Stats"
          desc="DAU / 留存 / Bot 排行 / 对话与消息分布（产品侧）"
        />
        <Card href="/users" title="Users & Quota" desc="用户配额、月度预算、异常" comingSoon />
        <Card href="/admin-audit" title="Admin Audit" desc="管理操作留痕（谁、什么、何时）" />
      </section>
    </main>
  );
}

function Card({
  href,
  title,
  desc,
  comingSoon,
}: {
  href: string;
  title: string;
  desc: string;
  comingSoon?: boolean;
}) {
  const inner = (
    <div className="rounded-lg border bg-card p-5 transition hover:border-foreground/30">
      <div className="flex items-center justify-between">
        <h2 className="font-semibold">{title}</h2>
        {comingSoon && (
          <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
            待实现
          </span>
        )}
      </div>
      <p className="mt-1 text-sm text-muted-foreground">{desc}</p>
    </div>
  );
  return comingSoon ? inner : <Link href={href}>{inner}</Link>;
}
