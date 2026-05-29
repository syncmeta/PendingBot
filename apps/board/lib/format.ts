// Display formatters. All callers receive numbers; nulls/undefined
// degrade to "—" so the table cells don't render the literal string.

export function fmtNumber(n: number | null | undefined): string {
  if (n == null) return '—';
  return new Intl.NumberFormat('en-US').format(Math.round(n));
}

export function fmtTokens(n: number | null | undefined): string {
  if (n == null) return '—';
  if (n < 1000) return String(n);
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10_000 ? 1 : 0) + 'K';
  return (n / 1_000_000).toFixed(n < 10_000_000 ? 2 : 1) + 'M';
}

export function fmtUsd(n: number | string | null | undefined): string {
  if (n == null) return '—';
  const v = typeof n === 'string' ? parseFloat(n) : n;
  if (!Number.isFinite(v)) return '—';
  if (v >= 100) return `$${v.toFixed(2)}`;
  if (v >= 1) return `$${v.toFixed(3)}`;
  return `$${v.toFixed(4)}`;
}

// PND (Pending Name Credit, ∂) — user-facing accounting unit. $1 list
// price = 2700 ∂. DB columns and SQL RPCs still say `*_credits`; that
// stored value IS the PND amount (legacy naming, see usdToPnd() in
// apps/edge/src/lib/billing.ts).
export function fmtPnd(n: number | string | null | undefined): string {
  if (n == null) return '—';
  const v = typeof n === 'string' ? parseFloat(n) : n;
  if (!Number.isFinite(v)) return '—';
  const sign = v < 0 ? '-' : '';
  const abs = Math.abs(Math.round(v));
  return sign + '∂' + new Intl.NumberFormat('en-US').format(abs);
}

// PNC (Pending Name Credits) — billing v2 unit. Stored internally as
// micros (1 PNC = 1_000_000 micros); $1 = 27 PNC. This formats a micros
// value to a human PNC string with 2 decimals.
export function fmtPncMicros(micros: number | string | null | undefined): string {
  if (micros == null) return '—';
  const v = typeof micros === 'string' ? parseFloat(micros) : micros;
  if (!Number.isFinite(v)) return '—';
  const pnc = v / 1_000_000;
  const sign = pnc < 0 ? '-' : '';
  return sign + new Intl.NumberFormat('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Math.abs(pnc)) + ' PNC';
}

export function fmtMs(n: number | null | undefined): string {
  if (n == null) return '—';
  if (n < 1000) return `${Math.round(n)}ms`;
  return `${(n / 1000).toFixed(2)}s`;
}

// "2026-05-01" given a Date or ISO string. Always UTC, since the
// audit_log day buckets are UTC.
export function fmtDay(d: Date | string): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  return date.toISOString().slice(0, 10);
}
