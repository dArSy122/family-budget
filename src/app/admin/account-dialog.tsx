"use client";

import {
  useEffect,
  useId,
  useRef,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";

type AccountDialogProps = {
  title: string;
  onClose: () => void;
  pending?: boolean;
  danger?: boolean;
  children: ReactNode;
};

const focusableSelector = [
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'a[href]',
  '[tabindex]:not([tabindex="-1"])',
].join(", ");

export function AccountDialog({
  title,
  onClose,
  pending = false,
  danger = false,
  children,
}: AccountDialogProps) {
  const titleId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  const pendingRef = useRef(pending);

  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);

  useEffect(() => {
    const previousFocus =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;

    const previousOverflow = document.body.style.overflow;

    document.body.style.overflow = "hidden";

    const dialog = dialogRef.current;

    const initialFocus = dialog?.querySelector<HTMLElement>(
      'input:not([disabled]):not([type="hidden"]), button:not([disabled])'
    );

    if (initialFocus) {
      initialFocus.focus();
    } else {
      dialog?.focus();
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        if (!pendingRef.current) {
          event.preventDefault();
          closeRef.current();
        }
        return;
      }

      if (event.key !== "Tab") {
        return;
      }

      const container = dialogRef.current;

      if (!container) {
        return;
      }

      const elements = Array.from(
        container.querySelectorAll<HTMLElement>(
          focusableSelector
        )
      ).filter((element) => element.getClientRects().length > 0);

      if (elements.length === 0) {
        event.preventDefault();
        container.focus();
        return;
      }

      const first = elements[0];
      const last = elements[elements.length - 1];
      const active = document.activeElement;

      if (event.shiftKey) {
        if (active === first || !container.contains(active)) {
          event.preventDefault();
          last.focus();
        }
      } else if (
        active === last ||
        !container.contains(active)
      ) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", handleKeyDown);

    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      document.body.style.overflow = previousOverflow;
      previousFocus?.focus();
    };
  }, []);

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4"
      role="presentation"
      onMouseDown={(event) => {
        if (
          event.target === event.currentTarget &&
          !pending
        ) {
          onClose();
        }
      }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className={
          "max-h-[calc(100dvh-2rem)] w-full max-w-lg overflow-y-auto rounded-2xl border bg-zinc-900 p-5 shadow-2xl outline-none sm:p-7 " +
          (danger
            ? "border-red-900"
            : "border-zinc-700")
        }
      >
        <div className="mb-5">
          <h2
            id={titleId}
            className={
              "text-xl font-semibold " +
              (danger
                ? "text-red-400"
                : "text-zinc-100")
            }
          >
            {title}
          </h2>
        </div>

        {children}
      </div>
    </div>,
    document.body
  );
}