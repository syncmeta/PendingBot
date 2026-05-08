'use client';

export function StatusFilter({ value }: { value: string }) {
  return (
    <form className="text-xs">
      <select
        name="status"
        defaultValue={value}
        onChange={(e) => e.currentTarget.form?.requestSubmit()}
        className="rounded-md border border-input bg-background px-2 py-1"
      >
        <option value="enabled">未使用</option>
        <option value="used">已使用</option>
        <option value="disabled">已停用</option>
        <option value="all">全部</option>
      </select>
    </form>
  );
}
