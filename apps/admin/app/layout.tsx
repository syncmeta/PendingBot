import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: '大绿豆 Admin',
  description: 'PendingBot 后端管理面板',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN" suppressHydrationWarning>
      <body className="min-h-screen bg-background font-sans antialiased">{children}</body>
    </html>
  );
}
