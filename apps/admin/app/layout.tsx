import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Board',
  description: 'Board',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN" suppressHydrationWarning>
      <body className="min-h-screen bg-background font-sans antialiased">{children}</body>
    </html>
  );
}
