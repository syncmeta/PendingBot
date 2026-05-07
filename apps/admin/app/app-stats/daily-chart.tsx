'use client';

import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

export type DailyPoint = { day: string; value: number };

export function DailyAreaChart({
  data,
  label,
  color = 'hsl(var(--primary))',
}: {
  data: DailyPoint[];
  label: string;
  color?: string;
}) {
  return (
    <ResponsiveContainer width="100%" height={180}>
      <AreaChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" />
        <XAxis dataKey="day" tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))" />
        <YAxis
          tick={{ fontSize: 11 }}
          stroke="hsl(var(--muted-foreground))"
          allowDecimals={false}
        />
        <Tooltip
          contentStyle={{
            background: 'hsl(var(--card))',
            border: '1px solid hsl(var(--border))',
            borderRadius: 6,
            fontSize: 12,
          }}
          formatter={(value: number) => [value, label]}
        />
        <Area
          type="monotone"
          dataKey="value"
          stroke={color}
          fill={color}
          fillOpacity={0.15}
          strokeWidth={2}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
