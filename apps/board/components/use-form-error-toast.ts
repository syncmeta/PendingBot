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

/// Same as useFormErrorToast but also fires a success toast when the
/// state's `ok` truthiness flips on. Used by editors that stay on the
/// page after a successful save (markup-editor, web-tool-prices row,
/// grant form, upstream diff) so the user gets the same green
/// acknowledgement those redirect-based forms now get via withFlash.
///
/// Pass a unique `successKey` (e.g. JSON.stringify(state.ok)) when the
/// success payload can repeat — by default we only re-fire on the
/// transition from "no ok" to "ok".
export function useFormToast(
  state: { error?: string | null; ok?: unknown } | undefined | null,
  successMessage: string,
  successKey?: string,
) {
  const { push } = useToast();
  const lastError = useRef<string | null>(null);
  const lastSuccessKey = useRef<string | null>(null);

  useEffect(() => {
    const err = state?.error ?? null;
    if (err) {
      if (lastError.current !== err) {
        lastError.current = err;
        push({ kind: 'error', message: err });
      }
      return;
    }
    lastError.current = null;

    if (!state?.ok) {
      lastSuccessKey.current = null;
      return;
    }
    const key = successKey ?? '_ok';
    if (lastSuccessKey.current === key) return;
    lastSuccessKey.current = key;
    push({ kind: 'success', message: successMessage });
  }, [state, push, successMessage, successKey]);
}
