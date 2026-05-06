import { useEffect, useState } from 'react';

// Tiny useState wrapper that persists to localStorage. Keys are
// namespaced under `scroll-lab.` so we don't collide with whatever
// else might be in this origin's storage.
//
// Single-user dev tool, so no merge / conflict handling — last write
// from this tab wins. JSON-encoded; non-serializable values blow up
// at write time.
const NS = 'scroll-lab.';

export function useLocalStorage<T>(key: string, initial: T): [T, (v: T) => void] {
  const fullKey = NS + key;
  const [value, setValue] = useState<T>(() => {
    try {
      const raw = localStorage.getItem(fullKey);
      if (raw === null) return initial;
      return JSON.parse(raw) as T;
    } catch {
      return initial;
    }
  });
  useEffect(() => {
    try {
      localStorage.setItem(fullKey, JSON.stringify(value));
    } catch {
      // quota exceeded or storage disabled — silently ignore
    }
  }, [fullKey, value]);
  return [value, setValue];
}

// Wipe every scroll-lab.* key. Used by the "reset all" button.
export function clearAll(): void {
  const keys: string[] = [];
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.startsWith(NS)) keys.push(k);
  }
  for (const k of keys) localStorage.removeItem(k);
}
