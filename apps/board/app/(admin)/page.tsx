import Link from 'next/link';

export default function HomePage() {
  return (
    <main className="container py-12">
      <h1 className="text-3xl font-bold tracking-tight">Board</h1>

      <section className="mt-10 grid gap-4 sm:grid-cols-2">
        <Card
          href="/app-stats"
          title="App Stats"
          desc="DAU / 留存 / Bot 排行 / 对话与消息分布（产品侧）"
        />
        <Card
          href="/web-tool-prices"
          title="Web tool prices"
          desc="搜索 / 抓取服务的批发单价（Brave、Tavily、Exa、Firecrawl 等）"
        />
        <Card href="/users" title="Users & Quota" desc="用户配额、月度预算、异常用量" />
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
