'use client';

import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

export type DailySavings = {
  day: string;
  actual: number;
  counterfactual: number;
};

export function SavingsChart({ data }: { data: DailySavings[] }) {
  return (
    <ResponsiveContainer width="100%" height={260}>
      <BarChart data={data} margin={{ top: 16, right: 16, bottom: 0, left: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" />
        <XAxis dataKey="day" tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))" />
        <YAxis
          tick={{ fontSize: 11 }}
          stroke="hsl(var(--muted-foreground))"
          tickFormatter={(v: number) => `$${v.toFixed(v < 1 ? 3 : 2)}`}
        />
        <Tooltip
          contentStyle={{
            background: 'hsl(var(--card))',
            border: '1px solid hsl(var(--border))',
            borderRadius: 6,
            fontSize: 12,
          }}
          formatter={(value: number, name: string) => [
            `$${Number(value).toFixed(4)}`,
            name === 'actual' ? '实际' : '若全走 OpenRouter',
          ]}
        />
        <Legend
          wrapperStyle={{ fontSize: 12 }}
          formatter={(value) => (value === 'actual' ? '实际' : '若全走 OpenRouter')}
        />
        <Bar dataKey="counterfactual" fill="hsl(var(--muted-foreground))" />
        <Bar dataKey="actual" fill="hsl(var(--primary))" />
      </BarChart>
    </ResponsiveContainer>
  );
}
