'use client';

import { useEffect, useRef } from 'react';
import { useToast } from './toast';

/// Fires an error toast whenever a useActionState's `state.error` flips
/// to a new non-empty value. Avoids re-firing for the same error if the
/// form re-renders without a new submission.
///
/// Used by form pages that already keep inline error display — the toast
/// is a redundant signal so the user notices even if they've scrolled
/// past the inline message.
export function useFormErrorToast(error: string | undefined | null) {
  const { push } = useToast();
  const last = useRef<string | null>(null);
  useEffect(() => {
    if (!error) {
      last.current = null;
      return;
    }
    if (last.current === error) return;
    last.current = error;
    push({ kind: 'error', message: error });
  }, [error, push]);
}
